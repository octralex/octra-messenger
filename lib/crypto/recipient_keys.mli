type t

val generate : unit -> t * string
val of_octets : string -> t
val secret_to_octets : t -> string
val public_of_secret : t -> string
