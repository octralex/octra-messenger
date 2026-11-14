# On-chain messenger

Owner-requested OCaml-centered implementation of the fully on-chain Octra messenger, using Octra-native
HFHE-PVAC and the closest existing core primitives. Current status is **experimental native recipient profile
under review plus an isolated Phase 2 registry/segment spike**. Complete encrypted frames have finalized on a synthetic
fakenet and been retrieved and decrypted after restart, pruning, index loss, and fresh sync. Do not use this for
real conversations, production claims, validator promotion or mainnet transactions.

## Implemented

- Bounded opaque 2 KiB/4 KiB storage frames and SHA-256 deduplication keys; these are not final native buckets.
- Canonical session-context and epoch/sequence/root cursor codecs with malformed-input tests.
- Bounded page accounting.
- An AppliedML append/read/hash/page/close segment spike, passing both compiler profiles and Irmin restarts.
- An OCaml `Pvac_ffi` + Ed25519 same-key representation spike with negative controls.
- A genuine recipient-only X25519/AES-GCM path through `lib/crypto/recipient_message.ml`: separate endpoint
  processes, secret-free sender, offline recipient recovery, expected-sender checks and normalized public rejection.
- Dedicated opaque X25519 messaging keys, randomized production message IDs/ephemerals/nonces, mandatory per-version
  policy, test-only signed contacts, and previous-version grace for unread messages. Deterministic inputs are
  test-only; B6 contact authorization is deferred to on-chain registration.
- Per-message fsynced plaintext files with atomic dedup/pointer state, per-sender and global record/byte quotas,
  crash injection, and a durable exact-byte outbox. Pruned erased/out-of-grace rows lose replay history while
  archived plaintext remains. These are local prototype stores, not encrypted key persistence or a secure receiver.
- Realistic size/performance receipts for recipient and same-key representations, from zero to 16 KiB.
- An isolated AppliedML segment with exact 2,048-byte frames, content-hash dedup, append-only rollover registry,
  canonical base64 I/O with malformed/unpadded/pad-bit/wrong-shape/duplicate-key rejection, and bounded
  `MultiExec` batches. One hundred
  encrypted frames finalized in 13 batches;
  registry rollover and two more frames are included in the 102-frame feed index.
- Exact frame retrieval and recipient decryption, rejection of malformed/short/duplicate/closed appends, native
  pack-GC retention, chaindata index rebuild, fresh-node sync, and common-feed index regeneration. See
  `docs/FAKENET.md` and `receipts/chain/` for the disclosed VM I/O extension and evidence.

## Not implemented

Independent profile review, production contact/key registration and finalized policy authority, encrypted local
secret state, production feed cursors/completeness proofs, 10,000/100,000-frame storage acceptance, sustained
1/10/100 fps and multi-client interference tests, storage/scheduler optimization, and production readiness. The
base64 VM I/O extension and lab admission patch are isolated only, not proposed for unreviewed activation. The
local stores are crash-injection tested but not power-loss certified. Forward secrecy, post-compromise recovery
and post-quantum guarantees remain unestablished.

## Verify on Hetzner

Use the node OCaml 4.14.2 switch and the current `gc_build.py` storage wrapper; do not build the read-only laptop
tracking clone.

```bash
eval $(opam env --switch=/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml --set-switch)
dune build --root /home/kimi/workspace/octra-egregore/projects/onchain-messenger \
  --build-dir /srv/octra-node/fakenet-kimi-messenger/protocol-build @runtest
projects/onchain-messenger/tests/run_recipient_spike.sh
projects/onchain-messenger/tests/run_size_sweep.sh
```

Run these commands from `/home/kimi/workspace/octra-egregore` on Hetzner. They use only
`/srv/octra-node/fakenet-kimi-messenger/` for build output and runtime scratch, with synthetic bytes and
independent synthetic keys. They do not deploy a program or modify the shared fakenet or validator. The endpoint
and size commands share the approved messenger source at `/srv/octra-node/fakenet-kimi-messenger/src/lite_node`.
Historical segment and same-key PVAC scripts remain reproduction tools, not current recipient acceptance tests.

## Documents

- `NATIVE-STACK.md`: native capability matrix.
- `CAPABILITIES.md`: pins, storage evidence, current gaps and resource estimate.
- `docs/RECIPIENT-ENCRYPTION.md`: candidate comparison, disposition and endpoint controls.
- `docs/NATIVE-RECIPIENT-EXTENSION.md`: experimental thin native message profile, open for review.
- `docs/CIPHERTEXT-SIZES.md`: realistic native and bootstrap measurements.
- `docs/FAKENET.md`: isolated node source/patch/binary identities, ports, limits and stop/run procedures.
- `docs/PROTOCOL.md`: implemented encodings and native cryptographic boundary.
- `docs/PRIVACY.md`: intended privacy statement and residual metadata.
- `receipts/`: raw storage, protocol, native and isolated-chain results, including instructive failures.
