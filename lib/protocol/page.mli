(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type request = {
  start : int;
  max_records : int;
  max_bytes : int;
}

val max_records : int
val max_bytes : int
val validate : request -> (unit, string) result
val complete : request -> frame_bytes:int -> returned_records:int -> returned_bytes:int -> (request, string) result
