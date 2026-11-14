type envelope = {
  context : string;
  message_id : string;
  ciphertext : string;
  sender_public : string;
  signature : string;
}

let max_context_bytes = 4096
let max_ciphertext_bytes = 16_777_216
let max_plaintext_bytes = 7
let magic = "OCMENV1"
let auth_magic = "OCMNAUTH1\000"
let header_bytes = 7 + 2 + 4 + 16 + 32 + 64

let check condition message = if not condition then Error message else Ok ()

let validate envelope =
  match check (String.length envelope.context <= max_context_bytes) "context exceeds limit" with
  | Error _ as error -> error
  | Ok () ->
    match check (String.length envelope.message_id = 16) "message id must be 16 bytes" with
    | Error _ as error -> error
    | Ok () ->
      match check (String.length envelope.sender_public = 32) "sender key must be 32 bytes" with
      | Error _ as error -> error
      | Ok () ->
        match check (String.length envelope.signature = 64) "signature must be 64 bytes" with
        | Error _ as error -> error
        | Ok () ->
          check
            (String.length envelope.ciphertext > 0
             && String.length envelope.ciphertext <= max_ciphertext_bytes)
            "ciphertext outside limits"

let add_u16 buffer value =
  Buffer.add_char buffer (Char.chr ((value lsr 8) land 255));
  Buffer.add_char buffer (Char.chr (value land 255))

let add_u32 buffer value =
  for index = 3 downto 0 do
    Buffer.add_char buffer (Char.chr ((value lsr (index * 8)) land 255))
  done

let byte text offset = Char.code text.[offset]
let u16 text offset = (byte text offset lsl 8) lor byte text (offset + 1)

let u32 text offset =
  (byte text offset lsl 24)
  lor (byte text (offset + 1) lsl 16)
  lor (byte text (offset + 2) lsl 8)
  lor byte text (offset + 3)

let encode envelope =
  match validate envelope with
  | Error _ as error -> error
  | Ok () ->
    let buffer = Buffer.create (header_bytes + String.length envelope.context + String.length envelope.ciphertext) in
    Buffer.add_string buffer magic;
    add_u16 buffer (String.length envelope.context);
    add_u32 buffer (String.length envelope.ciphertext);
    Buffer.add_string buffer envelope.message_id;
    Buffer.add_string buffer envelope.sender_public;
    Buffer.add_string buffer envelope.signature;
    Buffer.add_string buffer envelope.context;
    Buffer.add_string buffer envelope.ciphertext;
    Ok (Buffer.contents buffer)

let decode text =
  let length = String.length text in
  if length < header_bytes then Error "envelope truncated"
  else if not (String.equal (String.sub text 0 7) magic) then Error "envelope magic mismatch"
  else
    let context_length = u16 text 7 in
    let ciphertext_length = u32 text 9 in
    if context_length > max_context_bytes then Error "context exceeds limit"
    else if ciphertext_length = 0 || ciphertext_length > max_ciphertext_bytes then
      Error "ciphertext outside limits"
    else if length <> header_bytes + context_length + ciphertext_length then
      Error "envelope trailing or truncated bytes"
    else
      let context_offset = header_bytes in
      let ciphertext_offset = context_offset + context_length in
      let envelope = {
        context = String.sub text context_offset context_length;
        message_id = String.sub text 13 16;
        sender_public = String.sub text 29 32;
        signature = String.sub text 61 64;
        ciphertext = String.sub text ciphertext_offset ciphertext_length;
      } in
      validate envelope |> Result.map (fun () -> envelope)

let authentication_payload envelope =
  let buffer = Buffer.create (String.length auth_magic + 2 + 4 + 16 + 32 + String.length envelope.context + String.length envelope.ciphertext) in
  Buffer.add_string buffer auth_magic;
  add_u16 buffer (String.length envelope.context);
  add_u32 buffer (String.length envelope.ciphertext);
  Buffer.add_string buffer envelope.message_id;
  Buffer.add_string buffer envelope.sender_public;
  Buffer.add_string buffer envelope.context;
  Buffer.add_string buffer envelope.ciphertext;
  Buffer.contents buffer

let plaintext_to_int64 plaintext =
  let length = String.length plaintext in
  if length > max_plaintext_bytes then Error "plaintext exceeds seven bytes"
  else
    let value = ref 0L in
    String.iter (fun byte ->
      value := Int64.logor (Int64.shift_left !value 8) (Int64.of_int (Char.code byte)))
      (String.make 1 (Char.chr length) ^ plaintext ^ String.make (max_plaintext_bytes - length) '\000');
    Ok !value

let int64_to_plaintext value =
  let buffer = Buffer.create 8 in
  for index = 7 downto 0 do
    Buffer.add_char buffer (Char.chr Int64.(to_int (logand (shift_right_logical value (index * 8)) 255L)))
  done;
  let raw = Buffer.contents buffer in
  let length = Char.code raw.[0] in
  if length > max_plaintext_bytes then Error "decrypted length outside limits"
  else if String.sub raw (length + 1) (max_plaintext_bytes - length) <> String.make (max_plaintext_bytes - length) '\000' then
    Error "decrypted padding is not canonical"
  else Ok (String.sub raw 1 length)

let seal_same_key_holder ~recipient_pk ~recipient_sk ~sender_secret ~context ~message_id plaintext =
  match plaintext_to_int64 plaintext with
  | Error _ as error -> error
  | Ok value ->
    let seed = Digestif.SHA256.(digest_string (context ^ message_id) |> to_raw_string |> Bytes.of_string) in
    let cipher = Pvac_ffi.enc_value_seeded recipient_pk recipient_sk value seed in
    let ciphertext = Pvac_ffi.serialize_cipher cipher |> Bytes.to_string in
    let sender_public = Mirage_crypto_ec.Ed25519.(pub_of_priv sender_secret |> pub_to_octets) in
    let unsigned = { context; message_id; ciphertext; sender_public; signature = String.make 64 '\000' } in
    let signature = Mirage_crypto_ec.Ed25519.sign ~key:sender_secret (authentication_payload unsigned) in
    let envelope = { unsigned with signature } in
    Result.map (fun raw -> envelope, raw) (encode envelope)

let verify_envelope envelope =
  match validate envelope with
  | Error _ as error -> error
  | Ok () ->
    begin
      match Mirage_crypto_ec.Ed25519.pub_of_octets envelope.sender_public with
      | Error _ -> Error "sender public key invalid"
      | Ok public_key ->
        if Mirage_crypto_ec.Ed25519.verify ~key:public_key envelope.signature
          ~msg:(authentication_payload envelope)
        then Ok ()
        else Error "envelope authentication failed"
    end

let open_envelope ~recipient_pk ~recipient_sk ~context ~message_id ~seen ~mark_seen raw =
  match decode raw with
  | Error _ as error -> error
  | Ok envelope when not (String.equal envelope.context context) -> Error "context mismatch"
  | Ok envelope when not (String.equal envelope.message_id message_id) -> Error "message id mismatch"
  | Ok envelope ->
    begin
      match verify_envelope envelope with
      | Error _ as error -> error
      | Ok () when seen ~sender_public:envelope.sender_public ~message_id -> Error "replay rejected"
      | Ok () ->
        begin
          match Pvac_ffi.deserialize_cipher_result (Bytes.of_string envelope.ciphertext) with
          | Error _ -> Error "ciphertext decoding failed"
          | Ok cipher when not (Pvac_ffi.cipher_matches_key recipient_pk cipher) -> Error "wrong recipient"
          | Ok cipher ->
            begin
              try
                let plaintext = int64_to_plaintext (Pvac_ffi.dec_value recipient_pk recipient_sk cipher) in
                Result.map (fun value -> mark_seen ~sender_public:envelope.sender_public ~message_id; value) plaintext
              with _ ->
                Error "native decryption failed"
            end
        end
    end
