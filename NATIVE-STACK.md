# Octra-native capability map

Status: architecture correction adopted. Only the behavior named as tested below is implemented. This map demonstrates an experimental recipient path, not a final wire profile, forward secrecy,
post-compromise recovery, recipient anonymity or production readiness.

## Pins and trust boundaries

- lite_node `3aab2d992035076dd216ad8808710d3a5a56063a`; running devnet executable SHA-256
  `c56f152ba4eb2372c1ecde446f1ac7feb932b8b3adc900e3701258e0a02ea208`.
- Deployed webcli source `28208507bf704b9d2726dd48cb6597319c594688`; executable SHA-256
  `93702748d072725ebebf564c55bf35b38ecb481bad4c09f02fef6520e3e6db3a`; deployed PVAC library SHA-256
  `fc72588467f5e84f34323de51b50b83bd8cb74c7b91b2cbfb7c150a365984357`.
- OCaml 4.14.2 and dune 3.23.0. Native calls use the existing `Pvac_ffi` C++ handles and finalizers; its
  `Runtime_scope` releases the OCaml runtime around native work. No primitive was rewritten in OCaml.
- Synthetic independent test seeds only. No validator, spending-key seed, production wallet or real message was
  used. Signing and PVAC key material stay outside the test envelope and public receipts.

## Capability matrix

| Requirement | Exact source symbol / route and active profile | Input and output | Trust boundary and evidence | Missing operation / minimal native extension |
| --- | --- | --- | --- | --- |
| Bounded payload confidentiality | `pvac_ffi/pvac_ffi.mli`: `enc_value_seeded`; `pvac/include/pvac/ops/encrypt.hpp`; same native library used by `Crypto.FheBalance` | Nonnegative `int64` and 32-byte seed; serialized PVAC ciphertext | Actual C++ encryption/decryption passed for a 7-byte synthetic payload. Ciphertext 43,168 bytes. | This proves same-key-holder encryption only. It does not prove encryption by a separate sender to a recipient. |
| Vector payload support | `Pvac_ffi.enc_values_seeded` / `dec_values` | Array of nonnegative `int64`; slot-vector ciphertext | Existing native API supports slots; this spike measured only one slot. | Bounded canonical byte-to-field chunking, slot caps and malformed-padding rejection must be specified and tested before arbitrary text support. |
| Recipient-only encryption | `Crypto.StealthAddress.generate_ephemeral` / `ecdh_shared_secret`; `Recipient_message.seal` / `open_envelope`; existing X25519/AES-GCM/Ed25519 | Ephemeral sender secret + recipient public view key; recipient view secret only at open | Separate offline sender/recipient processes pass exact recovery, production RNG and rotation/grace controls. Coherent wrong-recipient and re-signed associated-data controls reach AEAD; signature, policy, context, framing and replay guards reject without new receive state. | Existing native path through thin binding. Message-domain/profile composition and contact registry need independent review. Static recipient keys do not establish forward secrecy or post-quantum guarantees. |
| Sender authentication | `Mirage_crypto_ec.Ed25519.sign` / `verify`; account derivation in `lib/core/crypto.ml` | 32-byte Ed25519 secret/public keys; 64-byte signature | The test envelope authenticates sender, context, message ID and exact ciphertext. Tampering and wrong context fail. | Integrate with the transaction signer without exporting wallet signing secrets. Messaging authorization and message key lifecycle must remain separately scoped. |
| Ciphertext integrity | Test envelope in `lib/crypto/pvac_message.ml`, using the existing Ed25519 primitive | Signature covers context, ID, sender public key and serialized ciphertext | Altering the final ciphertext byte is rejected before decryption. | Arithmetic PVAC ciphertext is not asserted to be an AEAD. The test composition needs independent review and must not become a general decryption oracle. |
| Context binding | `lib/protocol/session_context.ml`; `authentication_payload` in `pvac_message.ml` | Canonical chain, registry, format and suite bytes, plus message ID and sender | Wrong context is rejected. | Native suite ID and registry object are not assigned/frozen. Inclusion-dependent values remain outside pre-submission associated data. |
| Replay resistance | `Transaction.nonce`; `Receive_store.commit_receive`; segment `seen[sha256(frame)]` | Local sender/context/message ID and exact frame hash | Local dedup and inbox pointer commit after AEAD and per-message plaintext fsync. On-chain duplicate frames reject without mutation. Concurrent local duplicates, crash/restart and closed-segment controls pass. | Global caps are 10,000 records and 512,000,000 bytes; per-sender caps are 1,000 and 51,200,000. Pruned erased/out-of-grace rows lose replay history and must not be reactivated in the same domain. Production nonce queue recovery and global cap migration remain open. |
| Key registration | `lib/core/pvac_registry.ml`: `register_decision`, `key_blob`; `Store_irmin` PVAC key registry | Raw/compressed public key, maximum 5,000,000 bytes | Existing-key replacement requires key switch; measured public key is 3,128,595 bytes. | Messaging-specific typed keys are implemented locally. **B6 is deferred to on-chain contact registration**: the test root secret is public-constant-derived and stored beside its config, not an authorization boundary. |
| Key isolation | `Recipient_keys.generate`; native `X25519.gen_key`; separate `Crypto.FheBalance.derive_pvac_keys` | Opaque X25519 messaging secret and public key; no Ed25519 input | Dedicated messaging key generation and public derivation pass; the key differs from the synthetic Ed25519 identity and legacy wallet-derived view key. | Production contact registration, encrypted backup and chain/application/device custody binding remain open. Never reinterpret an Ed25519 wallet secret as this type. |
| Grant semantics | `Circle_key_transition.grant`; `Circle_key_policy.live` | Key ID, activation and expiry epochs | Existing grants set lifecycle windows. | A lifecycle grant is not a decryption grant and does not prove recipient decryption. A reviewed capability/grant object is still needed. |
| Revocation and erasure | `Circle_key_transition.revoke` / `erase`; `Circle_key_state`; `Circle_key_resolution` | Policy transitions to revoked/erased and delivery cancellation | Source proves future delivery gating, not deletion of copied secrets. | Integrate policy checks with the selected recipient operation. No forward-secrecy or historical-erasure claim. |
| Rotation and key switch | Per-version signed `view_public`/`previous_view_public`, policy and grace lists; existing native lifecycle APIs | Current and retained previous X25519 keys | A genuinely unread v1 envelope opens after rotation during grace; a v1 envelope outside the accepted/grace lists is rejected. Each accepted version is bound to its registered public key. | Chain-finalized registration and secret-deletion scheduling remain open. Rotation alone does not establish forward secrecy. |
| Recovery | `Circle_sealed.read_key`, `digest`, `write_digest` | Passphrase, circle/key IDs, digest | The sealed module provides KDF/digest behavior, not a message AEAD or complete key backup. | Recovery format, encryption, key custody and history limitations are unimplemented. Do not use the sealed digest as message encryption. |
| HFHE access policy | `Circle_hfhe_policy`: access modes, allowlist, `require_live_key_policy` | Policy rows for load/encrypt/decrypt/arithmetic/proofs | Existing access-control configuration. | Policy configuration alone supplies neither key material nor a sender-to-recipient primitive. |
| Object membership | `Circle_object_member`, `Circle_object_policy`, `Circle_object_transition` | State/member/transition references and statuses | Native object lifecycle and membership records exist. | Membership does not automatically confer decryption. Map authorized recipients only after the native capability exists. |
| Circle transport | `CircleOutboxOpen`, relay claims/ingress, `delivery_key_id` | Intent/payload hashes, optional ciphertext blob hash, expiry and policy | Native relay lifecycle and key-expiry handling exist. | A hash or off-chain relay body is not fully on-chain messaging. Use only with complete ciphertext retained in Octra state and proven retrieval. |
| Durable chain storage | `programs/segment_spike.aml`; `segment_registry.aml`; Irmin current state and chaindata | Exact 2,048-byte frames, caps, full pages, content-hash dedup and append-only descriptors | Finalized encrypted bodies and registry descriptors match retrieval on restart, pack GC, index rebuild and fresh sync. A 102-frame common-feed index rebuild is byte-identical. | 10,000/100,000-frame storage, sustained/interference load, committed page proofs and bounded whole-contract append cost remain open. |
| Arbitrary-byte RPC | Disclosed base64 input/output profile in `program_input.ml`, `contract.ml`, `receipt_view.ml`, `contract_rpc.ml`, `rpc_view.ml` | Unique two-field `{encoding,data}` objects, valid UTF-8 text preserved | Canonical base64 decodes to `VBytes`; malformed, unpadded, pad-bit, wrong-shape and duplicate-key inputs reject at both routes. Empty/ASCII/invalid-byte and split-multibyte output controls pass. | Isolated compiler profile `6eb1af82…` needs independent review. Unrelated legacy objects retain fallback; storage keys remain raw strings. No production proposal or external transport stack is introduced. |
| Local persistence | `Receive_store`; `Outbox_journal`; native key handles remain outside receipts | Per-message plaintext files, dedup/pointer-only JSON and exact envelope bytes; synthetic secret files mode 0600 | Lock, unique temporary file, file/fsync plus directory fsync and atomic rename are implemented; crash injection, exact retry and cross-sender quota controls pass. | Secret files and plaintext inbox files are not encrypted at rest. Archived plaintext survives pointer pruning. Secure key backup, chain submission/nonce allocation and power-loss certification remain open. |
| Client integration | `chain_driver.ml`; `feed_scan.py`; existing native transaction/RPC routes | Native signed transactions, exact retry bytes, common-feed pages and local decryption | Signed bytes persist before submission. The common feed rebuild validates every frame and decrypts a selected record locally. | Production UI, finalized cursor/completeness semantics, contact/policy acquisition and multi-client behavior remain open. No external relay stack is introduced. |
| Performance | `MultiExec` batches; `chain-metrics.json`; `storage-growth.json`; `/usr/bin/time -v` and systemd counters | 100 encrypted 2,048-byte frames in 13 batches | Median finalization 7.078 s, p95 7.368 s, 113,000 OU, 77,100 effort, 293,111 signed JSON bytes and 293,891 RPC bytes. The old first-batch sample is not a slope; the final 14-point slopes are 9,812.67 apparent and 10,763.12 allocated bytes/frame, with pack-GC, restart and exact-read checkpoints. | Whole-directory growth includes consensus/index/view writes. 10,000/100,000 frames, sustainable 1/10/100 fps, multi-client interference and before/after optimization are unmeasured. |
| Historical and quantum properties | Native rotation/lifecycle APIs | Not established | No ratchet-like property is inferred from native key rotation or PVAC selection. | Forward secrecy, post-compromise recovery and post-quantum confidentiality each need a separate demonstrated design. |

## Historical same-key spike evidence (c49de45c)

`receipts/native/spike.txt` is a successful run of `tests/native_spike_driver.ml` against the pinned C++ PVAC
implementation and existing Ed25519 implementation:

- intended-recipient recovery of `pvac-v1` succeeded;
- wrong-recipient, tampering, wrong-context, replay and trailing-byte controls were rejected;
- failed controls did not advance the replay guard;
- plaintext 7 bytes; ciphertext 43,168 bytes; complete test envelope 43,357 bytes;
- public key 3,128,595 bytes; cipher slots 1, layers 2, edges 40;
- initial encryption 153.868 ms, direct decryption 0.101 ms, signature verification 0.260 ms;
- five seal/decrypt rounds: seal median 154.201 ms, maximum 157.715 ms; decrypt median 0.152 ms,
  maximum 0.163 ms; allocated bytes 1,747,384;
- whole test: 4.37 s user CPU, 4.43 s elapsed, maximum RSS 71,444 KiB (69.77 MiB);
- envelope SHA-256 `4eb156d1709e9cec7914ce344cf7f9e31e874f65624115e4852f2af3ac2bb89c`.

Ciphertext expansion is about 6,166.9 times the seven-byte payload; complete-envelope expansion is about 6,193.9
times. These are single-slot smoke measurements, not throughput or capacity claims. Public-key bootstrap size is
also material to the cost model.

`tests/run_native_spike.sh` reproduces the historical build and run on Hetzner. The signed test envelope is a
measurement and negative-control vehicle, not the final routine-message format. Its PVAC replay set is deliberately
in-memory; the separate recipient profile's durable receive store is described above.

## Recipient path evidence

`docs/RECIPIENT-ENCRYPTION.md` classifies the inspected candidates and selects the existing stealth-derived
X25519/AES-GCM route through a thin binding. `docs/NATIVE-RECIPIENT-EXTENSION.md` keeps the message profile
experimental and open for independent review. `docs/CIPHERTEXT-SIZES.md` and `receipts/recipient/sizes.csv`
contain all lengths, payload classes, cold/warm timings and allocations.

- Sender and recipient are separate processes with independent synthetic keys. `strace` shows no recipient-secret
  input to the sender. The recipient is offline during sealing.
- Expected-sender authorization is checked independently. Rotation to a fresh view key/version works; an unread
  v1 delivery opens during grace, while a v1 delivery outside the accepted/grace lists fails. Negative controls
  assert their own error class, no plaintext output and unchanged dedup/inbox state; crash-after-rename is the
  deliberate committed-state exception and rejects replay on restart.
- Current envelope overhead is 161 bytes plus 77-byte context and 28-byte nonce/tag: 266 bytes total.
- At 1, 2, 4 and 16 KiB, complete envelopes are 1,290, 2,314, 4,362 and 16,650 bytes; base64/JSON sizes are
  1,722, 3,090, 5,818 and 22,202 bytes.
- Same-key PVAC is only a representation baseline: at 16 KiB its vector ciphertext is 1,878,512 bytes, with
  3,128,595-byte public key and 4,171,462-byte base64 string. It is not a recipient-encryption benchmark.
- `receipts/chain/` adds signed transaction sizes and OU, actual registry/segment deployment, exact body
  retrieval/decryption, pruning/fresh sync, index rebuild, common-feed recovery and a 100-frame load spike. Explicit
  fee burn, 10,000/100,000-frame acceptance, production profile review, forward secrecy, post-compromise recovery
  and post-quantum guarantees remain open.

## Superseded investigation

The earlier libsignal/X3DH provider search is historical and superseded by the owner correction. Its reports and
receipts are retained for audit, not used as dependencies or blockers. The active path is Octra-native HFHE-PVAC
plus the nearest existing identity, policy, lifecycle, storage, transport and client primitives. Any missing
security operation gets a small reviewed native extension proposal; no external messaging stack is substituted.
