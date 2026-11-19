# Octra-native capability map

Status: maintainer v2 revision under design and independent review. Only behavior named as tested below is
implemented. This is an experimental recipient profile, not a final wire profile, forward secrecy, post-compromise
recovery, recipient anonymity or production readiness. The realtime demo and external sync are not approved yet.

## Pins and trust boundaries

- lite_node `8f785a93a4e7392a0f3e65674f9de89854d33dbc`; webcli
  `28208507bf704b9d2726dd48cb6597319c594688` and executable SHA-256
  `93702748d072725ebebf564c55bf35b38ecb481bad4c09f02fef6520e3e6db3a`.
- PVAC library reference SHA-256 `fc72588467f5e84f34323de51b50b83bd8cb74c7b91b2cbfb7c150a365984357`.
  The same-key PVAC message path is removed; PVAC arithmetic is not asserted to be a KEM.
- OCaml 4.14.2, dune 3.23.0, Mirage 2.1.0. The recipient path uses existing X25519, AES-GCM and Ed25519
  implementations plus `Octra_net.Oce1` and `Octra_net.Hash_domain`. No external messaging stack or package.
- Synthetic independent test keys only. No validator, spending-key seed, production wallet or real conversation.
  Secrets and receive state are excluded from public receipts.

## Capability matrix

| Requirement | Exact source route and active profile | Trust boundary and evidence | Missing operation / limit |
| --- | --- | --- | --- |
| Payload confidentiality | `Crypto.StealthAddress` X25519 plus native AES-GCM in `Recipient_message.seal` | Ephemeral sender key + recipient public view key; separate sender/recipient processes recover plaintext while recipient is offline. Sender `strace` has no recipient-secret open. | Static keys do not establish forward secrecy or post-quantum protection. |
| Key isolation | `Recipient_keys.generate`, typed JSON and atomic writes | Dedicated X25519 type, validated tagged key files, independent from synthetic Ed25519 identity. | Production custody needs encrypted backup. Raw construction is not exported. |
| Sender authentication | `Hash_domain.hash_encoded` + Ed25519, expected key resolved by wallet address | Address/key binding and signature verification precede context, policy, ECDH and AEAD. Modified signatures and wrong senders reject. | Contact registration is deferred; test roots are not production trust anchors. Wallet key is used for message signatures. |
| Key derivation | HMAC-SHA256 extract-and-expand over OCE1 fields | ECDH secret plus recipient/ephemeral/view/context/sequence/epoch/sender-instance fields. No external KDF or public deterministic seed. | Independent composition review is still required. |
| Ciphertext integrity | Native AES-GCM and tagged Ed25519 signature | Wrong recipient, modified header/ciphertext/context/signature and re-signed AD controls reach named guards. | No PVAC arithmetic ciphertext is treated as AEAD. |
| Structured encoding | `Octra_net.Oce1` and `Octra_net.Hash_domain` | Same-concatenation field splits produce different tagged digests. Every v2 digest/signature/replay/storage path uses native primitives. | v1 legacy encoding is removed, not accepted. |
| Versioning | Explicit u16 codec/context/cursor versions | Only v2 readers and writers. Unknown versions, v1 rewraps, legacy tags and trailing bytes reject. | No legacy compatibility or ratchet is claimed. |
| Replay resistance | Per-contact `Outbox_journal` and `Receive_store.commit_receive` | Full channel digest, durable pre-seal sequence/instance, permanent 1,024-bit window, any forward jump, atomic commit. 1,025 other-contact sends and two devices pass. | High-water windows are never pruned; growth across channels/rotations needs migration. |
| Epoch handling | `Freshness.Live` and `Freshness.Archive` | Live: at most 64 old and 2 ahead. Archive: sender epoch at or before frame commit epoch; no live age bound. | Production finalized-epoch/contact policy acquisition remains integration work. |
| Atomic persistence | Receive lock, unique temporary file, file/directory fsync and atomic rename | Per-message plaintext, updated window and pointer-only inbox in one state replacement. Concurrent duplicates accept once; crash/retry controls pass. | Crash orphans count until retry; power-loss certification is not done. Files are not encrypted at rest. |
| Quotas | Per-sender and global record/byte caps | 1,000 / 51,200,000 per sender; 10,000 / 512,000,000 global. One capped sender does not block a second. | Ten authorized contacts can exhaust the global cap; receive scans the directory. |
| On-chain sender | Owner-instantiated `segment_spike.aml` and `segment_registry.aml`; `Sender_binding.verify_envelope` | Owner/granted writer and stored caller; non-owner writes reject without mutation; fixed-header sender binds before full decode. | Production writer registry and circle policy are not implemented. CircleDeploy does not run the AML constructor. |
| Circle transport | Native `CircleDeploy` / `CircleCall` / `octra_circleView` | Owner-specific bytecode, exact public v2 envelope retrieval and local decryption without owner-secret reads or lab patch. | Per-user client, rollover, production fees and larger writes are not implemented. |
| Binary RPC | Separately disclosed older lab `program_input.ml`, `contract.ml`, `receipt_view.ml`, `contract_rpc.ml`, `rpc_view.ml` | Canonical two-field base64 inputs and text/base64 values, with negative controls. | Storage keys remain raw strings. Older lab only, not an upstream activation or evidence for this library. |
| Durable chain storage | Exact 2,048-byte frames in circles/segments, append-only descriptors | Current owner-specific devnet read proof plus local restart controls. | Revised pruning/fresh-sync, large chunks, committed page proofs and bounded whole-contract cost remain open. |
| Performance | Native size sweep and chain receipts | Cold/warm timings, allocations, signed sizes, OU and source/executable hashes. | Large retention, sustained rates, multi-client interference and before/after optimization are unmeasured. |
| Historical and quantum properties | Native key rotation/lifecycle only | No ratchet-like property is inferred from rotation or PVAC selection. | Forward secrecy, post-compromise recovery and post-quantum confidentiality each need a separate demonstrated design. |

## Removed paths and rationale

The same-key PVAC spike and historical drivers are deleted from the active library and tests. PVAC's API requires
the secret mask key, so it cannot provide recipient-offline public-key encryption. Its unauthenticated envelope,
public deterministic seed, malleable ciphertext acceptance and oversized parse cap are not retained as an optional
mode. The unused Python feed scanner is also removed; there is no parallel non-OCaml messaging implementation.

## Evidence and open work

`receipts/recipient/` binds endpoint and size results; `receipts/chain/` binds segment, devnet, binary I/O and
storage evidence. `docs/SCHEME.md` is the one-page scheme for the maintainer's design read, which is still
open. Production contacts/policy,
encrypted secret persistence, large-message chunking, committed feed completeness, explicit fee burn, large retention,
revised pruning/fresh-sync, sustained load, client integration and production readiness are not established.
