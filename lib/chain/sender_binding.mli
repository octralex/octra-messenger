(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

val verify :
  expected_address:string -> expected_sender_public:string -> onchain_sender:string ->
  (unit, string) result

val verify_envelope :
  expected_address:string -> onchain_sender:string -> string -> (string, string) result
