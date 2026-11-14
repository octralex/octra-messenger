# Isolated messenger fakenet runbook

Status: all seven isolated nodes are active with the binary-envelope correction and final controls. Earlier
deployment, exact encrypted-body reads and recipient
decryption, restart, fresh sync, pack GC, index rebuild, append-only registry rollover, common-feed rebuild and a
100-frame batched load have passed. The feed contains 102 frames across two segments. This is not devnet, mainnet,
a production candidate, or a production activation of the operations below. The initial unsupported-chain refusal
wrote no chain state. A legacy segment deployed at epoch 7; the first hex-text append was rejected at epoch 18; a
base64 frame was accepted at epoch 52. Raw `VString` byte results exposed non-UTF-8 output, which the profile below
encodes explicitly. The live validator, updater, shared fakenet, fleet identities, wallets, and devnet accounts are
not used.

## Current measured evidence

- Deduplicating segment deployed at epoch 276; 100 unique encrypted frames finalized in 13 `MultiExec` batches.
  Median latency 7.078 s, p95 7.368 s, total 113,000 OU and 77,100 receipt effort. The segment closed at epoch 325.
- Successor deployed at epoch 361; append-only registry deployed at epoch 396 and published both immutable
  descriptors at epoch 400. The common feed has 102 frames and rebuilds identically after index deletion.
- Two pack-GC runs preserve the encrypted body; chaindata rebuild recovers two transactions over 221 epochs.
  Node 7 fresh sync starts with only its wallet and matches state roots. Rollback copies `data.pre-prune` and
  `chaindata/index.pre-rebuild` are retained for this evidence run.
- The original 2,729,368-byte first-batch growth is one historical sample that can include pack/log/WAL setup; the
  derived 29,667-byte figure is withdrawn. `receipts/chain/storage-growth.json` instead records checkpoints before
  and after every batch, an all-frame regression slope, allocated and apparent bytes, post-pack-GC, restart-before-read
  and post-read measurements. The final 14-point slopes are 9,812.67 apparent bytes/frame (R² 0.99892) and
  10,763.12 allocated bytes/frame (R² 0.99886). Pack GC reclaimed 5,439,877 apparent bytes while collecting older
  history; its baseline delta is not message-only. Restart added 409,600 bytes, and all 100 exact reads added zero
  measured bytes in this run. Whole-directory growth includes consensus, indexes, empty epochs and view-call writes.
  Neither run is a 10,000/100,000-frame acceptance run, sustainable-rate result or production readiness claim.
- Canonical input controls accept ordinary base64 frames and reject malformed, unpadded, noncanonical pad-bit,
  wrong-shape and duplicate-key forms through finalized execution outcomes. A canonical append after the shape
  controls confirms normal nonce recovery. A 2,999,565-byte envelope produced 3,999,863 signed JSON bytes and a
  3,999,923-byte RPC request. RPC accepted it, then the VM rejected the 2,048-byte frame violation without changing
  segment state. See `receipts/chain/binary-controls.json`.
- Direct `binary-io-unit.txt` controls pass both ABI input routes and receipt/event/storage byte-output paths,
  including empty, ASCII, invalid UTF-8 and split-multibyte truncation. The test executable is
  `e84387c75b354c53dc838fdbdb01ffe3d76e4c1afe36a8955738fe51b622d4c9`; storage keys remain a raw-string limit.
- Full evidence is in `receipts/chain/`; original machine-readable performance is `receipts/chain/chain-metrics.json`.
  Remaining work includes production policy/contact integration, explicit fee-burn accounting, larger storage and
  multi-client interference runs, committed feed completeness, and independent review of the VM I/O extension.

## Identity and patch

- Venue: `/srv/octra-node/fakenet-kimi-messenger/` on Hetzner.
- Chain ID: `octra-fakenet-kimi-msgnet`; no devnet peers or shared-fakenet state.
- Base source: lite_node `3aab2d992035076dd216ad8808710d3a5a56063a`, the mandated review pin. The tracking
  clone advanced to `a1ead4a1181c743bd136c7ddeca5a7ccfa60e430` during this follow-up; those broader upstream
  changes were not incorporated or treated as reviewed. No upstream write is authorized.
- Patch: `receipts/chain/fakenet-node.patch`, SHA-256
  `0f10cf5d5d0d58ccfc93351aec9dca466acd19d1142f6266c38cd4bb6dc42c07`.
  The change to `lib/core/transaction.ml` lets the release-off laboratory profile admit the existing
  `ContractDeploy`, `ProgramDeploy`, `ContractCall`, `ProgramExec`, and `MultiExec` operations when named by
  `OCTRA_BFT_ADMIT_OPS`. The change to `lib/core/rule_graph.ml` registers only
  `octra-fakenet-kimi-msgnet` in `live_chain`; every activation plan remains `Prior`.
- Binary-input extension: `lib/vm/runtime/program_input.ml` and `lib/vm/runtime/contract.ml` accept exactly one
  unique `encoding`/`data` pair, in either order, for `{"encoding":"base64","data":"…"}` at the existing ABI
  boundary, producing the same `VBytes` value as a raw byte string. Objects containing either field reject if they
  have duplicates, missing or extra fields, wrong types, or a non-base64 encoding. Canonical base64 is enforced by
  re-encoding and exact string equality, so malformed, unpadded, whitespace-bearing and noncanonical pad-bit forms
  reject instead of becoming empty strings. Unrelated legacy objects without either field retain their previous
  fallback; this is not a blanket fail-closed claim for every JSON shape. This was the smallest missing capability
  found by the rejected hex-text append, not an encryption or consensus-primitive change.
- Rejection behavior: the legacy decoder's exception is contained by normal VM execution and returned as a finalized
  `program_exec_exception`, not left pending. Rejected transactions do not advance the account nonce, so the next
  valid transaction uses the account's current next nonce. The maximum valid envelope instead reaches the segment's
  `program_exec_failed` / `frame must be 2048 bytes` guard and leaves segment state unchanged.
- Binary-output extension: `lib/vm/runtime/receipt_view.ml`, `lib/vm/rpc/contract_rpc.ml`, and
  `node_runtime/rpc_view.ml` preserve valid UTF-8 text but return non-UTF-8 results, event values, storage values,
  and storage-page values as the same two-field base64 object. Raw byte lengths and truncation flags remain
  unchanged. Direct controls cover empty, ASCII and invalid bytes plus truncation through a two-byte character.
  Storage **keys** remain raw legacy strings and are not base64-envelope encoded; the profile covers byte values,
  not arbitrary non-UTF-8 object keys. Readers must accept both content-dependent value forms.
- Compiler identity: `lib/vm/dune` moves the expected source stamp from
  `cf3a6384a7f8d00ece9044c036b181fe106402ca9d1a383ca19b94d7529806a3` to
  `6eb1af8241430645904abb6524df5791a11c0ca98eb8a6d859624742d9d8b20f`, computed by the unchanged source-stamp
  rule. The guard remains active and all six source-pin tests pass. Every result must carry the label
  **fakenet, exact-ID registration, lab operations, canonical base64-I/O profile 6eb1af82 only**. No upstream write or
  production activation is authorized.
- Release-profile rationale: upstream `devnet_full_v1` already admits these operations, but it also requires
  security-curve emission, preverify activation and a migration admission root. Manufacturing those unrelated
  consensus artifacts would expand the test, so the lab registers one exact chain ID with release-off and explicit
  operation names. This is containment for an isolated experiment, not a claim that release-off is a better
  production profile or that activation is unnecessary outside the lab.
- Toolchain: OCaml 4.14.2, dune 3.23.0, the node opam lock, and Mirage 2.1.0.
- Webcli reference: `28208507bf704b9d2726dd48cb6597319c594688`; deployed executable SHA-256
  `93702748d072725ebebf564c55bf35b38ecb481bad4c09f02fef6520e3e6db3a`; `libpvac.so` SHA-256
  `fc72588467f5e84f34323de51b50b83bd8cb74c7b91b2cbfb7c150a365984357`.

## Build recipe

Run on Hetzner as `kimi`, with `VENUE=/srv/octra-node/fakenet-kimi-messenger`, `SOURCE=$VENUE/node-src/lite_node`,
and `PROJECT=/home/kimi/workspace/octra-egregore/projects/onchain-messenger`:

```bash
git clone --shared /home/kimi/workspace/upstream-heads/lite_node "$SOURCE"
git -C "$SOURCE" checkout --detach 3aab2d992035076dd216ad8808710d3a5a56063a
git -C "$SOURCE" apply "$PROJECT/receipts/chain/fakenet-node.patch"
make -C "$SOURCE/mcl" MCL_FP_BIT=256 MCL_FR_BIT=256 lib/libmcl.a -j2
eval $(opam env --switch=/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml --set-switch)
export LIBRARY_PATH="$VENUE/link-libs"
export LD_LIBRARY_PATH="/srv/octra-node/runtime-libs:$VENUE/link-libs"
export TMPDIR="$VENUE/tmp"
python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" \
  --profile release -j 2 bin/octra_node.exe bin/octra_pvac_worker.exe \
  bin/octra_state_sync_client.exe bin/octra_state_sync_manifest.exe
cp "$PROJECT/tests/chain_driver.ml" "$SOURCE/test/chain_driver.ml"
# Append the chain_driver executable stanza recorded in tests/run_chain_spike.sh to test/dune.
python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" \
  --profile release -j 2 test/chain_driver.exe
cp "$PROJECT/tests/messenger_binary_io.ml" "$SOURCE/test/test_messenger_binary_io.ml"
python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" \
  --profile release -j 2 test/test_messenger_binary_io.exe
"$SOURCE/_build/default/test/test_messenger_binary_io.exe"
python3 "$SOURCE/test/test_source_pin.py" "$SOURCE/lib/vm/dune"
```

Install those executables in `$VENUE/bin/`. The build receipts are `$VENUE/receipts/node-build.log`,
`mcl-build.log`, `node-build-chain-registration.log`, `node-build-binary-input.log`,
`node-build-binary-output.log`, `node-build-storage-page.log`, `node-build-multi-exec.log`,
`node-build-base64-strict.log`, `program-input-tests-strict.log`, `source-pin-tests-strict.log`,
`node-build-binary-envelope.log`, `binary-io-unit.txt`, `source-pin-tests-binary-envelope.log`,
`program-input-tests.log`, `source-pin-tests.log`, and `chain-driver-build.log`.

| Executable | SHA-256 |
| --- | --- |
| `octra_node.exe` | `8846d2a9f3240d2aedfecb49553f082c284c2b951a6ddb7a9b60afe09800ef18` |
| `octra_pvac_worker.exe` | `2939f29cfbbac4b35500cc4207032334b3c78357c0bf9b772ecec8ef376944a7` |
| `octra_state_sync_client.exe` | `7be2e6445d425bb7c1060ac63d6f7418a2ef01c7043231d9aac7df9007860afd` |
| `octra_state_sync_manifest.exe` | `ed7d8610b6f3b0f8247fa866a879c4d80184c578ce4c9a30a9e597f3a7192c3a` |
| `chain_driver.exe` | `a86b7baf83c86ab813c3198bc0ed6fdb1f9b04bb1af7741a49f39220def8077e` |
| `prune_driver.exe` | `9caf61ecd134f406eb253edd7a6bc8a45e8048d75b26ab280b8f1ebb5082f2fa` |
| `rebuild_index_driver.exe` | `e1e236839e7523711bcc74b7bfb5a88e1f171a6759cda8d24b25a4fc9a39e8d8` |
| `test_messenger_binary_io.exe` | `e84387c75b354c53dc838fdbdb01ffe3d76e4c1afe36a8955738fe51b622d4c9` |
| `segment_spike.aml` | `b519b36a634bb1baaadacb41c3d63edf4a52cf435b09f2ce626f8d605cd8c6e3` |
| `segment_registry.aml` | `ede79a8dfcc83264db5ed47c75c6cc6b3793f17c2e4abc23d68f279ab8f33a9c` |

The test-only chain driver accepts `@path` for transaction parameters so large signed messages do not exceed the
Linux command-line argument limit. The parameter file is read by the native signer; the node ABI is unchanged.

If any binary or patch changes, republish this runbook and the new hash before the next run.

## Network layout and limits

Seven fresh synthetic validator wallets are generated locally with mode-0600 files; private keys are never printed
or committed. Nodes 1-6 are for the initial cluster. Node 7 remains stopped and unprovisioned beyond its wallet/env
until the fresh-sync test. Each node has an empty `nodes.config` in the venue working directory.

| Node | RPC loopback | P2P loopback | Consensus loopback | Initial role |
| ---: | ---: | ---: | ---: | --- |
| 1 | 18171 | 19151 | 19161 | validator/state-sync exporter |
| 2 | 18172 | 19152 | 19162 | validator |
| 3 | 18173 | 19153 | 19163 | validator |
| 4 | 18174 | 19154 | 19164 | validator |
| 5 | 18175 | 19155 | 19165 | validator |
| 6 | 18176 | 19156 | 19166 | validator/restart subject |
| 7 | 18177 | 19157 | 19167 | fresh-sync subject, initially stopped |

`OCTRA_PEERS` contains only these consensus loopback endpoints. The release profile is off, the crypto profile is
`private_v1`, and `OCTRA_BFT_ADMIT_OPS=deploy,program_deploy,call,program_exec,multi_exec`. There is no migration root or
production network bundle. The common source and binary must be identical on every node.

Bound all seven nodes and related run commands to the approved slice:

```bash
systemctl --user set-property kimi-msgnet.slice CPUQuota=200% MemoryMax=4G
```

The venue is capped at 50 GiB of new data. Check `du -sh /srv/octra-node/fakenet-kimi-messenger` and include it in
the daily prune report. No host-wide kernel, sysctl, firewall, swap, or live-validator cgroup change is permitted.

## Provision, start, and stop

For the binary-envelope update, publish this runbook first, stop all seven units, retain
`bin/octra_node.exe.prev-d748`, install the `8846d2a9…` executable, and set `OCTRA_BINARY_HASH` to that hash in every
`nodes/node*/node.env`. Start all seven only after `run_chain_spike.sh` verifies the installed node, driver and this
runbook. Rollback is to stop the isolated units, restore the retained prior executable and prior environment hashes,
and verify them before restart. No live-validator binary or environment is involved.

Publish this file in control before the first start, then run `tests/run_chain_spike.sh provision` to generate the
fresh wallets and node env files. Start nodes 1-6 only, with `n` set to each number:

```bash
systemd-run --user --slice=kimi-msgnet.slice --unit=octra-kimi-msgnet-$n \
  --property=WorkingDirectory=/srv/octra-node/fakenet-kimi-messenger \
  --property=EnvironmentFile=/srv/octra-node/fakenet-kimi-messenger/nodes/node$n/node.env \
  --property=Environment=LD_LIBRARY_PATH=/srv/octra-node/runtime-libs:/srv/octra-node/fakenet-kimi-messenger/link-libs \
  --property=StandardOutput=append:/srv/octra-node/fakenet-kimi-messenger/nodes/node$n/node.log \
  --property=StandardError=append:/srv/octra-node/fakenet-kimi-messenger/nodes/node$n/node.log \
  /srv/octra-node/fakenet-kimi-messenger/bin/octra_node.exe --init
```

Readiness is a bounded JSON-RPC `node_status` response plus head advancement and voting on nodes 1-6; a process or
socket alone is not acceptance. Keep node 7 stopped until the fresh-sync test.

Stop all messenger units, including the fresh-sync subject if it was started:

```bash
systemctl --user stop octra-kimi-msgnet-{1,2,3,4,5,6,7}
```

Check the exact binary paths with `pgrep -af '/srv/octra-node/fakenet-kimi-messenger/bin/octra_node.exe'`; do not
use a broad `pkill octra_node`. Rollback is to stop the isolated units, retain the synthetic state and receipts for
analysis, and remove the venue-local patch before any later rebuild. Nothing is promoted or rolled back on the live
validator.
