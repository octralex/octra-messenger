(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

type request = {
  start : int;
  max_records : int;
  max_bytes : int;
}

let max_records = 64
let max_bytes = 262144

let validate request =
  if request.start < 0 then Error "page start negative"
  else if request.max_records <= 0 || request.max_records > max_records then
    Error "page record limit outside bounds"
  else if request.max_bytes <= 0 || request.max_bytes > max_bytes then
    Error "page byte limit outside bounds"
  else Ok ()

let complete request ~frame_bytes ~returned_records ~returned_bytes =
  let ( let* ) = Result.bind in
  let reject_if condition reason = if condition then Error reason else Ok () in
  let* () = validate request in
  let* () = reject_if (frame_bytes <> 2048 && frame_bytes <> 4096) "frame bucket invalid" in
  let* () = reject_if (returned_records < 0 || returned_records > request.max_records)
    "returned record count outside bounds" in
  let* () = reject_if (returned_records > 0 && request.start > max_int - returned_records)
    "next sequence overflow" in
  let* () = reject_if (returned_records <> 0 && returned_bytes / returned_records <> frame_bytes)
    "page contains a partial frame" in
  let* () = reject_if (returned_bytes <> returned_records * frame_bytes) "page byte count mismatch" in
  let* () = reject_if (returned_bytes > request.max_bytes) "page exceeds byte budget" in
  Ok { request with start = request.start + returned_records }
