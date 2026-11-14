let state_path directory = Filename.concat directory "outbox.json"
let lock_path directory = Filename.concat directory "outbox.lock"

let read_file path =
  if not (Sys.file_exists path) then ""
  else
    let channel = open_in_bin path in
    let value = In_channel.input_all channel in
    close_in channel;
    value

let read_state directory =
  match read_file (state_path directory) with
  | "" -> `Assoc ["version", `Int 1; "next_sequence", `Int 1; "records", `List []]
  | raw -> Yojson.Safe.from_string raw

let write_json_atomic path json =
  let temporary = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let channel = open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_binary] 0o600 temporary in
  output_string channel (Yojson.Safe.to_string json ^ "\n");
  flush channel;
  Unix.fsync (Unix.descr_of_out_channel channel);
  close_out channel;
  Unix.rename temporary path;
  let directory = Unix.openfile (Filename.dirname path) [Unix.O_RDONLY] 0 in
  Unix.fsync directory;
  Unix.close directory

let with_lock directory action =
  let channel = Unix.openfile (lock_path directory) [O_WRONLY; O_CREAT] 0o600 in
  Unix.lockf channel Unix.F_LOCK 0;
  Fun.protect ~finally:(fun () -> Unix.close channel) action

let records state =
  match Yojson.Safe.Util.member "records" state with `List values -> values | _ -> []

let prepare ~directory ~seal =
  with_lock directory (fun () ->
    let state = read_state directory in
    let sequence = Yojson.Safe.Util.(state |> member "next_sequence" |> to_int) in
    let envelope, raw = seal () in
    let record = `Assoc [
      "sequence", `Int sequence;
      "status", `String "prepared";
      "envelope", `String (Base64.encode_exn raw);
      "envelope_sha256", `String (Digestif.SHA256.(digest_string raw |> to_hex));
    ] in
    let next = `Assoc [
      "version", `Int 1;
      "next_sequence", `Int (sequence + 1);
      "records", `List (records state @ [record]);
    ] in
    write_json_atomic (state_path directory) next;
    envelope, raw, sequence)

let pending directory = records (read_state directory)

let retry_bytes ~directory ~sequence =
  let state = read_state directory in
  match List.find_opt (fun record -> Yojson.Safe.Util.(record |> member "sequence" |> to_int) = sequence)
    (records state) with
  | Some record -> Ok (Base64.decode_exn (Yojson.Safe.Util.(record |> member "envelope" |> to_string)))
  | None -> Error "outbox sequence not found"

let mark ~directory ~sequence ~status =
  with_lock directory (fun () ->
    let state = read_state directory in
    let found = ref false in
    let updated =
      List.map
        (fun record ->
          if Yojson.Safe.Util.(record |> member "sequence" |> to_int) = sequence then (
            found := true;
            match record with
            | `Assoc fields ->
              `Assoc (List.map (fun (name, value) ->
                if name = "status" then name, `String status else name, value) fields)
            | other -> other)
          else record)
        (records state)
    in
    if not !found then Error "outbox sequence not found"
    else begin
      let next = `Assoc [
        "version", `Int 1;
        "next_sequence", Yojson.Safe.Util.(state |> member "next_sequence");
        "records", `List updated;
      ] in
      write_json_atomic (state_path directory) next;
      Ok ()
    end)
