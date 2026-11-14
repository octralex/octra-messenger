type t = {
  epoch : int64;
  sequence : int;
  segment : string;
  state_root : string;
}

let magic = "OCMCUR"
let encoded_length = 6 + 1 + 8 + 4 + 47 + 64

let valid_root root =
  String.length root = 64
  && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) root

let validate cursor =
  if cursor.epoch < 0L then Error "cursor epoch negative"
  else if cursor.sequence < 0 then Error "cursor sequence negative"
  else if Int64.of_int cursor.sequence > 0xffff_ffffL then Error "cursor sequence exceeds wire width"
  else if String.length cursor.segment <> 47 then Error "cursor segment length invalid"
  else if not (valid_root cursor.state_root) then Error "cursor state root invalid"
  else Ok ()

let add_u32 buffer value =
  for shift = 24 downto 0 do
    if shift mod 8 = 0 then Buffer.add_char buffer (Char.chr ((value lsr shift) land 255))
  done

let add_u64 buffer value =
  for index = 7 downto 0 do
    let shift = index * 8 in
    Buffer.add_char buffer (Char.chr Int64.(to_int (logand (shift_right_logical value shift) 255L)))
  done

let encode cursor =
  match validate cursor with
  | Error _ as error -> error
  | Ok () ->
    let buffer = Buffer.create encoded_length in
    Buffer.add_string buffer magic;
    Buffer.add_char buffer (Char.chr 1);
    add_u64 buffer cursor.epoch;
    add_u32 buffer cursor.sequence;
    Buffer.add_string buffer cursor.segment;
    Buffer.add_string buffer cursor.state_root;
    Ok (Buffer.contents buffer)

let u64 text offset =
  let value = ref 0L in
  for index = 0 to 7 do
    value := Int64.logor (Int64.shift_left !value 8)
      (Int64.of_int (Char.code text.[offset + index]))
  done;
  !value

let u32 text offset =
  let value = ref 0L in
  for index = 0 to 3 do
    value := Int64.logor (Int64.shift_left !value 8)
      (Int64.of_int (Char.code text.[offset + index]))
  done;
  !value

let decode text =
  if String.length text <> encoded_length then Error "cursor length invalid"
  else if not (String.equal (String.sub text 0 6) magic) then Error "cursor magic mismatch"
  else if Char.code text.[6] <> 1 then Error "cursor version unsupported"
  else
    let sequence64 = u32 text 15 in
    if sequence64 > Int64.of_int max_int then Error "cursor sequence overflows host int"
    else
      let cursor = {
        epoch = u64 text 7;
        sequence = Int64.to_int sequence64;
        segment = String.sub text 19 47;
        state_root = String.sub text 66 64;
      } in
      validate cursor |> Result.map (fun () -> cursor)
