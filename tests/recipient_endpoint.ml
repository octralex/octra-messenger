(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

open Octra_messenger
open Octra_messenger_testkit

exception Rejection of string

let reject reason = raise (Rejection reason)
let get = function Ok value -> value | Error reason -> reject reason
let b64 = Base64.encode_exn
let unb64 = Base64.decode_exn
let recipient_chain_id = Option.value (Sys.getenv_opt "MESSENGER_RECIPIENT_CHAIN_ID")
  ~default:"octra-fakenet-kimi-msgnet"
let recipient_epoch = match Option.bind (Sys.getenv_opt "MESSENGER_RECIPIENT_EPOCH") int_of_string_opt with
  | Some value when value >= 0 -> value
  | None -> 10
  | Some _ -> reject "invalid recipient epoch"
let detailed_errors = ref false

let read_file path =
  let channel = open_in_bin path in
  let value = In_channel.input_all channel in
  close_in channel;
  value

let write_file ?(perm = 0o600) path value =
  let temporary = path ^ ".tmp" in
  let channel = open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_binary] perm temporary in
  output_string channel value;
  flush channel;
  Unix.fsync (Unix.descr_of_out_channel channel);
  close_out channel;
  Unix.rename temporary path

let write_json ?(perm = 0o600) path json = write_file ~perm path (Yojson.Safe.to_string json ^ "\n")
let read_json path = Yojson.Safe.from_string (read_file path)
let string_field json name = Yojson.Safe.Util.(json |> member name |> to_string)
let bytes_field json name = unb64 (string_field json name)
let int_field json name = Yojson.Safe.Util.(json |> member name |> to_int)
let bool_field json name = Yojson.Safe.Util.(json |> member name |> to_bool)

let optional_i64_field json name =
  match Yojson.Safe.Util.member name json with
  | `Null -> None
  | `String value -> Some (Int64.of_string value)
  | `Int value -> Some (Int64.of_int value)
  | `Intlit value -> Some (Int64.of_string value)
  | _ -> reject ("invalid " ^ name)

let policy_of_json json : Octra_core.Circle_key_policy.t = {
  activate_after_epoch = optional_i64_field json "activate_after_epoch";
  expire_after_epoch = optional_i64_field json "expire_after_epoch";
  revoked = bool_field json "revoked";
  erased = bool_field json "erased";
}

let policy_for_version config version =
  let policies = Yojson.Safe.Util.member "policies" config in
  match Yojson.Safe.Util.member (string_of_int version) policies with
  | `Null -> reject "mandatory key policy is missing for this version"
  | json -> policy_of_json json

let current_epoch_of_json json = Int64.of_int (int_field json "current_epoch")
let context_of_json json = bytes_field json "context"
let public_of_secret secret = Mirage_crypto_ec.Ed25519.(pub_of_priv secret |> pub_to_octets)

let int_list_field json name =
  Yojson.Safe.Util.(json |> member name |> to_list |> List.map to_int)

let registered_view_public config version =
  if version = int_field config "key_version" then bytes_field config "view_public"
  else begin
    let accepted = int_list_field config "accepted_previous_versions" in
    let grace = int_list_field config "grace_previous_versions" in
    if not (List.mem version accepted && List.mem version grace) then
      reject "recipient key version is not accepted";
    match Yojson.Safe.Util.member (string_of_int version)
      (Yojson.Safe.Util.member "previous_view_public" config) with
    | `String value -> unb64 value
    | _ -> reject "recipient key replaced or unregistered"
  end

let ed_secret raw =
  match Mirage_crypto_ec.Ed25519.priv_of_octets raw with
  | Ok key -> key
  | Error _ -> reject "invalid Ed25519 secret"

let contact_secret directory = ed_secret (bytes_field (read_json (Filename.concat directory "contact-secret.json")) "secret")

let sign_config directory config =
  let fields = match config with
    | `Assoc fields -> List.filter (fun (name, _) -> name <> "authorization_signature") fields
    | _ -> reject "contact config must be an object" in
  let fields = List.sort (fun (left, _) (right, _) -> String.compare left right) fields in
  let signature = Mirage_crypto_ec.Ed25519.sign ~key:(contact_secret directory)
    (Octra_net.Hash_domain.hash_encoded "octra:msg:contact-sign:v2" (fun buffer ->
      Octra_net.Oce1.put_bytes buffer (Yojson.Safe.to_string (`Assoc fields)))) in
  match config with
  | `Assoc _ -> `Assoc (fields @ ["authorization_signature", `String (b64 signature)])
  | _ -> assert false

let verify_config ?(config_name = "recipient-public.json") directory =
  let config = read_json (Filename.concat directory config_name) in
  let root = read_json (Filename.concat directory "contact-root.json") in
  let expected_root = bytes_field root "authorization_public" in
  if not (String.equal (bytes_field config "authorization_public") expected_root) then
    reject "contact authorization root mismatch";
  let fields = match config with
    | `Assoc fields -> List.filter (fun (name, _) -> name <> "authorization_signature") fields
    | _ -> reject "contact config must be an object" in
  let fields = List.sort (fun (left, _) (right, _) -> String.compare left right) fields in
  let signature = bytes_field config "authorization_signature" in
  let public_key = match Mirage_crypto_ec.Ed25519.pub_of_octets expected_root with Ok key -> key | Error _ -> reject "contact public key invalid" in
  if not (Mirage_crypto_ec.Ed25519.verify ~key:public_key signature
    ~msg:(Octra_net.Hash_domain.hash_encoded "octra:msg:contact-sign:v2" (fun buffer ->
      Octra_net.Oce1.put_bytes buffer (Yojson.Safe.to_string (`Assoc fields))))) then
    reject "contact authorization failed";
  config

let write_contact_init directory =
  if not (Sys.file_exists (Filename.concat directory "contact-secret.json")) then begin
    let seed = Octra_net.Hash_domain.hash_encoded "octra:test:contact-root:v2" (fun _ -> ()) in
    let secret = ed_secret seed in
    write_json (Filename.concat directory "contact-secret.json")
      (`Assoc ["secret", `String (b64 (Mirage_crypto_ec.Ed25519.priv_to_octets secret))]);
    write_json ~perm:0o644 (Filename.concat directory "contact-root.json")
      (`Assoc ["authorization_public", `String (b64 (public_of_secret secret))])
  end

let sender_init ?(variant = 1) directory =
  let seed = Octra_net.Hash_domain.hash_encoded "octra:test:sender-ed25519:v2" (fun buffer ->
  Octra_net.Oce1.put_bytes buffer (string_of_int variant)) in
  let secret = ed_secret seed in
  write_json (Filename.concat directory "sender-secret.json")
    (`Assoc ["secret", `String (b64 (Mirage_crypto_ec.Ed25519.priv_to_octets secret))]);
  write_json ~perm:0o644 (Filename.concat directory "sender-public.json")
    (`Assoc ["sender_public", `String (b64 (public_of_secret secret))]);
  Printf.printf "{\"status\":\"sender_initialized\",\"sender_public\":\"%s\"}\n%!" (b64 (public_of_secret secret))

let write_recipient_secret directory version =
  Mirage_crypto_rng_unix.use_default ();
  let view_secret, view_public = Recipient_keys.generate () in
  Recipient_keys.write_atomic
    (Filename.concat directory ("recipient-secret-v" ^ string_of_int version ^ ".json")) view_secret;
  view_public

let read_recipient_secret path = get (Recipient_keys.read path)

let policy_json activate expire revoked erased : Yojson.Safe.t =
  `Assoc [
    "activate_after_epoch", `String (Int64.to_string activate);
    "expire_after_epoch", (match expire with Some value -> `String (Int64.to_string value) | None -> `Null);
    "revoked", `Bool revoked;
    "erased", `Bool erased;
  ]

let write_recipient_config directory expected_sender version previous_versions view_public =
  let context = Recipient_message.make_context ~chain_id:recipient_chain_id
    ~application:"onchain-messenger" ~registry:"native-spike-registry" ~format_version:1 ~suite:1 in
  let policies = List.map (fun version ->
    string_of_int version, policy_json 0L None false false) (version :: previous_versions) in
  let previous_view_public =
    let path = Filename.concat directory "recipient-public.json" in
    if not (Sys.file_exists path) then []
    else
      let previous = read_json path in
      let previous_version = string_of_int (int_field previous "key_version") in
      let existing = match Yojson.Safe.Util.member "previous_view_public" previous with
        | `Assoc fields -> fields
        | _ -> [] in
      (previous_version, `String (string_field previous "view_public"))
      :: List.remove_assoc previous_version existing in
  let root = read_json (Filename.concat directory "contact-root.json") in
  let config = `Assoc [
    "view_public", `String (b64 view_public);
    "expected_sender_public", `String (b64 expected_sender);
    "context", `String (b64 context);
    "chain_id", `String recipient_chain_id;
    "application", `String "onchain-messenger";
    "registry", `String "native-spike-registry";
    "format_version", `Int 1;
    "suite", `Int 1;
    "key_version", `Int version;
    "accepted_previous_versions", `List (List.map (fun value -> `Int value) previous_versions);
    "grace_previous_versions", `List (List.map (fun value -> `Int value) previous_versions);
    "previous_view_public", `Assoc previous_view_public;
    "policies", `Assoc policies;
    "current_epoch", `Int recipient_epoch;
    "authorization_public", `String (string_field root "authorization_public");
    "authorization_signature", `String "";
  ] in
  write_json ~perm:0o644 (Filename.concat directory "recipient-public.json") (sign_config directory config)

let recipient_init directory sender_public =
  write_contact_init directory;
  let view_public = write_recipient_secret directory 1 in
  write_recipient_config directory (unb64 sender_public) 1 [] view_public;
  let config = verify_config directory in
  Printf.printf "{\"status\":\"recipient_initialized\",\"view_public\":\"%s\",\"key_version\":1}\n%!"
    (string_field config "view_public")

let rotate_recipient directory =
  let config = verify_config directory in
  let expected_sender = bytes_field config "expected_sender_public" in
  let view_public = write_recipient_secret directory 2 in
  write_recipient_config directory expected_sender 2 [1] view_public;
  let updated = verify_config directory in
  Printf.printf "{\"status\":\"recipient_rotated\",\"view_public\":\"%s\",\"key_version\":2}\n%!"
    (string_field updated "view_public")

let generate_messaging_key directory sender_secret_path =
  Mirage_crypto_rng_unix.use_default ();
  let secret, view_public = Recipient_keys.generate () in
  let derived_public = Recipient_keys.public_of_secret secret in
  if not (String.equal view_public derived_public) then reject "X25519 public key derivation mismatch";
  let view_secret = Recipient_keys.secret_to_octets secret in
  if String.equal view_secret view_public then reject "X25519 secret and public key overlap";
  let sender_raw = bytes_field (read_json sender_secret_path) "secret" in
  let sender_secret = ed_secret sender_raw in
  let wallet_view_secret, wallet_view_public =
    Octra_core.Crypto.StealthAddress.derive_view_keypair (b64 sender_raw) in
  if String.equal view_secret sender_raw
    || String.equal view_secret wallet_view_secret
    || String.equal view_public wallet_view_public
    || String.equal view_public (public_of_secret sender_secret) then
    reject "messaging and signing key namespaces overlap";
  Recipient_keys.write_atomic (Filename.concat directory "messaging-secret.json") secret;
  Printf.printf "{\"status\":\"messaging_key_generated\",\"key_type\":\"x25519\",\"independent_from_ed25519\":true,\"public_matches_secret\":false}\n%!"

let resign_config directory =
  let config = read_json (Filename.concat directory "recipient-public.json") in
  write_json ~perm:0o644 (Filename.concat directory "recipient-public.json") (sign_config directory config)

let test_message_id directory =
  let path = Filename.concat directory "test-counter" in
  let current = if Sys.file_exists path then int_of_string (read_file path) else 0 in
  let next = current + 1 in
  write_file path (string_of_int next);
  String.sub (Octra_net.Hash_domain.hash_encoded "octra:test:message-id:v2" (fun buffer ->
  Octra_net.Oce1.put_bytes buffer (string_of_int next))) 0 16, Int64.of_int next

let test_sender_instance ~context ~recipient_view_public ~key_version ~sender_public =
  String.sub (Octra_net.Hash_domain.hash_encoded "octra:test:sender-instance:v2" (fun buffer ->
    Octra_net.Oce1.put_bytes buffer context;
    Octra_net.Oce1.put_bytes buffer recipient_view_public;
    Octra_net.Oce1.put_u32_int buffer key_version;
    Octra_net.Oce1.put_bytes buffer sender_public)) 0 16

let seal_with_mode ~production ?(initialize_rng = true) ?sequence ?sender_epoch config_path sender_secret_path plaintext_path envelope_path =
  let config = verify_config ~config_name:(Filename.basename config_path) (Filename.dirname config_path) in
  let sender_secret = ed_secret (bytes_field (read_json sender_secret_path) "secret") in
  let sender_public = public_of_secret sender_secret in
  let expected_sender = bytes_field config "expected_sender_public" in
  if not (String.equal sender_public expected_sender) then reject "sender authorization mismatch";
  let plaintext = read_file plaintext_path in
  let key_version = int_field config "key_version" in
  let policy = policy_for_version config key_version in
  let current_epoch = current_epoch_of_json config in
  let context = context_of_json config in
  let recipient_view_public = bytes_field config "view_public" in
  let _, raw, _ =
    if production then begin
      if Option.is_some sequence then invalid_arg "production sequences must come from the outbox";
      if Option.is_some sender_epoch then invalid_arg "production epochs must come from the configured authority";
      if initialize_rng then Mirage_crypto_rng_unix.use_default ();
      let directory = Filename.concat (Filename.dirname sender_secret_path) "outbox" in
      if not (Sys.file_exists directory) then Unix.mkdir directory 0o700;
      let seal ~sender_instance ~sequence =
        get (Recipient_message.seal ~recipient_view_public ~sender_secret ~context ~key_version ~sequence
          ~sender_epoch:current_epoch ~sender_instance ~policy ~current_epoch plaintext) in
      Outbox_journal.prepare ~codec_version:2 ~context ~recipient_view_public ~key_version ~sender_public
        ~directory ~seal
    end else begin
      let message_id, generated_sequence = test_message_id (Filename.dirname plaintext_path) in
      let sequence = Option.value ~default:generated_sequence sequence in
      let sender_instance = test_sender_instance ~context ~recipient_view_public ~key_version ~sender_public in
      let ephemeral_secret = Octra_net.Hash_domain.hash_encoded "octra:test:ephemeral:v2" (fun buffer ->
  Octra_net.Oce1.put_bytes buffer message_id) in
      let nonce = String.sub (Octra_net.Hash_domain.hash_encoded "octra:test:nonce:v2" (fun buffer ->
  Octra_net.Oce1.put_bytes buffer message_id)) 0 12 in
      let envelope, raw = get (Recipient_message_testkit.seal ~recipient_view_public
        ~sender_secret ~context ~key_version ~sequence ~sender_instance ~message_id ~ephemeral_secret ~nonce
        ?sender_epoch ~policy ~current_epoch plaintext) in
      envelope, raw, "test-only"
    end in
  write_file envelope_path raw;
  let envelope = get (Recipient_message.decode raw) in
  Printf.printf "{\"status\":\"sealed\",\"envelope_bytes\":%d,\"ciphertext_bytes\":%d,\"recipient_secret_input\":false}\n%!"
    (String.length raw) (String.length envelope.Recipient_message.ciphertext)

let seal = seal_with_mode ~production:false
let send = seal_with_mode ~production:true
let send_uninitialized config_path sender_secret_path plaintext_path envelope_path =
  Mirage_crypto_rng.unset_default_generator ();
  seal_with_mode ~production:true ~initialize_rng:false config_path sender_secret_path plaintext_path envelope_path

let open_with_mode ~production ?(max_receive_bytes = 3_000_000) ?commit_epoch
    ?fail_after_temp_write ?crash_after_rename secret_path config_path envelope_path output_path =
  let config = verify_config ~config_name:(Filename.basename config_path) (Filename.dirname config_path) in
  let raw = read_file envelope_path in
  let preliminary = get (Recipient_message.decode raw) in
  let version = preliminary.Recipient_message.key_version in
  let registered_view_public = registered_view_public config version in
  let secret_path = Filename.concat (Filename.dirname secret_path)
    ("recipient-secret-v" ^ string_of_int version ^ ".json") in
  let recipient_view_secret = read_recipient_secret secret_path in
  let recipient_view_public = Recipient_keys.public_of_secret recipient_view_secret in
  if not (String.equal registered_view_public recipient_view_public) then
    reject "recipient key replaced or unregistered";
  let context = context_of_json config in
  let freshness = match commit_epoch with
    | Some commit_epoch -> Freshness.Archive { commit_epoch }
    | None -> Freshness.Live { receiver_epoch = current_epoch_of_json config } in
  let dedup_retained candidate =
    let policy = policy_for_version config candidate in
    if policy.Octra_core.Circle_key_policy.erased then false
    else if candidate = int_field config "key_version" then true
    else List.mem candidate (int_list_field config "accepted_previous_versions")
      && List.mem candidate (int_list_field config "grace_previous_versions") in
  let receive ~codec_version ~context:_ ~recipient_view_public:_ ~sender_public ~sender_instance ~key_version:_
    ~sequence ~sender_epoch ~freshness ~plaintext =
    Receive_store.commit_receive ?fail_after_temp_write ?crash_after_rename ~directory:(Filename.dirname secret_path)
      ~codec_version ~context ~recipient_view_public ~sender_public ~sender_instance ~key_version:version
      ~sequence ~sender_epoch ~freshness ~dedup_retained ~plaintext () in
  let opener = if production then Recipient_message.open_envelope else Recipient_message_testkit.open_envelope in
  let expected_sender_public = bytes_field config "expected_sender_public" in
  let expected_sender_address = Octra_core.Crypto.Address.address_from_pubkey (b64 expected_sender_public) in
  let sender_public_for_address address =
    if String.equal address expected_sender_address then Ok expected_sender_public
    else Error "sender address is not registered" in
  let plaintext = get (opener ~max_receive_bytes ~recipient_view_secret
    ~expected_sender_address ~sender_public_for_address
    ~context ~key_version:version ~policy:(policy_for_version config version) ~freshness ~receive raw) in
  write_file output_path plaintext;
  Printf.printf "{\"status\":\"opened\",\"plaintext_bytes\":%d}\n%!" (String.length plaintext)

let open_envelope =
  open_with_mode ~production:true ~max_receive_bytes:Recipient_message.default_max_receive_bytes
let open_test = open_with_mode ~production:false
let open_archive commit_epoch =
  open_with_mode ~production:true ~max_receive_bytes:Recipient_message.default_max_receive_bytes ~commit_epoch
let open_archive_test commit_epoch = open_with_mode ~production:false ~commit_epoch

let corrupt mode envelope_path sender_secret_path output_path =
  let envelope = get (Recipient_message.decode (read_file envelope_path)) in
  let sender_secret = ed_secret (bytes_field (read_json sender_secret_path) "secret") in
  let fields = Recipient_message_testkit.to_fields envelope in
  let fields = match mode with
    | "body" ->
      let ciphertext = String.init (String.length fields.ciphertext)
        (fun index -> Char.chr ((index * 37 + 11) land 255)) in
      { fields with ciphertext }
    | "id" ->
      let message_id = String.init 16 (fun index -> if index = 0 then '\001' else fields.message_id.[index]) in
      { fields with message_id }
    | "ephemeral" ->
      let ephemeral_public = String.init 32 (fun index -> if index = 0 then '\001' else fields.ephemeral_public.[index]) in
      { fields with ephemeral_public }
    | "zero-ephemeral" -> { fields with ephemeral_public = String.make 32 '\000' }
    | "ordinary-ones-ephemeral" -> { fields with ephemeral_public = String.make 32 '\001' }
    | "u-one-ephemeral" ->
      let point = String.init 32 (fun index -> if index = 0 then '\001' else '\000') in
      { fields with ephemeral_public = point }
    | "order-eight-a-ephemeral" ->
      { fields with ephemeral_public = unb64 "4Ot6fDtBuK4WVuP68Z/EatoJjeucMrH9hmIFFl9JuAA=" }
    | "order-eight-b-ephemeral" ->
      { fields with ephemeral_public = unb64 "X5yVvKNQjCSx0LFVnIPvWwREXMRYHI6G2CJO3dCfEVc=" }
    | "low-order-ephemeral" ->
      let ephemeral_public = String.init 32 (fun index ->
        if index = 0 then '\236' else if index = 31 then '\127' else '\255') in
      { fields with ephemeral_public }
    | "p-ephemeral" ->
      let ephemeral_public = String.init 32 (fun index ->
        if index = 0 then '\237' else if index = 31 then '\127' else '\255') in
      { fields with ephemeral_public }
    | "p-plus-one-ephemeral" ->
      let ephemeral_public = String.init 32 (fun index ->
        if index = 0 then '\238' else if index = 31 then '\127' else '\255') in
      { fields with ephemeral_public }
    | "noncanonical-ephemeral" -> { fields with ephemeral_public = String.make 32 '\255' }
    | "version" -> { fields with key_version = fields.key_version + 1 }
    | "context" -> { fields with context = fields.context ^ "|modified" }
    | "future-epoch" -> { fields with sender_epoch = Int64.add fields.sender_epoch 3L }
    | "future-tolerance" -> { fields with sender_epoch = Int64.add fields.sender_epoch 2L }
    | "stale-epoch" -> { fields with sender_epoch = 0L }
    | "sender-instance" ->
      let sender_instance = Bytes.of_string fields.sender_instance in
      Bytes.set sender_instance 0 (Char.chr (Char.code (Bytes.get sender_instance 0) lxor 1));
      { fields with sender_instance = Bytes.to_string sender_instance }
    | _ -> reject "unknown corrupt mode" in
  let mutated = get (Recipient_message_testkit.of_fields fields) in
  let resigned = get (Recipient_message_testkit.resign ~sender_secret mutated) in
  let raw = get (Recipient_message.encode resigned) in
  write_file output_path raw;
  Printf.printf "{\"status\":\"resigned_envelope\",\"mode\":%s}\n" (Yojson.Safe.to_string (`String mode))

let receive_seed ?(high_water = 1L) ?sender directory count key_version =
  let messages = Filename.concat directory "messages" in
  if not (Sys.file_exists messages) then Unix.mkdir messages 0o700;
  write_file (Filename.concat messages "seed.bin") "x";
  let config = read_json (Filename.concat directory "recipient-public.json") in
  let context = context_of_json config in
  let recipient_view_public =
    if key_version = int_field config "key_version" then bytes_field config "view_public"
    else
      match Yojson.Safe.Util.member (string_of_int key_version)
        (Yojson.Safe.Util.member "previous_view_public" config) with
      | `String value -> unb64 value
      | _ -> reject "seed recipient key is not registered" in
  let sender_for index = match sender with
    | Some value -> value
    | None -> b64 ("seed-sender-" ^ string_of_int (index / Receive_store.max_records_per_sender)) in
  let bitmap = Bytes.make 128 '\000' in
  Bytes.set bitmap 0 '\001';
  let windows = match sender with
    | Some value -> [unb64 value]
    | None -> List.init 10 (fun index -> b64 ("seed-sender-" ^ string_of_int index)) in
  let windows = List.map (fun sender_public ->
    let sender_instance = test_sender_instance ~context ~recipient_view_public ~key_version ~sender_public in
    let key = Receive_store.window_key ~codec_version:2 ~context ~recipient_view_public ~key_version ~sender_public
      ~sender_instance in
    `Assoc ["key", `String key; "high_water", `Intlit (Int64.to_string high_water);
      "bitmap", `String (b64 (Bytes.to_string bitmap))]) windows in
  let records = List.init count (fun index ->
    let sender_public = sender_for index in
    let sender_instance = test_sender_instance ~context ~recipient_view_public ~key_version
      ~sender_public:(unb64 sender_public) in
    let key = Receive_store.window_key ~codec_version:2 ~context ~recipient_view_public ~key_version ~sender_public
      ~sender_instance in
    let sequence = Int64.of_int (index + 1) in
    let replay = Receive_store.replay_key ~codec_version:2 ~context ~recipient_view_public ~key_version
      ~sender_public ~sender_instance ~sequence ~sender_epoch:10L in
    `Assoc [
      "replay", `String replay;
      "window", `String key;
      "context", `String (b64 context);
      "recipient_view_public", `String (b64 recipient_view_public);
      "sender_public", `String sender_public;
      "sender_instance", `String (b64 sender_instance);
      "key_version", `Int key_version;
      "sequence", `Intlit (Int64.to_string sequence);
      "sender_epoch", `Intlit "10";
      "path", `String "messages/seed.bin";
      "plaintext_bytes", `Int 1;
      "sha256", `String (Octra_net.Hash_domain.hash_encoded_hex "octra:test:seed-plaintext:v2" (fun buffer ->
  Octra_net.Oce1.put_bytes buffer "x"));
    ]) in
  Receive_store.write_json_atomic (Receive_store.state_path directory)
    (`Assoc ["version", `Int 4; "windows", `List windows; "inbox", `List records]);
  Printf.printf "{\"status\":\"receive_seeded\",\"records\":%d,\"high_water\":%s}\n%!" count (Int64.to_string high_water)

let store_prune_test directory =
  let config = verify_config directory in
  let context = context_of_json config in
  let recipient_view_public = bytes_field config "view_public" in
  let sender_public = bytes_field config "expected_sender_public" in
  let key_version = int_field config "key_version" in
  let current_epoch = current_epoch_of_json config in
  let sender_instance = test_sender_instance ~context ~recipient_view_public ~key_version ~sender_public in
  let freshness = Freshness.Live { receiver_epoch = current_epoch } in
  let commit dedup_retained =
    Receive_store.commit_receive ~directory ~codec_version:2 ~context ~recipient_view_public
      ~sender_public ~sender_instance ~key_version ~sequence:3L ~sender_epoch:current_epoch ~freshness
      ~dedup_retained ~plaintext:"pruned" () in
  get (commit (fun _ -> true));
  let after_first = Receive_store.state_hash directory in
  match commit (fun _ -> false) with
  | Ok () -> reject "replay after pruning accepted"
  | Error "replay rejected" ->
    if not (String.equal after_first (Receive_store.state_hash directory)) then
      reject "replay rejection changed receive state";
    Printf.printf "{\"status\":\"expected_replay_rejected\",\"state_unchanged\":true}\n%!"
  | Error reason -> reject reason

let binding_test config_path sender_secret_path =
  let config = verify_config (Filename.dirname config_path) in
  let sender_secret = ed_secret (bytes_field (read_json sender_secret_path) "secret") in
  let sender_public = public_of_secret sender_secret in
  let expected_address = Octra_core.Crypto.Address.address_from_pubkey (b64 sender_public) in
  let current_epoch = current_epoch_of_json config in
  let context = context_of_json config in
  let recipient_view_public = bytes_field config "view_public" in
  let key_version = int_field config "key_version" in
  let sender_instance = test_sender_instance ~context ~recipient_view_public ~key_version ~sender_public in
  Mirage_crypto_rng_unix.use_default ();
  let _, raw = get (Recipient_message.seal ~recipient_view_public ~sender_secret ~context ~key_version
    ~sequence:1L ~sender_epoch:current_epoch ~sender_instance
    ~policy:(policy_for_version config key_version) ~current_epoch "sender binding") in
  let other_public = public_of_secret (ed_secret (Octra_net.Hash_domain.hash_encoded "octra:test:other-writer:v2" (fun _ -> ()))) in
  let other_address = Octra_core.Crypto.Address.address_from_pubkey (b64 other_public) in
  let expect_error expected = function
    | Error reason when String.equal reason expected -> ()
    | Error reason -> reject reason
    | Ok _ -> reject ("binding control unexpectedly accepted: " ^ expected) in
  (match Sender_binding.verify_envelope ~expected_address ~onchain_sender:expected_address raw with
   | Ok bound when String.equal bound sender_public -> ()
   | Ok _ -> reject "wrong sender returned by binding"
   | Error reason -> reject reason);
  expect_error "on-chain sender mismatch"
    (Sender_binding.verify_envelope ~expected_address ~onchain_sender:other_address raw);
  expect_error "envelope sender is not bound to on-chain address"
    (Sender_binding.verify_envelope ~expected_address:other_address ~onchain_sender:other_address raw);
  expect_error "envelope header truncated"
    (Sender_binding.verify_envelope ~expected_address ~onchain_sender:expected_address "OCMMSG");
  Printf.printf "{\"status\":\"onchain_sender_binding_pass\",\"mismatch_rejected_before_decode\":true}\n%!"

let bind_envelope expected_address onchain_sender envelope_path =
  match Sender_binding.verify_envelope ~expected_address ~onchain_sender (read_file envelope_path) with
  | Ok sender_public ->
    Printf.printf "{\"status\":\"sender_bound\",\"sender_public\":%s}\n%!"
      (Yojson.Safe.to_string (`String (b64 sender_public)))
  | Error reason -> reject reason

let outbox_prepare ?(fail_before_seal = false) config_path sender_secret_path plaintext_path directory =
  let config = verify_config ~config_name:(Filename.basename config_path) (Filename.dirname config_path) in
  let sender_secret = ed_secret (bytes_field (read_json sender_secret_path) "secret") in
  let sender_public = public_of_secret sender_secret in
  let expected_sender = bytes_field config "expected_sender_public" in
  if not (String.equal sender_public expected_sender) then reject "sender authorization mismatch";
  let plaintext = read_file plaintext_path in
  let current_epoch = current_epoch_of_json config in
  let context = context_of_json config in
  let recipient_view_public = bytes_field config "view_public" in
  let key_version = int_field config "key_version" in
  let seal ~sender_instance ~sequence =
    if fail_before_seal then reject "injected outbox crash before sealing";
    get (Recipient_message.seal ~recipient_view_public ~sender_secret ~context ~key_version
      ~sequence ~sender_epoch:current_epoch ~sender_instance
      ~policy:(policy_for_version config key_version) ~current_epoch plaintext) in
  Mirage_crypto_rng_unix.use_default ();
  if not (Sys.file_exists directory) then Unix.mkdir directory 0o700;
  let _, raw, id = Outbox_journal.prepare ~codec_version:2 ~context ~recipient_view_public ~key_version
    ~sender_public ~directory ~seal in
  let envelope = get (Recipient_message.decode raw) in
  (match List.find_opt (fun record -> String.equal (string_field record "record_id") id)
    (Outbox_journal.pending directory) with
   | Some record ->
     if Option.get (optional_i64_field record "sequence") <> envelope.Recipient_message.sequence
       || not (String.equal (unb64 (string_field record "sender_instance"))
         envelope.Recipient_message.sender_instance) then
       reject "outbox allocation does not match sealed channel";
   | None -> reject "outbox prepared record missing");
  write_file (Filename.concat directory "prepared.ocm") raw;
  Printf.printf "{\"status\":\"outbox_prepared\",\"record_id\":%s,\"sequence\":%s}\n%!"
    (Yojson.Safe.to_string (`String id)) (Yojson.Safe.to_string (`String (Int64.to_string envelope.Recipient_message.sequence)))

let outbox_retry directory record_id output_path =
  let raw = get (Outbox_journal.retry_bytes ~directory ~record_id) in
  write_file output_path raw;
  Printf.printf "{\"status\":\"outbox_retry\",\"bytes\":%d}\n%!" (String.length raw)

let outbox_mark directory record_id status =
  get (Outbox_journal.mark ~directory ~record_id ~status);
  Printf.printf "{\"status\":\"outbox_marked\",\"state\":%s}\n" (Yojson.Safe.to_string (`String status))

let outbox_recover config_path sender_secret_path directory observed_high_water =
  let config = verify_config ~config_name:(Filename.basename config_path) (Filename.dirname config_path) in
  let sender_secret = ed_secret (bytes_field (read_json sender_secret_path) "secret") in
  let sender_public = public_of_secret sender_secret in
  let context = context_of_json config in
  get (Outbox_journal.recover ~codec_version:2 ~context
    ~recipient_view_public:(bytes_field config "view_public")
    ~key_version:(int_field config "key_version") ~sender_public ~directory ~observed_high_water);
  Printf.printf "{\"status\":\"outbox_recovered\",\"observed_high_water\":%s}\n%!"
    (Yojson.Safe.to_string (`String (Int64.to_string observed_high_water)))

let key_read_test path =
  match Recipient_keys.read path with
  | Ok _ -> Printf.printf "{\"status\":\"key_loaded\"}\n%!"
  | Error reason ->
    Printf.printf "{\"status\":\"key_rejected\",\"reason\":%s}\n%!" (Yojson.Safe.to_string (`String reason))

let print_error error =
  if !detailed_errors then
    Printf.eprintf "%s\n" (Yojson.Safe.to_string (`Assoc ["status", `String "error"; "reason", `String (Printexc.to_string error)]))
  else
    Printf.eprintf "%s\n" (Yojson.Safe.to_string (`Assoc ["status", `String "rejected"]));
  exit 2

let () =
  try
    match Array.to_list Sys.argv with
    | [_; "sender-init"; directory] -> sender_init directory
    | [_; "sender-init"; directory; variant] -> sender_init ~variant:(int_of_string variant) directory
    | [_; "recipient-init"; directory; sender_public] -> recipient_init directory sender_public
    | [_; "rotate"; directory] -> rotate_recipient directory
    | [_; "generate-messaging-key"; directory; sender_secret] -> generate_messaging_key directory sender_secret
    | [_; "resign-config"; directory] -> resign_config directory
    | [_; "seal-test"; config; secret; plaintext; envelope] ->
      detailed_errors := true;
      seal config secret plaintext envelope
    | [_; "seal-test"; config; secret; plaintext; envelope; sequence] ->
      detailed_errors := true;
      seal ?sequence:(Some (Int64.of_string sequence)) config secret plaintext envelope
    | [_; "seal-epoch-test"; config; secret; plaintext; envelope; epoch] ->
      detailed_errors := true;
      seal_with_mode ~production:false ~sender_epoch:(Int64.of_string epoch) config secret plaintext envelope
    | [_; "send"; config; secret; plaintext; envelope] -> send config secret plaintext envelope
    | [_; "send-uninitialized"; config; secret; plaintext; envelope] -> send_uninitialized config secret plaintext envelope
    | [_; "open"; secret; config; envelope; output] -> open_envelope secret config envelope output
    | [_; "open-archive"; secret; config; envelope; output; commit_epoch] ->
      open_archive (Int64.of_string commit_epoch) secret config envelope output
    | [_; "open-test"; secret; config; envelope; output] ->
      detailed_errors := true;
      open_test secret config envelope output
    | [_; "open-archive-test"; secret; config; envelope; output; commit_epoch] ->
      detailed_errors := true;
      open_archive_test (Int64.of_string commit_epoch) secret config envelope output
    | [_; "open-limited"; secret; config; envelope; output] ->
      detailed_errors := true;
      open_with_mode ~production:false ~max_receive_bytes:64 secret config envelope output
    | [_; "open-crash-after-rename"; secret; config; envelope; output] ->
      detailed_errors := true;
      open_with_mode ~production:false ~crash_after_rename:"injected crash after rename" secret config envelope output
    | [_; "open-fail-after-temp"; secret; config; envelope; output] ->
      detailed_errors := true;
      open_with_mode ~production:false ~fail_after_temp_write:"injected failure before rename" secret config envelope output
    | [_; "receive-seed"; directory; count; version] ->
      detailed_errors := true;
      receive_seed directory (int_of_string count) (int_of_string version)
    | [_; "receive-seed"; directory; count; version; sender] ->
      detailed_errors := true;
      receive_seed ~sender directory (int_of_string count) (int_of_string version)
    | [_; "receive-seed"; directory; count; version; sender; high_water] ->
      detailed_errors := true;
      receive_seed ~high_water:(Int64.of_string high_water) ~sender directory (int_of_string count) (int_of_string version)
    | [_; "store-prune-test"; directory] ->
      detailed_errors := true;
      store_prune_test directory
    | [_; "binding-test"; config; secret] ->
      detailed_errors := true;
      binding_test config secret
    | [_; "bind-envelope"; expected_address; onchain_sender; envelope] ->
      bind_envelope expected_address onchain_sender envelope
    | [_; "outbox-prepare"; config; secret; plaintext; directory] -> outbox_prepare config secret plaintext directory
    | [_; "outbox-fail-before-seal"; config; secret; plaintext; directory] ->
      detailed_errors := true;
      outbox_prepare ~fail_before_seal:true config secret plaintext directory
    | [_; "outbox-retry"; directory; record_id; output] ->
      detailed_errors := true;
      outbox_retry directory record_id output
    | [_; "outbox-mark"; directory; record_id; status] ->
      detailed_errors := true;
      outbox_mark directory record_id status
    | [_; "outbox-recover"; config; secret; directory; high_water] ->
      detailed_errors := true;
      outbox_recover config secret directory (Int64.of_string high_water)
    | [_; "key-read-test"; path] -> key_read_test path
    | [_; "corrupt"; mode; envelope; secret; output] -> corrupt mode envelope secret output
    | _ -> reject "unsupported command"
  with
  | Rejection reason -> print_error (Rejection reason)
  | Invalid_argument reason -> print_error (Invalid_argument reason)
  | Yojson.Json_error reason -> print_error (Yojson.Json_error reason)
  | Sys_error reason -> print_error (Sys_error reason)
  | Unix.Unix_error (error, function_name, argument) ->
    print_error (Unix.Unix_error (error, function_name, argument))
  | Mirage_crypto_rng.No_default_generator -> print_error Mirage_crypto_rng.No_default_generator
  | Mirage_crypto_rng.Unseeded_generator -> print_error Mirage_crypto_rng.Unseeded_generator
