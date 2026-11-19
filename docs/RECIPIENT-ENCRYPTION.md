# Recipient encryption disposition — v2

Disposition: **existing Octra-native X25519/AES-GCM recipient encryption through a thin message-profile binding**.
It is experimental and open for independent review, not a production security claim or a PVAC KEM. The active
scheme is `docs/SCHEME.md`; measurements are in `docs/CIPHERTEXT-SIZES.md` and `receipts/recipient/`.

## Inspected scope

Current native identities at verification:

- lite_node `8f785a93a4e7392a0f3e65674f9de89854d33dbc`.
- webcli `28208507bf704b9d2726dd48cb6597319c594688`, deployed executable SHA-256
  `93702748d072725ebebf564c55bf35b38ecb481bad4c09f02fef6520e3e6db3a`.
- PVAC library reference SHA-256 `fc72588467f5e84f34323de51b50b83bd8cb74c7b91b2cbfb7c150a365984357`.
  PVAC's C API requires the secret mask key for encryption and does not supply a secret-free sender boundary.

No candidate was chosen by name search alone: the PVAC C API, OCaml FFI, client bridge, key lifecycle, sealed
resources and native stealth calls were traced to implementation and key-material requirements.

## Candidate comparison

| Candidate | What the native path actually provides | Why it is or is not suitable |
| --- | --- | --- |
| PVAC same-key encryption and key switching | Arithmetic ciphertext and amount proofs, with the secret mask key required for encryption. | **Removed from the message path.** It cannot let a separate sender encrypt using only public recipient material. The old spike also had an unauthenticated envelope, public deterministic seed and unsafe parse cap. |
| Circle key policies, grants, object membership and HFHE policy | Activation, expiry, revocation and erasure states for native resources. | **Supporting lifecycle only.** A grant or policy row is not a decryption key or recipient-encryption operation. |
| Circle sealed resources, outbox/relay lifecycle and delivery IDs | Owner-controlled resources, delivery policy and status/intent hashes. | **Transport/lifecycle support only.** No arbitrary recipient encryption is implied, and a hash/off-chain body is not full on-chain message storage. |
| `Crypto.StealthAddress` and webcli stealth send | Fresh ephemeral X25519 sender key plus recipient public view key; the recipient later uses its own view secret. | **Selected closest native path.** The recipient can be offline and the sender needs no recipient secret. `Recipient_message` adds message domain, expected-sender authorization, replay, versions and exact framing. |
| `Octra_net.Oce1` and `Hash_domain` | Canonical big-endian fields, bounded reads and tagged SHA-256 for signing and replay identities. | **Used directly.** No parallel messenger encoder or competing tagged hash format is introduced. HMAC-SHA256 remains only for key derivation. |

## v2 key and signature boundary

Production messaging keys come from `Recipient_keys.generate` and have a dedicated opaque type; tagged JSON loading
and atomic writes are in the library. Raw construction and deterministic fixtures are not exported. The sender uses
its Octra wallet Ed25519 key; the receiver resolves that key from a contact registry by address. The signature is a
`Hash_domain` digest of the exact header and ciphertext, not an Octra transaction serialization.

The sender receives only its own wallet secret, public recipient view material and plaintext. The recipient is
offline during sealing and opens with its local view secret. `strace` confirms no recipient-secret file open in the
sender process. Production seals accept no caller-supplied ID, ephemeral secret or nonce; deterministic values
remain test-only.

Opening enforces receive size and v2 structure, checks the address binding and expected-sender signature, then
context, key version and policy, then ECDH, AEAD and atomic receive. The default chat cap is 64 KiB, separate from
the 3,000,000-byte explicitly raised test limit.

## Replay and version evidence

The signed header contains u64 sequence and sender epoch, both in signature and AEAD input. Per-contact sequence
allocation and a random sender instance prevent cross-contact jumps and same-wallet device collisions. Any forward
jump advances a permanent per-channel 1,024-bit window; duplicates and old out-of-window sequences reject.
High-water marks are never pruned, so replay after pruning remains rejected and retention across channels/rotations
requires migration.

Live acceptance is at most 64 epochs old and two ahead. Archive mode uses the frame's on-chain commit epoch, accepts
old messages when `sender_epoch <= commit_epoch`, and rejects future-after-commit envelopes. Policy uses the same
reference epoch. Atomic plaintext/window/inbox replacement prevents concurrent duplicate commits.

Only v2 readers and writers exist; v1 rewraps, old tags and unknown versions reject. `Session_context` is the single
application-bearing context codec and preserves version. Every digest, KDF, signature, associated-data payload,
replay identity and fixture uses native `Oce1` and `Hash_domain`; equal-concatenation splits produce different
hashes.

## Measured controls

`tests/run_recipient_spike.sh` uses independent synthetic endpoint keys in the approved VPS venue. Positive and
negative controls include:

- exact offline recovery, equal-plaintext distinct production envelopes, typed-key independence and sender access
  tracing;
- coherent wrong recipient, modified ID/ephemeral/header/context/signature and re-signed associated-data controls;
- all-zero, true `u = 1`, both order-8 points, `p - 1`, `p` and `p + 1` key-exchange failures, with ordinary
  all-`0x01` and all-`0xff` controls separately reaching AEAD;
- v1 rewrap and legacy-tag rejection, replay after pruning, out-of-order acceptance inside the window,
  outside-window rollback, large forward jumps, restart rollback and concurrent duplicates;
- live future tolerance, stale/future archive epochs, two-device identity and 1,025 other-contact sends;
- per-sender and global record/byte caps, crash/restart, exact retry bytes, production receive boundary and
  cap-plus-one rejection;
- on-chain non-writer rejection, owner-granted append, owner-only registry publish, restart reads and fixed-header
  sender-address binding before full decoding.

Raw results are in `receipts/recipient/endpoint.txt` and `sender.strace`. Source, executable, compiler/dependency
and command bindings are in `environment.json` and `sizes-environment.json`. `receipts/chain/devnet-feasibility.json`
adds an owner-specific circle deployment/write and exact public circle-view read followed by archive decryption
without the lab binary-I/O patch.

## On-chain binding and removed path

Native `CircleDeploy` does not execute the AML constructor, so segment and registry templates embed the owner before
compilation. Appends require the owner or an owner-granted writer and store `caller`; registry publishes require the
owner. The client requires the stored caller to match the contact wallet and fixed-header sender key before full
 decoding. Unauthorized writers cannot consume segment capacity. The `octra:msg:frame:v2` digest is the dedup key
and exact frame bodies are retained separately. Large-message chunking remains unimplemented.

The same-key PVAC spike, its historical driver and unused Python feed scanner are removed from the active source
tree. Their unsafe paths are not shipped as optional alternatives. Arithmetic PVAC remains a separate native
representation only, not a recipient-encryption claim.

## Remaining work

- Maintainer design read and independent specialist review of the whole v2 library, KDF/signature composition,
  replay atomicity, version negotiation, contact registration and on-chain sender binding.
- Production contact/policy acquisition, encrypted secret persistence and recovery, committed feed completeness,
  explicit fee-burn accounting and large retention/interference measurements.
- Large-message chunking, sustained rates, multi-client behavior and production admission. The isolated results
  are lab controls, not a deployed or secure messenger.

Messages are non-deniable and transferable. A leaked view secret exposes every retained ciphertext for that
version, including harvest-now archives. Forward secrecy, post-compromise recovery, recipient anonymity and
post-quantum confidentiality remain unestablished.
