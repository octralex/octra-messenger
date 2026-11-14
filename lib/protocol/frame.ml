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
let hash frame = Digestif.SHA256.(digest_string frame.bytes |> to_hex)
let dedup_key = hash

let for_ciphertext_size size =
  if size < 0 then Error "negative ciphertext size"
  else if size <= 2048 then Ok Bucket_2K
  else if size <= 4096 then Ok Bucket_4K
  else Error "ciphertext exceeds largest frame bucket"
