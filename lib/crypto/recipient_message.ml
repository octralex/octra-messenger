type envelope = Recipient_message_core.envelope

let header_bytes = Recipient_message_core.header_bytes
let max_envelope_bytes = Recipient_message_core.max_envelope_bytes
let max_ciphertext_bytes = Recipient_message_core.max_ciphertext_bytes
let max_plaintext_bytes = Recipient_message_core.max_plaintext_bytes
let max_key_version = Recipient_message_core.max_key_version
let make_context = Recipient_message_core.make_context
let recipient_key_hash = Recipient_message_core.recipient_key_hash
let encode = Recipient_message_core.encode
let decode = Recipient_message_core.decode
let associated_payload = Recipient_message_core.associated_payload
let authentication_payload = Recipient_message_core.authentication_payload
let verify_envelope = Recipient_message_core.verify_envelope

let seal = Recipient_message_core.seal

let open_envelope ~recipient_view_secret ~expected_sender_public
    ~context ~key_version ~policy ~current_epoch ~seen ~mark_seen raw =
  match Recipient_message_core.open_envelope ~recipient_view_secret
    ~expected_sender_public ~context ~key_version ~policy ~current_epoch ~seen ~mark_seen raw with
  | Ok plaintext -> Ok plaintext
  | Error _ -> Error "rejected"
