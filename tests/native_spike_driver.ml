let check message condition = if not condition then failwith message
let get = function Ok value -> value | Error reason -> failwith reason
let get_error label = function Ok _ -> failwith (label ^ " unexpectedly accepted") | Error _ -> ()

let timed action =
  let started = Unix.gettimeofday () in
  let value = action () in
  (Unix.gettimeofday () -. started) *. 1000., value

let milliseconds values =
  let values = List.sort compare values in
  let length = List.length values in
  let middle = if length = 0 then 0. else List.nth values ((length - 1) / 2) in
  let maximum = if length = 0 then 0. else List.nth values (length - 1) in
  middle, maximum

let () =
  let params = Pvac_ffi.default_params () in
  let recipient_pk, recipient_sk = Pvac_ffi.keygen_from_seed params (Bytes.make 32 '\001') in
  let wrong_pk, wrong_sk = Pvac_ffi.keygen_from_seed params (Bytes.make 32 '\002') in
  let sender_secret = match Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 (Char.chr 3)) with Ok key -> key | Error _ -> failwith "sender key" in
  let context = "octra-fakenet-kimi-msgnet|native-spike-registry|format=1|suite=1" in
  let message_id = String.make 16 (Char.chr 4) in
  let plaintext = "pvac-v1" in
  let encrypt_ms, (envelope, raw) = timed (fun () ->
    get (Pvac_message.seal_same_key_holder ~recipient_pk ~recipient_sk ~sender_secret
      ~context ~message_id plaintext))
  in
  let seen = Hashtbl.create 8 in
  let remember ~sender_public ~message_id = Hashtbl.replace seen (sender_public, message_id) () in
  let known ~sender_public ~message_id = Hashtbl.mem seen (sender_public, message_id) in
  let opened = get (Pvac_message.open_envelope ~recipient_pk ~recipient_sk ~context ~message_id
    ~seen:known ~mark_seen:remember raw) in
  check "intended recipient" (String.equal opened plaintext);
  get_error "replay" (Pvac_message.open_envelope ~recipient_pk ~recipient_sk ~context ~message_id
    ~seen:known ~mark_seen:remember raw);
  let fresh = Hashtbl.create 1 in
  let fresh_seen ~sender_public ~message_id = Hashtbl.mem fresh (sender_public, message_id) in
  let fresh_mark ~sender_public ~message_id = Hashtbl.replace fresh (sender_public, message_id) () in
  get_error "wrong recipient" (Pvac_message.open_envelope ~recipient_pk:wrong_pk ~recipient_sk:wrong_sk
    ~context ~message_id ~seen:fresh_seen ~mark_seen:fresh_mark raw);
  check "wrong recipient changed replay state" (Hashtbl.length fresh = 0);
  get_error "wrong context" (Pvac_message.open_envelope ~recipient_pk ~recipient_sk
    ~context:(context ^ "|wrong") ~message_id ~seen:fresh_seen ~mark_seen:fresh_mark raw);
  let tampered = Bytes.of_string raw in
  let index = Bytes.length tampered - 1 in
  Bytes.set tampered index (Char.chr (Char.code (Bytes.get tampered index) lxor 1));
  get_error "tampering" (Pvac_message.open_envelope ~recipient_pk ~recipient_sk ~context ~message_id
    ~seen:fresh_seen ~mark_seen:fresh_mark (Bytes.to_string tampered));
  get_error "trailing bytes" (Pvac_message.decode (raw ^ "\000"));
  check "wrong context changed replay state" (Hashtbl.length fresh = 0);
  let signature_ms, () = timed (fun () -> get (Pvac_message.verify_envelope envelope)) in
  let decrypt_ms, decoded = timed (fun () ->
    get (Pvac_ffi.deserialize_cipher_result (Bytes.of_string envelope.Pvac_message.ciphertext))) in
  let decrypted = Pvac_ffi.dec_value recipient_pk recipient_sk decoded in
  check "native scalar recovery" (get (Pvac_message.int64_to_plaintext decrypted) = plaintext);
  let seal_samples = ref [] in
  let decrypt_samples = ref [] in
  let allocated_before = Gc.allocated_bytes () in
  for index = 0 to 4 do
    let id = String.make 16 (Char.chr (16 + index)) in
    let elapsed, (_, sample_raw) = timed (fun () ->
      get (Pvac_message.seal_same_key_holder ~recipient_pk ~recipient_sk ~sender_secret
        ~context ~message_id:id plaintext)) in
    seal_samples := elapsed :: !seal_samples;
    let sample = get (Pvac_message.decode sample_raw) in
    let cipher = get (Pvac_ffi.deserialize_cipher_result (Bytes.of_string sample.Pvac_message.ciphertext)) in
    let elapsed, value = timed (fun () -> Pvac_ffi.dec_value recipient_pk recipient_sk cipher) in
    decrypt_samples := elapsed :: !decrypt_samples;
    check "sample plaintext" (get (Pvac_message.int64_to_plaintext value) = plaintext)
  done;
  let allocated_after = Gc.allocated_bytes () in
  let seal_median, seal_max = milliseconds !seal_samples in
  let decrypt_median, decrypt_max = milliseconds !decrypt_samples in
  let shape = Pvac_ffi.cipher_shape decoded in
  let public_key_bytes = Bytes.length (Pvac_ffi.serialize_pubkey recipient_pk) in
  let ciphertext_bytes = String.length envelope.Pvac_message.ciphertext in
  let digest = Digestif.SHA256.(digest_string raw |> to_hex) in
  Printf.printf "{\"status\":\"pass\",\"profile\":\"same-key-holder PVAC plus Ed25519 test envelope\",\"plaintext_bytes\":%d,\"ciphertext_bytes\":%d,\"envelope_bytes\":%d,\"public_key_bytes\":%d,\"slots\":%d,\"layers\":%d,\"edges\":%d,\"encrypt_ms\":%.3f,\"decrypt_ms\":%.3f,\"verify_ms\":%.3f,\"seal_median_ms\":%.3f,\"seal_max_ms\":%.3f,\"decrypt_median_ms\":%.3f,\"decrypt_max_ms\":%.3f,\"allocated_bytes_five_rounds\":%.0f,\"envelope_sha256\":\"%s\",\"controls\":[\"intended_recipient\",\"wrong_recipient\",\"tampering\",\"wrong_context\",\"replay\",\"trailing_bytes\"]}\n%!"
    (String.length plaintext) ciphertext_bytes (String.length raw) public_key_bytes
    shape.Pvac_ffi.slots shape.Pvac_ffi.layers shape.Pvac_ffi.edges
    encrypt_ms decrypt_ms signature_ms seal_median seal_max decrypt_median decrypt_max
    (allocated_after -. allocated_before) digest
