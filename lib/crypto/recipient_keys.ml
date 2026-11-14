type t = Mirage_crypto_ec.X25519.secret

let generate () = Mirage_crypto_ec.X25519.gen_key ()

let secret_to_octets = Mirage_crypto_ec.X25519.secret_to_octets

let of_octets value =
  if String.length value <> 32 then invalid_arg "X25519 messaging secret must be 32 bytes";
  match Mirage_crypto_ec.X25519.secret_of_octets value with
  | Ok (secret, _) -> secret
  | Error _ -> invalid_arg "invalid X25519 messaging secret"

let public_of_secret value =
  match Mirage_crypto_ec.X25519.secret_of_octets (secret_to_octets value) with
  | Ok (_, public_key) -> public_key
  | Error _ -> invalid_arg "invalid X25519 messaging secret"
