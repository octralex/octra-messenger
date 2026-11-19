(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

val max_records : int
val max_inbox_bytes : int
val max_records_per_sender : int
val max_inbox_bytes_per_sender : int
val window_slots : int

val state_path : string -> string
val window_key :
  codec_version:int -> context:string -> recipient_view_public:string ->
  key_version:int -> sender_public:string -> sender_instance:string -> string
val replay_key :
  codec_version:int -> context:string -> recipient_view_public:string ->
  key_version:int -> sender_public:string -> sender_instance:string ->
  sequence:int64 -> sender_epoch:int64 -> string

val write_json_atomic : ?fail_after_temp_write:string -> string -> Yojson.Safe.t -> unit

val commit_receive :
  ?fail_after_temp_write:string -> ?crash_after_rename:string ->
  directory:string -> codec_version:int -> context:string ->
  recipient_view_public:string -> sender_public:string -> sender_instance:string ->
  key_version:int -> sequence:int64 -> sender_epoch:int64 ->
  freshness:Freshness.t -> dedup_retained:(int -> bool) -> plaintext:string -> unit ->
  (unit, string) result

val state_hash : string -> string
val record_counts : string -> int * int
