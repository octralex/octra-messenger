(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type envelope = private {
  codec_version : int;
  context : string;
  key_version : int;
  sequence : int64;
  sender_epoch : int64;
  message_id : string;
  recipient_key_hash : string;
  ephemeral_public : string;
  sender_public : string;
  sender_instance : string;
  signature : string;
  ciphertext : string;
}

val current_version : int
val tag : string
val header_bytes : int
val sender_public_offset : int
val max_envelope_bytes : int
val default_max_receive_bytes : int
val max_ciphertext_bytes : int
val max_plaintext_bytes : int
val max_key_version : int
val replay_window : int

val make_context :
  chain_id:string -> application:string -> registry:string ->
  format_version:int -> suite:int -> string

val recipient_key_hash : string -> string
val encode : envelope -> (string, string) result
val decode : string -> (envelope, string) result
val associated_payload : envelope -> string
val authentication_payload : envelope -> string

val seal :
  recipient_view_public:string ->
  sender_secret:Mirage_crypto_ec.Ed25519.priv ->
  context:string ->
  key_version:int ->
  sequence:int64 ->
  sender_epoch:int64 ->
  sender_instance:string ->
  policy:Octra_core.Circle_key_policy.t ->
  current_epoch:int64 ->
  string ->
  (envelope * string, string) result

val verify_envelope :
  expected_sender_public:string -> envelope -> (unit, string) result

val open_envelope :
  ?max_receive_bytes:int ->
  recipient_view_secret:Recipient_keys.t ->
  expected_sender_address:string ->
  sender_public_for_address:(string -> (string, string) result) ->
  context:string ->
  key_version:int ->
  policy:Octra_core.Circle_key_policy.t ->
  freshness:Freshness.t ->
  receive:(codec_version:int ->
    context:string ->
    recipient_view_public:string ->
    sender_public:string ->
    sender_instance:string ->
    key_version:int ->
    sequence:int64 ->
    sender_epoch:int64 ->
    freshness:Freshness.t ->
    plaintext:string ->
    (unit, string) result) ->
  string ->
  (string, string) result
