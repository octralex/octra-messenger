(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

module Oce1 = Octra_net.Oce1
module Hash_domain = Octra_net.Hash_domain

type envelope = {
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

let ( let* ) = Result.bind
let current_version = 2
let tag = "OCMMSG"
let max_context_bytes = 512
let max_key_version = 0xffff_ffff
let header_bytes = 194
let sender_public_offset = 82
let max_envelope_bytes = 3_000_000
let default_max_receive_bytes = 65_536
let max_ciphertext_bytes = max_envelope_bytes - header_bytes - max_context_bytes
let max_plaintext_bytes = max_ciphertext_bytes - 28
let replay_window = 1024

let make_context ~chain_id ~application ~registry ~format_version ~suite =
  match Session_context.encode
    (Session_context.make ~chain_id ~application ~registry ~format_version ~suite) with
  | Ok context -> context
  | Error reason -> invalid_arg reason

let recipient_key_hash view_public =
  Hash_domain.hash_encoded "octra:msg:view-hash:v2" (fun buffer -> Oce1.put_bytes buffer view_public)

let validate (envelope : envelope) =
  if envelope.codec_version <> current_version then
    Error (Printf.sprintf "unsupported version %d" envelope.codec_version)
  else if String.length envelope.context = 0 || String.length envelope.context > max_context_bytes then
    Error "context outside limits"
  else if envelope.key_version <= 0 || Int64.of_int envelope.key_version > 0xffff_ffffL then
    Error "key version outside uint32"
  else if envelope.sequence <= 0L then Error "sender sequence outside limits"
  else if envelope.sender_epoch < 0L then Error "sender epoch outside limits"
  else if String.length envelope.message_id <> 16 then Error "message id must be 16 bytes"
  else if String.length envelope.recipient_key_hash <> 0 && String.length envelope.recipient_key_hash <> 32 then
    Error "recipient key hash is not canonical"
  else if String.length envelope.ephemeral_public <> 32 then Error "ephemeral key must be 32 bytes"
  else if String.length envelope.sender_public <> 32 then Error "sender key must be 32 bytes"
  else if String.length envelope.sender_instance <> Message_channel.instance_bytes then
    Error "sender instance must be 16 bytes"
  else if String.length envelope.signature <> 64 then Error "signature must be 64 bytes"
  else if String.length envelope.ciphertext < 28 || String.length envelope.ciphertext > max_ciphertext_bytes then
    Error "ciphertext outside limits"
  else if header_bytes + String.length envelope.context + String.length envelope.ciphertext > max_envelope_bytes then
    Error "envelope exceeds admission cap"
  else Ok ()

let encode_v2 (envelope : envelope) =
  let buffer = Buffer.create (header_bytes + String.length envelope.context + String.length envelope.ciphertext) in
  Buffer.add_string buffer tag;
  Oce1.put_u16 buffer envelope.codec_version;
  Oce1.put_u16 buffer (String.length envelope.context);
  Oce1.put_u32_int buffer (String.length envelope.ciphertext);
  Oce1.put_u32_int buffer envelope.key_version;
  Oce1.put_u64 buffer envelope.sequence;
  Oce1.put_u64 buffer envelope.sender_epoch;
  Buffer.add_string buffer envelope.message_id;
  Buffer.add_string buffer envelope.ephemeral_public;
  Buffer.add_string buffer envelope.sender_public;
  Buffer.add_string buffer envelope.sender_instance;
  Buffer.add_string buffer envelope.signature;
  Buffer.add_string buffer envelope.context;
  Buffer.add_string buffer envelope.ciphertext;
  Buffer.contents buffer

let encode (envelope : envelope) =
  if envelope.codec_version <> current_version then Error "writer only supports version 2"
  else Ok (encode_v2 envelope)

let decode_v2 text cursor =
  let length = String.length text in
  let version = current_version in
  if length < header_bytes then Error "envelope truncated"
  else
    let context_length = Oce1.get_u16 cursor in
    let ciphertext_length = Oce1.get_u32_int cursor in
    let key_version = Int64.to_int (Int64.logand (Int64.of_int (Oce1.get_u32_int cursor)) 0xffff_ffffL) in
    let sequence = Oce1.get_u64 cursor in
    let sender_epoch = Oce1.get_u64 cursor in
    let message_id = Oce1.get_raw cursor 16 in
    let ephemeral_public = Oce1.get_hash32 cursor in
    let sender_public = Oce1.get_hash32 cursor in
    let sender_instance = Oce1.get_raw cursor Message_channel.instance_bytes in
    let signature = Oce1.get_sig64 cursor in
    if context_length = 0 || context_length > max_context_bytes then Error "context outside limits"
    else if ciphertext_length < 28 || ciphertext_length > max_ciphertext_bytes then
      Error "ciphertext outside limits"
    else if length <> header_bytes + context_length + ciphertext_length then
      Error "envelope trailing or truncated bytes"
    else
      let context = Oce1.get_raw cursor context_length in
      let ciphertext = Oce1.get_raw cursor ciphertext_length in
      if Oce1.remaining cursor <> 0 then Error "envelope trailing or truncated bytes"
      else
        let envelope : envelope = {
          codec_version = version;
          context;
          key_version;
          sequence;
          sender_epoch;
          message_id;
          recipient_key_hash = "";
          ephemeral_public;
          sender_public;
          sender_instance;
          signature;
          ciphertext;
        } in
        validate envelope |> Result.map (fun () -> envelope)

let decode text =
  if String.length text < 8 then Error "envelope truncated"
  else if not (String.equal (String.sub text 0 6) tag) then Error "unsupported envelope type"
  else
    let cursor = Oce1.make_cursor text in
    ignore (Oce1.get_raw cursor 6);
    match Oce1.get_u16 cursor with
    | 2 -> decode_v2 text cursor
    | version -> Error (Printf.sprintf "unsupported version %d" version)

let write_signed_fields buffer (envelope : envelope) =
  Oce1.put_raw buffer tag;
  Oce1.put_u16 buffer envelope.codec_version;
  Oce1.put_u16 buffer (String.length envelope.context);
  Oce1.put_u32_int buffer (String.length envelope.ciphertext);
  Oce1.put_u32_int buffer envelope.key_version;
  Oce1.put_u64 buffer envelope.sequence;
  Oce1.put_u64 buffer envelope.sender_epoch;
  Oce1.put_raw buffer envelope.message_id;
  Oce1.put_hash32 buffer envelope.ephemeral_public;
  Oce1.put_hash32 buffer envelope.sender_public;
  Oce1.put_raw buffer envelope.sender_instance;
  Oce1.put_bytes buffer envelope.context

let associated_payload (envelope : envelope) =
  Hash_domain.hash_encoded "octra:msg:ad:v2" (fun buffer -> write_signed_fields buffer envelope)

let authentication_payload (envelope : envelope) =
  Hash_domain.hash_encoded "octra:msg:sig:v2" (fun buffer ->
    write_signed_fields buffer envelope;
    Oce1.put_bytes buffer envelope.ciphertext)

let hmac ~key message = Digestif.SHA256.hmac_string ~key message |> Digestif.SHA256.to_raw_string

let encode_kdf_fields label fields =
  Oce1.encode (fun buffer ->
    Oce1.put_string buffer label;
    List.iter (Oce1.put_bytes buffer) fields)

let hkdf ~label ~ikm ~salt_fields ~info_fields =
  let salt = encode_kdf_fields (label ^ ":salt") salt_fields in
  let prk = hmac ~key:salt ikm in
  let info = encode_kdf_fields label info_fields in
  hmac ~key:prk (info ^ "\001")

let derive_key shared recipient_key_hash ephemeral_public view_public context sequence sender_epoch sender_instance =
  let fields = [recipient_key_hash; ephemeral_public; view_public; context;
    Oce1.encode (fun buffer -> Oce1.put_u64 buffer sequence);
    Oce1.encode (fun buffer -> Oce1.put_u64 buffer sender_epoch);
    sender_instance] in
  hkdf ~label:"octra:msg:kdf:v2" ~ikm:shared ~salt_fields:fields ~info_fields:fields

let seal ~recipient_view_public ~sender_secret ~context ~key_version ~sequence ~sender_epoch
    ~sender_instance ~policy ~current_epoch plaintext =
  let* () =
    if not (Octra_core.Circle_key_policy.live policy current_epoch) then Error "recipient key policy is not live"
    else if String.length plaintext > max_plaintext_bytes then Error "plaintext outside limits"
    else if key_version <= 0 || Int64.of_int key_version > 0xffff_ffffL then Error "key version outside uint32"
    else if sequence <= 0L then Error "sender sequence outside limits"
    else if sender_epoch < 0L then Error "sender epoch outside limits"
    else if String.length sender_instance <> Message_channel.instance_bytes then
      Error "sender instance must be 16 bytes"
    else Ok () in
  let message_id = Mirage_crypto_rng.generate 16 in
  let ephemeral_secret, _ = Octra_core.Crypto.StealthAddress.generate_ephemeral () in
  let nonce = Mirage_crypto_rng.generate 12 in
  let* _, ephemeral_public = Mirage_crypto_ec.X25519.secret_of_octets ephemeral_secret
    |> Result.map_error (fun _ -> "invalid ephemeral secret") in
  let recipient_key_hash = recipient_key_hash recipient_view_public in
  let* shared = Octra_core.Crypto.StealthAddress.ecdh_shared_secret ephemeral_secret recipient_view_public in
  let key = Mirage_crypto.AES.GCM.of_secret
    (derive_key shared recipient_key_hash ephemeral_public recipient_view_public context sequence sender_epoch
      sender_instance) in
  let sender_public = Mirage_crypto_ec.Ed25519.(pub_of_priv sender_secret |> pub_to_octets) in
  let unsigned : envelope = {
    codec_version = current_version;
    context;
    key_version;
    sequence;
    sender_epoch;
    message_id;
    recipient_key_hash;
    ephemeral_public;
    sender_public;
    sender_instance;
    signature = String.make 64 '\000';
    ciphertext = String.make (String.length plaintext + 28) '\000';
  } in
  let adata = associated_payload unsigned in
  let ciphertext = nonce ^ Mirage_crypto.AES.GCM.authenticate_encrypt ~key ~nonce ~adata plaintext in
  let unsigned = { unsigned with ciphertext } in
  let signature = Mirage_crypto_ec.Ed25519.sign ~key:sender_secret (authentication_payload unsigned) in
  let envelope = { unsigned with signature } in
  let* () = validate envelope in
  Ok (envelope, encode_v2 envelope)

let verify_envelope ~expected_sender_public (envelope : envelope) =
  let* public_key = Mirage_crypto_ec.Ed25519.pub_of_octets expected_sender_public
    |> Result.map_error (fun _ -> "sender public key invalid") in
  if Mirage_crypto_ec.Ed25519.verify ~key:public_key envelope.signature
    ~msg:(authentication_payload envelope)
  then Ok ()
  else Error "sender authentication failed"

let open_envelope ?(max_receive_bytes = default_max_receive_bytes) ~recipient_view_secret
    ~expected_sender_address ~sender_public_for_address ~context ~key_version ~policy ~freshness ~receive raw =
  let recipient_view_public = Recipient_keys.public_of_secret recipient_view_secret in
  let recipient_view_secret = Recipient_keys.secret_to_octets recipient_view_secret in
  let* () =
    if String.length raw > max_receive_bytes then Error "envelope exceeds receive limit" else Ok () in
  let* envelope = decode raw in
  let* expected_sender_public = sender_public_for_address expected_sender_address in
  let* () =
    if Octra_core.Crypto.Address.verify_address_pubkey expected_sender_address
      (Base64.encode_exn expected_sender_public) then Ok ()
    else Error "sender address binding failed" in
  let* () = verify_envelope ~expected_sender_public envelope in
  let* () =
    if not (String.equal envelope.sender_public expected_sender_public) then
      Error "sender authentication failed"
    else Ok () in
  let* () =
    if not (String.equal envelope.context context) then Error "wrong chain, application or registry context"
    else Ok () in
  let* () = if envelope.key_version <> key_version then Error "recipient key version mismatch" else Ok () in
  let reference_epoch = Freshness.reference_epoch freshness in
  let* () =
    if not (Octra_core.Circle_key_policy.live policy reference_epoch) then
      Error "recipient key policy is stale"
    else Ok () in
  let* () = Freshness.validate freshness ~sender_epoch:envelope.sender_epoch in
  let* shared = Octra_core.Crypto.StealthAddress.ecdh_shared_secret
    recipient_view_secret envelope.ephemeral_public
    |> Result.map_error (fun _ -> "recipient key exchange failed") in
  let key = Mirage_crypto.AES.GCM.of_secret
    (derive_key shared (recipient_key_hash recipient_view_public)
      envelope.ephemeral_public recipient_view_public envelope.context envelope.sequence envelope.sender_epoch
      envelope.sender_instance) in
  let nonce = String.sub envelope.ciphertext 0 12 in
  let body = String.sub envelope.ciphertext 12 (String.length envelope.ciphertext - 12) in
  let* plaintext =
    match Mirage_crypto.AES.GCM.authenticate_decrypt ~key ~nonce
      ~adata:(associated_payload envelope) body with
    | Some plaintext -> Ok plaintext
    | None -> Error "ciphertext authentication failed" in
  let* () = receive ~codec_version:envelope.codec_version ~context ~recipient_view_public
    ~sender_public:envelope.sender_public ~sender_instance:envelope.sender_instance
    ~key_version:envelope.key_version ~sequence:envelope.sequence ~sender_epoch:envelope.sender_epoch
    ~freshness ~plaintext in
  Ok plaintext
