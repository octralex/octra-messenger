# Isolated OCPG lab network

Scope: lab network, fleet-generated release key. This is not devnet and is not evidence of a devnet deployment.

- lite_node source pin: `8f785a93a4e7392a0f3e65674f9de89854d33dbc`
- embedded `SOURCE_COMMIT`: `0c8ff3ba57102e3217c73fc9733b78cfc9ee45c8`
- lab compiler fingerprint: `69b1ef589a42dcae1636a9da7d699db83a42b9ce7718de0c87e536d2db4b3fef`
- byte-literal patch SHA-256: `b7b790c4f4204b38665080dd661fab7683695f97992fed08a53eab96f443d08c`
- Circle typed-storage runtime patch SHA-256: `5d0a92063ffd019615f8815ba0a8332b5084c0e64f67588eb7d9735ee4a1f6a9`
- node SHA-256: `40cffe88706554e2bd3645fea9d7b401097461114fc7eb631f94c2836cecc0e1`
- PVAC worker SHA-256: `dd6cfa294566807f293b4895c2e2d2f8ad9947c46fd471c5cc4de9b88b46c040`
- segment driver SHA-256: `d824961f3acfbaf5e2f22492378fd55c6c5532bd1323ab021171a8ea69e61151`
- chain driver SHA-256: `1f56ad21ff8dfdd4a72efee417e93fb82c1bde301ec3ded71b3db42b4bfad1af`
- static LMDB archive SHA-256 (lmdb.1.1.1 built in the lab): `3bd42eb55d86f61c49a5430919997850ef81df8e6010479d657eadd1ff152443`
- chain ID: `octra-devnet-9871-cluster`
- release profile: `off`
- BFT crypto profile: `off`
- admitted lab operations: `deploy_circle,circle_call`
- preverify receipt activation epoch: `1000000000`
- release key ID: `lab-messenger-ocpg-v1`

The release key is generated for this isolated network, held only in its run directory and deleted after the run.
Its public half configures `OCTRA_PROGRAM_RELEASE_KEYS` identically on all seven isolated validators. No devnet trust
configuration, production key, updater or shared fakenet is changed.

The separately disclosed `native/circle-typed-storage.patch` is also required in this lab. At the pinned source,
`Circle_exec.prepare_octb_call` incorrectly derives storage typing from nested-call permission, so an unset typed
field rejects before the append guards. The patch always uses the certified storage declarations. It is not accepted
upstream, is not a devnet compatibility claim, and must be reviewed separately from the compiler patch and OCPG signer.

The 2,049-byte control uses the ordinary epoch-finalization path. An earlier attempt with preverify active at epoch 0
repeatedly skipped the method-reverting transaction without a terminal rejection receipt. This run does not claim
preverify rejection acceptance.

Build the full chain with `controls/lib/gc_build.py -- dune build --profile release -j 2` at the pinned source, then
run `tests/run_ocpg_lab.sh`. The harness creates an attested OCPG Circle, appends exactly 2,048 bytes, retrieves the
frame publicly without the Circle owner secret, binds the caller to the envelope signer, decrypts through the archive
path at the actual commit epoch, and attempts exactly 2,049 bytes without changing the successful frame. A terminal
rejection is claimed only when it finalizes; a pending transaction produces an explicitly partial report. Every receipt
is labelled `lab network, fleet-generated release key`.
