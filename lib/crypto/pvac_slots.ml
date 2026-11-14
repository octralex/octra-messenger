let slot_bytes = 7
let chunk_header_bytes = 16

let slot_count plaintext_bytes =
  if plaintext_bytes = 0 then 0 else (plaintext_bytes + 4 + slot_bytes - 1) / slot_bytes

let encode plaintext =
  let length = String.length plaintext in
  let slots = slot_count length in
  if length = 0 then [|0L|]
  else
    let prefixed = Bytes.create (4 + length) in
    Bytes.set_int32_be prefixed 0 (Int32.of_int length);
    Bytes.blit_string plaintext 0 prefixed 4 length;
    Array.init slots (fun slot ->
      let offset = slot * slot_bytes in
      let value = ref 0L in
      for index = 0 to slot_bytes - 1 do
        let byte = if offset + index < Bytes.length prefixed then Bytes.get prefixed (offset + index) else '\000' in
        value := Int64.logor (Int64.shift_left !value 8) (Int64.of_int (Char.code byte))
      done;
      !value)

let decode values =
  let buffer = Buffer.create (Array.length values * slot_bytes) in
  Array.iter (fun value ->
    for index = slot_bytes - 1 downto 0 do
      Buffer.add_char buffer (Char.chr Int64.(to_int (logand (shift_right_logical value (index * 8)) 255L)))
    done) values;
  let raw = Buffer.contents buffer in
  if String.length raw < 4 then Error "slot payload truncated"
  else
    let length = Int32.to_int (String.get_int32_be raw 0) in
    if length < 0 || length + 4 > String.length raw then Error "slot payload length invalid"
    else if String.sub raw (length + 4) (String.length raw - length - 4) <> String.make (String.length raw - length - 4) '\000' then
      Error "slot padding is not canonical"
    else Ok (String.sub raw 4 length)

let seed plaintext =
  Digestif.SHA256.(digest_string ("octra-test-pvac-slots" ^ plaintext) |> to_raw_string |> Bytes.of_string)

let encrypt_vector ~pk ~sk plaintext =
  let values = encode plaintext in
  if String.length plaintext = 0 then Pvac_ffi.enc_zero_seeded pk sk (seed plaintext)
  else Pvac_ffi.enc_values_seeded pk sk values (seed plaintext)

let encrypt_scalar_chunks ~pk ~sk plaintext =
  let values = encode plaintext in
  Array.map (fun value -> Pvac_ffi.enc_value_seeded pk sk value (seed plaintext)) values

let decrypt_vector ~pk ~sk cipher =
  decode (Pvac_ffi.dec_values pk sk cipher)

let decrypt_scalar_chunks ~pk ~sk ciphers =
  decode (Array.map (fun cipher -> Pvac_ffi.dec_value pk sk cipher) ciphers)
