# On-chain messenger

OCaml-centered implementation of the fully on-chain Octra messenger, using Octra-native primitives.
Current status is **maintainer v2 revision under design and independent review**, not a completed messenger.
The realtime demo is paused until `docs/SCHEME.md` receives the maintainer design read and the remaining reviews
complete. Do not use this for real conversations, production claims, validator promotion or mainnet transactions.

## Implemented in the v2 library

- One `octra_messenger` Dune library built in place against `octra_net` and `octra_core`. `recipient_message_core`
  is private, public modules have `.mli` interfaces, and `tests/testkit/` is a separate test-only library.
- Native `Oce1` encoding and `Hash_domain` tagged SHA-256 for signing, AEAD associated data, replay identities,
  storage paths and test fixtures. HMAC-SHA256 is used only for key derivation.
- A 194-byte v2 envelope with explicit version, sender sequence, sender epoch and sender instance. Only v2 readers
  and writers exist; v1 and legacy context/cursor forms reject. One `Session_context` codec includes application and
  preserves version.
- Expected-sender resolution by contact wallet address, followed by signature verification, context/policy checks,
  ECDH and AEAD. Messages are signed with the Octra wallet Ed25519 key using `octra:msg:sig:v2`, not a transaction
  serialization.
- Random production message IDs, ephemeral keys and nonces. Dedicated typed X25519 recipient keys, tagged key-file
  loading and atomic 0600 writes live in `Recipient_keys`; raw construction and deterministic fixtures stay test-only.
- Per-contact outbox channels with positive signed-64-bit sequences and a random 16-byte sender instance, so
  independent devices using one wallet do not collide and other contacts do not consume this channel's sequence.
  Allocation persists before sealing. `Int64.max_int` is the last usable sequence, followed by explicit `exhausted`;
  invalid/exhausted counters cannot wrap, reset or rotate the channel. Sealed records retain byte-identical retry.
  Verified-high-water recovery only advances the counter and preserves the instance and pending records.
- Permanent per-channel 1,024-bit replay windows and high-water marks. Any forward jump advances the window;
  duplicates and old out-of-window sequences reject. One atomic plaintext/window/inbox commit handles concurrent
  duplicates. Window growth across channels and rotations is currently unbounded and documented for migration.
- Separate live and archive modes: live accepts at most 64 epochs old and two epochs ahead; archive uses the frame's
  commit epoch and rejects only a sender epoch after that commit. Policy uses the same reference epoch.
- Owner/granted-writer on-chain appends with the caller stored per frame. Segment and registry bytecode embed the
  owner because native circle deployment does not run the AML constructor. Non-owner writes reject without state
  change; sender-key binding is checked before full envelope decoding.
- Canonical base64 I/O in the separately disclosed older lab profile. That profile is not evidence for the new
  recipient library or a production activation.

The same-key PVAC spike, its public deterministic seed, its unauthenticated open path and its historical Python
feed scanner are removed from the active source tree. PVAC is not a message-encryption substitute unless it gains
public-key-only encryption.

## Not implemented or not established

Realtime client and relay, production contact/key registration and finalized policy authority, large-message
chunking, committed feed completeness, encrypted secret persistence and recovery, production nonce queue,
10,000/100,000-frame retention, revised pruning/fresh-sync evidence, sustained 1/10/100 fps and multi-client
interference, explicit fee-burn accounting, storage/scheduler optimization and production readiness. Exact frame
bodies are retained once and deduplicated by the labelled `octra:msg:frame:v2` digest. Registry descriptors use
bounded OCE1; the lab-only `\xHH` lexer patch is not upstream-accepted. Crash orphans and the O(n) receive-directory
scan remain. Contact registration is deferred to on-chain registration. Forward secrecy, post-compromise recovery, recipient
anonymity and post-quantum guarantees are not established.

## Verify on Hetzner

Use the node OCaml 4.14.2 switch and current `gc_build.py` wrapper. Builds run only in the approved isolated venue.
The scripts copy the pinned native source into the project as vendored dependencies, assign local Dune package names,
and use isolated Cargo caches. No production library modules are copied into `lite_node/test`; standalone test drivers
are copied there.

```bash
projects/onchain-messenger/tests/run_recipient_spike.sh
projects/onchain-messenger/tests/run_size_sweep.sh
projects/onchain-messenger/tests/run_segment_spike.sh
projects/onchain-messenger/tests/run_binary_io_tests.sh
OCTRA_NODE_SOURCE=/srv/octra-node/fakenet-kimi-messenger/devnet-src/lite_node \
  projects/onchain-messenger/tests/run_chain_spike.sh build-driver
python3 projects/onchain-messenger/tests/run_devnet_feasibility.py
```

Run from `/home/kimi/workspace/octra-egregore` on Hetzner. Tests use synthetic endpoint keys and synthetic devnet
wallets only, never the live validator, updater, shared fakenet or production wallets. The fresh devnet run deploys
an owner-specific circle and submits synthetic writes. `--resume-read` performs only reads of the same deployment;
it does not validate a changed segment.

## Documents

- `docs/SCHEME.md`: one-page v2 scheme for maintainer design review.
- `docs/PROTOCOL.md`: codecs, signature/replay rules, storage and on-chain binding.
- `docs/NATIVE-RECIPIENT-EXTENSION.md`: native boundary and review questions.
- `docs/RECIPIENT-ENCRYPTION.md`: native candidate disposition and removed-path rationale.
- `docs/CIPHERTEXT-SIZES.md`: recipient and bootstrap measurements.
- `docs/PRIVACY.md`: privacy ceiling and residual metadata.
- `docs/FAKENET.md`: older isolated binary-I/O source/patch/binary identities and procedures.
- `NATIVE-STACK.md`: native capability matrix and trust boundaries.
- `CAPABILITIES.md`: measured limits, current evidence and open work.
- `receipts/`: raw recipient, protocol, segment, VM I/O, devnet and storage results, including historical evidence.
