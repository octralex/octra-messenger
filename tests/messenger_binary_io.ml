module V = Octra_vm
module N = Octra_node_runtime

let check reason value = if not value then failwith reason

let binary ?(encoding = "base64") data =
  `Assoc ["encoding", `String encoding; "data", `String data]

(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

let expect_legacy_rejection reason json =
  match V.Contract.parse_param json with
  | exception Invalid_argument _ -> ()
  | _ -> failwith reason

let expect_program_rejection reason json =
  match V.Program_input.parse [V.Program_type_flow.Bytes] [json] with
  | Error _ -> ()
  | Ok _ -> failwith reason

let reject_both reason json =
  expect_legacy_rejection (reason ^ " legacy") json;
  expect_program_rejection (reason ^ " program") json

let accept_both json =
  begin
    match V.Contract.parse_param json with
    | V.Contract_vm.VBytes "A" -> ()
    | _ -> failwith "legacy canonical byte mismatch"
  end;
  match V.Program_input.parse [V.Program_type_flow.Bytes] [json] with
  | Ok [V.Contract_vm.VBytes "A"] -> ()
  | _ -> failwith "program canonical byte mismatch"

let decoded = function
  | `String value -> value
  | `Assoc fields ->
    begin
      match List.assoc_opt "encoding" fields, List.assoc_opt "data" fields with
      | Some (`String "base64"), Some (`String data) -> Base64.decode_exn data
      | _ -> failwith "invalid byte output envelope"
    end
  | _ -> failwith "invalid byte output type"

let check_union reason json expected =
  let encoded = Yojson.Safe.to_string json in
  let parsed = Yojson.Safe.from_string encoded in
  check reason (decoded parsed = expected)

let member name = Yojson.Safe.Util.member name

let test_inputs () =
  accept_both (binary "QQ==");
  accept_both (`Assoc ["data", `String "QQ=="; "encoding", `String "base64"]);
  List.iter (fun json -> reject_both "invalid base64" json)
    [binary "not base64"; binary "QQ"; binary "QR=="];
  List.iter (fun json -> reject_both "invalid binary envelope" json)
    [binary ~encoding:"hex" "QQ==";
     `Assoc ["encoding", `String "base64"];
     `Assoc ["data", `String "QQ=="];
     `Assoc ["encoding", `String "base64"; "data", `Int 1];
     `Assoc ["encoding", `String "base64"; "data", `String "QQ=="; "extra", `Int 1];
     `Assoc ["encoding", `String "base64"; "data", `String "QQ=="; "data", `String "QR=="];
     `Assoc ["encoding", `String "base64"; "encoding", `String "base64"]];
  check "unrelated legacy object fallback changed"
    (V.Contract.parse_param (`Assoc ["foo", `Int 1; "bar", `Int 2]) = V.Contract_vm.VString "");
  print_endline "status = pass test = binary_input_shapes_and_canonical_base64"

let test_outputs () =
  check_union "empty result" (V.Receipt_view.result_json (V.Contract_vm.VString "")) "";
  check_union "ASCII result" (V.Receipt_view.result_json (V.Contract_vm.VString "hello")) "hello";
  check_union "invalid result" (V.Receipt_view.result_json (V.Contract_vm.VString "\xff")) "\xff";
  let event = V.Receipt_view.event_json
    {contract = "contract"; depth = 0; event = "event"; values = [V.Contract_vm.VString "\xfe"]} in
  let values = match member "values" event with `List values -> values | _ -> failwith "event values" in
  check_union "invalid event" (List.hd values) "\xfe";
  let storage = V.Contract_rpc.storage_value ~key:"key" ~value:"λ" ~limit:1 in
  check "storage size" (member "size" storage = `Int 2);
  check "storage truncation" (member "truncated" storage = `Bool true);
  check_union "multibyte truncation" (member "value" storage) (String.sub "λ" 0 1);
  let page = N.Rpc_view.storage_assoc ~limit:1 ["key", "λ"; "empty", ""; "ascii", "A"] in
  check_union "page multibyte truncation" (member "key" page) (String.sub "λ" 0 1);
  check_union "page empty" (member "empty" page) "";
  check_union "page ASCII" (member "ascii" page) "A";
  let raw_key = N.Rpc_view.storage_assoc ["\xff", "value"] in
  begin
    match raw_key with
    | `Assoc [(key, `String "value")] -> check "storage key encoding changed" (key = "\xff")
    | _ -> failwith "storage key case shape"
  end;
  print_endline "status = pass test = byte_output_union_and_truncation";
  print_endline "limit = storage keys remain raw legacy strings and are not base64 envelope encoded"

let () =
  test_inputs ();
  test_outputs ()
