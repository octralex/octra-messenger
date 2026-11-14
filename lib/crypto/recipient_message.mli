type envelope = Recipient_message_core.envelope

val header_bytes : int
val max_envelope_bytes : int
val max_ciphertext_bytes : int
val max_plaintext_bytes : int
val max_key_version : int

val make_context :
  chain_id:string -> application:string -> registry:string ->
  format_version:int -> suite:int -> string

val recipient_key_hash : string -> string
val encode : envelope -> (string, string) result
val decode : string -> (envelope, string) result
val associated_payload : envelope -> string
val authentication_payload : envelope -> string
val verify_envelope : envelope -> (unit, string) result

val seal :
  recipient_view_public:string ->
  sender_secret:Mirage_crypto_ec.Ed25519.priv ->
  context:string ->
  key_version:int ->
  policy:Octra_core.Circle_key_policy.t ->
  current_epoch:int64 ->
  string ->
  (envelope * string, string) result

val open_envelope :
  recipient_view_secret:Recipient_keys.t ->
  expected_sender_public:string ->
  context:string ->
  key_version:int ->
  policy:Octra_core.Circle_key_policy.t ->
  current_epoch:int64 ->
  seen:(sender_public:string -> message_id:string -> bool) ->
  mark_seen:(sender_public:string -> message_id:string -> plaintext:string -> unit) ->
  string ->
  (string, string) result
