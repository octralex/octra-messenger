let run = Lwt_main.run

let status = function
  | Octra_core.Store_irmin.Gc_started { floor; removed } ->
    `Assoc ["status", `String "started"; "floor", `Int floor; "tags_removed", `Int removed]
  | Gc_split epoch -> `Assoc ["status", `String "split"; "epoch", `Int epoch]
  | Gc_wait epoch -> `Assoc ["status", `String "wait"; "epoch", `Int epoch]
  | Gc_space { free; need } ->
    `Assoc ["status", `String "space"; "free", `String (Int64.to_string free); "need", `String (Int64.to_string need)]
  | Gc_busy -> `Assoc ["status", `String "busy"]
  | Gc_off -> `Assoc ["status", `String "off"]
  | Gc_missing epoch -> `Assoc ["status", `String "missing"; "epoch", `Int epoch]
  | Gc_error reason -> `Assoc ["status", `String "error"; "reason", `String reason]

let () =
  if Array.length Sys.argv <> 3 then failwith "usage: prune_driver STORE_PATH CURRENT_EPOCH";
  print_endline "opening";
  let store = run (Octra_core.Store_irmin.open_store Sys.argv.(1)) in
  print_endline "opened";
  Fun.protect ~finally:(fun () -> run (Octra_core.Store_irmin.close store)) (fun () ->
    print_endline "collecting";
    let result = run (Octra_core.Store_irmin.collect_pack_at ~keep:1 store (int_of_string Sys.argv.(2))) in
    print_endline (Yojson.Safe.to_string (status result));
    match result with
    | Octra_core.Store_irmin.Gc_started _ ->
      begin
        match run (Octra_core.Store_irmin.wait_pack_gc store) with
        | Ok () -> print_endline "{\"status\":\"complete\"}"
        | Error reason ->
          Printf.printf "{\"status\":\"error\",\"reason\":%s}\n" (Yojson.Safe.to_string (`String reason))
      end
    | _ -> ())
