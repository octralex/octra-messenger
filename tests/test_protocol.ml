(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

open Octra_messenger
module Oce1 = Octra_net.Oce1
module Hash_domain = Octra_net.Hash_domain

let get = function Ok value -> value | Error reason -> failwith reason
let expect_error label = function Ok _ -> failwith (label ^ " accepted") | Error _ -> ()
let check label condition = if not condition then failwith label

let test_frames () =
  List.iter (fun size ->
    let raw = String.init size (fun index -> Char.chr (index land 255)) in
    let frame = get (Frame.of_bytes raw) in
    check "frame round trip" (String.equal (Frame.to_bytes frame) raw);
    check "frame size" (Frame.size frame = size);
    check "frame hash" (String.equal (Frame.hash frame)
      (Hash_domain.hash_encoded_hex "octra:msg:frame:v2" (fun buffer -> Oce1.put_bytes buffer raw)));
    check "frame dedup" (String.equal (Frame.dedup_key frame) (Frame.hash frame)))
    [2048; 4096];
  for size = 0 to 5000 do
    let raw = String.make size '\255' in
    match Frame.of_bytes raw with
    | Ok frame -> check "frame sweep bucket" (Frame.size frame = size)
    | Error _ -> check "frame sweep rejection" (size <> 2048 && size <> 4096)
  done;
  expect_error "negative ciphertext" (Frame.for_ciphertext_size (-1));
  expect_error "large ciphertext" (Frame.for_ciphertext_size 4097);
  check "plaintext limit" (Frame.max_plaintext_bytes = 1024)

let context = {
  Session_context.version = 2;
  chain_id = "octra-fakenet-1";
  application = "onchain-messenger";
  registry = "oct" ^ String.make 44 '2';
  format_version = 1;
  suite = 1;
}

let test_context () =
  let encoded = get (Session_context.encode context) in
  let decoded = get (Session_context.decode encoded) in
  check "context round trip" (Session_context.equal context decoded);
  check "context canonical" (String.equal (get (Session_context.encode decoded)) encoded);
  let v1 = Bytes.of_string encoded in
  Bytes.set v1 6 '\000'; Bytes.set v1 7 '\001';
  check "context v1 rejected" (Session_context.decode (Bytes.to_string v1) = Error "unsupported version 1");
  check "context legacy tag rejected"
    (Session_context.decode "OCMCTX\000\001\002\003\004\005\006" = Error "unsupported version 1");
  let wrong_application = { context with application = "other-application" } in
  check "wrong application changes context"
    (not (String.equal encoded (get (Session_context.encode wrong_application))));
  let unsupported = Bytes.of_string encoded in
  Bytes.set unsupported 6 '\000'; Bytes.set unsupported 7 '\099';
  check "context unknown version" (Session_context.decode (Bytes.to_string unsupported) = Error "unsupported version 99");
  expect_error "context trailing" (Session_context.decode (encoded ^ "\000"));
  for length = 0 to String.length encoded - 1 do
    expect_error "context truncation" (Session_context.decode (String.sub encoded 0 length))
  done;
  let wrong_network = { context with chain_id = "octra-devnet-9871-cluster" } in
  check "wrong network changes context"
    (not (String.equal encoded (get (Session_context.encode wrong_network))));
  let wrong_registry = { context with registry = "oct" ^ String.make 44 '3' } in
  check "wrong registry changes context"
    (not (String.equal encoded (get (Session_context.encode wrong_registry))));
  let downgrade = { context with format_version = 0 } in
  expect_error "downgrade" (Session_context.encode downgrade);
  let suite_zero = { context with suite = 0 } in
  expect_error "unknown suite" (Session_context.encode suite_zero)

let cursor = {
  Cursor.epoch = 1833111L;
  sequence = 1023;
  segment = "oct" ^ String.make 44 '4';
  state_root = "4d7f346cb7f218a0d52da1dbb6fe704dbe770f4c04ebd024dc4ba46b57a954a9";
}

let test_cursor () =
  let encoded = get (Cursor.encode cursor) in
  check "cursor length" (String.length encoded = Cursor.encoded_length);
  check "cursor round trip" (get (Cursor.decode encoded) = cursor);
  check "cursor canonical" (String.equal (get (Cursor.encode (get (Cursor.decode encoded)))) encoded);
  let v1 = Bytes.of_string encoded in
  Bytes.set v1 6 '\000'; Bytes.set v1 7 '\001';
  check "cursor v1 rejected" (Cursor.decode (Bytes.to_string v1) = Error "unsupported version 1");
  let unsupported = Bytes.of_string encoded in
  Bytes.set unsupported 6 '\000'; Bytes.set unsupported 7 '\099';
  check "cursor unknown version" (Cursor.decode (Bytes.to_string unsupported) = Error "unsupported version 99");
  expect_error "cursor trailing" (Cursor.decode (encoded ^ "\000"));
  for length = 0 to String.length encoded - 1 do
    expect_error "cursor truncation" (Cursor.decode (String.sub encoded 0 length))
  done;
  expect_error "negative epoch" (Cursor.encode { cursor with epoch = -1L });
  expect_error "negative sequence" (Cursor.encode { cursor with sequence = -1 });
  expect_error "uppercase root" (Cursor.encode { cursor with state_root = String.uppercase_ascii cursor.state_root });
  let maximum = { cursor with epoch = Int64.max_int; sequence = Int64.to_int 0xffff_ffffL } in
  check "cursor maximum" (get (Cursor.decode (get (Cursor.encode maximum))) = maximum);
  expect_error "host sequence overflow" (Cursor.encode { cursor with sequence = max_int })

let request = { Page.start = 0; max_records = 64; max_bytes = 262144 }

let test_pages () =
  let next = get (Page.complete request ~frame_bytes:2048 ~returned_records:64 ~returned_bytes:131072) in
  check "page next" (next.Page.start = 64);
  let next = get (Page.complete request ~frame_bytes:4096 ~returned_records:64 ~returned_bytes:262144) in
  check "page large next" (next.Page.start = 64);
  expect_error "page records" (Page.complete { request with max_records = 65 }
    ~frame_bytes:2048 ~returned_records:0 ~returned_bytes:0);
  expect_error "page bytes" (Page.complete request
    ~frame_bytes:2048 ~returned_records:64 ~returned_bytes:131073);
  expect_error "partial frame" (Page.complete request
    ~frame_bytes:2048 ~returned_records:1 ~returned_bytes:2047);
  expect_error "empty nonzero page" (Page.complete request
    ~frame_bytes:2048 ~returned_records:0 ~returned_bytes:2048);
  expect_error "negative start" (Page.complete { request with start = -1 }
    ~frame_bytes:2048 ~returned_records:0 ~returned_bytes:0)

let test_encoding () =
  let left = Hash_domain.hash_encoded_hex "octra:test:split:v2" (fun buffer ->
    Oce1.put_bytes buffer "ab"; Oce1.put_bytes buffer "c") in
  let right = Hash_domain.hash_encoded_hex "octra:test:split:v2" (fun buffer ->
    Oce1.put_bytes buffer "a"; Oce1.put_bytes buffer "bc") in
  check "structured field split" (not (String.equal left right));
  let encoded = Oce1.encode (fun buffer ->
    Oce1.put_string buffer "octra:test:split:v2";
    Oce1.put_bytes buffer "ab";
    Oce1.put_bytes buffer "c") in
  let cursor = Oce1.make_cursor encoded in
  check "label" (Oce1.get_string cursor = "octra:test:split:v2");
  check "first field" (Oce1.get_string cursor = "ab");
  check "second field" (Oce1.get_string cursor = "c");
  check "encoding exhausted" (Oce1.remaining cursor = 0)

let () =
  test_encoding ();
  test_frames ();
  test_context ();
  test_cursor ();
  test_pages ();
  print_endline "protocol = pass frames = 5001 context = canonical cursor = canonical pages = bounded"
