(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type bucket = Bucket_2K | Bucket_4K
type t

val max_plaintext_bytes : int
val bucket_bytes : bucket -> int
val of_bytes : string -> (t, string) result
val to_bytes : t -> string
val bucket : t -> bucket
val size : t -> int
val equal : t -> t -> bool
val hash : t -> string
val dedup_key : t -> string
val for_ciphertext_size : int -> (bucket, string) result
