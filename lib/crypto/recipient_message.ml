(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type envelope = Recipient_message_core.envelope = private {
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

type receive = codec_version:int ->
  context:string ->
  recipient_view_public:string ->
  sender_public:string ->
  sender_instance:string ->
  key_version:int ->
  sequence:int64 ->
  sender_epoch:int64 ->
  freshness:Freshness.t ->
  plaintext:string ->
  (unit, string) result

let current_version = Recipient_message_core.current_version
let header_bytes = Recipient_message_core.header_bytes
let max_envelope_bytes = Recipient_message_core.max_envelope_bytes
let default_max_receive_bytes = Recipient_message_core.default_max_receive_bytes
let max_ciphertext_bytes = Recipient_message_core.max_ciphertext_bytes
let max_plaintext_bytes = Recipient_message_core.max_plaintext_bytes
let max_key_version = Recipient_message_core.max_key_version
let replay_window = Recipient_message_core.replay_window
let make_context = Recipient_message_core.make_context
let recipient_key_hash = Recipient_message_core.recipient_key_hash
let encode = Recipient_message_core.encode
let decode = Recipient_message_core.decode
let associated_payload = Recipient_message_core.associated_payload
let authentication_payload = Recipient_message_core.authentication_payload
let verify_envelope = Recipient_message_core.verify_envelope
let seal = Recipient_message_core.seal

let open_envelope ?max_receive_bytes ~recipient_view_secret ~expected_sender_address
    ~sender_public_for_address ~context ~key_version ~policy ~freshness ~receive raw =
  match Recipient_message_core.open_envelope ?max_receive_bytes ~recipient_view_secret
    ~expected_sender_address ~sender_public_for_address ~context ~key_version ~policy ~freshness ~receive raw with
  | Ok plaintext -> Ok plaintext
  | Error _ -> Error "rejected"

let open_envelope_detailed = Recipient_message_core.open_envelope
