type envelope = {
  context : string;
  key_version : int;
  message_id : string;
  recipient_key_hash : string;
  ephemeral_public : string;
  sender_public : string;
  signature : string;
  ciphertext : string;
}

let magic = "OCMMSG1"
let auth_magic = "OCMMSG-AUTH1\000"
let message_domain = "OCTRA_MESSAGE_V1\000"
let max_context_bytes = 512
let gossip_json_cap = 5_000_000
let storage_value_cap = 4_194_304
let max_key_version = 0xffff_ffff
let header_bytes = 161
let max_envelope_bytes = 3_000_000
let transaction_overhead_budget = 194_302
let max_ciphertext_bytes = max_envelope_bytes - header_bytes - max_context_bytes
let max_plaintext_bytes = max_ciphertext_bytes - 28

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

let make_context ~chain_id ~application ~registry ~format_version ~suite =
  let valid name value = String.length value > 0 && String.length value <= 64 in
  if not (valid "chain" chain_id && valid "application" application && valid "registry" registry) then
    invalid_arg "recipient context field length";
  if format_version <= 0 || format_version > 65535 then invalid_arg "recipient format version";
  if suite <= 0 || suite > 255 then invalid_arg "recipient suite";
  let buffer = Buffer.create 192 in
  Buffer.add_string buffer "OCMRCV1\000";
  List.iter (fun value ->
    Buffer.add_char buffer (Char.chr (String.length value));
    Buffer.add_string buffer value)
    [chain_id; application; registry];
  add_u16 buffer format_version;
  Buffer.add_char buffer (Char.chr suite);
  Buffer.contents buffer

let recipient_key_hash view_public =
  Digestif.SHA256.(digest_string ("octra:recipient-view:v1\000" ^ view_public) |> to_raw_string)

let validate envelope =
  if String.length envelope.context = 0 || String.length envelope.context > max_context_bytes then
    Error "context outside limits"
  else if envelope.key_version <= 0 || Int64.of_int envelope.key_version > 0xffff_ffffL then
    Error "key version outside uint32"
  else if String.length envelope.message_id <> 16 then Error "message id must be 16 bytes"
  else if String.length envelope.recipient_key_hash <> 0 && String.length envelope.recipient_key_hash <> 32 then
    Error "recipient key hash is not canonical"
  else if String.length envelope.ephemeral_public <> 32 then Error "ephemeral key must be 32 bytes"
  else if String.length envelope.sender_public <> 32 then Error "sender key must be 32 bytes"
  else if String.length envelope.signature <> 64 then Error "signature must be 64 bytes"
  else if String.length envelope.ciphertext < 28 || String.length envelope.ciphertext > max_ciphertext_bytes then
    Error "ciphertext outside limits"
  else if header_bytes + String.length envelope.context + String.length envelope.ciphertext > max_envelope_bytes then
    Error "envelope exceeds admission cap"
  else Ok ()

let encode envelope =
  match validate envelope with
  | Error _ as error -> error
  | Ok () ->
    let buffer = Buffer.create (header_bytes + String.length envelope.context + String.length envelope.ciphertext) in
    Buffer.add_string buffer magic;
    add_u16 buffer (String.length envelope.context);
    add_u32 buffer (String.length envelope.ciphertext);
    add_u32 buffer envelope.key_version;
    Buffer.add_string buffer envelope.message_id;
    Buffer.add_string buffer envelope.ephemeral_public;
    Buffer.add_string buffer envelope.sender_public;
    Buffer.add_string buffer envelope.signature;
    Buffer.add_string buffer envelope.context;
    Buffer.add_string buffer envelope.ciphertext;
    Ok (Buffer.contents buffer)

let decode text =
  let length = String.length text in
  if length < header_bytes then Error "envelope truncated"
  else if not (String.equal (String.sub text 0 7) magic) then Error "unsupported envelope version"
  else
    let context_length = u16 text 7 in
    let ciphertext_length = u32 text 9 in
    let key_version = u32 text 13 in
    if context_length = 0 || context_length > max_context_bytes then Error "context outside limits"
    else if ciphertext_length < 28 || ciphertext_length > max_ciphertext_bytes then
      Error "ciphertext outside limits"
    else if length <> header_bytes + context_length + ciphertext_length then
      Error "envelope trailing or truncated bytes"
    else
      let ciphertext_offset = header_bytes + context_length in
      let envelope = {
        context = String.sub text header_bytes context_length;
        key_version;
        message_id = String.sub text 17 16;
        recipient_key_hash = "";
        ephemeral_public = String.sub text 33 32;
        sender_public = String.sub text 65 32;
        signature = String.sub text 97 64;
        ciphertext = String.sub text ciphertext_offset ciphertext_length;
      } in
      validate envelope |> Result.map (fun () -> envelope)

let associated_payload envelope =
  let buffer = Buffer.create (String.length auth_magic + 2 + 4 + 4 + 16 + 32 + 32 + String.length envelope.context) in
  Buffer.add_string buffer auth_magic;
  add_u16 buffer (String.length envelope.context);
  add_u32 buffer envelope.key_version;
  Buffer.add_string buffer envelope.message_id;
  Buffer.add_string buffer envelope.ephemeral_public;
  Buffer.add_string buffer envelope.sender_public;
  Buffer.add_string buffer envelope.context;
  Buffer.contents buffer

let authentication_payload envelope =
  let buffer = Buffer.create (String.length auth_magic + 2 + 4 + 4 + 16 + 32 + 32 + String.length envelope.context + String.length envelope.ciphertext) in
  Buffer.add_string buffer auth_magic;
  add_u16 buffer (String.length envelope.context);
  add_u32 buffer (String.length envelope.ciphertext);
  add_u32 buffer envelope.key_version;
  Buffer.add_string buffer envelope.message_id;
  Buffer.add_string buffer envelope.ephemeral_public;
  Buffer.add_string buffer envelope.sender_public;
  Buffer.add_string buffer envelope.context;
  Buffer.add_string buffer envelope.ciphertext;
  Buffer.contents buffer

let derive_key shared recipient_key_hash ephemeral_public view_public context =
  Digestif.SHA256.(digest_string
    (shared ^ message_domain ^ recipient_key_hash ^ ephemeral_public ^ view_public ^ context)
    |> to_raw_string)

let seal ~recipient_view_public ~sender_secret ~context ~key_version ~policy ~current_epoch plaintext =
  let message_id = Mirage_crypto_rng.generate 16 in
  let ephemeral_secret, _ = Octra_core.Crypto.StealthAddress.generate_ephemeral () in
  let nonce = Mirage_crypto_rng.generate 12 in
  if not (Octra_core.Circle_key_policy.live policy current_epoch) then Error "recipient key policy is not live"
  else if String.length plaintext > max_plaintext_bytes then Error "plaintext outside limits"
  else if key_version <= 0 || Int64.of_int key_version > 0xffff_ffffL then Error "key version outside uint32"
  else if String.length message_id <> 16 then Error "message id must be 16 bytes"
  else if String.length nonce <> 12 then Error "recipient nonce must be 12 bytes"
  else
    match Mirage_crypto_ec.X25519.secret_of_octets ephemeral_secret with
    | Error _ -> Error "invalid ephemeral secret"
    | Ok (_, ephemeral_public) ->
      let recipient_key_hash = recipient_key_hash recipient_view_public in
      begin
        match Octra_core.Crypto.StealthAddress.ecdh_shared_secret ephemeral_secret recipient_view_public with
        | Error reason -> Error reason
        | Ok shared ->
          let key = Mirage_crypto.AES.GCM.of_secret
            (derive_key shared recipient_key_hash ephemeral_public recipient_view_public context) in
          let sender_public = Mirage_crypto_ec.Ed25519.(pub_of_priv sender_secret |> pub_to_octets) in
          let unsigned = {
            context; key_version; message_id; recipient_key_hash; ephemeral_public;
            sender_public; signature = String.make 64 '\000'; ciphertext = String.make 28 '\000';
          } in
          let adata = associated_payload unsigned in
          let ciphertext = nonce ^ Mirage_crypto.AES.GCM.authenticate_encrypt ~key ~nonce ~adata plaintext in
          let unsigned = { unsigned with ciphertext } in
          let signature = Mirage_crypto_ec.Ed25519.sign ~key:sender_secret (authentication_payload unsigned) in
          let envelope = { unsigned with signature } in
          Result.map (fun raw -> envelope, raw) (encode envelope)
      end

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
        else Error "sender authentication failed"
    end

let open_envelope ~recipient_view_secret ~expected_sender_public
    ~context ~key_version ~policy ~current_epoch ~seen ~mark_seen raw =
  let recipient_view_public = Recipient_keys.public_of_secret recipient_view_secret in
  let recipient_view_secret = Recipient_keys.secret_to_octets recipient_view_secret in
  match decode raw with
  | Error _ as error -> error
  | Ok envelope when not (String.equal envelope.context context) -> Error "wrong chain, application or registry context"
  | Ok envelope when envelope.key_version <> key_version -> Error "recipient key version mismatch"
  | Ok envelope when not (Octra_core.Circle_key_policy.live policy current_epoch) -> Error "recipient key policy is stale"
  | Ok envelope when not (String.equal envelope.sender_public expected_sender_public) ->
    Error "unexpected sender identity"
  | Ok envelope ->
    begin
      match verify_envelope envelope with
      | Error _ as error -> error
      | Ok () when seen ~sender_public:envelope.sender_public ~message_id:envelope.message_id ->
        Error "replay rejected"
      | Ok () ->
        begin
          match Octra_core.Crypto.StealthAddress.ecdh_shared_secret
            recipient_view_secret envelope.ephemeral_public with
          | Error _ -> Error "recipient key exchange failed"
          | Ok shared ->
            let key = Mirage_crypto.AES.GCM.of_secret
              (derive_key shared (recipient_key_hash recipient_view_public)
                envelope.ephemeral_public recipient_view_public envelope.context) in
            let nonce = String.sub envelope.ciphertext 0 12 in
            let body = String.sub envelope.ciphertext 12 (String.length envelope.ciphertext - 12) in
            begin
              match Mirage_crypto.AES.GCM.authenticate_decrypt ~key ~nonce
                ~adata:(associated_payload envelope) body with
              | Some plaintext ->
                mark_seen ~sender_public:envelope.sender_public ~message_id:envelope.message_id ~plaintext;
                Ok plaintext
              | None -> Error "ciphertext authentication failed"
            end
        end
    end
