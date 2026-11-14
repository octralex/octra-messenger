module C = Octra_core
module V = Octra_vm
module S = C.Store_irmin

let owner = "oct" ^ String.make 44 (Char.chr 49)
let stranger = "oct" ^ String.make 44 (Char.chr 50)
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

let frame sequence =
  String.init 2048 (fun index ->
    Char.chr ((index * 31 + sequence * 17 + (index / 251)) land 255))

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

let page store address start =
  call ~persist:false store address "page" [`Int start]
  |> V.Contract.exec_result_to_result |> bytes_result

let deploy_scoped store source =
  let packaged =
    match V.Program_package.compile_sources_at ~metered:true ~loops:true ~compiler:V.Program_package.Protocol
      ~point_ops:true ~main:"main.aml"
      ~sources:[V.Program_package.{ path = "main.aml"; body = source }] with
    | Ok value -> value
    | Error error -> failwith (V.Program_package.error_message error)
  in
  let admitted =
    match V.Code_check.decode_program_source ~point_ops:true packaged.V.Program_package.envelope with
    | Ok value -> value
    | Error error -> failwith (V.Code_check.error_message error)
  in
  let journal = V.Program_journal.create () in
  let address, result =
    V.Contract.deploy ~admitted ~journal store owner "CUSTOM" [||]
      packaged.V.Program_package.envelope 0
  in
  expect_success "deploy" result;
  V.Program_store.stage store journal;
  address, Digestif.SHA256.(digest_string packaged.V.Program_package.envelope |> to_hex)

let deploy_legacy store source =
  let compiled = V.Oct_compile.compile source in
  (match compiled.V.Oct_compile.error with
   | Some reason -> failwith reason
   | None -> ());
  let journal = V.Program_journal.create () in
  let address, result =
    V.Contract.deploy ~journal store owner "CUSTOM" [||]
      compiled.V.Oct_compile.bytecode 0
  in
  expect_success "deploy" result;
  V.Program_store.stage store journal;
  address, Digestif.SHA256.(digest_string compiled.V.Oct_compile.bytecode |> to_hex)

let () =
  if Array.length Sys.argv <> 4 then
    failwith "usage: segment_spike_driver SOURCE STORE legacy|scoped";
  let source_path = Sys.argv.(1) in
  let store_path = Sys.argv.(2) in
  let channel = open_in_bin source_path in
  let source = In_channel.input_all channel in
  close_in channel;
  let store = run (S.open_store store_path) in
  run (S.begin_epoch_batch ~mode:C.Rule_graph.Prior store);
  let address, code_hash = match Sys.argv.(3) with
    | "legacy" -> deploy_legacy store source
    | "scoped" -> deploy_scoped store source
    | _ -> failwith "unknown compiler profile" in
  for sequence = 0 to 19 do
    let result =
      call ~persist:true store address "append" [`String (frame sequence)]
      |> V.Contract.exec_result_to_result |> int_result
    in
    check "append sequence" (result = sequence)
  done;
  let root_before_reject = run (S.get_batch_tree_hash store) in
  call ~persist:true store address "append" [`String (String.make 2047 (Char.chr 0))]
  |> expect_revert "short frame";
  check "rejected append changed root"
    (root_before_reject = (run (S.get_batch_tree_hash store)));
  check "rejected append changed count"
    (String.equal (info store address) "1|2048|20|40960|8388608|false");
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
  call ~persist:false store address "page" [`Int 5]
  |> expect_revert "partial page";
  List.iter (fun sequence ->
    check "get round trip" (String.equal (get store address sequence) (frame sequence));
    let actual =
      call ~persist:false store address "content_hash" [`Int sequence]
      |> V.Contract.exec_result_to_result |> string_result
    in
    let expected = Digestif.SHA256.(digest_string (frame sequence) |> to_hex) in
    check "content hash" (String.equal actual expected))
    (List.init 20 Fun.id);
  run (S.commit_epoch_batch store "messenger segment spike");
  run (S.close store);
  let store = run (S.open_store store_path) in
  check "restart page" (String.equal (page store address 0) (frames 0 16));
  check "restart tail" (String.equal (get store address 19) (frame 19));
  let storage = run (S.load_contract_storage store address) in
  List.iter (fun sequence ->
    let present = Hashtbl.fold (fun _ value found -> found || String.equal value (frame sequence)) storage false in
    check "stored frame bytes differ" present)
    (List.init 20 Fun.id);
  run (S.begin_epoch_batch ~mode:C.Rule_graph.Prior store);
  call ~caller:stranger ~persist:true store address "close" []
  |> expect_revert "stranger close";
  call ~persist:true store address "close" [] |> expect_success "close";
  run (S.commit_epoch_batch store "messenger segment close");
  run (S.close store);
  let store = run (S.open_store store_path) in
  check "closed info" (String.equal (info store address) "1|2048|20|40960|8388608|true");
  run (S.begin_epoch_batch ~mode:C.Rule_graph.Prior store);
  call ~persist:true store address "append" [`String (frame 20)]
  |> expect_revert "closed append";
  check "closed append changed count" (String.equal (get store address 19) (frame 19));
  S.abort_epoch_batch store;
  run (S.close store);
  Printf.printf "{\"status\":\"pass\",\"address\":\"%s\",\"code_hash\":\"%s\",\"frames\":20,\"frame_bytes\":2048,\"page_records\":16,\"restart_reads\":true,\"closed\":true}\n%!"
    address code_hash
