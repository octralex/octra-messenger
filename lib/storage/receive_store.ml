let max_records = 10_000
let max_inbox_bytes = 512_000_000
let sender_share_divisor = 10
let max_records_per_sender = max_records / sender_share_divisor
let max_inbox_bytes_per_sender = max_inbox_bytes / sender_share_divisor
let temporary_sequence = ref 0

let b64 = Base64.encode_exn
let state_path directory = Filename.concat directory "receive-state.json"
let lock_path directory = Filename.concat directory "receive.lock"
let messages_path directory = Filename.concat directory "messages"

let read_file path =
  if not (Sys.file_exists path) then ""
  else
    let channel = open_in_bin path in
    let value = In_channel.input_all channel in
    close_in channel;
    value

let read_json path =
  match read_file path with
  | "" -> `Assoc ["version", `Int 2; "dedup", `List []; "inbox", `List []]
  | raw -> Yojson.Safe.from_string raw

let ensure_directory path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o700

let write_bytes_atomic ?fail_after_temp_write path value =
  let temporary = Printf.sprintf "%s.tmp.%d.%d" path (Unix.getpid ()) !temporary_sequence in
  incr temporary_sequence;
  let channel = open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_binary] 0o600 temporary in
  output_string channel value;
  flush channel;
  Unix.fsync (Unix.descr_of_out_channel channel);
  close_out channel;
  Option.iter (fun reason -> failwith reason) fail_after_temp_write;
  Unix.rename temporary path;
  let directory = Unix.openfile (Filename.dirname path) [Unix.O_RDONLY] 0 in
  Unix.fsync directory;
  Unix.close directory

let write_json_atomic ?fail_after_temp_write path json =
  write_bytes_atomic ?fail_after_temp_write path (Yojson.Safe.to_string json ^ "\n")

let with_lock directory action =
  let channel = Unix.openfile (lock_path directory) [O_WRONLY; O_CREAT] 0o600 in
  Unix.lockf channel Unix.F_LOCK 0;
  Fun.protect ~finally:(fun () -> Unix.close channel) action

let entries json name =
  match Yojson.Safe.Util.member name json with `List values -> values | _ -> []

let key context sender_public message_id key_version =
  `Assoc [
    "context", `String (b64 context);
    "sender_public", `String (b64 sender_public);
    "message_id", `String (b64 message_id);
    "key_version", `Int key_version;
  ]

let message_path directory ~context ~sender_public ~message_id =
  let digest = Digestif.SHA256.(digest_string
    ("octra:receive-message:v1\000" ^ context ^ sender_public ^ message_id) |> to_hex) in
  Filename.concat "messages" (digest ^ ".bin")

let seen state ~context ~sender_public ~message_id =
  let encoded_context = b64 context in
  let encoded_sender = b64 sender_public in
  let encoded_id = b64 message_id in
  List.exists (fun entry ->
    Yojson.Safe.Util.(entry |> member "context" |> to_string) = encoded_context
    && Yojson.Safe.Util.(entry |> member "sender_public" |> to_string) = encoded_sender
    && Yojson.Safe.Util.(entry |> member "message_id" |> to_string) = encoded_id)
    (entries state "dedup")

let retain_entry dedup_retained entry =
  match Yojson.Safe.Util.member "key_version" entry with
  | `Int version -> dedup_retained version
  | _ -> true

let prune state ~dedup_retained =
  let dedup = List.filter (retain_entry dedup_retained) (entries state "dedup") in
  let inbox = List.filter (retain_entry dedup_retained) (entries state "inbox") in
  dedup, inbox

let inbox_bytes directory =
  let messages = messages_path directory in
  let message_bytes =
    if not (Sys.file_exists messages) then 0
    else
      Array.fold_left (fun total name ->
        total + (Unix.stat (Filename.concat messages name)).Unix.st_size)
        0 (Sys.readdir messages) in
  let state_bytes =
    if Sys.file_exists (state_path directory) then
      (Unix.stat (state_path directory)).Unix.st_size
    else 0 in
  message_bytes + state_bytes

let sender_entries sender_public entries =
  let encoded_sender = b64 sender_public in
  List.filter (fun entry ->
    Yojson.Safe.Util.(entry |> member "sender_public" |> to_string) = encoded_sender) entries

let sender_inbox_bytes directory sender_public inbox =
  List.fold_left (fun total entry ->
    let relative = Yojson.Safe.Util.(entry |> member "path" |> to_string) in
    total + (Unix.stat (Filename.concat directory relative)).Unix.st_size)
    0 (sender_entries sender_public inbox)

let prepare_state state ~dedup_retained ~plaintext_bytes ~directory ~sender_public =
  let dedup, inbox = prune state ~dedup_retained in
  let sender_dedup = sender_entries sender_public dedup in
  let sender_inbox = sender_entries sender_public inbox in
  if List.length sender_dedup >= max_records_per_sender
    || List.length sender_inbox >= max_records_per_sender then
    Error "receive sender state capacity reached"
  else if sender_inbox_bytes directory sender_public inbox + plaintext_bytes > max_inbox_bytes_per_sender then
    Error "receive sender byte capacity reached"
  else if List.length dedup >= max_records || List.length inbox >= max_records then
    Error "receive state capacity reached"
  else if inbox_bytes directory + plaintext_bytes > max_inbox_bytes then
    Error "receive byte capacity reached"
  else Ok (dedup, inbox)

let commit_receive ?fail_after_temp_write ?crash_after_rename ~directory ~context
    ~sender_public ~message_id ~key_version ~dedup_retained ~plaintext () =
  with_lock directory (fun () ->
    let path = state_path directory in
    let state = read_json path in
    if seen state ~context ~sender_public ~message_id then Error "replay rejected"
    else
      match prepare_state state ~dedup_retained ~plaintext_bytes:(String.length plaintext) ~directory ~sender_public with
      | Error _ as error -> error
      | Ok (dedup, inbox) ->
        let relative = message_path directory ~context ~sender_public ~message_id in
        ensure_directory (messages_path directory);
        let full_path = Filename.concat directory relative in
        write_bytes_atomic full_path plaintext;
        let record = key context sender_public message_id key_version in
        let inbox_record = match record with
          | `Assoc fields ->
            `Assoc (fields @ [
              "path", `String relative;
              "plaintext_bytes", `Int (String.length plaintext);
              "sha256", `String Digestif.SHA256.(digest_string plaintext |> to_hex);
            ])
          | _ -> assert false in
        let next = `Assoc [
          "version", `Int 2;
          "dedup", `List (dedup @ [record]);
          "inbox", `List (inbox @ [inbox_record]);
        ] in
        write_json_atomic ?fail_after_temp_write path next;
        Option.iter (fun reason -> failwith reason) crash_after_rename;
        Ok ())

let state_hash directory =
  Digestif.SHA256.(digest_string (read_file (state_path directory)) |> to_hex)

let record_counts directory =
  let state = read_json (state_path directory) in
  List.length (entries state "dedup"), List.length (entries state "inbox")
