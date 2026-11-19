(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type t =
  | Live of { receiver_epoch : int64 }
  | Archive of { commit_epoch : int64 }

val max_age : int64
val future_tolerance : int64
val reference_epoch : t -> int64
val validate : t -> sender_epoch:int64 -> (unit, string) result
