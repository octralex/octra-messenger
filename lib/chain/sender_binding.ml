(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

let ( let* ) = Result.bind

let verify ~expected_address ~expected_sender_public ~onchain_sender =
  if not (String.equal onchain_sender expected_address) then Error "on-chain sender mismatch"
  else if not (Octra_core.Crypto.Address.verify_address_pubkey onchain_sender
    (Base64.encode_exn expected_sender_public)) then
    Error "envelope sender is not bound to on-chain address"
  else Ok ()

let sender_public raw =
  let length = String.length raw in
  if length < 8 then Error "envelope header truncated"
  else if not (String.equal (String.sub raw 0 6) Recipient_message_core.tag) then
    Error "unsupported envelope type"
  else
    let cursor = Octra_net.Oce1.make_cursor raw in
    ignore (Octra_net.Oce1.get_raw cursor 6);
    match Octra_net.Oce1.get_u16 cursor with
    | 2 ->
      let offset = Recipient_message_core.sender_public_offset in
      if length < offset + 32 then Error "envelope header truncated"
      else Ok (String.sub raw offset 32)
    | version -> Error (Printf.sprintf "unsupported version %d" version)

let verify_envelope ~expected_address ~onchain_sender raw =
  let* expected_sender_public = sender_public raw in
  verify ~expected_address ~expected_sender_public ~onchain_sender
  |> Result.map (fun () -> expected_sender_public)
