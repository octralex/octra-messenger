(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

val instance_bytes : int

val contact_key :
  codec_version:int -> context:string -> recipient_view_public:string ->
  key_version:int -> sender_public:string -> string

val key :
  codec_version:int -> context:string -> recipient_view_public:string ->
  key_version:int -> sender_public:string -> sender_instance:string -> string
