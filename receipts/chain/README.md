# Isolated chain evidence

This directory contains synthetic prototype evidence only. No wallet file, private key, node env, plaintext inbox,
or production account is included. `message.ocm` is synthetic ciphertext. `feed-index.json` and `load-seals.json`
contain hashes and public metadata, not endpoint secrets.

## Identity and scope

- Chain ID `octra-fakenet-kimi-msgnet`; venue `/srv/octra-node/fakenet-kimi-messenger/` on Hetzner.
- lite_node `3aab2d992035076dd216ad8808710d3a5a56063a`; webcli
  `28208507bf704b9d2726dd48cb6597319c594688`; `libpvac.so` SHA-256
  `fc72588467f5e84f34323de51b50b83bd8cb74c7b91b2cbfb7c150a365984357`.
- Current binary-envelope node SHA-256 `8846d2a9f3240d2aedfecb49553f082c284c2b951a6ddb7a9b60afe09800ef18`;
  patch SHA-256 `0f10cf5d5d0d58ccfc93351aec9dca466acd19d1142f6266c38cd4bb6dc42c07`;
  compiler source stamp `6eb1af8241430645904abb6524df5791a11c0ca98eb8a6d859624742d9d8b20f`.
  Direct `binary-io-unit.txt` controls cover both input routes, wrong shapes, duplicate keys, empty/ASCII/invalid
  output bytes and split-multibyte truncation. Storage keys remain raw legacy strings.
- The original 100-frame `chain-metrics.json` and its environment retain their actual historical identities: node
  `f22d49e0…`, patch `9ca42e09…` and compiler stamp `ababef86…`. They are not current-binary bindings.
- Current file-backed `chain_driver.exe` SHA-256 `a86b7baf83c86ab813c3198bc0ed6fdb1f9b04bb1af7741a49f39220def8077e`;
  `prune_driver.exe` SHA-256 `9caf61ecd134f406eb253edd7a6bc8a45e8048d75b26ab280b8f1ebb5082f2fa`;
  `rebuild_index_driver.exe` SHA-256 `e1e236839e7523711bcc74b7bfb5a88e1f171a6759cda8d24b25a4fc9a39e8d8`.
- `segment_spike.aml` SHA-256 `b519b36a634bb1baaadacb41c3d63edf4a52cf435b09f2ce626f8d605cd8c6e3`;
  `segment_registry.aml` SHA-256 `ede79a8dfcc83264db5ed47c75c6cc6b3793f17c2e4abc23d68f279ab8f33a9c`.

The node admits existing program operations only in the disclosed release-off laboratory configuration and adds a
small base64 I/O profile. This is not an upstream or production activation. `review-environment.json` binds the
recipient, node-profile, full-submission, read-only-resume and storage source commits separately, plus executables,
compiler/dependency versions and commands. `evidence-validation.json` records publication-time receipt, regression,
size-table and artifact-hash checks. See `docs/FAKENET.md` for every patch, port, build command and stop command.

## Main results

- Legacy segment deployed at epoch 7; recipient envelope accepted at epoch 52 and decrypted after exact retrieval.
- Deduplicating segment deployed at epoch 276; 100 encrypted frames finalized in 13 `MultiExec` batches. Duplicate,
  short, malformed and closed appends reject without changing the accepted body.
- Segment closed at epoch 325; successor deployed at epoch 361 and accepts new frames while the old body remains
  readable. Registry deployed at epoch 396 and published both immutable descriptors at epoch 400.
- Restart, fresh sync with only a wallet, native pack GC, chaindata index rebuild and common-feed index deletion and
  regeneration preserve exact bytes and state roots. `feed-recipient-open.json` confirms decryption through the
  common-feed route.
- The 100-frame run has latency p50 7.078 s, p95 7.368 s, total 113,000 OU and 77,100 effort. Signed JSON totals
  293,111 bytes; RPC requests total 293,891 bytes. Its one-sample 2,729,368-byte first-batch growth is historical
  context only, not a per-frame slope or amplification estimate.
- `binary-controls.json` records malformed, unpadded, noncanonical pad-bit, wrong-shape and duplicate-key rejection
  beside canonical acceptance, including a canonical append after the shape controls. `binary-io-unit.txt` covers
  both ABI routes and byte-output union/truncation behavior directly. The maximum 2,999,565-byte envelope produced
  3,999,863 signed JSON bytes and a 3,999,923-byte RPC request. RPC
  accepted it; the VM rejected the whole envelope because a frame must be 2,048 bytes, without changing state.
- `storage-growth.json` is the fresh all-frame checkpoint/regression receipt, with apparent and allocated bytes,
  post-pack-GC, restart-before-read and post-read measurements. Slopes are 9,812.67 apparent and 10,763.12 allocated
  bytes/frame over 14 points. Pack GC reclaimed 5,439,877 apparent bytes while collecting older history; restart
  added 409,600 and 100 exact reads added zero in this run. It supersedes any per-frame interpretation of the
  original first-batch sample, but does not isolate message-only writes from consensus, index or view-call writes.

`ou` is the transaction fee field and `ou_cost` is the native base-cost calculation. Receipt effort is VM effort,
not an OU-denominated burn. Account-balance deltas are not used to infer a fee burn.

## Reproduction entry points

Run only on Hetzner as `kimi` and read `docs/FAKENET.md` first. Do not run `provision` while any messenger unit is
active; it refuses to modify a running cluster. `start` defaults to nodes 1-6; node 7 is reserved for fresh sync.

```bash
projects/onchain-messenger/tests/run_chain_spike.sh provision
projects/onchain-messenger/tests/run_chain_spike.sh start 1 2 3 4 5 6 7
projects/onchain-messenger/tests/run_chain_spike.sh stop
```

The native signer persists signed JSON before RPC submission. `resubmit` uses the exact recorded bytes; a later
submission was rejected for timestamp drift without a state change. Large parameters use `@path` rather than a
multi-megabyte command-line argument. `chain-metrics.json` is the original machine-readable performance receipt;
`binary-controls.json` is the canonical-input and signed-maximum receipt. `registry-state.json` has immutable
descriptor strings and current segment.

The binary controls and storage-growth harness share the synthetic account and must not run concurrently. For a
fresh storage run, use a new run ID; it deploys a separate segment, checkpoints every batch, stops only node 1 for
pack GC, retains a rollback copy, restarts node 1, and reads all 100 bodies exactly:

```bash
python3 projects/onchain-messenger/tests/run_binary_controls.py
MESSENGER_STORAGE_RUN_ID=storage-growth-NEW \
  python3 projects/onchain-messenger/tests/run_storage_growth.py
```

For supported recovery operations, stop the target node first and preserve its rollback copy:

```bash
/srv/octra-node/fakenet-kimi-messenger/bin/prune_driver.exe \
  /srv/octra-node/fakenet-kimi-messenger/nodes/node6/data/irmin_store CURRENT_EPOCH
/srv/octra-node/fakenet-kimi-messenger/bin/rebuild_index_driver.exe \
  /srv/octra-node/fakenet-kimi-messenger/nodes/node6/data/chaindata
python3 projects/onchain-messenger/tests/feed_scan.py \
  http://127.0.0.1:18177/rpc REGISTRY_ADDRESS OUTPUT_JSON
```

The prune driver uses the native `collect_pack_at ~keep:1` API on the isolated store only. The index driver rebuilds
from transaction and epoch logs. Restart the node and compare state roots and exact frame bytes after either
operation. `data.pre-prune` and `chaindata/index.pre-rebuild` are retained for this evidence run.

## Remaining acceptance gates

This is not a completed production messenger. **B6 is deferred to on-chain contact registration**; the local
contact-root signature is only a test fixture. Large-message chunking is not implemented. Required still-open work
includes production contact/policy authority, committed feed completeness, encrypted secret persistence and recovery, 10,000/100,000-frame storage acceptance,
sustained 1/10/100 fps and multi-client interference, explicit fee-burn accounting, storage/scheduler optimization,
and independent review of the base64 VM extension and isolated admission profile. Forward secrecy, post-compromise
recovery, recipient anonymity and post-quantum protection remain unestablished.
