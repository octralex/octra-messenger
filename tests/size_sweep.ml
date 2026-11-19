(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

open Octra_messenger
open Octra_messenger_testkit

let get = function Ok value -> value | Error reason -> failwith reason
let b64_bytes value = String.length (Base64.encode_exn value) + 2

let measure thunk =
  let before = Gc.allocated_bytes () in
  let started = Unix.gettimeofday () in
  let value = thunk () in
  (Unix.gettimeofday () -. started) *. 1000., value, Gc.allocated_bytes () -. before

let timed thunk =
  let started = Unix.gettimeofday () in
  let value = thunk () in
  (Unix.gettimeofday () -. started) *. 1000., value

let median values =
  let values = List.sort compare values in
  let length = List.length values in
  if length = 0 then 0. else List.nth values (length / 2)

let maximum values = List.fold_left max 0. values
let f value = Printf.sprintf "%.3f" value

let context = Recipient_message.make_context ~chain_id:"octra-fakenet-kimi-msgnet"
  ~application:"onchain-messenger" ~registry:"native-spike-registry" ~format_version:1 ~suite:1
let current_epoch = 10L
let policy = Octra_core.Circle_key_policy.{activate_after_epoch = None; expire_after_epoch = None; revoked = false; erased = false}

let utf8_text length =
  let alphabet = [|"a"; "é"; "λ"; "水"; "🙂"|] in
  let buffer = Buffer.create length in
  let index = ref 0 in
  while Buffer.length buffer + 4 <= length do
    Buffer.add_string buffer alphabet.(!index mod Array.length alphabet);
    incr index
  done;
  let suffix = match length - Buffer.length buffer with
    | 0 -> "" | 1 -> "a" | 2 -> "é" | 3 -> "水"
    | _ -> assert false in
  Buffer.add_string buffer suffix;
  Buffer.contents buffer

let plaintext kind length =
  match kind with
  | "ascii" -> String.init length (fun index -> Char.chr (index mod 95 + 32))
  | "utf8" ->
    let text = utf8_text length in
    if not (String.is_valid_utf_8 text) then failwith "invalid UTF-8 fixture" else text
  | "repeat" -> String.make length 'A'
  | "random" ->
    let state = Random.State.make [|length; 42|] in
    String.init length (fun _ -> Char.chr (Random.State.int state 256))
  | "zeros" -> String.init length (fun index -> if index mod 17 = 0 then '\000' else 'Z')
  | _ -> String.init length (fun index -> Char.chr (index land 255))

let measure_recipient kind length =
  let recipient_view_secret, recipient_view_public = Recipient_message_testkit.x25519_from_seed
    (Octra_net.Hash_domain.hash_encoded "octra:test:size:view-seed:v2" (fun _ -> ())) in
  let sender_secret = get (Mirage_crypto_ec.Ed25519.priv_of_octets
    (Octra_net.Hash_domain.hash_encoded "octra:test:size:sender-seed:v2" (fun _ -> ()))
    |> Result.map_error (fun _ -> "invalid Ed25519 test seed")) in
  let sender_public = Mirage_crypto_ec.Ed25519.(pub_of_priv sender_secret |> pub_to_octets) in
  let message_id = Octra_net.Hash_domain.hash_encoded "octra:test:size:message-id:v2" (fun buffer ->
    Octra_net.Oce1.put_bytes buffer kind;
    Octra_net.Oce1.put_bytes buffer (string_of_int length)) in
  let message_id = String.sub message_id 0 16 in
  let ephemeral_secret = Octra_net.Hash_domain.hash_encoded "octra:test:size:ephemeral:v2" (fun buffer ->
    Octra_net.Oce1.put_bytes buffer message_id) in
  let nonce = String.sub (Octra_net.Hash_domain.hash_encoded "octra:test:size:nonce:v2" (fun buffer ->
    Octra_net.Oce1.put_bytes buffer message_id)) 0 12 in
  let text = plaintext kind length in
  let sender_instance = String.sub (Octra_net.Hash_domain.hash_encoded "octra:test:size:sender-instance:v2"
    (fun buffer -> Octra_net.Oce1.put_bytes buffer sender_public)) 0 16 in
  let receive ~codec_version:_ ~context:_ ~recipient_view_public:_ ~sender_public:_ ~sender_instance:_ ~key_version:_
    ~sequence:_ ~sender_epoch:_ ~freshness:_ ~plaintext:_ = Ok () in
  let seal () = get (Recipient_message_testkit.seal ~recipient_view_public ~sender_secret ~context
    ~key_version:1 ~sender_instance ~message_id ~ephemeral_secret ~nonce ~policy ~current_epoch text) in
  let expected_sender_address = Octra_core.Crypto.Address.address_from_pubkey (Base64.encode_exn sender_public) in
  let sender_public_for_address address =
    if String.equal address expected_sender_address then Ok sender_public
    else Error "sender address is not registered" in
  let freshness = Freshness.Live { receiver_epoch = current_epoch } in
  let open_raw raw = get (Recipient_message_testkit.open_envelope ~recipient_view_secret
    ~expected_sender_address ~sender_public_for_address ~context ~key_version:1 ~policy ~freshness ~receive raw) in
  let cold_seal, (_, raw), seal_allocated = measure seal in
  let cold_open, opened, open_allocated = measure (fun () -> open_raw raw) in
  if not (String.equal opened text) then failwith "recipient round trip mismatch";
  let seal_times = ref [] and open_times = ref [] in
  for _ = 1 to 4 do
    let seal_ms, (_, raw), _ = measure seal in
    let open_ms, opened, _ = measure (fun () -> open_raw raw) in
    if not (String.equal opened text) then failwith "recipient warm round trip mismatch";
    seal_times := seal_ms :: !seal_times;
    open_times := open_ms :: !open_times
  done;
  let envelope = get (Recipient_message.decode raw) in
  let allocated = int_of_float (seal_allocated +. open_allocated) in
  [
    "recipient-x25519-aes-gcm"; kind; string_of_int length; "0"; "0"; "0"; "0";
    string_of_int (String.length envelope.Recipient_message.ciphertext);
    string_of_int (String.length raw);
    string_of_int (String.length raw - length);
    string_of_int (b64_bytes raw);
    "unmeasured";
    f cold_seal; f (median !seal_times); f (maximum !seal_times); f (maximum (cold_seal :: !seal_times));
    f cold_open; f (median !open_times); f (maximum !open_times); f (maximum (cold_open :: !open_times));
    "included-in-open"; "included-in-seal"; string_of_int allocated; "pass";
  ]

let columns = [
  "route"; "kind"; "plaintext_bytes"; "slots"; "chunks"; "layers"; "edges";
  "native_bytes"; "envelope_bytes"; "envelope_overhead"; "wire_bytes"; "signed_transaction_bytes";
  "seal_cold_ms"; "seal_warm_median_ms"; "seal_warm_max_ms"; "seal_overall_max_ms";
  "open_cold_ms"; "open_warm_median_ms"; "open_warm_max_ms"; "open_overall_max_ms";
  "verify_median_ms"; "serialize_median_ms"; "allocated_bytes"; "status";
]

let emit row =
  if List.length row <> List.length columns then failwith "size row does not match schema";
  print_endline (String.concat "," row)

let () =
  let view_keygen_ms, _ = timed (fun () -> Recipient_message_testkit.x25519_from_seed
    (Octra_net.Hash_domain.hash_encoded "octra:test:size:view-seed:v2" (fun _ -> ()))) in
  let sender_keygen_ms, _ = timed (fun () -> Mirage_crypto_ec.Ed25519.priv_of_octets
    (Octra_net.Hash_domain.hash_encoded "octra:test:size:sender-seed:v2" (fun _ -> ()))) in
  Printf.printf "# source=8f785a93a4e7392a0f3e65674f9de89854d33dbc profile=native-recipient-v2 samples=5 view_keygen_ms=%.3f sender_keygen_ms=%.3f recipient_view_public_key_bytes=32 recipient_view_public_key_b64_json=46\n%!"
    view_keygen_ms sender_keygen_ms;
  print_endline (String.concat "," columns);
  let lengths = [0; 1; 7; 8; 16; 32; 64; 128; 256; 512; 1024; 2048; 4096; 16384] in
  List.iter (fun length -> emit (measure_recipient "mixed" length)) lengths;
  List.iter (fun (kind, length) -> emit (measure_recipient kind length))
    ["ascii", 64; "utf8", 128; "repeat", 128; "random", 128; "zeros", 128]
