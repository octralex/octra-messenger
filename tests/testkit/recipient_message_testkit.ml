(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

open Octra_messenger

let get = function Ok value -> value | Error reason -> failwith reason

module Test_generator = struct
  type g = { mutable remaining : string }

  let block = 1
  let create ?time:_ () = { remaining = "" }

  let generate_into ~g buffer ~off length =
    if length > String.length g.remaining then failwith "deterministic test RNG exhausted";
    Bytes.blit_string g.remaining 0 buffer off length;
    g.remaining <- String.sub g.remaining length (String.length g.remaining - length)

  let reseed ~g bytes = g.remaining <- g.remaining ^ bytes
  let accumulate ~g:_ _source = `Acc (fun _ -> ())
  let seeded ~g:_ = true
  let pools = 1
end

type fields = {
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

let to_fields (envelope : Recipient_message.envelope) = {
  codec_version = envelope.codec_version;
  context = envelope.context;
  key_version = envelope.key_version;
  sequence = envelope.sequence;
  sender_epoch = envelope.sender_epoch;
  message_id = envelope.message_id;
  recipient_key_hash = envelope.recipient_key_hash;
  ephemeral_public = envelope.ephemeral_public;
  sender_public = envelope.sender_public;
  sender_instance = envelope.sender_instance;
  signature = envelope.signature;
  ciphertext = envelope.ciphertext;
}

let of_fields fields =
  let buffer = Buffer.create (Recipient_message.header_bytes + String.length fields.context
    + String.length fields.ciphertext) in
  Buffer.add_string buffer "OCMMSG";
  Octra_net.Oce1.put_u16 buffer fields.codec_version;
  Octra_net.Oce1.put_u16 buffer (String.length fields.context);
  Octra_net.Oce1.put_u32_int buffer (String.length fields.ciphertext);
  Octra_net.Oce1.put_u32_int buffer fields.key_version;
  Octra_net.Oce1.put_u64 buffer fields.sequence;
  Octra_net.Oce1.put_u64 buffer fields.sender_epoch;
  Buffer.add_string buffer fields.message_id;
  Buffer.add_string buffer fields.ephemeral_public;
  Buffer.add_string buffer fields.sender_public;
  Buffer.add_string buffer fields.sender_instance;
  Buffer.add_string buffer fields.signature;
  Buffer.add_string buffer fields.context;
  Buffer.add_string buffer fields.ciphertext;
  Recipient_message.decode (Buffer.contents buffer)

let seal ~recipient_view_public ~sender_secret ~context ~key_version ?(sequence = 1L)
    ?sender_epoch ~sender_instance ~message_id ~ephemeral_secret ~nonce ~policy ~current_epoch plaintext =
  let sender_epoch = Option.value ~default:current_epoch sender_epoch in
  if String.length message_id <> 16 then invalid_arg "test message id must be 16 bytes";
  if String.length ephemeral_secret <> 32 then invalid_arg "test ephemeral secret must be 32 bytes";
  if String.length nonce <> 12 then invalid_arg "test nonce must be 12 bytes";
  let generator = Mirage_crypto_rng.create
    ~seed:(Octra_net.Oce1.encode (fun buffer ->
      Octra_net.Oce1.put_string buffer "octra:test:rng-seed:v2";
      List.iter (Octra_net.Oce1.put_bytes buffer) [message_id; ephemeral_secret; nonce]))
    (module Test_generator) in
  Mirage_crypto_rng.set_default_generator generator;
  Fun.protect ~finally:Mirage_crypto_rng.unset_default_generator (fun () ->
    Recipient_message.seal ~recipient_view_public ~sender_secret ~context ~key_version
      ~sequence ~sender_epoch ~sender_instance ~policy ~current_epoch plaintext)

let open_envelope = Recipient_message.open_envelope_detailed

let resign ~sender_secret envelope =
  let fields = to_fields envelope in
  let signature = Mirage_crypto_ec.Ed25519.sign ~key:sender_secret
    (Recipient_message.authentication_payload envelope) in
  of_fields { fields with signature }

let x25519_from_seed seed =
  let raw_secret, view_public = match Mirage_crypto_ec.X25519.secret_of_octets seed with
    | Ok pair -> pair
    | Error _ -> failwith "invalid X25519 test seed" in
  let json = `Assoc [
    "key_type", `String Recipient_keys.key_type;
    "view_secret", `String (Base64.encode_exn (Mirage_crypto_ec.X25519.secret_to_octets raw_secret));
    "view_public", `String (Base64.encode_exn view_public);
  ] in
  get (Recipient_keys.of_yojson json), view_public
