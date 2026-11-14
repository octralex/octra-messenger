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
  match validate request with
  | Error _ as error -> error
  | Ok () when frame_bytes <> 2048 && frame_bytes <> 4096 -> Error "frame bucket invalid"
  | Ok () when returned_records < 0 || returned_records > request.max_records ->
    Error "returned record count outside bounds"
  | Ok () when returned_records > 0 && request.start > max_int - returned_records ->
    Error "next sequence overflow"
  | Ok () when returned_records <> 0 && returned_bytes / returned_records <> frame_bytes ->
    Error "page contains a partial frame"
  | Ok () when returned_bytes <> returned_records * frame_bytes ->
    Error "page byte count mismatch"
  | Ok () when returned_bytes > request.max_bytes -> Error "page exceeds byte budget"
  | Ok () -> Ok { request with start = request.start + returned_records }
