(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

let max_records = 10_000
let max_inbox_bytes = 512_000_000
let sender_share_divisor = 10
let max_records_per_sender = max_records / sender_share_divisor
let max_inbox_bytes_per_sender = max_inbox_bytes / sender_share_divisor
let window_slots = 1024
let bitmap_bytes = window_slots / 8
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
  | "" -> `Assoc ["version", `Int 4; "windows", `List []; "inbox", `List []]
  | raw ->
    let json = Yojson.Safe.from_string raw in
    if Yojson.Safe.Util.(json |> member "version" |> to_int) <> 4 then
      invalid_arg "receive state version requires an explicit migration";
    json

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
  match Yojson.Safe.Util.member name json with
  | `List values -> values
  | _ -> invalid_arg ("invalid receive state field " ^ name)

let window_key = Message_channel.key

let replay_key ~codec_version ~context ~recipient_view_public ~key_version ~sender_public
    ~sender_instance ~sequence ~sender_epoch =
  Octra_net.Hash_domain.hash_encoded_hex "octra:msg:replay:v2" (fun buffer ->
    Octra_net.Oce1.put_u16 buffer codec_version;
    Octra_net.Oce1.put_bytes buffer context;
    Octra_net.Oce1.put_bytes buffer recipient_view_public;
    Octra_net.Oce1.put_u32_int buffer key_version;
    Octra_net.Oce1.put_bytes buffer sender_public;
    Octra_net.Oce1.put_bytes buffer sender_instance;
    Octra_net.Oce1.put_u64 buffer sequence;
    Octra_net.Oce1.put_u64 buffer sender_epoch)

let message_path ~codec_version ~context ~recipient_view_public ~key_version ~sender_public
    ~sender_instance ~sequence ~sender_epoch =
  let digest = Octra_net.Hash_domain.hash_encoded_hex "octra:msg:path:v2" (fun buffer ->
    Octra_net.Oce1.put_u16 buffer codec_version;
    Octra_net.Oce1.put_bytes buffer context;
    Octra_net.Oce1.put_bytes buffer recipient_view_public;
    Octra_net.Oce1.put_u32_int buffer key_version;
    Octra_net.Oce1.put_bytes buffer sender_public;
    Octra_net.Oce1.put_bytes buffer sender_instance;
    Octra_net.Oce1.put_u64 buffer sequence;
    Octra_net.Oce1.put_u64 buffer sender_epoch) in
  Filename.concat "messages" (digest ^ ".bin")

let bit_get bitmap index =
  index >= 0 && index < window_slots
  && Char.code (Bytes.get bitmap (index / 8)) land (1 lsl (index mod 8)) <> 0

let bit_set bitmap index =
  let offset = index / 8 in
  Bytes.set bitmap offset (Char.chr (Char.code (Bytes.get bitmap offset) lor (1 lsl (index mod 8))))

let shift_window bitmap count =
  if count >= window_slots then Bytes.make bitmap_bytes '\000'
  else
    let shifted = Bytes.make bitmap_bytes '\000' in
    for index = count to window_slots - 1 do
      if bit_get bitmap (index - count) then bit_set shifted index
    done;
    shifted

let int64_field json name =
  match Yojson.Safe.Util.member name json with
  | `Int value -> Ok (Int64.of_int value)
  | `Intlit value | `String value ->
    (try Ok (Int64.of_string value) with Failure _ -> Error ("invalid integer field " ^ name))
  | _ -> Error ("invalid integer field " ^ name)

let bitmap_field entry =
  match Yojson.Safe.Util.member "bitmap" entry with
  | `String value ->
    (match Base64.decode value with
     | Ok raw -> Ok (Bytes.of_string raw)
     | Error _ -> Error "invalid receive replay bitmap encoding")
  | _ -> Error "invalid receive replay bitmap"

let validate_window_entry entry =
  let ( let* ) = Result.bind in
  let* high_water = int64_field entry "high_water" in
  let* bitmap = bitmap_field entry in
  if high_water <= 0L then Error "invalid receive replay high-water"
  else if Bytes.length bitmap <> bitmap_bytes then Error "invalid receive replay bitmap size"
  else Ok ()

let accept_window entry ~sequence =
  let ( let* ) = Result.bind in
  let* high_water = int64_field entry "high_water" in
  let* bitmap = bitmap_field entry in
  if high_water <= 0L then Error "invalid receive replay high-water"
  else if Bytes.length bitmap <> bitmap_bytes then Error "invalid receive replay bitmap size"
  else if sequence <= 0L then Error "sender sequence outside limits"
  else if sequence > high_water then
    let distance = Int64.sub sequence high_water in
    let bitmap =
      if distance >= Int64.of_int window_slots then Bytes.make bitmap_bytes '\000'
      else shift_window bitmap (Int64.to_int distance) in
    bit_set bitmap 0;
    Ok (sequence, bitmap)
  else
    let distance = Int64.sub high_water sequence in
    if distance >= Int64.of_int window_slots then Error "sender sequence rollback"
    else if bit_get bitmap (Int64.to_int distance) then Error "replay rejected"
    else begin
      bit_set bitmap (Int64.to_int distance);
      Ok (high_water, bitmap)
    end

let validate_window_entries windows =
  let rec loop = function
    | [] -> Ok ()
    | entry :: rest -> Result.bind (validate_window_entry entry) (fun () -> loop rest)
  in
  loop windows

let update_window windows ~key ~sequence =
  let rec loop = function
    | [] ->
      let bitmap = Bytes.make bitmap_bytes '\000' in
      bit_set bitmap 0;
      if sequence <= 0L then Error "sender sequence outside limits"
      else Ok [`Assoc ["key", `String key; "high_water", `Intlit (Int64.to_string sequence);
        "bitmap", `String (b64 (Bytes.to_string bitmap))]]
    | entry :: rest ->
      if not (String.equal Yojson.Safe.Util.(entry |> member "key" |> to_string) key) then
        Result.map (fun tail -> entry :: tail) (loop rest)
      else
        Result.map (fun (high_water, bitmap) ->
          `Assoc ["key", `String key; "high_water", `Intlit (Int64.to_string high_water);
            "bitmap", `String (b64 (Bytes.to_string bitmap))] :: rest)
          (accept_window entry ~sequence)
  in
  Result.bind (validate_window_entries windows) (fun () -> loop windows)

let retain_entry dedup_retained entry =
  match Yojson.Safe.Util.member "key_version" entry with
  | `Int version -> dedup_retained version
  | _ -> true

let prune_inbox state ~dedup_retained =
  List.filter (retain_entry dedup_retained) (entries state "inbox")

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

let prepare_inbox state ~dedup_retained ~plaintext_bytes ~directory ~sender_public =
  let inbox = prune_inbox state ~dedup_retained in
  let sender_inbox = sender_entries sender_public inbox in
  if List.length sender_inbox >= max_records_per_sender then
    Error "receive sender state capacity reached"
  else if sender_inbox_bytes directory sender_public inbox + plaintext_bytes > max_inbox_bytes_per_sender then
    Error "receive sender byte capacity reached"
  else if List.length inbox >= max_records then
    Error "receive state capacity reached"
  else if inbox_bytes directory + plaintext_bytes > max_inbox_bytes then
    Error "receive byte capacity reached"
  else Ok inbox

let commit_receive ?fail_after_temp_write ?crash_after_rename ~directory ~codec_version ~context
    ~recipient_view_public ~sender_public ~sender_instance ~key_version ~sequence ~sender_epoch
    ~freshness ~dedup_retained ~plaintext () =
  with_lock directory (fun () ->
    let path = state_path directory in
    let state = read_json path in
    let key = window_key ~codec_version ~context ~recipient_view_public ~key_version ~sender_public
      ~sender_instance in
    let replay = replay_key ~codec_version ~context ~recipient_view_public ~key_version ~sender_public
      ~sender_instance ~sequence ~sender_epoch in
    let ( let* ) = Result.bind in
    let* () = Freshness.validate freshness ~sender_epoch in
    let* windows = update_window (entries state "windows") ~key ~sequence in
    let* inbox = prepare_inbox state ~dedup_retained ~plaintext_bytes:(String.length plaintext)
      ~directory ~sender_public in
    let relative = message_path ~codec_version ~context ~recipient_view_public ~key_version
      ~sender_public ~sender_instance ~sequence ~sender_epoch in
    ensure_directory (messages_path directory);
    write_bytes_atomic (Filename.concat directory relative) plaintext;
    let inbox_record = `Assoc [
      "replay", `String replay;
      "window", `String key;
      "context", `String (b64 context);
      "recipient_view_public", `String (b64 recipient_view_public);
      "sender_public", `String (b64 sender_public);
      "sender_instance", `String (b64 sender_instance);
      "key_version", `Int key_version;
      "sequence", `Intlit (Int64.to_string sequence);
      "sender_epoch", `Intlit (Int64.to_string sender_epoch);
      "path", `String relative;
      "plaintext_bytes", `Int (String.length plaintext);
      "sha256", `String (Octra_net.Hash_domain.hash_encoded_hex "octra:msg:plaintext:v2"
        (fun buffer -> Octra_net.Oce1.put_bytes buffer plaintext));
    ] in
    let next = `Assoc [
      "version", `Int 4;
      "windows", `List windows;
      "inbox", `List (inbox @ [inbox_record]);
    ] in
    write_json_atomic ?fail_after_temp_write path next;
    Option.iter (fun reason -> failwith reason) crash_after_rename;
    Ok ())

let state_hash directory =
  Octra_net.Hash_domain.hash_encoded_hex "octra:msg:receive-state:v2" (fun buffer ->
    Octra_net.Oce1.put_bytes buffer (read_file (state_path directory)))

let record_counts directory =
  let state = read_json (state_path directory) in
  List.length (entries state "windows"), List.length (entries state "inbox")
