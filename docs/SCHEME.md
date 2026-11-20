# Messenger scheme v2

**Status:** experimental. The library passes its suites and the full path runs on devnet (`receipts/devnet/`). It
is not a production messenger; the limits are listed at the end. The same-key PVAC path is removed.

## Encryption and sender authentication

Each message uses a fresh X25519 ephemeral key and the recipient's dedicated public view key. The recipient can be
offline and never supplies its secret to the sender. A native RNG generates the 16-byte message ID, ephemeral key,
12-byte AES-GCM nonce and the 16-byte sender instance. AES-GCM supplies ciphertext and a 16-byte tag.

The data key is HMAC-SHA256 extract-and-expand over ECDH material, with salt/info fields encoded by
`Octra_net.Oce1`. The signed header, sender instance, sequence and epoch are also authenticated in AEAD associated
data. `Octra_net.Hash_domain.hash_encoded` produces the tagged SHA-256 signature and AD digests; HMAC is used only
for key derivation.

The sender signs with its **Octra wallet Ed25519 key**, not a separate messaging signing key. The receiver resolves
that key from its contact registry by wallet address and checks the address binding before verifying the signature.
The `octra:msg:sig:v2` payload is a labelled hash of the exact envelope header and ciphertext, not an Octra
transaction serialization, so it cannot be reused as a transaction signature. Opening enforces the receive cap
(default 64 KiB), structural checks, expected-sender verification, context/version/policy checks, then ECDH, AEAD
and the atomic store. No production caller can supply deterministic message IDs, ephemeral secrets or nonces.

## Sequence and replay

The channel is `(codec, context, recipient key/version, sender key, sender instance)`. Each outbox contact has a
monotonic positive signed-64-bit sequence and a random sender instance persisted before sealing, so independent
devices using one wallet do not collide and activity on other contacts does not skip this channel. Sequences
1 through `Int64.max_int` are usable; the next counter then becomes the explicit string `exhausted`. An invalid or
exhausted counter refuses allocation before sealing or journal mutation. Exhaustion never wraps, resets or rotates
the channel. Existing sealed records still retry byte-for-byte, and valid old integer journals resume without ID,
instance or pending-receipt changes.

`Outbox_journal.recover` accepts a **verified observed channel high-water**. It advances the next counter to
`max(local_next, observed_high_water + 1)`, or to `exhausted` when that observation is `Int64.max_int`. It never
lowers the counter, rotates the sender instance, changes pending records/IDs or recovers an exhausted channel.
Callers must not supply an unverified high-water; an inflated value can deny future allocations.

The receiver keeps a permanent high-water mark and 1,024-bit window per channel. Stored high-water values must be
positive and bitmaps exactly 128 bytes; every stored window is validated before mutation. Forward distance is
compared with 1,024 in `int64` and converted to host `int` only below that width. Any forward jump advances the
window, including `Int64.max_int`; distances at or above the width clear it before marking the new high-water bit.
Duplicates and sequences at or below `high_water - 1024` reject. Out-of-order delivery inside the window is allowed.
One lock-protected, fsynced state replacement commits plaintext, window and inbox pointer together. Windows are never
pruned, including after old inbox pruning; growth across new channels and key rotations is currently unbounded and
needs an operational migration policy.

## Freshness and versions

Live mode uses the receiver's finalized epoch: at most 64 epochs old and at most two epochs in the future. Archive
mode instead uses the frame's on-chain commit epoch and accepts any age when `sender_epoch <= commit_epoch`. Policy
is evaluated at the corresponding reference epoch. Signature, replay and atomic-write checks apply in both modes.

Only v2 readers and writers exist; v1 and its legacy encodings are rejected. The 194-byte header contains explicit
u16 version, u64 sequence, u64 epoch and sender instance. `Session_context` is the sole `OCMCTX` encoder, includes
application and preserves version in decoded values. OCE1 context is 86 bytes for the test profile; nonce/tag adds
28, giving 308 bytes overhead. Unknown versions and trailing bytes reject.

## Library

`octra_messenger` builds in place against `octra_net` and `octra_core`; the core remains private and the testkit is
a separate test-only library. Public modules have `.mli` interfaces and SPDX headers. Tagged typed-key loading and
atomic secret-file writes live in the library; raw key construction and deterministic fixtures are not exported.

## On-chain store and sender binding

Messages are stored by two source-admitted programs, `programs/segment.aml` and `programs/registry.aml`. They are
deployed with `ProgramDeploy` as a source package: the node compiles the source itself and compares the result, so
no release signature and no node change is involved. The constructor records the deployer as owner.

Segment `append` accepts the owner or an owner-granted writer and exactly 2,048 bytes of base64 text per frame, up to
1,024 frames. Each frame stores its caller. A frame is stored once: the program keeps
`sha256("octra:msg:segment-dedup:v1:" ‖ frame)` for every accepted frame and rejects a repeat. The frame length is
fixed, so the label prefix is unambiguous. Views return the frame, its caller, the owner and the counters to anyone.
The registry maps a segment id to a segment address and activation epoch; only its owner publishes.

Before decoding an envelope, the client checks that the stored caller is the contact's wallet and that the
envelope's sender key derives that address. An envelope signed by one wallet and written by another is rejected at
that step.

On devnet at `8f785a93`, one run deploys both programs, appends, reads the frame back through the public view,
binds the caller and decrypts in archive mode at the append's commit epoch. The same run shows terminal rejections
for a duplicate frame, a 2,049-byte frame, a non-writer append, a non-owner grant, close and publish, and an append
after close, with the stored frame and counters unchanged. `tests/run_devnet_program.py` produces
`receipts/devnet/devnet-program.json`.

## Open packing question

One append carries one 2,048-byte frame, and one envelope with 64 plaintext bytes is 372 bytes, or 496 base64
characters. Four base64 envelopes fit in a frame before any packing framing. Packing several envelopes per frame, or
committing only a hash and keeping bodies elsewhere, are both undecided. A hash-only commitment changes
availability, and one transaction carrying frames from several wallets would need a new sender-binding rule.

## Not provided

No forward secrecy, post-compromise recovery, sender/recipient anonymity, post-quantum protection or guaranteed
deletion. Signatures are public and non-deniable. A leaked view secret exposes retained history. Contact
registration is deferred to on-chain registration; prototype contact roots are not production trust anchors. Plaintext and secret files
are mode 0600 but unencrypted. Crash orphans and an O(n) receive-directory scan remain. Large-message chunking,
committed feed completeness, revised pruning/fresh-sync evidence, explicit fee burn, retention and sustained-load
measurements, and production readiness remain open.
