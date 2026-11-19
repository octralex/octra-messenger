(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type t =
  | Live of { receiver_epoch : int64 }
  | Archive of { commit_epoch : int64 }

let max_age = 64L
let future_tolerance = 2L

let reference_epoch = function
  | Live { receiver_epoch } -> receiver_epoch
  | Archive { commit_epoch } -> commit_epoch

let validate t ~sender_epoch =
  let reference = reference_epoch t in
  if reference < 0L then Error "reference epoch outside limits"
  else if sender_epoch < 0L then Error "sender epoch outside limits"
  else
    match t with
    | Live { receiver_epoch } ->
      if Int64.sub sender_epoch receiver_epoch > future_tolerance then
        Error "sender epoch exceeds live future tolerance"
      else if Int64.sub receiver_epoch sender_epoch > max_age then
        Error "sender epoch is stale for live delivery"
      else Ok ()
    | Archive { commit_epoch } ->
      if sender_epoch > commit_epoch then Error "sender epoch is after frame commit epoch"
      else Ok ()
