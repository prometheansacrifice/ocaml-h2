(*----------------------------------------------------------------------------
    Copyright (c) 2019 António Nuno Monteiro

    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its
    contributors may be used to endorse or promote products derived from this
    software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
  POSSIBILITY OF SUCH DAMAGE.
  ----------------------------------------------------------------------------*)

open H2

module type Server_intf = sig
  val create_connection_handler
    :  ?config : Config.t
    -> request_handler : Server_connection.request_handler
    -> error_handler : Server_connection.error_handler
    -> (Conduit_mirage.Flow.flow -> unit Lwt.t)
end

module Server : Server_intf

module Server_with_conduit : sig
  include Server_intf

  type t = Conduit_mirage.Flow.flow -> unit Lwt.t

  val connect:
    Conduit_mirage.t ->
    (Conduit_mirage.server -> t -> unit Lwt.t) Lwt.t
end

(* For an example, see [examples/lwt_get.ml]. *)
(* module Client : sig
  val request
    :  ?config : Config.t
    -> Conduit_mirage.Flow.flow
    -> Request.t
    -> error_handler : Client_connection.error_handler
    -> response_handler : Client_connection.response_handler
      -> [`write] Httpaf.Body.t
end *)
