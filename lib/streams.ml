module StreamsTbl = struct
  include Hashtbl.MakeSeeded (struct
    type t = Stream_identifier.t

    let equal = Stream_identifier.(===)

    let hash i k = Hashtbl.seeded_hash i k
  end)

  let[@inline] find_opt h key =
    try Some (find h key)
    with Not_found -> None
end

module rec PriorityTreeNode : sig
  type root = Root
  type nonroot = NonRoot

  type stream = nonroot node

  and parent =
    Parent: _ node -> parent

  and _ node =
    (* From RFC7540§5.3.1:
         A stream that is not dependent on any other stream is given a stream
         dependency of 0x0. In other words, the non-existent stream 0 forms the
         root of the tree.

       Note:
         We use a GADT because the root of the tree doesn't have an associated
         request descriptor. It has the added advantage of allowing us to
         enforce that all (other) streams in the tree are associated with a
         request descriptor. *)
    | Connection :
        { all_streams : stream StreamsTbl.t
        ; mutable t_last : int
        ; mutable children : PriorityQueue.t
          (* Connection-level flow control window.

             From RFC7540§6.9.1:
               Two flow-control windows are applicable: the stream flow-control
               window and the connection flow-control window. *)
          (* outbound flow control, what we're allowed to send. *)
        ; mutable flow : Settings.WindowSize.t
          (* inbound flow control, what the client is allowed to send. *)
        ; mutable inflow : Settings.WindowSize.t
        } -> root node
    | Stream :
        { reqd : Reqd.t
        ; mutable t_last : int
        ; mutable t : int
        ; mutable priority : Priority.t
        ; mutable parent : parent
        ; mutable children : PriorityQueue.t
          (* Stream-level flow control window. See connection-level above.
             From RFC7540§6.9.1:
               Two flow-control windows are applicable: the stream flow-control
               window and the connection flow-control window. *)
        ; mutable flow : Settings.WindowSize.t
        ; mutable inflow : Settings.WindowSize.t
        } -> nonroot node
end = PriorityTreeNode

and PriorityQueue
  : Psq.S with type k = Int32.t
           and type p = PriorityTreeNode.stream = Psq.Make
  (Int32)
  (struct
    include PriorityTreeNode
    type t = stream

    let compare (Stream { t = t1; _ }) (Stream { t = t2; _ }) =
      compare t1 t2
  end)

include PriorityTreeNode

type t = root node

(* TODO(anmonteiro): change according to SETTINGS_MAX_CONCURRENT_STREAMS? *)
let make_root ?(capacity=128) () =
  Connection
    { t_last = 0
    ; children = PriorityQueue.empty
    ; all_streams = StreamsTbl.create ~random:true capacity
    ; flow = Settings.WindowSize.default_initial_window_size
    ; inflow = Settings.WindowSize.default_initial_window_size
    }

let create ~parent ~initial_window_size reqd =
  Stream
    { reqd
    ; t_last = 0
    ; t = 0
    (* From RFC7540§5.3.5:
         All streams are initially assigned a non-exclusive dependency on
         stream 0x0. Pushed streams (Section 8.2) initially depend on their
         associated stream. In both cases, streams are assigned a default
         weight of 16. *)
    ; priority = Priority.default_priority
    ; parent
    ; children = PriorityQueue.empty
    ; flow = initial_window_size
    ; inflow = initial_window_size
    }

let pq_add stream_id node pq =
  PriorityQueue.add stream_id node pq

let remove_from_parent (Parent parent) id =
  match parent with
  | Connection root ->
    (* From RFC7540§5.3.1:
         A stream that is not dependent on any other stream is given a stream
         dependency of 0x0. In other words, the non-existent stream 0 forms
         the root of the tree. *)
    root.children <- PriorityQueue.remove id root.children
  | Stream stream ->
    stream.children <- PriorityQueue.remove id stream.children

let children: type a. a node -> PriorityQueue.t = function
  | Stream { children; _ } -> children
  | Connection { children; _ } -> children

let stream_id: type a. a node -> int32 = function
  | Connection _ -> Stream_identifier.connection
  | Stream { reqd; _ } -> reqd.id

let set_parent stream_node ~exclusive new_parent =
  let Stream stream = stream_node in
  let Parent new_parent_node = new_parent in
  let stream_id = stream.reqd.id in
  remove_from_parent stream.parent stream_id;
  stream.parent <- new_parent;
  let new_children =
    let new_children = children new_parent_node in
    if exclusive then begin
      (* From RFC7540§5.3.3:
           Dependent streams move with their parent stream if the parent is
           reprioritized. Setting a dependency with the exclusive flag for a
           reprioritized stream causes all the dependencies of the new parent
           stream to become dependent on the reprioritized stream. *)
      stream.children <-
        PriorityQueue.fold (fun k (Stream p as p_node) pq ->
          p.parent <- Parent stream_node;
          PriorityQueue.add k p_node pq)
        stream.children new_children;
      (* From RFC7540§5.3.1:
           An exclusive flag allows for the insertion of a new level of
           dependencies. The exclusive flag causes the stream to become the
           sole dependency of its parent stream, causing other dependencies to
           become dependent on the exclusive stream. *)
      PriorityQueue.sg stream_id stream_node
    end else
      pq_add stream_id stream_node new_children
  in
  begin match new_parent_node with
  | Stream stream -> stream.children <- new_children
  | Connection root -> root.children <- new_children
  end

let would_create_cycle ~new_parent (Stream stream) =
  let rec inner: type a. a node -> bool = function
    | Connection _ -> false
    | Stream { parent = Parent parent; _ }
      when Stream_identifier.(stream_id parent === stream.reqd.id) ->
      true
    | Stream { parent = Parent parent; _ } -> inner parent
  in
  let Parent parent_node = new_parent in
  inner parent_node

let reprioritize_stream (Connection root as t) ~priority stream_node =
  let Stream stream = stream_node in
  let new_parent, new_priority =
    if Stream_identifier.is_connection priority.Priority.stream_dependency then
      (Parent t), priority
    else
      match StreamsTbl.find_opt root.all_streams priority.stream_dependency with
      | Some parent_stream -> (Parent parent_stream), priority
      | None ->
        (* From RFC7540§5.3.1:
             A dependency on a stream that is not currently in the tree — such
             as a stream in the "idle" state — results in that stream being
             given a default priority (Section 5.3.5). *)
        (Parent t), Priority.default_priority
  in
  (* bail early if trying to set the same priority *)
  if not (Priority.equal stream.priority new_priority) then begin
    let { Priority.stream_dependency; exclusive; _ } = new_priority in
    let Parent current_parent_node = stream.parent in
    let current_parent_id = stream_id current_parent_node in
    (* only need to set a different parent if the parent or exclusive status
     * changed *)
    if not Stream_identifier.(stream_dependency === current_parent_id) ||
       exclusive != stream.priority.exclusive then begin
      let Parent new_parent_node = new_parent in
      begin match new_parent_node with
      | Stream new_parent_stream ->
        if would_create_cycle ~new_parent stream_node then begin
          (* From RFC7540§5.3.3:
               If a stream is made dependent on one of its own dependencies, the
               formerly dependent stream is first moved to be dependent on the
               reprioritized stream's previous parent. The moved dependency
               retains its weight. *)
          set_parent new_parent_node ~exclusive:false stream.parent;
          new_parent_stream.priority <-
            { new_parent_stream.priority
            with stream_dependency = current_parent_id
            };
        end;
      | Connection _ ->
        (* The root node cannot be dependent on any other streams, so we don't
         * need to worry about it creating cycles. *)
        ()
      end;
      (* From RFC7540§5.3.1:
           When assigning a dependency on another stream, the stream is added
           as a new dependency of the parent stream. *)
      set_parent stream_node ~exclusive new_parent;
    end;
    stream.priority <- priority;
  end

let add (Connection root as t) ?priority ~initial_window_size reqd =
  let stream = create ~parent:(Parent t) ~initial_window_size reqd in
  StreamsTbl.add root.all_streams reqd.id stream;
  root.children <- pq_add reqd.id stream root.children;
  match priority with
  | Some priority -> reprioritize_stream t ~priority stream
  | None -> ()

let get_node (Connection root) stream_id =
  StreamsTbl.find_opt root.all_streams stream_id

let find t stream_id =
  match get_node t stream_id with
  | Some (Stream { reqd; _ }) -> Some reqd
  | None -> None

let iter (Connection { all_streams; _ }) ~f =
  StreamsTbl.iter (fun _id -> f) all_streams

let allowed_to_transmit (Connection root) (Stream stream) =
  root.flow > 0 && stream.flow > 0

let allowed_to_receive (Connection root) (Stream stream) size =
  size < root.inflow && size < stream.inflow

let requires_output t stream =
  let Stream { reqd; _ } = stream in
  allowed_to_transmit t stream && Reqd.requires_output reqd

let write (Connection root as t) stream_node =
  let (Stream ({reqd;_ } as stream)) = stream_node in
  (* From RFC7540§6.9.1:
       Two flow-control windows are applicable: the stream flow-control
       window and the connection flow-control window. The sender MUST NOT
       send a flow-controlled frame with a length that exceeds the space
       available in either of the flow-control windows advertised by the
       receiver. *)
  if allowed_to_transmit t stream_node then begin
    let allowed_bytes = min root.flow stream.flow in
    let written = Reqd.flush_response_body ~max_bytes:allowed_bytes reqd in
    (* From RFC7540§6.9.1:
         After sending a flow-controlled frame, the sender reduces the space
         available in both windows by the length of the transmitted frame. *)
    root.flow <- root.flow - written;
    stream.flow <- stream.flow - written;
    written
  end else
    0

let update_t stream n =
  let Stream ({ parent = Parent parent; _ } as stream) = stream in
  let tlast_p = match parent with
  | Connection { t_last; _ } -> t_last
  | Stream { t_last; _ } -> t_last
  in
  stream.t <- tlast_p + n * 256 / stream.priority.weight

(* Scheduling algorithm from https://goo.gl/3sSHXJ (based on nghttp2):

   1  def schedule(p):
   2    if stream #p has data to send:
   3      send data for #p, update nsent[p]
   4      return
   5    if #p's queue is empty:
   6      return
   7    pop #i from queue
   8    update t_last[p] = t[i]
   9    schedule(i)
   10   if #i or its descendant is "active":
   11     update t[i] and push it into queue again
   12
   13 schedule(0)
 *)
let flush t =
  let rec schedule: type a. a node -> int * bool = function
    | Connection p ->
      (* The root can never send data. *)
      begin match PriorityQueue.pop p.children with
      | Some ((id, (Stream i as i_node)), children') ->
        p.t_last <- i.t;
        let written, subtree_is_active = schedule i_node in
        if subtree_is_active then begin
          update_t i_node written;
          p.children <- PriorityQueue.add id i_node children'
        end else begin
          (* XXX(anmonteiro): we may not want to remove from the tree right
           * away. *)
          p.children <- children';
        end;
        written, subtree_is_active
      | None ->
        (* Queue is empty, see line 6 above. *)
        0, false
      end
    | Stream p as p_node ->
      if Reqd.requires_output p.reqd then begin
        (* In this branch, flow-control has no bearing on activity, otherwise
         * a flow-controlled stream would be considered inactive (because it
         * can't make progress at the moment) and removed from the priority
         * tree altogether. *)
        let written = write t p_node in
        (* We check for activity again, because the stream may have gone
         * inactive after the call to `write` above. *)
        written, Reqd.requires_output p.reqd
      end else begin
        match PriorityQueue.pop p.children with
        | Some ((id, (Stream i as i_node)), children') ->
          p.t_last <- i.t;
          let written, subtree_is_active = schedule i_node in
          if subtree_is_active then begin
            update_t i_node written;
            p.children <- PriorityQueue.add id i_node children'
          end else begin
            p.children <- children';
          end;
          written, subtree_is_active
        | None ->
          (* Queue is empty, see line 6 above. *)
          0, false
      end
  in
  ignore (schedule t)

let check_flow flow growth flow' =
  (* Check for overflow on 32-bit systems. *)
  (flow' > growth) == (flow > 0) &&
  flow' <= Settings.WindowSize.max_window_size

let add_flow: type a. a node -> int -> bool = fun t growth ->
  match t with
  | Connection ({ flow; _ } as root) ->
    let flow' = flow + growth in
    let valid_flow = check_flow flow growth flow' in
    if valid_flow then root.flow <- flow';
    valid_flow
  | Stream ({ flow; _ } as stream) ->
    let flow' = flow + growth in
    let valid_flow = check_flow flow growth flow' in
    if valid_flow then stream.flow <- flow';
    valid_flow

let add_inflow: type a. a node -> int -> bool = fun t growth ->
  match t with
  | Connection ({ inflow; _ } as root) ->
    let inflow' = inflow + growth in
    let valid_inflow = check_flow inflow growth inflow' in
    if valid_inflow then root.inflow <- inflow';
    valid_inflow
  | Stream ({ inflow; _ } as stream) ->
    let inflow' = inflow + growth in
    let valid_inflow = check_flow inflow growth inflow' in
    if valid_inflow then stream.inflow <- inflow';
    valid_inflow

let deduct_inflow: type a. a node -> int -> unit = fun t size ->
  match t with
  | Connection ({ inflow; _ } as root) ->
    (* no need to check, we verify that the peer is allowed to send. *)
    root.inflow <- inflow - size
  | Stream ({ inflow; _ } as stream) ->
    stream.inflow <- inflow - size

let on_more_output_available t (max_client_stream_id, max_pushed_stream_id) k =
  let Connection root = t in
  let implicitly_close_stream reqd =
    match reqd.Reqd.stream_state with
    | Idle ->
      (* From RFC7540§5.1.1:
           The first use of a new stream identifier implicitly closes all
           streams in the "idle" state that might have been initiated by
           that peer with a lower-valued stream identifier. *)
      Reqd.finish_stream reqd Finished
    | Closed c ->
      (* When a stream completes, i.e. doesn't require more output and enters
       * the `Closed` state, we set a TTL value which represents the number
       * of writer yields that the stream has before it is removed from the
       * connection Hash Table. By doing this we avoid losing some
       * potentially useful information regarding the stream's state at the
       * cost of keeping it around for a little while longer. *)
      if c.ttl = 0 then
        StreamsTbl.remove root.all_streams reqd.id
      else
        c.ttl <- c.ttl - 1
    | _ -> ()
  in
  StreamsTbl.iter (fun id stream_node ->
    let Stream { reqd; _} = stream_node in
    if Stream_identifier.is_request id then begin
      if id < max_client_stream_id then
        implicitly_close_stream reqd;
    end else begin
      if id < max_pushed_stream_id then
        implicitly_close_stream reqd;
    end;
    if requires_output t stream_node then
      Reqd.on_more_output_available reqd k)
    root.all_streams

let pp_hum fmt t =
  let rec pp_hum_inner level fmt t =
    let pp_binding fmt (i, (Stream { children; t; _ })) =
      Format.fprintf fmt
        "\n%s%ld, %d -> [%a]"
        (String.make (level * 2) ' ')
        i
        t
        (pp_hum_inner (level + 1)) children
    in
    PriorityQueue.pp pp_binding fmt t
  in
  pp_hum_inner 0 fmt t