(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type t

val key_type : string
val generate : unit -> t * string
val secret_to_octets : t -> string
val public_of_secret : t -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val read : string -> (t, string) result
val write_atomic : string -> t -> unit
