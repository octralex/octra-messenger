let get = function Ok value -> value | Error reason -> failwith reason

let timed action =
  let started = Unix.gettimeofday () in
  let value = action () in
  (Unix.gettimeofday () -. started) *. 1000., value

let median values =
  let values = List.sort compare values in
  match values with [] -> 0. | _ -> List.nth values ((List.length values - 1) / 2)

let maximum values = List.fold_left max 0. values
let b64_bytes raw = 4 * ((String.length raw + 2) / 3) + 2

let payload kind length =
  match kind with
  | "repeat" -> String.make length 'A'
  | "zeros" -> String.init length (fun index -> if index mod 2 = 0 then '\000' else '\255')
  | "ascii" -> String.init length (fun index -> "hello Octra".[index mod 11])
  | "utf8" ->
    let text = "Octra こんにちは 👋" in
    let buffer = Buffer.create length in
    while Buffer.length buffer + String.length text <= length do
      Buffer.add_string buffer text
    done;
    Buffer.add_string buffer (String.make (length - Buffer.length buffer) 'x');
    Buffer.contents buffer
  | "random" ->
    let state = ref (Int64.of_int (length + 17)) in
    String.init length (fun _ ->
      state := Int64.logxor !state (Int64.shift_left !state 13);
      state := Int64.logxor !state (Int64.shift_right_logical !state 7);
      state := Int64.logxor !state (Int64.shift_left !state 17);
      Char.chr (Int64.to_int (Int64.logand !state 255L)))
  | _ -> String.init length (fun index -> Char.chr ((index * 31 + length) land 255))

let context = Recipient_message.make_context ~chain_id:"octra-fakenet-kimi-msgnet"
  ~application:"onchain-messenger" ~registry:"native-spike-registry" ~format_version:1 ~suite:1

let recipient_view_secret, recipient_view_public =
  Recipient_message_testkit.x25519_from_seed
    (Digestif.SHA256.(digest_string "octra-test-recipient-x25519-size-v1" |> to_raw_string))

let sender_secret =
  let seed = Digestif.SHA256.(digest_string "octra-test-sender-ed25519-v1" |> to_raw_string) in
  match Mirage_crypto_ec.Ed25519.priv_of_octets seed with Ok key -> key | Error _ -> failwith "sender key"

let expected_sender = Mirage_crypto_ec.Ed25519.(pub_of_priv sender_secret |> pub_to_octets)

let rec repeat count action = if count > 0 then action (); repeat (count - 1) action

let measure_recipient kind length =
  let allocated_before = Gc.allocated_bytes () in
  let plaintext = payload kind length in
  let message_id = Digestif.SHA256.(digest_string ("octra-test-size-message-id" ^ kind ^ string_of_int length) |> to_raw_string)
    |> fun value -> String.sub value 0 16 in
  let ephemeral_secret = Digestif.SHA256.(digest_string ("octra-test-ephemeral" ^ message_id) |> to_raw_string) in
  let nonce = Digestif.SHA256.(digest_string ("octra-test-nonce" ^ message_id) |> to_raw_string) |> fun value -> String.sub value 0 12 in
  let seal_cold, (envelope, raw) = timed (fun () -> get (Recipient_message_testkit.seal
    ~recipient_view_public ~sender_secret ~context ~key_version:1 ~message_id
    ~ephemeral_secret ~nonce ~policy:Octra_core.Circle_key_policy.default ~current_epoch:0L plaintext)) in
  let open_cold, opened = timed (fun () -> get (Recipient_message.open_envelope
    ~recipient_view_secret ~expected_sender_public:expected_sender
    ~context ~key_version:1 ~policy:Octra_core.Circle_key_policy.default ~current_epoch:0L ~seen:(fun ~sender_public:_ ~message_id:_ -> false)
    ~mark_seen:(fun ~sender_public:_ ~message_id:_ ~plaintext:_ -> ()) raw)) in
  if not (String.equal opened plaintext) then failwith "recipient round trip";
  let seal_times = ref [] in
  let open_times = ref [] in
  let verify_times = ref [] in
  for _ = 1 to 4 do
    let elapsed, (_, raw) = timed (fun () -> get (Recipient_message_testkit.seal
      ~recipient_view_public ~sender_secret ~context ~key_version:1 ~message_id
      ~ephemeral_secret ~nonce ~policy:Octra_core.Circle_key_policy.default ~current_epoch:0L plaintext)) in
    seal_times := elapsed :: !seal_times;
    let elapsed, opened = timed (fun () -> get (Recipient_message.open_envelope
      ~recipient_view_secret ~expected_sender_public:expected_sender
      ~context ~key_version:1 ~policy:Octra_core.Circle_key_policy.default ~current_epoch:0L ~seen:(fun ~sender_public:_ ~message_id:_ -> false)
      ~mark_seen:(fun ~sender_public:_ ~message_id:_ ~plaintext:_ -> ()) raw)) in
    open_times := elapsed :: !open_times;
    if not (String.equal opened plaintext) then failwith "recipient warm round trip";
    let elapsed, () = timed (fun () -> get (Recipient_message.verify_envelope envelope)) in
    verify_times := elapsed :: !verify_times
  done;
  let allocated = Gc.allocated_bytes () -. allocated_before in
  [
    "recipient-x25519-aes-gcm"; kind; string_of_int length; "0"; "0"; "0"; "0";
    string_of_int (String.length envelope.Recipient_message_core.ciphertext);
    string_of_int (String.length raw);
    string_of_int (String.length raw - String.length envelope.Recipient_message_core.ciphertext + 28);
    string_of_int (b64_bytes raw); "unmeasured";
    Printf.sprintf "%.3f" seal_cold; Printf.sprintf "%.3f" (median !seal_times);
    Printf.sprintf "%.3f" (maximum !seal_times); Printf.sprintf "%.3f" (maximum (seal_cold :: !seal_times)); Printf.sprintf "%.3f" open_cold;
    Printf.sprintf "%.3f" (median !open_times); Printf.sprintf "%.3f" (maximum !open_times); Printf.sprintf "%.3f" (maximum (open_cold :: !open_times));
    Printf.sprintf "%.3f" (median !verify_times); "included-in-seal";
    Printf.sprintf "%.0f" allocated; "pass"
  ]

let measure_pvac_vector ~pk ~sk kind length =
  let allocated_before = Gc.allocated_bytes () in
  let plaintext = payload kind length in
  let seal_cold, cipher = timed (fun () -> Pvac_slots.encrypt_vector ~pk ~sk plaintext) in
  let serialize_cold, raw = timed (fun () -> Pvac_ffi.serialize_cipher cipher |> Bytes.to_string) in
  let open_cold, opened = timed (fun () -> get (Pvac_slots.decrypt_vector ~pk ~sk cipher)) in
  if not (String.equal opened plaintext) then failwith "pvac vector round trip";
  let shape = Pvac_ffi.cipher_shape cipher in
  let seal_times = ref [] in
  let open_times = ref [] in
  let serialize_times = ref [] in
  for _ = 1 to 4 do
    let elapsed, cipher = timed (fun () -> Pvac_slots.encrypt_vector ~pk ~sk plaintext) in
    seal_times := elapsed :: !seal_times;
    let elapsed, raw = timed (fun () -> Pvac_ffi.serialize_cipher cipher |> Bytes.to_string) in
    serialize_times := elapsed :: !serialize_times;
    ignore raw;
    let elapsed, opened = timed (fun () -> get (Pvac_slots.decrypt_vector ~pk ~sk cipher)) in
    open_times := elapsed :: !open_times;
    if not (String.equal opened plaintext) then failwith "pvac vector warm round trip"
  done;
  let allocated = Gc.allocated_bytes () -. allocated_before in
  [
    "same-key-pvac-vector"; kind; string_of_int length;
    string_of_int (Pvac_slots.slot_count length); string_of_int (Pvac_slots.slot_count length);
    string_of_int shape.Pvac_ffi.layers; string_of_int shape.Pvac_ffi.edges;
    string_of_int (String.length raw); "unmeasured"; "unmeasured";
    string_of_int (b64_bytes raw); "unmeasured";
    Printf.sprintf "%.3f" seal_cold; Printf.sprintf "%.3f" (median !seal_times);
    Printf.sprintf "%.3f" (maximum !seal_times); Printf.sprintf "%.3f" (maximum (seal_cold :: !seal_times)); Printf.sprintf "%.3f" open_cold;
    Printf.sprintf "%.3f" (median !open_times); Printf.sprintf "%.3f" (maximum !open_times); Printf.sprintf "%.3f" (maximum (open_cold :: !open_times));
    "not-applicable"; Printf.sprintf "%.3f" (median !serialize_times);
    Printf.sprintf "%.0f" allocated; "same-key-holder"
  ]

let measure_pvac_scalar ~pk ~sk kind length =
  let allocated_before = Gc.allocated_bytes () in
  let plaintext = payload kind length in
  let seal_cold, ciphers = timed (fun () -> Pvac_slots.encrypt_scalar_chunks ~pk ~sk plaintext) in
  let raws = Array.map (fun cipher -> Pvac_ffi.serialize_cipher cipher |> Bytes.to_string) ciphers in
  let open_cold, opened = timed (fun () -> get (Pvac_slots.decrypt_scalar_chunks ~pk ~sk ciphers)) in
  if not (String.equal opened plaintext) then failwith "pvac scalar round trip";
  let layers = Array.fold_left (fun total cipher -> total + (Pvac_ffi.cipher_shape cipher).Pvac_ffi.layers) 0 ciphers in
  let edges = Array.fold_left (fun total cipher -> total + (Pvac_ffi.cipher_shape cipher).Pvac_ffi.edges) 0 ciphers in
  let native_bytes = Array.fold_left (fun total raw -> total + String.length raw) 0 raws in
  let wire_bytes = Array.fold_left (fun total raw -> total + b64_bytes raw) 0 raws in
  let seal_times = ref [] in
  let open_times = ref [] in
  for _ = 1 to 4 do
    let elapsed, ciphers = timed (fun () -> Pvac_slots.encrypt_scalar_chunks ~pk ~sk plaintext) in
    seal_times := elapsed :: !seal_times;
    let elapsed, opened = timed (fun () -> get (Pvac_slots.decrypt_scalar_chunks ~pk ~sk ciphers)) in
    open_times := elapsed :: !open_times;
    if not (String.equal opened plaintext) then failwith "pvac scalar warm round trip"
  done;
  let allocated = Gc.allocated_bytes () -. allocated_before in
  [
    "same-key-pvac-scalar-chunks"; kind; string_of_int length;
    string_of_int (Pvac_slots.slot_count length); string_of_int (Pvac_slots.slot_count length);
    string_of_int layers; string_of_int edges;
    string_of_int native_bytes; "unmeasured"; "unmeasured";
    string_of_int wire_bytes; "unmeasured";
    Printf.sprintf "%.3f" seal_cold; Printf.sprintf "%.3f" (median !seal_times);
    Printf.sprintf "%.3f" (maximum !seal_times); Printf.sprintf "%.3f" (maximum (seal_cold :: !seal_times)); Printf.sprintf "%.3f" open_cold;
    Printf.sprintf "%.3f" (median !open_times); Printf.sprintf "%.3f" (maximum !open_times); Printf.sprintf "%.3f" (maximum (open_cold :: !open_times));
    "not-applicable"; "unmeasured"; Printf.sprintf "%.0f" allocated; "same-key-holder"
  ]

let columns = [
  "route"; "kind"; "plaintext_bytes"; "slots"; "chunks"; "layers"; "edges";
  "native_bytes"; "envelope_bytes"; "envelope_overhead"; "wire_bytes";
  "signed_transaction_bytes"; "seal_cold_ms"; "seal_warm_median_ms"; "seal_warm_max_ms";
  "seal_overall_max_ms"; "open_cold_ms"; "open_warm_median_ms"; "open_warm_max_ms";
  "open_overall_max_ms"; "verify_median_ms"; "serialize_median_ms"; "allocated_bytes"; "status"
]

let unsupported route kind length reason =
  [route; kind; string_of_int length]
  @ List.init (List.length columns - 4) (fun _ -> "unmeasured")
  @ [reason]

let emit row =
  if List.length row <> List.length columns then failwith "size row does not match schema";
  print_endline (String.concat "," row)

let () =
  let view_keygen_ms, _ = timed (fun () -> Recipient_message_testkit.x25519_from_seed
    (Digestif.SHA256.(digest_string "octra-test-recipient-x25519-size-v1" |> to_raw_string))) in
  let sender_keygen_ms, _ = timed (fun () -> Mirage_crypto_ec.Ed25519.priv_of_octets
    (Digestif.SHA256.(digest_string "octra-test-sender-ed25519-v1" |> to_raw_string))) in
  let keygen_ms, (pk, sk) = timed (fun () -> Pvac_ffi.keygen_from_seed (Pvac_ffi.default_params ()) (Bytes.make 32 '\001')) in
  let public_key_bytes = Bytes.length (Pvac_ffi.serialize_pubkey pk) in
  Printf.printf "# source=3aab2d992035076dd216ad8808710d3a5a56063a profile=native-recipient-v1 samples=5 view_keygen_ms=%.3f sender_keygen_ms=%.3f keygen_ms=%.3f pvac_public_key_bytes=%d pvac_public_key_b64_json=%d recipient_view_public_key_bytes=32 recipient_view_public_key_b64_json=46\n%!"
    view_keygen_ms sender_keygen_ms keygen_ms public_key_bytes (b64_bytes (Pvac_ffi.serialize_pubkey pk |> Bytes.to_string));
  print_endline (String.concat "," columns);
  let lengths = [0; 1; 7; 8; 16; 32; 64; 128; 256; 512; 1024; 2048; 4096; 16384] in
  List.iter (fun length ->
    emit (measure_recipient "mixed" length);
    emit (measure_pvac_vector ~pk ~sk "mixed" length);
    if length <= 128 then emit (measure_pvac_scalar ~pk ~sk "mixed" length)
    else emit (unsupported "same-key-pvac-scalar-chunks" "mixed" length "not-measured-time-budget")
  ) lengths;
  List.iter (fun (kind, length) ->
    emit (measure_recipient kind length);
    emit (measure_pvac_vector ~pk ~sk kind length))
    ["ascii", 64; "utf8", 128; "repeat", 128; "random", 128; "zeros", 128]
