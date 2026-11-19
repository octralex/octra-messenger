(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

let state_path directory = Filename.concat directory "outbox.json"
let lock_path directory = Filename.concat directory "outbox.lock"

type counter = Available of int64 | Exhausted

let last_usable_sequence = Int64.max_int

let read_file path =
  if not (Sys.file_exists path) then ""
  else
    let channel = open_in_bin path in
    let value = In_channel.input_all channel in
    close_in channel;
    value

let read_state directory =
  match read_file (state_path directory) with
  | "" -> `Assoc ["version", `Int 2; "channels", `List []]
  | raw ->
    let json = Yojson.Safe.from_string raw in
    if Yojson.Safe.Util.(json |> member "version" |> to_int) <> 2 then
      invalid_arg "outbox state version requires an explicit migration";
    json

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

let list_field name json =
  match Yojson.Safe.Util.member name json with
  | `List values -> values
  | _ -> invalid_arg ("invalid outbox field " ^ name)

let channels state = list_field "channels" state
let records channel = list_field "records" channel
let string_field name json = Yojson.Safe.Util.(json |> member name |> to_string)
let channel_key channel = string_field "key" channel
let channel_contact channel = string_field "contact" channel
let channel_instance channel = Base64.decode_exn (string_field "sender_instance" channel)

let next_sequence channel =
  match Yojson.Safe.Util.member "next_sequence" channel with
  | `String "exhausted" -> Exhausted
  | `Int value -> Available (Int64.of_int value)
  | `Intlit value | `String value ->
    (try Available (Int64.of_string value)
     with Failure _ -> invalid_arg "invalid outbox next_sequence")
  | _ -> invalid_arg "invalid outbox next_sequence"

let counter_sequence = function
  | Available sequence when sequence > 0L -> sequence
  | Available _ -> invalid_arg "invalid outbox next_sequence"
  | Exhausted -> invalid_arg "outbox channel exhausted"

let validate_counter = function
  | Available sequence when sequence > 0L -> ()
  | Available _ -> invalid_arg "invalid outbox next_sequence"
  | Exhausted -> ()

let counter_json = function
  | Available sequence -> `Intlit (Int64.to_string sequence)
  | Exhausted -> `String "exhausted"

let following_counter sequence =
  if sequence = last_usable_sequence then Exhausted
  else Available (Int64.succ sequence)

let replace_channel replacement state =
  let found = ref false in
  let updated = List.map (fun channel ->
    if String.equal (channel_key channel) (channel_key replacement) then begin
      found := true;
      replacement
    end else channel) (channels state) in
  let updated = if !found then updated else updated @ [replacement] in
  `Assoc ["version", `Int 2; "channels", `List updated]

let make_channel ~contact ~key ~sender_instance =
  `Assoc [
    "contact", `String contact;
    "key", `String key;
    "sender_instance", `String (Base64.encode_exn sender_instance);
    "next_sequence", `Intlit "1";
    "records", `List [];
  ]

let update_channel channel ~next_sequence ~records =
  `Assoc [
    "contact", `String (channel_contact channel);
    "key", `String (channel_key channel);
    "sender_instance", `String (Base64.encode_exn (channel_instance channel));
    "next_sequence", counter_json next_sequence;
    "records", `List records;
  ]

let record_id ~key ~sender_instance ~sequence =
  Octra_net.Hash_domain.hash_encoded_hex "octra:msg:outbox-record:v2" (fun buffer ->
    Octra_net.Oce1.put_bytes buffer key;
    Octra_net.Oce1.put_bytes buffer sender_instance;
    Octra_net.Oce1.put_u64 buffer sequence)

let prepare ~codec_version ~context ~recipient_view_public ~key_version ~sender_public ~directory ~seal =
  let contact = Message_channel.contact_key ~codec_version ~context ~recipient_view_public ~key_version
    ~sender_public in
  with_lock directory (fun () ->
    let state = read_state directory in
    let existing = List.find_opt (fun channel -> String.equal (channel_contact channel) contact)
      (channels state) in
    let sender_instance = match existing with
      | Some channel -> channel_instance channel
      | None -> Mirage_crypto_rng.generate Message_channel.instance_bytes in
    let key = Message_channel.key ~codec_version ~context ~recipient_view_public ~key_version ~sender_public
      ~sender_instance in
    let channel = match existing with
      | Some channel -> channel
      | None -> make_channel ~contact ~key ~sender_instance in
    let sequence = counter_sequence (next_sequence channel) in
    let following = following_counter sequence in
    let id = record_id ~key ~sender_instance ~sequence in
    let allocation = `Assoc [
      "record_id", `String id;
      "sequence", `Intlit (Int64.to_string sequence);
      "status", `String "allocating";
    ] in
    let allocated = update_channel channel ~next_sequence:following
      ~records:(records channel @ [allocation]) in
    write_json_atomic (state_path directory) (replace_channel allocated state);
    let envelope, raw = seal ~sender_instance ~sequence in
    let record = `Assoc [
      "record_id", `String id;
      "sequence", `Intlit (Int64.to_string sequence);
      "status", `String "prepared";
      "envelope", `String (Base64.encode_exn raw);
      "envelope_sha256", `String (Octra_net.Hash_domain.hash_encoded_hex "octra:msg:outbox:v2"
  (fun buffer -> Octra_net.Oce1.put_bytes buffer raw));
    ] in
    let prepared = update_channel allocated ~next_sequence:following
      ~records:(records channel @ [record]) in
    write_json_atomic (state_path directory) (replace_channel prepared state);
    envelope, raw, id)

let recover ~codec_version ~context ~recipient_view_public ~key_version ~sender_public ~directory
    ~observed_high_water =
  if observed_high_water < 0L then Error "outbox recovery high-water outside limits"
  else
    let contact = Message_channel.contact_key ~codec_version ~context ~recipient_view_public ~key_version
      ~sender_public in
    with_lock directory (fun () ->
      let state = read_state directory in
      match List.find_opt (fun channel -> String.equal (channel_contact channel) contact)
        (channels state) with
      | None -> Error "outbox recovery channel not found"
      | Some channel ->
        (try
          match next_sequence channel with
          | Exhausted -> Error "outbox channel exhausted"
          | Available local_next when local_next <= 0L -> Error "invalid outbox next_sequence"
          | Available local_next ->
            if observed_high_water < local_next then Ok ()
            else
              let recovered = following_counter observed_high_water in
              let updated = update_channel channel ~next_sequence:recovered
                ~records:(records channel) in
              write_json_atomic (state_path directory) (replace_channel updated state);
              Ok ()
        with Invalid_argument reason -> Error reason))

let pending directory =
  List.concat_map (fun channel ->
    List.map (fun record ->
      match record with
      | `Assoc fields ->
        `Assoc (fields @ [
          "channel", `String (channel_key channel);
          "sender_instance", `String (Base64.encode_exn (channel_instance channel));
        ])
      | other -> other)
      (records channel))
    (channels (read_state directory))

let find_record state id =
  List.concat_map records (channels state)
  |> List.find_opt (fun record -> String.equal (string_field "record_id" record) id)

let retry_bytes ~directory ~record_id =
  match find_record (read_state directory) record_id with
  | None -> Error "outbox record not found"
  | Some record ->
    match Yojson.Safe.Util.member "envelope" record with
    | `String encoded ->
      Base64.decode encoded |> Result.map_error (fun _ -> "outbox envelope encoding invalid")
    | _ -> Error "outbox sequence is not sealed"

let mark ~directory ~record_id ~status =
  with_lock directory (fun () ->
    let state = read_state directory in
    let found = ref false in
    let sealed = ref false in
    let updated_channels = List.map (fun channel ->
      let next = next_sequence channel in
      validate_counter next;
      let updated_records = List.map (fun record ->
        if not (String.equal (string_field "record_id" record) record_id) then record
        else begin
          found := true;
          match record with
          | `Assoc fields ->
            begin
              match List.assoc_opt "envelope" fields with
              | Some (`String _) ->
                sealed := true;
                `Assoc (List.map (fun (name, value) ->
                  if name = "status" then name, `String status else name, value) fields)
              | _ -> record
            end
          | other -> other
        end)
        (records channel) in
      update_channel channel ~next_sequence:next ~records:updated_records)
      (channels state) in
    if not !found then Error "outbox record not found"
    else if not !sealed then Error "outbox sequence is not sealed"
    else begin
      write_json_atomic (state_path directory) (`Assoc ["version", `Int 2; "channels", `List updated_channels]);
      Ok ()
    end)
