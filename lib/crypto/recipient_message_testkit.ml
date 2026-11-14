module Test_generator = struct
  type g = { mutable remaining : string }

  let block = 1
  let create ?time:_ () = { remaining = "" }

  let generate_into ~g buffer ~off length =
    if length > String.length g.remaining then failwith "deterministic test RNG exhausted";
    Bytes.blit_string g.remaining 0 buffer off length;
    g.remaining <- String.sub g.remaining length (String.length g.remaining - length)

  let reseed ~g bytes = g.remaining <- g.remaining ^ bytes
  let accumulate ~g:_ _source = `Acc (fun _ -> ())
  let seeded ~g:_ = true
  let pools = 1
end

let seal ~recipient_view_public ~sender_secret ~context ~key_version ~message_id
    ~ephemeral_secret ~nonce ~policy ~current_epoch plaintext =
  if String.length message_id <> 16 then invalid_arg "test message id must be 16 bytes";
  if String.length ephemeral_secret <> 32 then invalid_arg "test ephemeral secret must be 32 bytes";
  if String.length nonce <> 12 then invalid_arg "test nonce must be 12 bytes";
  let generator = Mirage_crypto_rng.create
    ~seed:(message_id ^ ephemeral_secret ^ nonce) (module Test_generator) in
  Mirage_crypto_rng.set_default_generator generator;
  Fun.protect ~finally:Mirage_crypto_rng.unset_default_generator (fun () ->
    Recipient_message.seal ~recipient_view_public ~sender_secret ~context ~key_version
      ~policy ~current_epoch plaintext)

let open_envelope = Recipient_message_core.open_envelope

let x25519_from_seed seed = Recipient_keys.of_octets seed, Recipient_keys.public_of_secret (Recipient_keys.of_octets seed)
