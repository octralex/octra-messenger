(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    In_channel.input_all channel)

let write_file path value =
  let temporary = Printf.sprintf "%s.tmp.%d" path (Unix.getpid ()) in
  let channel = open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_binary] 0o600 temporary in
  output_string channel value;
  flush channel;
  Unix.fsync (Unix.descr_of_out_channel channel);
  close_out channel;
  Unix.rename temporary path;
  let directory = Unix.openfile (Filename.dirname path) [Unix.O_RDONLY] 0 in
  Unix.fsync directory;
  Unix.close directory

let string_field name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> value
  | _ -> failwith ("missing string field " ^ name)

let request_body method_name params =
  `Assoc [
    "jsonrpc", `String "2.0";
    "id", `Int 1;
    "method", `String method_name;
    "params", `List params;
  ] |> Yojson.Safe.to_string

let rpc_body ~url body_text =
  let body = Cohttp_lwt.Body.of_string body_text in
  let headers = Cohttp.Header.of_list [
    "content-type", "application/json";
    "user-agent", "octra-messenger-chain-spike/1";
  ] in
  let open Lwt.Infix in
  Cohttp_lwt_unix.Client.post ~headers ~body (Uri.of_string url)
  >>= fun (_response, body) ->
  Cohttp_lwt.Body.to_string body >|= fun raw ->
  match Yojson.Safe.from_string raw with
  | `Assoc fields ->
    begin
      match List.assoc_opt "error" fields with
      | Some error -> failwith ("RPC rejected: " ^ Yojson.Safe.to_string error)
      | None ->
        begin
          match List.assoc_opt "result" fields with
          | Some result -> result
          | None -> failwith ("RPC result missing: " ^ raw)
        end
    end
  | _ -> failwith ("invalid RPC response: " ^ raw)
  | exception Yojson.Json_error _ -> failwith ("invalid RPC JSON: " ^ raw)

let rpc ~url ~method_name ~params = rpc_body ~url (request_body method_name params)

let submit_raw ~url raw =
  let tx =
    match Octra_core.Transaction.of_network_yojson (Yojson.Safe.from_string raw) with
    | Ok value -> value
    | Error reason -> failwith reason in
  let body = Printf.sprintf
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"octra_submit\",\"params\":[%s]}" raw in
  let result = Lwt_main.run (rpc_body ~url body) in
  let output = `Assoc [
    "status", `String "submitted";
    "tx_hash", `String (Octra_core.Transaction.hash tx);
    "signed_json_bytes", `Int (String.length raw);
    "rpc_request_bytes", `Int (String.length body);
    "signed_json_sha256", `String (Octra_net.Hash_domain.hash_encoded_hex "octra:msg:signed-json:v2"
  (fun buffer -> Octra_net.Oce1.put_bytes buffer raw));
    "ou", `String (Z.to_string tx.Octra_core.Transaction.ou);
    "ou_cost", `String (Z.to_string (Octra_core.Transaction.ou_cost tx));
    "rpc_result", result;
  ] in
  print_endline (Yojson.Safe.to_string output)

let submit_tx ~url ~output_path tx priv =
  let signed = Octra_core.Transaction.sign_with_privkey tx priv in
  let raw = Yojson.Safe.to_string (Octra_core.Transaction.to_yojson signed) in
  write_file output_path raw;
  submit_raw ~url raw

let load_wallet path =
  let json = Yojson.Safe.from_string (read_file path) in
  string_field "address" json, string_field "pub" json, string_field "priv" json

let operation = function
  | "legacy-deploy" -> Octra_core.Transaction.ContractDeploy
  | "deploy" -> Octra_core.Transaction.ProgramDeploy
  | "legacy-exec" -> Octra_core.Transaction.ContractCall
  | "exec" -> Octra_core.Transaction.ProgramExec
  | "circle-exec" -> Octra_core.Transaction.CircleCall
  | "multi" -> Octra_core.Transaction.MultiExec
  | _ -> failwith "unsupported operation"

let base_tx ~op ~from ~to_ ~nonce ~ou ~public_key ~message ~encrypted_data =
  Octra_core.Transaction.{
    from;
    to_;
    amount = Z.zero;
    nonce;
    ou = Z.of_string ou;
    timestamp = Unix.gettimeofday ();
    signature = "";
    public_key = Some public_key;
    message = Some message;
    encrypted_data;
    op_type = op;
  }

let parameter_text value =
  if String.starts_with ~prefix:"@" value then
    read_file (String.sub value 1 (String.length value - 1))
  else value

let deploy kind url wallet_path nonce ou payload_path params output_path =
  let from, public_key, priv = load_wallet wallet_path in
  let payload = String.trim (read_file payload_path) in
  let result = Lwt_main.run (rpc ~url ~method_name:"octra_computeContractAddress"
    ~params:[`String payload; `String from; `Int nonce]) in
  let target = string_field "address" result in
  let tx = base_tx ~op:(operation kind) ~from ~to_:target ~nonce ~ou
    ~public_key ~message:(parameter_text params) ~encrypted_data:(Some payload) in
  submit_tx ~url ~output_path tx priv

let circle_deploy url wallet_path nonce ou payload_path output_path =
  let from, public_key, priv = load_wallet wallet_path in
  let payload = match Octra_core.Circles.deploy_payload_of_yojson
    (Yojson.Safe.from_string (read_file payload_path)) with
    | Ok value -> value
    | Error reason -> failwith reason in
  let target = Octra_core.Circles.circle_id_of_deploy ~deployer:from ~nonce payload in
  let message = Yojson.Safe.to_string (Octra_core.Circles.yojson_of_deploy_payload payload) in
  let tx = base_tx ~op:Octra_core.Transaction.CircleDeploy ~from ~to_:target ~nonce ~ou
    ~public_key ~message ~encrypted_data:None in
  submit_tx ~url ~output_path tx priv

let circle_view url target method_name params =
  let params = Yojson.Safe.from_string (parameter_text params) in
  let result = Lwt_main.run (rpc ~url ~method_name:"octra_circleView"
    ~params:[`String target; `String method_name; params]) in

  print_endline (Yojson.Safe.to_string result)

let exec kind url wallet_path nonce ou target method_name params output_path =
  let from, public_key, priv = load_wallet wallet_path in
  let tx = base_tx ~op:(operation kind) ~from ~to_:target ~nonce ~ou
    ~public_key ~message:(parameter_text params) ~encrypted_data:(Some method_name) in
  submit_tx ~url ~output_path tx priv

let multi url wallet_path nonce ou params output_path =
  let from, public_key, priv = load_wallet wallet_path in
  let tx = base_tx ~op:Octra_core.Transaction.MultiExec ~from ~to_:"multi_exec" ~nonce ~ou
    ~public_key ~message:(parameter_text params) ~encrypted_data:None in
  submit_tx ~url ~output_path tx priv

let () =
  Mirage_crypto_rng_unix.use_default ();
  match Array.to_list Sys.argv with
  | [_; (("deploy" | "legacy-deploy") as kind); url; wallet; nonce; ou; payload; params; output] ->
    deploy kind url wallet (int_of_string nonce) ou payload params output
  | [_; (("exec" | "legacy-exec" | "circle-exec") as kind); url; wallet; nonce; ou; target; method_name; params; output] ->
    exec kind url wallet (int_of_string nonce) ou target method_name params output
  | [_; "circle-deploy"; url; wallet; nonce; ou; payload; output] ->
    circle_deploy url wallet (int_of_string nonce) ou payload output
  | [_; "circle-view"; url; target; method_name; params] -> circle_view url target method_name params
  | [_; "multi"; url; wallet; nonce; ou; params; output] ->
    multi url wallet (int_of_string nonce) ou params output
  | [_; "resubmit"; url; signed] -> submit_raw ~url (read_file signed)
  | _ -> failwith "usage: deploy|legacy-deploy|exec|legacy-exec|resubmit ..."
