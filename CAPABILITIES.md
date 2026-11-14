# Capabilities and limits

Status: Octra-native architecture correction adopted. Offline storage and native recipient controls pass. The
isolated Phase 2 registry/segment spike has complete encrypted frames in finalized state, exact retrieval and
recipient decryption, restart/prune/index-rebuild/fresh-sync evidence, and a 100-frame batched load measurement.
This is not a deployed messenger, capacity proof, production candidate or readiness claim. Independent review,
production policy/key integration, encrypted secret persistence and larger/interference benchmarks remain open.

## Implementation and live pins

- Implementation: `projects/onchain-messenger/` in `octralex/octra-egregore`, built and tested only on Hetzner.
- Devnet source and deployed commit at 2026-11-14T10:54:54Z:
  `3aab2d992035076dd216ad8808710d3a5a56063a`.
- Running devnet executable: SHA-256 `c56f152ba4eb2372c1ecde446f1ac7feb932b8b3adc900e3701258e0a02ea208`.
- Devnet RPC at that observation: head epoch 1,836,733, state root
  `63b92440629001be43746da5a3a60fc9118aaa48a68c93cba8c5269966556945`.
- Deployed webcli source `28208507bf704b9d2726dd48cb6597319c594688`, executable SHA-256
  `93702748d072725ebebf564c55bf35b38ecb481bad4c09f02fef6520e3e6db3a`, PVAC library SHA-256
  `fc72588467f5e84f34323de51b50b83bd8cb74c7b91b2cbfb7c150a365984357`.
- OCaml 4.14.2 and dune 3.23.0 from the node switch. No OCaml 5 migration or external messaging dependency.

The validator identity, wallet, live binary, updater and devnet accounts were not used. The approved isolated
venue is `/srv/octra-node/fakenet-kimi-messenger/`, RPC 18171-18177 and consensus 19161-19167, with a separate
lock, 2 vCPU/4 GiB slice and 50 GiB cap. Seven synthetic lab nodes are provisioned; the shared fakenet was not modified.

## Measured source limits at the pin

| Limit | Observed value | Consequence |
| --- | ---: | --- |
| Ordinary transfer message | 256 bytes | Not a messenger transport. |
| Program message field | 10,000,000 bytes | Not an end-to-end payload guarantee. |
| Transaction gossip JSON | 5,000,000 bytes | JSON and encoding overhead must be included. |
| Program execution lane | 128 transactions, 4 MiB, 10,000,000 OU per budget | Capacity needs multi-node measurement. |
| Contract storage value | 4,194,304 bytes | A native-size ciphertext fits; the 8 MiB segment is split across keys. |
| PVAC public key registration | 5,000,000 bytes | Measured 3,128,595-byte key fits, with material bootstrap cost. |
| View call | 10 second RPC deadline, singleton busy guard | Feed paging needs explicit budgets and backpressure. |
| Storage dump RPC | Disabled; explicit keys only | The client uses `get`/`page`, not a full-state dump. |

Source anchors: `lib/core/tx_payload.ml`, `net/p2p_tx_gossip.ml`, `lib/core/resource_lanes.ml`,
`lib/core/pvac_registry.ml`, `lib/vm/runtime/contract_vm.ml`, `lib/vm/rpc/contract_rpc.ml` and
`node_runtime/program_read_rpc.ml`.

## Historical storage spike (c49de45c)

`programs/segment_spike.aml` appends exactly 2,048 opaque bytes with at most 1,024 records and 8,388,608 frame
bytes. It provides single-record reads, recomputed SHA-256, unrolled 16-record pages, publisher-only close and
hash/sequence events without a second body copy.

Both historical and scoped compiler profiles pass 20 binary frames, page/tail reads, rejection atomicity,
unauthorized-close rejection, closed-append rejection and two Irmin restarts. Earlier loop/type-flow failures
are retained in receipts. The devnet compiler artifact is 3,900 bytes, 483 instructions, SHA-256
`dd175e71733eb547cb4ca5a375aff87174d4ead184d3d43639fcb38102e3d282`.

This proves disposable-store behavior only. It does not prove consensus inclusion, pruning recovery, fresh sync,
a complete page proof, registry immutability or chain-level deduplication. Whole-contract load/save remains
linear in retained history, so bounded append cost is not established.

## Historical same-key HFHE-PVAC spike (c49de45c)

The detailed requirement/source/trust matrix is [`NATIVE-STACK.md`](NATIVE-STACK.md). The active implementation
uses `Pvac_ffi` and existing Octra Ed25519, not an external messaging protocol.

`lib/crypto/pvac_message.ml` creates and opens a bounded signed test envelope. `tests/native_spike_driver.ml`
and `tests/run_native_spike.sh` demonstrate:

- a 7-byte synthetic plaintext recovered by the intended key holder;
- wrong-recipient, tampering, wrong-context, replay and trailing-byte rejection;
- no replay-state advancement on those failed controls;
- ciphertext 43,168 bytes, signed envelope 43,357 bytes and public key 3,128,595 bytes;
- five-round seal median 154.201 ms, maximum 157.715 ms; decrypt median 0.152 ms, maximum 0.163 ms;
- whole-process maximum RSS 71,444 KiB (69.77 MiB).

The receipt is `receipts/native/spike.txt`. This is same-key-holder PVAC encryption plus an Ed25519 test envelope,
not an AEAD or a final messaging composition. `enc_value_seeded` requires the secret key used for the mask, so
a separate sender cannot encrypt to a recipient using only the registered public key. This remains a same-key
baseline only. The separate recipient profile below uses the existing X25519 path; no PVAC KEM/key-wrap is invented.

The existing 2/4 KiB frame buckets cannot hold this native envelope. A 64 KiB bucket is a candidate, and bounded
native chunking is another, but neither is frozen. Revisit storage fees, scanner bandwidth and public-key
bootstrap size before choosing.

## Genuine recipient path and size evidence

`docs/RECIPIENT-ENCRYPTION.md` selects the existing stealth-derived X25519/AES-GCM route through a thin binding,
with `docs/NATIVE-RECIPIENT-EXTENSION.md` as its experimental profile. Separate processes prove secret-free
sender sealing, offline recipient recovery, rotation and all required negative controls; `strace` shows no
recipient-secret input. This is distinct from the same-key PVAC representation above.

The recipient envelope has 161-byte header + 77-byte context + 28-byte nonce/tag. At 1, 2, 4 and 16 KiB,
envelopes are 1,290, 2,314, 4,362 and 16,650 bytes; base64/JSON sizes are 1,722, 3,090, 5,818 and 22,202.
`docs/CIPHERTEXT-SIZES.md` and `receipts/recipient/sizes.csv` record every length, fixture, timing and allocation.
For the selected legacy append route, a 322-byte envelope produced a 3,174-byte signed transaction (3,234-byte
RPC request) with 1,000 OU. Legacy deployment was 3,078 bytes and 200,000 OU; registry deployment was 1,447 bytes
and 200,000 OU. Receipt effort is VM effort, not an OU-denominated burn. The public sender signature is non-deniable
and transferable, and `sender_public` is clear metadata. A leaked view secret exposes all retained ciphertext for
that version, including harvest-now archives; rotation supplies neither forward secrecy nor post-compromise recovery.

## Isolated chain evidence

The disclosed fakenet uses source `3aab2d99…`, exact-ID registration, release-off program-operation admission, and
the canonical base64 I/O/compiler profile `6eb1af82…`. The current isolated node SHA-256 is
`8846d2a9f3240d2aedfecb49553f082c284c2b951a6ddb7a9b60afe09800ef18`; patch SHA-256 is
`0f10cf5d5d0d58ccfc93351aec9dca466acd19d1142f6266c38cd4bb6dc42c07`. The file-backed test signer is SHA-256
`a86b7baf83c86ab813c3198bc0ed6fdb1f9b04bb1af7741a49f39220def8077e`. Binary-envelope and byte-union controls
include wrong shapes, duplicates, empty/ASCII/invalid bytes and split-multibyte truncation; storage keys remain raw
legacy strings. See `docs/FAKENET.md` for the build/stop contract and `receipts/chain/` for evidence.

- First legacy segment deployed at epoch 7; a 322-byte recipient envelope finalized at epoch 52 and decrypted
  after exact retrieval. Short/malformed frames reject without changing state.
- Deduplicating segment deployed at epoch 276; 100 unique encrypted frames finalized in 13 bounded `MultiExec`
  batches. Median finalization latency 7.078 s, p95 7.368 s, 113,000 OU, 77,100 receipt effort. Duplicate,
  closed and closed-append guards reject without changing state. The segment closed at epoch 325.
- Successor deployed at epoch 361 and accepts unique frames while the closed segment remains readable. The
  append-only registry deployed at epoch 396 and published both immutable descriptors at epoch 400.
- Node restart, a fresh node starting with only its wallet, native pack GC, chaindata index rebuild, and common-feed
  index deletion/rebuild all preserve exact frame bytes and state roots. Two prune runs complete and preserve the
  encrypted body; index rebuild recovered two transactions over 221 epochs.
- The original 2,729,368-byte first-batch sample and derived 29,667-byte figure are not a storage slope.
  `receipts/chain/storage-growth.json` records every batch, regression over all 100 frames, apparent and allocated
  bytes, post-pack-GC state, restart and exact-read checkpoints. Final slopes are 9,812.67 apparent and 10,763.12
  allocated bytes/frame over 14 points. Pack GC reclaimed 5,439,877 apparent bytes while collecting older history;
  restart added 409,600 and 100 exact reads added zero in this run. Whole-directory growth includes consensus, WAL,
  indexes and view-call writes. This is not 10,000/100,000-frame acceptance or sustainable-load evidence.

## Current native gaps

1. Independent specialist review of the new message-domain/profile, expected-contact registry, static-recipient
   compromise, nonce/replay handling and rotation/revocation. The selected native route is demonstrated but not
   a production cryptographic audit.
2. Encrypted local key persistence, production recovery and chain-integrated submission. The prototype has
   per-message fsynced plaintext files, atomic dedup-plus-pointer state and a durable exact-byte outbox with crash
   injection, but secret files and plaintext inbox contents are not encrypted at rest. Global 10,000-record and
   512,000,000-byte caps need an operational migration policy; per-sender quotas are 1,000 records and 51,200,000
   bytes. Pruned erased/out-of-grace rows lose replay history while archived plaintext remains. No chain nonce
   allocation or power-loss certification is established.
3. Committed feed-page completeness proofs, production cursor/finality semantics, larger retained-body tests and
   explicit fee-burn measurement. Binary I/O and signed sizes/OU are demonstrated only in the isolated profile.
4. Production contact/key registration and recovery behavior. **B6 is deferred to on-chain registration.** The
   test contact-root secret comes from a public constant and sits beside the config it signs, so the signature is
   only a fixture. Dedicated opaque X25519 messaging keys are implemented and tested separately from Ed25519
   identities; chain registration and secure backup remain open. Existing lifecycle rows do not by themselves
   prove forward secrecy or secure recovery.
5. Production registry/code-upgrade immutability, client suite pinning and native contact/policy object integration.
   The append-only registry is a small prototype, not a production authorization boundary.
6. Linear contract storage, malformed-input resource bounds, 10,000/100,000-frame runs, sustained offered-load
   and multi-client interference. Storage growth and the disclosed VM I/O extension need independent review.
7. Forward secrecy, post-compromise recovery and post-quantum guarantees remain unestablished. Native rotation
   or revocation does not change that.

## New APIs and resource estimate

New application work comprises the native binding, signed test envelope, registry/segment/bootstrap designs,
OCaml client/store/feed modules and recovery receipts. No consensus opcode, state-root rule or fee change is
proposed. The first node optimization candidate remains bounded lazy/delta contract storage. The selected recipient message profile is a thin native binding requiring independent security review; no
consensus-visible extension is currently proposed. No writes to octra-labs repositories are authorized.

Order-of-magnitude estimate, excluding independent review and activation: Phase 1 about 5-8 focused engineering
days, Phase 2 about 4-7, and Phase 3 about 5-10. The recipient operation and atomic crash boundary are the largest
uncertainties. The approved initial venue budget is 2 vCPU, 4 GiB RAM and 50 GiB. A 100,000-frame run needs
retained-store measurement first; a 1,000,000-frame run is outside this budget.

## Superseded investigation

The earlier libsignal/X3DH/PQXDH/Double Ratchet/MLS dependency search is historical and superseded by the
2026-11-14 owner correction. It is not a blocker or implementation dependency. Historical reports and receipts
remain for audit; active development uses Octra-native HFHE-PVAC and the closest existing core primitives.
