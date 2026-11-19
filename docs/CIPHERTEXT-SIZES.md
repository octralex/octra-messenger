# Ciphertext and bootstrap sizes

Scope: recipient profile v2 measured on Hetzner at lite_node
`8f785a93a4e7392a0f3e65674f9de89854d33dbc`, using `tests/size_sweep.ml` and
`tests/run_size_sweep.sh`. The selected route is `recipient-x25519-aes-gcm`, built through `octra_messenger` against
`octra_net` and `octra_core`. Synthetic keys and plaintexts only. The same-key PVAC route and comparison rows are
removed; no PVAC result is presented as recipient encryption.

## Method

- Plaintext lengths: 0, 1, 7, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 and 16384 bytes.
- Additional 64-byte ASCII, 128-byte multilingual UTF-8, repeated-byte, deterministic-random and embedded-zero
  fixtures make 19 recipient rows. The UTF-8 generator repeats whole codepoints and uses ASCII only for the final
  fill; it never slices a multibyte character. Length is bytes, not character count. No compression.
- Five seal/open repetitions per case: one cold followed by four warm. Warm median/max excludes the cold sample;
  overall max includes all five. Allocation is the sum of cold seal and cold open allocation. Signature
  verification and serialization are included in open and seal respectively, not reported as separate operations.
- `/usr/bin/time -v` records process resource use. This run used 0.08 seconds user CPU, 0.18 seconds elapsed wall
  time and had maximum RSS 23,376 KiB (22.83 MiB). These are measurements of this small sweep, not sustained load.
- OCaml 4.14.2, dune 3.23.0, Linux x86-64 and Mirage 2.1.0. Source, separate executable hashes, lock file,
  dependency hashes and commands are bound in `receipts/recipient/environment.json` and
  `receipts/recipient/sizes-environment.json`. The CSV SHA-256 is
  `071b2abfeba9d21f81e7ecada2d6c8cbc24e5f3dd530707ffd000a1edd38165d`.
- Deterministic testkit seeds invoke the production v2 sealer. Production callers cannot supply a message ID,
  ephemeral secret or nonce; those values come from the native RNG. Sender instance and sequence are allocated by
  the per-contact outbox on production sends.

Raw evidence: `receipts/recipient/sizes.csv`, `sizes-time.txt` and `sizes-validation.json`.
Negative controls are in `receipts/recipient/endpoint.txt`, not in this positive-only size sweep.

## Recipient v2 measurements

The fixed header is 194 bytes. With the current 86-byte OCE1 context and 28-byte nonce/tag, overhead is 308 bytes.
`native_bytes` is the 12-byte nonce, ciphertext and 16-byte GCM tag. `wire_bytes` is base64 of the complete
envelope plus JSON string quotes. Times are cold / warm median / warm maximum / overall maximum milliseconds.

| Plaintext B | Native B | Envelope B | Overhead B | Base64/JSON B | Seal ms | Open ms |
| ---: | ---: | ---: | ---: | ---: | --- | --- |
| 0 | 28 | 308 | 308 | 414 | 1.699 / 0.483 / 0.527 / 1.699 | 0.337 / 0.401 / 0.471 / 0.471 |
| 1 | 29 | 309 | 308 | 414 | 0.490 / 0.423 / 0.438 / 0.490 | 0.351 / 0.209 / 0.306 / 0.351 |
| 7 | 35 | 315 | 308 | 422 | 0.244 / 0.393 / 0.434 / 0.434 | 0.184 / 0.314 / 0.630 / 0.630 |
| 8 | 36 | 316 | 308 | 426 | 0.432 / 0.545 / 0.550 / 0.550 | 0.325 / 0.324 / 0.341 / 0.341 |
| 16 | 44 | 324 | 308 | 434 | 0.496 / 0.563 / 0.606 / 0.606 | 0.315 / 0.395 / 0.455 / 0.455 |
| 32 | 60 | 340 | 308 | 458 | 0.445 / 0.354 / 0.528 / 0.528 | 0.232 / 0.217 / 0.310 / 0.310 |
| 64 | 92 | 372 | 308 | 498 | 0.329 / 0.440 / 0.617 / 0.617 | 0.266 / 0.313 / 0.331 / 0.331 |
| 128 | 156 | 436 | 308 | 586 | 0.441 / 0.513 / 0.630 / 0.630 | 0.312 / 0.327 / 0.335 / 0.335 |
| 256 | 284 | 564 | 308 | 754 | 0.426 / 0.437 / 0.556 / 0.556 | 0.318 / 0.321 / 0.324 / 0.324 |
| 512 | 540 | 820 | 308 | 1098 | 0.430 / 0.434 / 0.445 / 0.445 | 0.320 / 0.315 / 0.317 / 0.320 |
| 1024 | 1052 | 1332 | 308 | 1778 | 0.450 / 0.435 / 0.446 / 0.450 | 0.329 / 0.328 / 0.335 / 0.335 |
| 2048 | 2076 | 2356 | 308 | 3146 | 0.457 / 0.456 / 0.461 / 0.461 | 0.336 / 0.343 / 0.344 / 0.344 |
| 4096 | 4124 | 4404 | 308 | 5874 | 0.477 / 0.470 / 0.482 / 0.482 | 0.427 / 0.356 / 0.371 / 0.427 |
| 16384 | 16412 | 16692 | 308 | 22258 | 0.352 / 0.368 / 0.379 / 0.379 | 0.329 / 0.290 / 0.295 / 0.329 |

All 19 rows passed seal/open round trips. The encrypted payload grows one byte per plaintext byte plus 28 bytes;
envelope growth is linear with constant header/context overhead. A 1 KiB envelope has 1,776 base64 bytes and fits
the selected 2,048-byte text frame with padding. A 2 KiB envelope has 3,144 base64 bytes and does not. Large-message
chunking is not implemented.

## Key generation and bootstrap

| Material | Raw bytes | Base64 plus JSON quotes | Measured operation | Scope |
| --- | ---: | ---: | --- | --- |
| Recipient X25519 view public key | 32 | 46 | 0.155 ms deterministic fixture decode/derivation | Per independent recipient key/version; not a production RNG benchmark. |
| Sender Ed25519 public key | 32 | 46 | 0.001 ms deterministic fixture decode | Per sender/contact identity. |
| Sender instance | 16 | 24 | Included in first channel allocation | Per outbox contact and device. |
| Ephemeral public key | 32 | 46 | Included in seal | Per message. |
| AES nonce + GCM tag | 28 | Base64 of containing envelope | Included in seal/open | Per message. |

These are key and encoding sizes only. They exclude contact signatures, policy objects, transaction envelopes,
registration storage and fees. No PVAC public key is required by this recipient route. Production key registration
remains deferred to on-chain contact/policy integration.

## Limits and chain evidence

The encoding cap is 3,000,000 bytes including the header, context and encrypted payload. With a maximum 512-byte
context, the plaintext cap is 2,999,266 bytes. With the endpoint's 86-byte context, exact-cap plaintext is
2,999,266 bytes, the envelope is 2,999,574 bytes and base64 plus quotes is 3,999,434 bytes. That large-vector
round trip uses the explicitly raised test limit. The production open command's default 65,536-byte receive cap
accepts exactly 65,228 plaintext bytes in this context and rejects the 65,537-byte envelope produced by one more
plaintext byte.

The current segment accepts exactly 2,048 bytes of base64 text per frame. Consequently the encoding cap is not a
chain message-size claim: whole large envelopes require a separate chunking design. Current small-message signed
sizes and native OU base costs are recorded by `receipts/chain/devnet-feasibility.json`; those OU values are not
receipt effort, explicit fee burn or a production fee schedule.

Historical signed-transport, storage-growth and latency receipts remain bound to their original source and
executable identities in `receipts/chain/`. They are not fresh evidence for the v2 segment or recipient profile.
In particular, earlier maximum-signed-append and 100-frame measurements do not establish current v2 chain
acceptance, large-message storage, sustainable throughput or production admission. Fresh 10,000/100,000-frame,
retention, revised pruning/fresh-sync, sustained-rate and multi-client measurements remain open.
