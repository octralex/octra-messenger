(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type t = Mirage_crypto_ec.X25519.secret

let key_type = "octra-x25519-recipient-message-v1"

let generate () = Mirage_crypto_ec.X25519.gen_key ()
let secret_to_octets = Mirage_crypto_ec.X25519.secret_to_octets

let public_of_secret value =
  match Mirage_crypto_ec.X25519.secret_of_octets (secret_to_octets value) with
  | Ok (_, public_key) -> public_key
  | Error _ -> invalid_arg "invalid X25519 messaging secret"

let to_yojson value =
  `Assoc [
    "key_type", `String key_type;
    "view_secret", `String (Base64.encode_exn (secret_to_octets value));
    "view_public", `String (Base64.encode_exn (public_of_secret value));
  ]

let string_field name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> Ok value
  | _ -> Error ("missing messaging key field " ^ name)

let decode_field name value =
  Base64.decode value |> Result.map_error (fun _ -> "invalid base64 in messaging key field " ^ name)

let of_yojson json =
  let ( let* ) = Result.bind in
  let* actual_type = string_field "key_type" json in
  if not (String.equal actual_type key_type) then Error "recipient secret is not a typed X25519 messaging key"
  else
    let* encoded_secret = string_field "view_secret" json in
    let* encoded_public = string_field "view_public" json in
    let* raw_secret = decode_field "view_secret" encoded_secret in
    let* expected_public = decode_field "view_public" encoded_public in
    let* secret, derived_public = Mirage_crypto_ec.X25519.secret_of_octets raw_secret
      |> Result.map_error (fun _ -> "invalid X25519 messaging secret") in
    if not (String.equal derived_public expected_public) then Error "messaging public key does not match secret"
    else Ok secret

let read path =
  try
    let channel = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      of_yojson (Yojson.Safe.from_string (In_channel.input_all channel)))
  with
  | Sys_error reason -> Error ("messaging key file I/O error: " ^ reason)
  | Unix.Unix_error (error, function_name, argument) ->
    Error (Printf.sprintf "messaging key file I/O error: %s in %s%s"
      (Unix.error_message error) function_name argument)
  | Yojson.Json_error reason -> Error ("invalid messaging key JSON: " ^ reason)
  | Invalid_argument reason -> Error ("invalid messaging key: " ^ reason)

let write_atomic path value =
  let temporary = Printf.sprintf "%s.tmp.%d" path (Unix.getpid ()) in
  let channel = open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_binary] 0o600 temporary in
  output_string channel (Yojson.Safe.to_string (to_yojson value) ^ "\n");
  flush channel;
  Unix.fsync (Unix.descr_of_out_channel channel);
  close_out channel;
  Unix.rename temporary path;
  let directory = Unix.openfile (Filename.dirname path) [Unix.O_RDONLY] 0 in
  Unix.fsync directory;
  Unix.close directory
