(* SPDX-License-Identifier: BSD-3-Clause *)
(* Copyright (c) 2023-2026 Octra Labs <dev@octra.org> *)

module Oce1 = Octra_net.Oce1
module Hash_domain = Octra_net.Hash_domain

let instance_bytes = 16

let contact_key ~codec_version ~context ~recipient_view_public ~key_version ~sender_public =
  Hash_domain.hash_encoded_hex "octra:msg:outbox-channel:v2" (fun buffer ->
    Oce1.put_u16 buffer codec_version;
    Oce1.put_bytes buffer context;
    Oce1.put_bytes buffer recipient_view_public;
    Oce1.put_u32_int buffer key_version;
    Oce1.put_bytes buffer sender_public)

let key ~codec_version ~context ~recipient_view_public ~key_version ~sender_public ~sender_instance =
  Hash_domain.hash_encoded_hex "octra:msg:replay-window:v2" (fun buffer ->
    Oce1.put_u16 buffer codec_version;
    Oce1.put_bytes buffer context;
    Oce1.put_bytes buffer recipient_view_public;
    Oce1.put_u32_int buffer key_version;
    Oce1.put_bytes buffer sender_public;
    Oce1.put_bytes buffer sender_instance)
