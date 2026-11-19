(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type t = {
  version : int;
  chain_id : string;
  application : string;
  registry : string;
  format_version : int;
  suite : int;
}

val current_version : int
val magic : string
val max_field : int
val max_encoded : int

val make :
  chain_id:string -> application:string -> registry:string ->
  format_version:int -> suite:int -> t
val validate : t -> (unit, string) result
val encode : t -> (string, string) result
val decode : string -> (t, string) result
val equal : t -> t -> bool
