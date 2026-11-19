(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

let () =
  if Array.length Sys.argv <> 2 then failwith "usage: rebuild_index_driver CHAINDATA_PATH";
  let chaindata = Octra_core.Store_chaindata.open_chaindata Sys.argv.(1) in
  Fun.protect ~finally:(fun () -> Octra_core.Store_chaindata.close chaindata) (fun () ->
    match Octra_core.Store_chaindata.rebuild_index chaindata with
    | Ok stats ->
      `Assoc [
        "status", `String "rebuilt";
        "transactions", `String (Int64.to_string stats.transactions);
        "epochs", `Int stats.epochs;
        "last_epoch", `Int stats.last_epoch;
        "epoch_index_root", `String stats.epoch_index_root;
      ] |> Yojson.Safe.to_string |> print_endline
    | Error reason -> failwith reason)
