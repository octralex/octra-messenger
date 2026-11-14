let get = function Ok value -> value | Error reason -> failwith reason
let b64 = Base64.encode_exn
let unb64 = Base64.decode_exn
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
  | _ -> failwith ("invalid " ^ name)

let policy_of_json json : Octra_core.Circle_key_policy.t = {
  activate_after_epoch = optional_i64_field json "activate_after_epoch";
  expire_after_epoch = optional_i64_field json "expire_after_epoch";
  revoked = bool_field json "revoked";
  erased = bool_field json "erased";
}

let policy_for_version config version =
  let policies = Yojson.Safe.Util.member "policies" config in
  match Yojson.Safe.Util.member (string_of_int version) policies with
  | `Null -> failwith "mandatory key policy is missing for this version"
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
      failwith "recipient key version is not accepted";
    match Yojson.Safe.Util.member (string_of_int version)
      (Yojson.Safe.Util.member "previous_view_public" config) with
    | `String value -> unb64 value
    | _ -> failwith "recipient key replaced or unregistered"
  end

let ed_secret raw =
  match Mirage_crypto_ec.Ed25519.priv_of_octets raw with
  | Ok key -> key
  | Error _ -> failwith "invalid Ed25519 secret"

let contact_secret directory = ed_secret (bytes_field (read_json (Filename.concat directory "contact-secret.json")) "secret")

let sign_config directory config =
  let fields = match config with
    | `Assoc fields -> List.filter (fun (name, _) -> name <> "authorization_signature") fields
    | _ -> failwith "contact config must be an object" in
  let fields = List.sort (fun (left, _) (right, _) -> String.compare left right) fields in
  let signature = Mirage_crypto_ec.Ed25519.sign ~key:(contact_secret directory) (Yojson.Safe.to_string (`Assoc fields)) in
  match config with
  | `Assoc _ -> `Assoc (fields @ ["authorization_signature", `String (b64 signature)])
  | _ -> assert false

let verify_config ?(config_name = "recipient-public.json") directory =
  let config = read_json (Filename.concat directory config_name) in
  let root = read_json (Filename.concat directory "contact-root.json") in
  let expected_root = bytes_field root "authorization_public" in
  if not (String.equal (bytes_field config "authorization_public") expected_root) then
    failwith "contact authorization root mismatch";
  let fields = match config with
    | `Assoc fields -> List.filter (fun (name, _) -> name <> "authorization_signature") fields
    | _ -> failwith "contact config must be an object" in
  let fields = List.sort (fun (left, _) (right, _) -> String.compare left right) fields in
  let signature = bytes_field config "authorization_signature" in
  let public_key = match Mirage_crypto_ec.Ed25519.pub_of_octets expected_root with Ok key -> key | Error _ -> failwith "contact public key invalid" in
  if not (Mirage_crypto_ec.Ed25519.verify ~key:public_key signature ~msg:(Yojson.Safe.to_string (`Assoc fields))) then
    failwith "contact authorization failed";
  config

let write_contact_init directory =
  if not (Sys.file_exists (Filename.concat directory "contact-secret.json")) then begin
    let seed = Digestif.SHA256.(digest_string "octra-test-contact-root-v1" |> to_raw_string) in
    let secret = ed_secret seed in
    write_json (Filename.concat directory "contact-secret.json")
      (`Assoc ["secret", `String (b64 (Mirage_crypto_ec.Ed25519.priv_to_octets secret))]);
    write_json ~perm:0o644 (Filename.concat directory "contact-root.json")
      (`Assoc ["authorization_public", `String (b64 (public_of_secret secret))])
  end

let sender_init ?(variant = 1) directory =
  let seed = Digestif.SHA256.(digest_string ("octra-test-sender-ed25519-v" ^ string_of_int variant) |> to_raw_string) in
  let secret = ed_secret seed in
  write_json (Filename.concat directory "sender-secret.json")
    (`Assoc ["secret", `String (b64 (Mirage_crypto_ec.Ed25519.priv_to_octets secret))]);
  write_json ~perm:0o644 (Filename.concat directory "sender-public.json")
    (`Assoc ["sender_public", `String (b64 (public_of_secret secret))]);
  Printf.printf "{\"status\":\"sender_initialized\",\"sender_public\":\"%s\"}\n%!" (b64 (public_of_secret secret))

let recipient_key_type = "octra-x25519-recipient-message-v1"

let write_recipient_secret directory version =
  Mirage_crypto_rng_unix.use_default ();
  let view_secret, view_public = Recipient_keys.generate () in
  let raw_secret = Recipient_keys.secret_to_octets view_secret in
  write_json (Filename.concat directory ("recipient-secret-v" ^ string_of_int version ^ ".json"))
    (`Assoc [
      "key_type", `String recipient_key_type;
      "view_secret", `String (b64 raw_secret);
      "view_public", `String (b64 view_public);
    ]);
  view_public

let read_recipient_secret path =
  let secret = read_json path in
  if not (String.equal (string_field secret "key_type") recipient_key_type) then
    failwith "recipient secret is not a typed X25519 messaging key";
  Recipient_keys.of_octets (bytes_field secret "view_secret")

let policy_json activate expire revoked erased : Yojson.Safe.t =
  `Assoc [
    "activate_after_epoch", `String (Int64.to_string activate);
    "expire_after_epoch", (match expire with Some value -> `String (Int64.to_string value) | None -> `Null);
    "revoked", `Bool revoked;
    "erased", `Bool erased;
  ]

let write_recipient_config directory expected_sender version previous_versions view_public =
  let context = Recipient_message.make_context ~chain_id:"octra-fakenet-kimi-msgnet"
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
    "chain_id", `String "octra-fakenet-kimi-msgnet";
    "application", `String "onchain-messenger";
    "registry", `String "native-spike-registry";
    "format_version", `Int 1;
    "suite", `Int 1;
    "key_version", `Int version;
    "accepted_previous_versions", `List (List.map (fun value -> `Int value) previous_versions);
    "grace_previous_versions", `List (List.map (fun value -> `Int value) previous_versions);
    "previous_view_public", `Assoc previous_view_public;
    "policies", `Assoc policies;
    "current_epoch", `Int 10;
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
  if not (String.equal view_public derived_public) then failwith "X25519 public key derivation mismatch";
  let view_secret = Recipient_keys.secret_to_octets secret in
  if String.equal view_secret view_public then failwith "X25519 secret and public key overlap";
  let sender_raw = bytes_field (read_json sender_secret_path) "secret" in
  let sender_secret = ed_secret sender_raw in
  let wallet_view_secret, wallet_view_public =
    Octra_core.Crypto.StealthAddress.derive_view_keypair (b64 sender_raw) in
  if String.equal view_secret sender_raw
    || String.equal view_secret wallet_view_secret
    || String.equal view_public wallet_view_public
    || String.equal view_public (public_of_secret sender_secret) then
    failwith "messaging and signing key namespaces overlap";
  write_json (Filename.concat directory "messaging-secret.json")
    (`Assoc ["key_type", `String recipient_key_type;
      "view_secret", `String (b64 view_secret); "view_public", `String (b64 view_public)]);
  Printf.printf "{\"status\":\"messaging_key_generated\",\"key_type\":\"x25519\",\"independent_from_ed25519\":true,\"public_matches_secret\":false}\n%!"

let resign_config directory =
  let config = read_json (Filename.concat directory "recipient-public.json") in
  write_json ~perm:0o644 (Filename.concat directory "recipient-public.json") (sign_config directory config)

let test_message_id directory =
  let path = Filename.concat directory "test-counter" in
  let current = if Sys.file_exists path then int_of_string (read_file path) else 0 in
  let next = current + 1 in
  write_file path (string_of_int next);
  Digestif.SHA256.(digest_string ("octra-test-message-id" ^ string_of_int next) |> to_raw_string)
  |> fun value -> String.sub value 0 16

let seal_with_mode ~production ?(initialize_rng = true) config_path sender_secret_path plaintext_path envelope_path =
  let config = verify_config ~config_name:(Filename.basename config_path) (Filename.dirname config_path) in
  let sender_secret = ed_secret (bytes_field (read_json sender_secret_path) "secret") in
  let expected_sender = bytes_field config "expected_sender_public" in
  if not (String.equal (public_of_secret sender_secret) expected_sender) then failwith "sender authorization mismatch";
  let plaintext = read_file plaintext_path in
  let key_version = int_field config "key_version" in
  let policy = policy_for_version config key_version in
  let current_epoch = current_epoch_of_json config in
  let context = context_of_json config in
  let _, raw =
    if production then begin
      if initialize_rng then Mirage_crypto_rng_unix.use_default ();
      get (Recipient_message.seal ~recipient_view_public:(bytes_field config "view_public")
        ~sender_secret ~context ~key_version ~policy ~current_epoch plaintext)
    end else begin
      let message_id = test_message_id (Filename.dirname plaintext_path) in
      let ephemeral_secret = Digestif.SHA256.(digest_string ("octra-test-ephemeral" ^ message_id) |> to_raw_string) in
      let nonce = Digestif.SHA256.(digest_string ("octra-test-nonce" ^ message_id) |> to_raw_string)
        |> fun value -> String.sub value 0 12 in
      get (Recipient_message_testkit.seal ~recipient_view_public:(bytes_field config "view_public")
        ~sender_secret ~context ~key_version ~message_id ~ephemeral_secret ~nonce ~policy ~current_epoch plaintext)
    end in
  write_file envelope_path raw;
  let envelope = get (Recipient_message.decode raw) in
  Printf.printf "{\"status\":\"sealed\",\"envelope_bytes\":%d,\"ciphertext_bytes\":%d,\"recipient_secret_input\":false}\n%!"
    (String.length raw) (String.length envelope.Recipient_message_core.ciphertext)

let seal = seal_with_mode ~production:false
let send = seal_with_mode ~production:true
let send_uninitialized config_path sender_secret_path plaintext_path envelope_path =
  Mirage_crypto_rng.unset_default_generator ();
  seal_with_mode ~production:true ~initialize_rng:false config_path sender_secret_path plaintext_path envelope_path

let open_with_mode ~production ?fail_after_temp_write ?crash_after_rename secret_path config_path envelope_path output_path =
  let config = verify_config ~config_name:(Filename.basename config_path) (Filename.dirname config_path) in
  let raw = read_file envelope_path in
  let preliminary = get (Recipient_message.decode raw) in
  let version = preliminary.Recipient_message_core.key_version in
  let registered_view_public = registered_view_public config version in
  let secret_path = Filename.concat (Filename.dirname secret_path)
    ("recipient-secret-v" ^ string_of_int version ^ ".json") in
  let recipient_view_secret = read_recipient_secret secret_path in
  let recipient_view_public = Recipient_keys.public_of_secret recipient_view_secret in
  if not (String.equal registered_view_public recipient_view_public) then
    failwith "recipient key replaced or unregistered";
  let context = context_of_json config in
  let dedup_retained candidate =
    let policy = policy_for_version config candidate in
    if policy.Octra_core.Circle_key_policy.erased then false
    else if candidate = int_field config "key_version" then true
    else List.mem candidate (int_list_field config "accepted_previous_versions")
      && List.mem candidate (int_list_field config "grace_previous_versions") in
  let seen ~sender_public ~message_id =
    Receive_store.seen (Receive_store.read_json (Receive_store.state_path (Filename.dirname secret_path)))
      ~context ~sender_public ~message_id in
  let mark_seen ~sender_public ~message_id ~plaintext =
    match Receive_store.commit_receive ?fail_after_temp_write ?crash_after_rename ~directory:(Filename.dirname secret_path)
      ~context ~sender_public ~message_id ~key_version:version ~dedup_retained ~plaintext () with
    | Ok () -> ()
    | Error reason -> failwith reason in
  let opener = if production then Recipient_message.open_envelope else Recipient_message_testkit.open_envelope in
  let plaintext = get (opener ~recipient_view_secret
    ~expected_sender_public:(bytes_field config "expected_sender_public")
    ~context ~key_version:version ~policy:(policy_for_version config version)
    ~current_epoch:(current_epoch_of_json config) ~seen ~mark_seen raw) in
  write_file output_path plaintext;
  Printf.printf "{\"status\":\"opened\",\"plaintext_bytes\":%d}\n%!" (String.length plaintext)

let open_envelope = open_with_mode ~production:true
let open_test = open_with_mode ~production:false

let corrupt mode envelope_path sender_secret_path output_path =
  let envelope = get (Recipient_message.decode (read_file envelope_path)) in
  let sender_secret = ed_secret (bytes_field (read_json sender_secret_path) "secret") in
  let envelope = match mode with
    | "body" ->
      let ciphertext = String.init (String.length envelope.Recipient_message_core.ciphertext)
        (fun index -> Char.chr ((index * 37 + 11) land 255)) in
      { envelope with Recipient_message_core.ciphertext }
    | "id" ->
      let message_id = String.init 16 (fun index -> if index = 0 then '\001' else envelope.Recipient_message_core.message_id.[index]) in
      { envelope with Recipient_message_core.message_id }
    | "ephemeral" ->
      let ephemeral_public = String.init 32 (fun index -> if index = 0 then '\001' else envelope.Recipient_message_core.ephemeral_public.[index]) in
      { envelope with Recipient_message_core.ephemeral_public }
    | "zero-ephemeral" -> { envelope with Recipient_message_core.ephemeral_public = String.make 32 '\000' }
    | "ordinary-ones-ephemeral" -> { envelope with Recipient_message_core.ephemeral_public = String.make 32 '\001' }
    | "u-one-ephemeral" ->
      let point = String.init 32 (fun index -> if index = 0 then '\001' else '\000') in
      { envelope with Recipient_message_core.ephemeral_public = point }
    | "order-eight-a-ephemeral" ->
      { envelope with Recipient_message_core.ephemeral_public = unb64 "4Ot6fDtBuK4WVuP68Z/EatoJjeucMrH9hmIFFl9JuAA=" }
    | "order-eight-b-ephemeral" ->
      { envelope with Recipient_message_core.ephemeral_public = unb64 "X5yVvKNQjCSx0LFVnIPvWwREXMRYHI6G2CJO3dCfEVc=" }
    | "low-order-ephemeral" ->
      let low_order = String.init 32 (fun index ->
        if index = 0 then '\236' else if index = 31 then '\127' else '\255') in
      { envelope with Recipient_message_core.ephemeral_public = low_order }
    | "p-ephemeral" ->
      let point = String.init 32 (fun index ->
        if index = 0 then '\237' else if index = 31 then '\127' else '\255') in
      { envelope with Recipient_message_core.ephemeral_public = point }
    | "p-plus-one-ephemeral" ->
      let point = String.init 32 (fun index ->
        if index = 0 then '\238' else if index = 31 then '\127' else '\255') in
      { envelope with Recipient_message_core.ephemeral_public = point }
    | "noncanonical-ephemeral" -> { envelope with Recipient_message_core.ephemeral_public = String.make 32 '\255' }
    | "version" -> { envelope with Recipient_message_core.key_version = envelope.Recipient_message_core.key_version + 1 }
    | "context" -> { envelope with Recipient_message_core.context = envelope.Recipient_message_core.context ^ "|modified" }
    | _ -> failwith "unknown corrupt mode" in
  let signature = Mirage_crypto_ec.Ed25519.sign ~key:sender_secret
    (Recipient_message.authentication_payload envelope) in
  let raw = get (Recipient_message.encode { envelope with Recipient_message_core.signature }) in
  write_file output_path raw;
  Printf.printf "{\"status\":\"resigned_envelope\",\"mode\":%s}\n" (Yojson.Safe.to_string (`String mode))

let receive_seed ?sender directory count key_version =
  let messages = Filename.concat directory "messages" in
  if not (Sys.file_exists messages) then Unix.mkdir messages 0o700;
  write_file (Filename.concat messages "seed.bin") "x";
  let context = b64 "seed-context" in
  let records = List.init count (fun index ->
    let sender_public = match sender with
      | Some value -> value
      | None -> b64 ("seed-sender-" ^ string_of_int (index / Receive_store.max_records_per_sender)) in
    let message_id = Digestif.SHA256.(digest_string ("seed-message-" ^ string_of_int index) |> to_raw_string)
      |> fun value -> String.sub value 0 16 in
    `Assoc [
      "context", `String context;
      "sender_public", `String sender_public;
      "message_id", `String (b64 message_id);
      "key_version", `Int key_version;
      "path", `String "messages/seed.bin";
      "plaintext_bytes", `Int 1;
      "sha256", `String Digestif.SHA256.(digest_string "x" |> to_hex);
    ]) in
  Receive_store.write_json_atomic (Receive_store.state_path directory)
    (`Assoc ["version", `Int 2; "dedup", `List records; "inbox", `List records]);
  Printf.printf "{\"status\":\"receive_seeded\",\"records\":%d}\n%!" count

let outbox_prepare config_path sender_secret_path plaintext_path directory =
  let seal = fun () ->
    let config = verify_config ~config_name:(Filename.basename config_path) (Filename.dirname config_path) in
    let sender_secret = ed_secret (bytes_field (read_json sender_secret_path) "secret") in
    let expected_sender = bytes_field config "expected_sender_public" in
    if not (String.equal (public_of_secret sender_secret) expected_sender) then failwith "sender authorization mismatch";
    let plaintext = read_file plaintext_path in
    Mirage_crypto_rng_unix.use_default ();
    get (Recipient_message.seal ~recipient_view_public:(bytes_field config "view_public")
      ~sender_secret ~context:(context_of_json config)
      ~key_version:(int_field config "key_version")
      ~policy:(policy_for_version config (int_field config "key_version"))
      ~current_epoch:(current_epoch_of_json config) plaintext) in
  let _, raw, sequence = Outbox_journal.prepare ~directory ~seal in
  write_file (Filename.concat directory "prepared.ocm") raw;
  Printf.printf "{\"status\":\"outbox_prepared\",\"sequence\":%d}\n%!" sequence

let outbox_retry directory output_path =
  let raw = get (Outbox_journal.retry_bytes ~directory ~sequence:1) in
  write_file output_path raw;
  Printf.printf "{\"status\":\"outbox_retry\",\"bytes\":%d}\n%!" (String.length raw)

let outbox_mark directory status =
  get (Outbox_journal.mark ~directory ~sequence:1 ~status);
  Printf.printf "{\"status\":\"outbox_marked\",\"state\":%s}\n" (Yojson.Safe.to_string (`String status))

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
    | [_; "send"; config; secret; plaintext; envelope] -> send config secret plaintext envelope
    | [_; "send-uninitialized"; config; secret; plaintext; envelope] -> send_uninitialized config secret plaintext envelope
    | [_; "open"; secret; config; envelope; output] -> open_envelope secret config envelope output
    | [_; "open-test"; secret; config; envelope; output] ->
      detailed_errors := true;
      open_test secret config envelope output
    | [_; "open-crash-after-rename"; secret; config; envelope; output] ->
      detailed_errors := true;
      open_with_mode ~production:false ~crash_after_rename:"injected crash after rename" secret config envelope output
    | [_; "open-fail-after-temp"; secret; config; envelope; output] ->
      detailed_errors := true;
      open_with_mode ~production:false ~fail_after_temp_write:"injected failure before rename" secret config envelope output
    | [_; "receive-seed"; directory; count; version] -> receive_seed directory (int_of_string count) (int_of_string version)
    | [_; "receive-seed"; directory; count; version; sender] ->
      receive_seed ~sender directory (int_of_string count) (int_of_string version)
    | [_; "outbox-prepare"; config; secret; plaintext; directory] -> outbox_prepare config secret plaintext directory
    | [_; "outbox-retry"; directory; output] -> outbox_retry directory output
    | [_; "outbox-mark"; directory; status] -> outbox_mark directory status
    | [_; "corrupt"; mode; envelope; secret; output] -> corrupt mode envelope secret output
    | _ -> failwith "unsupported command"
  with error -> print_error error
