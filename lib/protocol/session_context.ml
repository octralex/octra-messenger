(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

module Oce1 = Octra_net.Oce1

type t = {
  version : int;
  chain_id : string;
  application : string;
  registry : string;
  format_version : int;
  suite : int;
}

let ( let* ) = Result.bind
let current_version = 2
let magic = "OCMCTX"
let max_field = 64
let max_encoded = 8 + (3 * (4 + max_field)) + 2 + 1

let make ~chain_id ~application ~registry ~format_version ~suite =
  { version = current_version; chain_id; application; registry; format_version; suite }

let validate_field name value =
  let length = String.length value in
  if length = 0 || length > max_field then Error (name ^ " length outside bounds") else Ok ()

let validate context =
  if context.version <> current_version then Error (Printf.sprintf "unsupported version %d" context.version)
  else
    let* () = validate_field "chain id" context.chain_id in
    let* () = validate_field "application" context.application in
    let* () = validate_field "registry" context.registry in
    if context.format_version <= 0 || context.format_version > 65535 then
      Error "format version outside bounds"
    else if context.suite <= 0 || context.suite > 255 then Error "suite outside bounds"
    else Ok ()

let encode context =
  let* () = validate context in
  Ok (Oce1.encode (fun buffer ->
    Oce1.put_raw buffer magic;
    Oce1.put_u16 buffer context.version;
    Oce1.put_bytes buffer context.chain_id;
    Oce1.put_bytes buffer context.application;
    Oce1.put_bytes buffer context.registry;
    Oce1.put_u16 buffer context.format_version;
    Oce1.put_u8 buffer context.suite))

let take_bounded cursor =
  if Oce1.remaining cursor < 4 then Error "context truncated"
  else
    let length = Oce1.get_u32_int cursor in
    if length <= 0 || length > max_field then Error "context field length outside bounds"
    else if Oce1.remaining cursor < length then Error "context truncated"
    else Ok (Oce1.get_raw cursor length)

let decode text =
  let length = String.length text in
  if length < 12 then Error "context length outside bounds"
  else if not (String.equal (String.sub text 0 6) magic) then Error "unsupported context type"
  else
    let cursor = Oce1.make_cursor text in
    ignore (Oce1.get_raw cursor 6);
    match Oce1.get_u16 cursor with
    | 2 as version ->
      let* chain_id = take_bounded cursor in
      let* application = take_bounded cursor in
      let* registry = take_bounded cursor in
      if Oce1.remaining cursor <> 3 then Error "context trailing or truncated bytes"
      else
        let format_version = Oce1.get_u16 cursor in
        let suite = Oce1.get_u8 cursor in
        validate { version; chain_id; application; registry; format_version; suite }
        |> Result.map (fun () -> { version; chain_id; application; registry; format_version; suite })
    | version -> Error (Printf.sprintf "unsupported version %d" version)

let equal left right =
  left.version = right.version
  && String.equal left.chain_id right.chain_id
  && String.equal left.application right.application
  && String.equal left.registry right.registry
  && left.format_version = right.format_version
  && left.suite = right.suite
