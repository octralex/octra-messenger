(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type t = {
  epoch : int64;
  sequence : int;
  segment : string;
  state_root : string;
}

let ( let* ) = Result.bind
let current_version = 2
let magic = "OCMCUR"
let encoded_length = 6 + 2 + 8 + 4 + 47 + 64

let valid_root root =
  String.length root = 64
  && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) root

let validate cursor =
  if cursor.epoch < 0L then Error "cursor epoch negative"
  else if cursor.sequence < 0 then Error "cursor sequence negative"
  else if Int64.of_int cursor.sequence > 0xffff_ffffL then Error "cursor sequence exceeds wire width"
  else if String.length cursor.segment <> 47 then Error "cursor segment length invalid"
  else if not (valid_root cursor.state_root) then Error "cursor state root invalid"
  else Ok ()

let encode cursor =
  let* () = validate cursor in
  let buffer = Buffer.create encoded_length in
  Buffer.add_string buffer magic;
  Octra_net.Oce1.put_u16 buffer current_version;
  Octra_net.Oce1.put_u64 buffer cursor.epoch;
  Octra_net.Oce1.put_u32_int buffer cursor.sequence;
  Buffer.add_string buffer cursor.segment;
  Buffer.add_string buffer cursor.state_root;
  Ok (Buffer.contents buffer)

let decode text =
  let length = String.length text in
  if length < 8 then Error "cursor length invalid"
  else if not (String.equal (String.sub text 0 6) magic) then Error "unsupported cursor type"
  else
    let cursor = Octra_net.Oce1.make_cursor text in
    ignore (Octra_net.Oce1.get_raw cursor 6);
    match Octra_net.Oce1.get_u16 cursor with
    | 2 when length <> encoded_length -> Error "cursor length invalid"
    | 2 ->
      let epoch = Octra_net.Oce1.get_u64 cursor in
      let sequence64 = Int64.logand (Int64.of_int (Octra_net.Oce1.get_u32_int cursor)) 0xffff_ffffL in
      if Int64.compare sequence64 (Int64.of_int max_int) > 0 then Error "cursor sequence overflows host int"
      else
        let segment = Octra_net.Oce1.get_raw cursor 47 in
        let state_root = Octra_net.Oce1.get_raw cursor 64 in
        if Octra_net.Oce1.remaining cursor <> 0 then Error "cursor length invalid"
        else
          let value = { epoch; sequence = Int64.to_int sequence64; segment; state_root } in
          validate value |> Result.map (fun () -> value)
    | version -> Error (Printf.sprintf "unsupported version %d" version)
