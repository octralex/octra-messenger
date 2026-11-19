(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type t = {
  epoch : int64;
  sequence : int;
  segment : string;
  state_root : string;
}

val current_version : int
val magic : string
val encoded_length : int
val validate : t -> (unit, string) result
val encode : t -> (string, string) result
val decode : string -> (t, string) result
