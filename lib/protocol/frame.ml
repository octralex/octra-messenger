(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type bucket = Bucket_2K | Bucket_4K

type t = {
  bucket : bucket;
  bytes : string;
}

let max_plaintext_bytes = 1024
let bucket_bytes = function Bucket_2K -> 2048 | Bucket_4K -> 4096

let of_bytes bytes =
  match String.length bytes with
  | 2048 -> Ok { bucket = Bucket_2K; bytes }
  | 4096 -> Ok { bucket = Bucket_4K; bytes }
  | size -> Error (Printf.sprintf "invalid frame size %d" size)

let to_bytes frame = frame.bytes
let bucket frame = frame.bucket
let size frame = bucket_bytes frame.bucket
let equal left right = String.equal left.bytes right.bytes
let hash frame =
  Octra_net.Hash_domain.hash_encoded_hex "octra:msg:frame:v2" (fun buffer ->
    Octra_net.Oce1.put_bytes buffer frame.bytes)

let for_ciphertext_size size =
  if size < 0 then Error "negative ciphertext size"
  else if size <= 2048 then Ok Bucket_2K
  else if size <= 4096 then Ok Bucket_4K
  else Error "ciphertext exceeds largest frame bucket"
