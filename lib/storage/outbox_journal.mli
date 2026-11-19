(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

val prepare :
  codec_version:int -> context:string -> recipient_view_public:string ->
  key_version:int -> sender_public:string -> directory:string ->
  seal:(sender_instance:string -> sequence:int64 -> Recipient_message.envelope * string) ->
  Recipient_message.envelope * string * string

val last_usable_sequence : int64

val recover :
  codec_version:int -> context:string -> recipient_view_public:string ->
  key_version:int -> sender_public:string -> directory:string ->
  observed_high_water:int64 -> (unit, string) result

val pending : string -> Yojson.Safe.t list
val retry_bytes : directory:string -> record_id:string -> (string, string) result
val mark : directory:string -> record_id:string -> status:string -> (unit, string) result
