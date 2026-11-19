(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

module C = Octra_core
module V = Octra_vm
module S = C.Store_irmin

let owner = Option.value (Sys.getenv_opt "MESSENGER_SEGMENT_OWNER")
  ~default:("oct" ^ String.make 44 (Char.chr 49))
let stranger = "oct" ^ String.make 44 (Char.chr 50)
let instantiate source owner =
  let marker = "__OWNER__" in
  let marker_bytes = String.length marker in
  let length = String.length source in
  let buffer = Buffer.create (length + 64) in
  let position = ref 0 in
  while !position < length do
    if !position + marker_bytes <= length
      && String.equal (String.sub source !position marker_bytes) marker then begin
      Buffer.add_string buffer owner;
      position := !position + marker_bytes
    end else begin
      Buffer.add_char buffer source.[!position];
      incr position
    end
  done;
  Buffer.contents buffer
let run = Lwt_main.run
let check message condition = if not condition then failwith message

let call ?(caller = owner) ~persist store address method_name params =
  let journal = V.Program_journal.create () in
  let result =
    V.Contract.execute_call ~journal store address method_name params caller Z.zero
  in
  if persist && result.V.Contract.success then V.Program_store.stage store journal;
  result

let bytes_result = function
  | Ok V.Contract_vm.VBytes value -> value
  | Ok V.Contract_vm.VString value -> value
  | Ok _ -> failwith "result is not bytes"
  | Error reason -> failwith reason

let int_result = function
  | Ok V.Contract_vm.VInt value -> Z.to_int value
  | Ok V.Contract_vm.VString value -> Z.to_int (Z.of_string value)
  | Ok _ -> failwith "result is not int"
  | Error reason -> failwith reason

let string_result = function
  | Ok V.Contract_vm.VString value -> value
  | Ok _ -> failwith "result is not string"
  | Error reason -> failwith reason

let address_result = function
  | Ok V.Contract_vm.VAddr value -> value
  | Ok V.Contract_vm.VString value -> value
  | Ok _ -> failwith "result is not address"
  | Error reason -> failwith reason

let frame sequence =
  String.init 2048 (fun index ->
    Char.chr ((index * 31 + sequence * 17 + (index / 251)) land 255))

let sender store address sequence =
  call ~persist:false store address "sender" [`Int sequence]
  |> V.Contract.exec_result_to_result |> address_result

let frames start count =
  String.concat "" (List.init count (fun offset -> frame (start + offset)))

let expect_success label result =
  check (label ^ ": " ^ Option.value result.V.Contract.error ~default:"reverted")
    result.V.Contract.success

let expect_revert label result =
  check (label ^ " unexpectedly succeeded") (not result.V.Contract.success)

let get store address sequence =
  call ~persist:false store address "get" [`Int sequence]
  |> V.Contract.exec_result_to_result |> bytes_result

let info store address =
  call ~persist:false store address "info" []
  |> V.Contract.exec_result_to_result |> string_result

let dedup_key store address raw =
  call ~persist:false store address "dedup_key" [`String raw]
  |> V.Contract.exec_result_to_result |> string_result

let expected_dedup_key raw =
  Octra_net.Hash_domain.hash_encoded_hex "octra:msg:frame:v2" (fun buffer ->
    Octra_net.Oce1.put_bytes buffer raw)

let descriptor_encoding segment activation_epoch record_cap byte_cap previous =
  Octra_net.Oce1.encode (fun buffer ->
    Octra_net.Oce1.put_u16 buffer 1;
    Octra_net.Oce1.put_bytes buffer segment;
    Octra_net.Oce1.put_u64 buffer activation_epoch;
    Octra_net.Oce1.put_u32_int buffer record_cap;
    Octra_net.Oce1.put_u64 buffer byte_cap;
    Octra_net.Oce1.put_option Octra_net.Oce1.put_u64 buffer previous;
    Octra_net.Oce1.put_u8 buffer 1)

let decode_descriptor raw =
  Octra_net.Oce1.decode (fun cursor ->
    let version = Octra_net.Oce1.get_u16 cursor in
    let segment = Octra_net.Oce1.get_string_bounded ~max:47 cursor in
    let activation_epoch = Octra_net.Oce1.get_u64 cursor in
    let record_cap = Octra_net.Oce1.get_u32_int cursor in
    let byte_cap = Octra_net.Oce1.get_u64 cursor in
    let previous = Octra_net.Oce1.get_option Octra_net.Oce1.get_u64 cursor in
    let flags = Octra_net.Oce1.get_u8 cursor in
    check "descriptor version" (version = 1);
    check "descriptor segment" (C.Crypto.Address.is_valid_address segment);
    check "descriptor activation" (activation_epoch >= 0L);
    check "descriptor record cap" (record_cap = 1024);
    check "descriptor byte cap" (byte_cap = 8_388_608L);
    check "descriptor flags" (flags = 1);
    segment, activation_epoch, previous) raw

let expect_invalid_descriptor raw =
  match decode_descriptor raw with
  | _ -> failwith "invalid descriptor accepted"
  | exception Failure _ -> ()

let literal_rejection_controls () =
  List.iter (fun (profile, compile) ->
    List.iter (fun literal ->
      let source = Printf.sprintf
        "program Literal { public view fn value(): bytes { return \"%s\" } }" literal in
      check (profile ^ " invalid literal accepted: " ^ literal) (compile source <> None))
      ["\\x0"; "\\xGG"; "\\x0z"])
    ["oct", (fun source -> (V.Oct_compile.compile source).V.Oct_compile.error);
     "prior", (fun source -> (V.Prior_compile.compile source).V.Oct_compile.error)]

let boolean_text value =
  if String.equal Sys.argv.(3) "legacy" then (if value then "true" else "0")
  else if value then "true" else "false"

let page store address start =
  call ~persist:false store address "page" [`Int start]
  |> V.Contract.exec_result_to_result |> bytes_result

let write_b64 path value =
  let channel = open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_binary] 0o600 path in
  output_string channel (Base64.encode_exn value);
  close_out channel

let write_json path value =
  let channel = open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_binary] 0o600 path in
  output_string channel (Yojson.Safe.to_string value ^ "\n");
  close_out channel

let read_attestation_key path =
  let channel = open_in_bin path in
  let text = String.trim (In_channel.input_all channel) in
  close_in channel;
  if String.length text = 32 then text
  else if String.length text = 64 then
    String.init 32 (fun index ->
      Char.chr (int_of_string ("0x" ^ String.sub text (index * 2) 2)))
  else failwith "attestation key file must contain 32 raw bytes or 64 hex characters"

let attestation_identity () =
  match Sys.getenv_opt "MESSENGER_ATTEST_KEY_FILE", Sys.getenv_opt "MESSENGER_ATTEST_KEY_ID" with
  | None, None -> None
  | Some path, Some key_id ->
    let private_key = read_attestation_key path in
    let secret = match Mirage_crypto_ec.Ed25519.priv_of_octets private_key with
      | Ok value -> value
      | Error _ -> failwith "invalid attestation private key" in
    let public_key = Mirage_crypto_ec.Ed25519.(pub_of_priv secret |> pub_to_octets) in
    Some (key_id, public_key, private_key)
  | _ -> failwith "both MESSENGER_ATTEST_KEY_FILE and MESSENGER_ATTEST_KEY_ID are required"

let native_circle_trace store circle_id owner key_id public_key =
  let trusted = [V.Program_attestation.{id = key_id; public_key}] in
  let loaded = match run (Octra_circle_runtime.Circle_program.load ~table_mode:C.Rule_graph.Prior ~trusted store circle_id) with
    | Ok value -> value
    | Error error -> failwith (C.Circle_wasm_host.error_message error)
  in
  match loaded.code with
  | Octra_circle_runtime.Circle_program.Wasm_v1 _ -> failwith "unexpected Wasm Circle"
  | Octra_circle_runtime.Circle_program.Octb {bytecode; profile} ->
    let ctx = {V.Contract_vm.default_ctx with
      proof_exec = C.Rule_graph.Active;
      current_epoch = 0;
    } in
    let fixed, state = match Octra_circle_runtime.Circle_exec.prepare_octb_call
      ~calls:false ~ctx ~depth:0 ~limit:1_000_000 ~caller:owner ~address:circle_id
      ~value:Z.zero ~method_name:"append" ~params:[`String (frame 0)]
      ~bytecode ~profile ~storage_tbl:(Hashtbl.create 16) with
      | Ok value -> value
      | Error error -> failwith error
    in
    Option.iter (fun entry -> state.V.Contract_vm.pc <- entry) (V.Contract.find_dispatcher fixed);
    let rec loop remaining =
      if remaining = 0 then failwith "native Circle trace did not terminate";
      let pc = state.pc in
      if pc < 0 || pc >= Array.length fixed then
        failwith (Printf.sprintf "native Circle trace stopped at pc %d" pc);
      let instruction = V.Assembler.emit_instr fixed.(pc) in
      match V.Contract_vm.step state fixed with
      | V.Contract_vm.Running -> loop (remaining - 1)
      | V.Contract_vm.Finished -> failwith "native Circle trace unexpectedly finished"
      | V.Contract_vm.Refused ->
        Printf.printf "native_circle_rejected_pc=%d instruction=%s effort=%d reverted=%b\n%!"
          pc instruction state.effort_used state.reverted
    in
    loop 10000

let native_circle_check store_path owner key_id public_key =
  let code_b64 =
    let channel = open_in_bin (store_path ^ ".ocpg.b64") in
    let value = In_channel.input_all channel in
    close_in channel;
    value
  in
  let raw = Base64.decode_exn code_b64 in
  let circle_id = "octMESSENGER_SEGMENT" in
  let store = run (S.open_store (store_path ^ ".circle-receipt")) in
  let info = {
    C.Circles.circle_id;
    runtime = C.Circles.Octb;
    version = 1L;
    owner;
    code_hash = C.Circles.sha256_hex raw;
    stable_root = C.Circles.zero_hash_hex;
    assets_root = C.Circles.zero_hash_hex;
    privacy_class = C.Circles.Public;
    browser_mode = C.Circles.Native_sealed;
    resource_mode = C.Circles.Public_resources;
    policy_hash = None;
    members_root = None;
    export_policy = None;
    limits = C.Circles.default_limits;
  } in
  run (S.deploy_circle store info);
  run (S.save_circle_program_code_b64 store circle_id code_b64);
  run (S.set_circle_asset_usage_bytes store circle_id 0L);
  run (S.begin_epoch_batch ~mode:C.Rule_graph.Active store);
  let journal = V.Program_journal.create () in
  let ctx = {V.Contract_vm.default_ctx with
    proof_exec = C.Rule_graph.Active;
    current_epoch = 0;
  } in
  let result = run (Octra_circle_runtime.Circle_exec.execute_call
    ~trusted:[V.Program_attestation.{id = key_id; public_key}]
    ~journal ~ctx ~limit:1_000_000
    store circle_id "append" [`String (frame 0)] owner Z.zero) in
  let receipt = result.receipt in
  let reason = V.Receipt_view.execution_revert_message receipt.events receipt.error in
  Printf.printf "native_circle_append=%s\n%!" (Yojson.Safe.to_string (`Assoc [
    "success", `Bool receipt.success;
    "effort_used", `Int receipt.effort_used;
    "error", (if receipt.success then `Null else `String reason);
    "events", V.Receipt_view.events_json receipt.events;
  ]));
  if not receipt.success then
    native_circle_trace store circle_id owner key_id public_key;
  check ("native Circle append: " ^ reason) receipt.success;
  S.abort_epoch_batch store;
  run (S.close store)

let deploy_scoped ?(circle_check = false) ~store_path store source =
  let packaged =
    match V.Program_package.compile_sources_at ~metered:true ~loops:true ~compiler:V.Program_package.Protocol
      ~point_ops:true ~main:"main.aml"
      ~sources:[V.Program_package.{ path = "main.aml"; body = source }] with
    | Ok value -> value
    | Error error -> failwith (V.Program_package.error_message error)
  in
  let identity = attestation_identity () in
  let result = match identity with
    | Some (key_id, _, private_key) ->
      let signed = V.Oct_compile.attest_program ~key_id ~private_key packaged.V.Program_package.result in
      (match signed.V.Oct_compile.error with
       | Some reason -> failwith reason
       | None -> signed)
    | None -> packaged.V.Program_package.result in
  let envelope = Option.get result.V.Oct_compile.program_envelope in
  let decoded = match V.Program_envelope.decode envelope with
    | Ok value -> value
    | Error error -> failwith (V.Program_envelope.error_message error)
  in
  check "package format" (String.equal (String.sub envelope 0 4) "OCPG");
  check "embedded bytecode differs from compiler result"
    (String.equal decoded.V.Program_envelope.code result.V.Oct_compile.bytecode);
  check "embedded certificate differs from compiler result"
    (String.equal decoded.V.Program_envelope.cert result.V.Oct_compile.certificate_json);
  let admitted =
    match identity with
    | Some (key_id, public_key, _) ->
      (match V.Code_check.decode_deploy
        ~trusted:[V.Program_attestation.{id = key_id; public_key}] ~point_ops:true envelope with
       | Ok value -> value
       | Error error -> failwith (V.Code_check.error_message error))
    | None ->
      (match V.Code_check.decode_program_source ~point_ops:true envelope with
       | Ok value -> value
       | Error error -> failwith (V.Code_check.error_message error))
  in
  let static_work = match V.Code_check.scalar_cost envelope with
    | Some value -> value
    | None -> failwith "OCPG static work is unavailable" in
  let encoded = Base64.encode_exn envelope in
  let load_work = Z.mul (Z.of_int (String.length encoded)) (Z.of_int 16) in
  let total_work = Z.add load_work static_work in
  let package_hash = Octra_net.Hash_domain.hash_encoded_hex "octra:msg:segment-package:v2"
    (fun buffer -> Octra_net.Oce1.put_bytes buffer envelope) in
  write_b64 (store_path ^ ".ocpg.b64") envelope;
  write_json (store_path ^ ".package.json") (`Assoc [
    "schema", `String "messenger_ocpg_preflight_v1";
    "format", `String "OCPG";
    "compiler_profile", `String "Protocol";
    "compiler_fingerprint", `String V.Source_stamp.id;
    "package_bytes", `Int (String.length envelope);
    "base64_bytes", `Int (String.length encoded);
    "bytecode_bytes", `Int (String.length decoded.V.Program_envelope.code);
    "certificate_bytes", `Int (String.length decoded.V.Program_envelope.cert);
    "package_sha256", `String (Digestif.SHA256.(digest_string envelope |> to_hex));
    "package_hash", `String package_hash;
    "bytecode_sha256", `String (Digestif.SHA256.(digest_string decoded.V.Program_envelope.code |> to_hex));
    "certificate_sha256", `String (Digestif.SHA256.(digest_string decoded.V.Program_envelope.cert |> to_hex));
    "static_work", `String (Z.to_string static_work);
    "load_work", `String (Z.to_string load_work);
    "total_work", `String (Z.to_string total_work);
    "decode_deploy", `String (if Option.is_some identity then "accepted" else "source_only_attestation_required");
    "attestation", (match identity with
      | Some (key_id, public_key, _) -> `Assoc [
        "key_id", `String key_id;
        "public_key", `String (Base64.encode_exn public_key);
        "trusted", `Bool true;
      ]
      | None -> `Null);
    "embedded_code_and_certificate_match", `Bool true;
  ]);
  if circle_check then
    Option.iter (fun (key_id, public_key, _) ->
      native_circle_check store_path owner key_id public_key) identity;
  let journal = V.Program_journal.create () in
  let address, result =
    V.Contract.deploy ~admitted ~journal store owner "CUSTOM" [||] envelope 0
  in
  expect_success "deploy" result;
  V.Program_store.stage store journal;
  address, package_hash

let deploy_legacy ~store_path store source =
  let compiled = V.Oct_compile.compile source in
  (match compiled.V.Oct_compile.error with
   | Some reason -> failwith reason
   | None -> ());
  write_b64 (store_path ^ ".bytecode.b64") compiled.V.Oct_compile.bytecode;
  let journal = V.Program_journal.create () in
  let address, result =
    V.Contract.deploy ~journal store owner "CUSTOM" [||]
      compiled.V.Oct_compile.bytecode 0
  in
  expect_success "deploy" result;
  V.Program_store.stage store journal;
  address, Octra_net.Hash_domain.hash_encoded_hex "octra:msg:segment-bytecode:v2"
  (fun buffer -> Octra_net.Oce1.put_bytes buffer compiled.V.Oct_compile.bytecode)

let registry_checks store_path profile source_path =
  let channel = open_in_bin source_path in
  let source = In_channel.input_all channel in
  close_in channel;
  let source = instantiate source owner in
  let store = run (S.open_store store_path) in
  run (S.begin_epoch_batch ~mode:C.Rule_graph.Prior store);
  let address, code_hash = match profile with
    | "legacy" -> deploy_legacy ~store_path store source
    | "scoped" -> deploy_scoped ~store_path store source
    | _ -> failwith "unknown registry compiler profile" in
  let segment = "oct" ^ String.make 44 (Char.chr 51) in
  let root_before_reject = run (S.get_batch_tree_hash store) in
  call ~caller:stranger ~persist:true store address "publish" [`String segment; `Int 10]
  |> expect_revert "non-owner registry publish";
  check "non-owner registry publish changed root"
    (root_before_reject = (run (S.get_batch_tree_hash store)));
  let first = call ~persist:true store address "publish" [`String segment; `Int 10]
    |> V.Contract.exec_result_to_result |> int_result in
  check "first registry id" (first = 0);
  let root_before_second_reject = run (S.get_batch_tree_hash store) in
  call ~caller:stranger ~persist:true store address "publish" [`String segment; `Int 11]
  |> expect_revert "second non-owner registry publish";
  check "second non-owner registry publish changed root"
    (root_before_second_reject = (run (S.get_batch_tree_hash store)));
  let second = call ~persist:true store address "publish" [`String segment; `Int 11]
    |> V.Contract.exec_result_to_result |> int_result in
  check "second registry id" (second = 1);
  check "registry owner" ((call ~persist:false store address "owner" []
    |> V.Contract.exec_result_to_result |> string_result) = owner);
  check "registry count" ((call ~persist:false store address "count" []
    |> V.Contract.exec_result_to_result |> int_result) = 2);
  let descriptor segment_id =
    call ~persist:false store address "descriptor" [`Int segment_id]
    |> V.Contract.exec_result_to_result |> bytes_result in
  let first_raw = descriptor_encoding segment 10L 1024 8_388_608L None in
  let second_raw = descriptor_encoding segment 11L 1024 8_388_608L (Some 0L) in
  check "first descriptor" (descriptor 0 = first_raw);
  check "second descriptor" (descriptor 1 = second_raw);
  check "first descriptor decode"
    (decode_descriptor first_raw = (segment, 10L, None));
  check "second descriptor decode"
    (decode_descriptor second_raw = (segment, 11L, Some 0L));
  for length = 0 to String.length second_raw - 1 do
    expect_invalid_descriptor (String.sub second_raw 0 length)
  done;
  expect_invalid_descriptor (second_raw ^ "\000");
  let invalid_version = Bytes.of_string second_raw in
  Bytes.set invalid_version 1 '\000';
  expect_invalid_descriptor (Bytes.to_string invalid_version);
  let invalid_option = Bytes.of_string second_raw in
  Bytes.set invalid_option (String.length second_raw - 10) '\002';
  expect_invalid_descriptor (Bytes.to_string invalid_option);
  run (S.commit_epoch_batch store "messenger registry spike");
  run (S.close store);
  let store = run (S.open_store store_path) in
  check "restart registry descriptor" ((call ~persist:false store address "descriptor" [`Int 0]
    |> V.Contract.exec_result_to_result |> bytes_result) = first_raw);
  run (S.close store);
  Printf.printf "{\"status\":\"pass\",\"registry\":\"%s\",\"code_hash\":\"%s\",\"non_owner_rejected\":true,\"restart_reads\":true}\n%!"
    address code_hash

let () =
  if Array.length Sys.argv <> 4 then
    failwith "usage: segment_spike_driver SOURCE STORE legacy|scoped";
  let source_path = Sys.argv.(1) in
  let store_path = Sys.argv.(2) in
  let channel = open_in_bin source_path in
  let source = In_channel.input_all channel in
  close_in channel;
  let source = instantiate source owner in
  check "invalid segment owner" (C.Crypto.Address.is_valid_address owner);
  literal_rejection_controls ();
  let store = run (S.open_store store_path) in
  run (S.begin_epoch_batch ~mode:C.Rule_graph.Prior store);
  let address, code_hash = match Sys.argv.(3) with
    | "legacy" -> deploy_legacy ~store_path store source
    | "scoped" -> deploy_scoped ~circle_check:true ~store_path store source
    | _ -> failwith "unknown compiler profile" in
  for sequence = 0 to 20 do
    let raw = frame sequence in
    let expected = expected_dedup_key raw in
    check "frame dedup digest" (dedup_key store address raw = expected);
    check "frame digest length" (String.length expected = 64)
  done;
  for sequence = 0 to 19 do
    let result =
      call ~persist:true store address "append" [`String (frame sequence)]
      |> V.Contract.exec_result_to_result |> int_result
    in
    check "append sequence" (result = sequence)
  done;
  let root_before_reject = run (S.get_batch_tree_hash store) in
  call ~caller:stranger ~persist:true store address "append" [`String (frame 20)]
  |> expect_revert "non-writer append";
  check "non-writer append changed root"
    (root_before_reject = (run (S.get_batch_tree_hash store)));
  call ~persist:true store address "grant_writer" [`String stranger]
  |> expect_success "grant writer";
  call ~caller:stranger ~persist:true store address "append" [`String (frame 20)]
  |> expect_success "granted append";
  check "granted writer sequence" (sender store address 20 = stranger);
  check "embedded owner" ((call ~persist:false store address "owner" []
    |> V.Contract.exec_result_to_result |> address_result) = owner);
  check "owner senders" (List.for_all (fun sequence -> sender store address sequence = owner)
    (List.init 20 Fun.id));
  call ~persist:true store address "append" [`String (frame 0)]
  |> expect_revert "duplicate frame";
  call ~persist:true store address "append" [`String (String.make 2047 (Char.chr 0))]
  |> expect_revert "short frame";
  let info_after_reject = info store address in
  Printf.printf "info_after_reject=%s\n%!" info_after_reject;
  check "rejected append changed count"
    (String.equal info_after_reject ("1|2048|21|43008|8388608|" ^ boolean_text false));
  let actual_page = page store address 0 in
  let expected_page = frames 0 16 in
  let mismatch = ref (-1) in
  for index = 0 to min (String.length actual_page) (String.length expected_page) - 1 do
    if !mismatch = -1 && actual_page.[index] <> expected_page.[index] then mismatch := index
  done;
  Printf.printf "page_debug actual_bytes = %d expected_bytes = %d first_mismatch = %d\n%!"
    (String.length actual_page) (String.length expected_page) !mismatch;
  check "first page" (String.equal actual_page expected_page);
  check "second page" (String.equal (page store address 4) (frames 4 16));
  call ~persist:false store address "page" [`Int 6]
  |> expect_revert "partial page";
  List.iter (fun sequence ->
    check "get round trip" (String.equal (get store address sequence) (frame sequence)))
    (List.init 20 Fun.id);
  run (S.commit_epoch_batch store "messenger segment spike");
  run (S.close store);
  let store = run (S.open_store store_path) in
  check "restart page" (String.equal (page store address 0) (frames 0 16));
  check "restart tail" (String.equal (get store address 20) (frame 20));
  let storage = run (S.load_contract_storage store address) in
  List.iter (fun sequence ->
    let present = Hashtbl.fold (fun _ value found -> found || String.equal value (frame sequence)) storage false in
    check "stored frame bytes differ" present)
    (List.init 21 Fun.id);
  run (S.begin_epoch_batch ~mode:C.Rule_graph.Prior store);
  call ~caller:stranger ~persist:true store address "close" []
  |> expect_revert "stranger close";
  call ~persist:true store address "close" [] |> expect_success "close";
  run (S.commit_epoch_batch store "messenger segment close");
  run (S.close store);
  let store = run (S.open_store store_path) in
  let closed_info = info store address in
  Printf.printf "closed_info=%s\n%!" closed_info;
  check "closed info" (String.equal closed_info
    ("1|2048|21|43008|8388608|" ^ boolean_text true));
  run (S.begin_epoch_batch ~mode:C.Rule_graph.Prior store);
  call ~persist:true store address "append" [`String (frame 21)]
  |> expect_revert "closed append";
  check "closed append changed count" (String.equal (get store address 20) (frame 20));
  S.abort_epoch_batch store;
  run (S.close store);
  Option.iter (fun registry_source -> registry_checks (store_path ^ ".registry") Sys.argv.(3) registry_source)
    (Sys.getenv_opt "MESSENGER_REGISTRY_SOURCE");
  Printf.printf "{\"status\":\"pass\",\"address\":\"%s\",\"code_hash\":\"%s\",\"frames\":21,\"frame_bytes\":2048,\"page_records\":16,\"restart_reads\":true,\"closed\":true}\n%!"
    address code_hash
