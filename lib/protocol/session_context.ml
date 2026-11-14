type t = {
  chain_id : string;
  registry : string;
  format_version : int;
  suite : int;
}

let magic = "OCMCTX\000"
let max_field = 64
let max_encoded = 7 + 1 + 64 + 1 + 64 + 2 + 1

let validate_field name value =
  let length = String.length value in
  if length = 0 || length > max_field then Error (name ^ " length outside bounds") else Ok ()

let validate context =
  match validate_field "chain id" context.chain_id with
  | Error _ as error -> error
  | Ok () ->
    match validate_field "registry" context.registry with
    | Error _ as error -> error
    | Ok () when context.format_version <= 0 || context.format_version > 65535 ->
      Error "format version outside bounds"
    | Ok () when context.suite <= 0 || context.suite > 255 -> Error "suite outside bounds"
    | Ok () -> Ok ()

let add_u8 buffer value = Buffer.add_char buffer (Char.chr value)
let add_u16 buffer value =
  add_u8 buffer ((value lsr 8) land 255);
  add_u8 buffer (value land 255)

let encode context =
  match validate context with
  | Error _ as error -> error
  | Ok () ->
    let buffer = Buffer.create max_encoded in
    Buffer.add_string buffer magic;
    add_u8 buffer 1;
    add_u8 buffer (String.length context.chain_id);
    Buffer.add_string buffer context.chain_id;
    add_u8 buffer (String.length context.registry);
    Buffer.add_string buffer context.registry;
    add_u16 buffer context.format_version;
    add_u8 buffer context.suite;
    Ok (Buffer.contents buffer)

let byte text offset = Char.code text.[offset]
let u16 text offset = (byte text offset lsl 8) lor byte text (offset + 1)

let decode text =
  let length = String.length text in
  if length > max_encoded || length < 12 then Error "context length outside bounds"
  else if not (String.equal (String.sub text 0 7) magic) then Error "context magic mismatch"
  else if byte text 7 <> 1 then Error "context version unsupported"
  else
    let chain_length = byte text 8 in
    let registry_offset = 9 + chain_length in
    if registry_offset + 1 + 2 + 1 > length then Error "context truncated"
    else
      let registry_length = byte text registry_offset in
      let format_offset = registry_offset + 1 + registry_length in
      if format_offset + 3 <> length then Error "context trailing or truncated bytes"
      else
        let context = {
          chain_id = String.sub text 9 chain_length;
          registry = String.sub text (registry_offset + 1) registry_length;
          format_version = u16 text format_offset;
          suite = byte text (format_offset + 2);
        } in
        validate context
        |> Result.map (fun () -> context)

let equal left right =
  String.equal left.chain_id right.chain_id
  && String.equal left.registry right.registry
  && left.format_version = right.format_version
  && left.suite = right.suite
