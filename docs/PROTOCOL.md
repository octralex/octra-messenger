# Native protocol profile v2 — experimental

This document describes implemented codecs and lab evidence, not a final wire specification, independent security
acceptance or production readiness. Compatibility begins at v2; no v1 reader remains. `docs/SCHEME.md` is the short
design summary for maintainer review after the current code and independent reviews clear.

## Native encoding, hashing and signatures

`Octra_net.Oce1` supplies big-endian integers, u32-length-prefixed byte fields, fixed-width values and bounded cursor
reads. `Octra_net.Hash_domain.hash_encoded` supplies `SHA256(tag ‖ 0 ‖ OCE1(fields))` for protocol digests and signing
bytes. There is no messenger-specific parallel encoder. HMAC-SHA256 is retained only for HKDF-style key derivation,
with OCE1 field encoding and no extra package.

`lib/protocol/frame.ml` accepts exact 2,048- or 4,096-byte frames and uses the labelled frame digest for dedup keys.
`lib/protocol/cursor.ml` writes `OCMCUR` with explicit u16 version, epoch, sequence, segment and root. The current
cursor is 131 bytes; older cursor versions reject. Pages remain capped at 64 records and 262,144 bytes, with exact
whole-frame accounting; a cursor is a scan bookmark, not a completeness proof.

`Session_context` is the only `OCMCTX` codec. It carries version, chain ID, application, registry, format version and
suite, and preserves version in the decoded value. OCE1 gives the test context 86 bytes. The same module is used by
`Recipient_message.make_context`; no second context layout or version-less equality check remains.

## Envelope and opening order

The v2 layout is:

```
"OCMMSG":6 | version:u16@6 | context-length:u16@8 | ciphertext-length:u32@10
key-version:u32@14 | sender-sequence:u64@18 | sender-epoch:u64@26
message-id:16@34 | ephemeral-public:32@50 | sender-public:32@82
sender-instance:16@114 | signature:64@130 | context@194 | nonce || ciphertext || GCM-tag
```

The fixed header is 194 bytes. With the current 86-byte context and 28-byte nonce/tag, overhead is 308 bytes. No
stable recipient-key hash is serialized; it is derived locally for KDF only. Sender instance is covered by the
signature, AEAD associated data, KDF and replay identity.

The sender uses its Octra wallet Ed25519 key. The receiver resolves the expected key from a contact registry by
wallet address and verifies the address binding before checking the signature. `octra:msg:sig:v2` is a labelled hash
of the exact header and ciphertext, not an Octra transaction serialization, so a message signature cannot be
reused as a transaction signature.

Opening enforces total receive size, structural checks and v2, then resolves and verifies the expected sender before
context, recipient key version and policy checks. Only then do ECDH, AEAD and the atomic receive commit run. The
default production receive limit is 65,536 bytes; the 3,000,000-byte encoding cap is an explicitly raised test limit,
not a safe chat parse limit. Production sealing exposes no deterministic message ID, ephemeral secret or nonce input.

## Channel sequence, replay and persistence

The channel is `(codec version, context, recipient public key/version, sender public key, sender instance)`.
`Message_channel.key` and `octra:msg:replay-window:v2` identify that full channel. The sender instance is a random
16-byte value generated and persisted per outbox contact, so two devices sharing a wallet have independent channels
and do not reset or collide with one another. It is not a cross-contact anonymity identifier.

`Outbox_journal` keeps a monotonic positive signed-64-bit sequence per contact and instance, not one counter per
device. Values 1 through `Int64.max_int` are usable; the next state is explicitly `exhausted`. Invalid or exhausted
counters refuse allocation before sealing or journal mutation, without wrap, reset or instance rotation. Valid old
integer journals retain sequences, IDs and pending receipts. Existing sealed records retry byte-for-byte after
exhaustion. Recovery takes a verified observed channel high-water and advances to `max(local_next, observed + 1)`;
it never lowers the counter, changes pending records or rotates the instance.

Allocation and an `allocating` record are fsynced before the sealer receives that exact sequence and instance. A
failed seal leaves a gap and an incomplete record, never reuse. Record IDs bind the channel, instance and sequence
for retry and status transitions; an incomplete allocation cannot be returned as an empty envelope or marked
submitted.

The receive store keeps a permanent high-water mark and 1,024-bit bitmap per channel. Persisted high-water values
must be positive and bitmaps exactly 128 bytes. Every stored window is validated before mutation. Forward distances
are bounded in `int64` before host-`int` conversion; a distance at or above 1,024 clears the bitmap before the new
high-water bit is set. A duplicate bit or sequence at or below `high_water - 1024` rejects; out-of-order delivery
inside the window
is accepted. One lock-protected, fsynced state replacement writes the plaintext file, updated window and pointer-only
inbox record. Concurrent duplicates have one acceptance. Windows are never pruned, even when old inbox rows are
pruned, so retention grows across new channels and key rotations and requires an operational migration policy.

Per-sender limits are 1,000 records and 51,200,000 bytes, and global limits are 10,000 records and 512,000,000 bytes.
Ten authorized senders can exhaust the global cap. Crash-before-rename can leave an orphan plaintext file counted
against the cap until the same path is retried. Receive-size accounting scans the whole message directory.

## Live and archive reads

Live mode uses the receiver's finalized epoch: sender age at most 64 epochs and future tolerance at most two epochs.
Archive mode uses the frame's on-chain commit epoch, accepts any age when `sender_epoch <= commit_epoch`, and rejects
a sender epoch after commit. Policy is evaluated at the corresponding reference epoch. Signature, replay and atomic
persistence checks apply in both modes; archive access is not a bypass for replay history.

## Versions and library boundary

Only v2 readers and writers exist. Unknown versions, v1 rewraps and the old `OCMMSG1`/`OCMCTX`/`OCMCUR` forms reject
with `unsupported version N`. Version is inside signed/authenticated bytes, and decoders reject trailing bytes.

`octra_messenger` builds in place against `octra_net` and `octra_core`. `recipient_message_core` is private; only the
wrapper is exposed. Public modules have `.mli` interfaces and SPDX headers. `tests/testkit/` is a separate test-only
library with no legacy encoder or production test constructors. Tagged typed-key loading and atomic secret-file
writes live in `Recipient_keys`; raw construction and deterministic fixtures are not exported.

## On-chain sender binding

Native `CircleDeploy` does not execute the AML constructor, so segment and registry source templates embed the owner
address before compilation. Segment `append` accepts that owner or an owner-granted writer; registry `publish` is
owner-only. No first-use initialization transaction exists. Segment frames store `caller`; clients bind it to the
contact wallet and fixed-header sender key before full decoding. Non-owner writes reject without state mutation.
Registry and segment tests cover owner, non-owner rejection, descriptors and restart reads in both compiler profiles.

The current segment accepts exactly 2,048 bytes of base64 text per frame and retains that exact body once. Its
64-character dedup key is the `octra:msg:frame:v2` digest used by `Frame.hash`. Registry descriptors use bounded
OCE1 fields and reject truncation or trailing bytes. A pinned lab-only `\xHH` lexer patch supplies the binary
prefixes; it adds no VM opcode. Large envelopes require a chunking design not yet implemented.

## Measured caps and evidence

With a maximum 512-byte context, the plaintext cap is 2,999,266 bytes. With the 86-byte test context, exact-cap
plaintext is 2,999,266 bytes, the envelope is 2,999,574 bytes and base64 plus quotes is 3,999,434 bytes. The default
65,536-byte receive cap accepts 65,228 plaintext bytes in this context and rejects a 65,537-byte envelope. The segment
still rejects whole large envelopes; encoding headroom is not chain storage evidence.

The current small-message signed sizes and native OU base costs are in `receipts/chain/devnet-feasibility.json`.
These OU values are not receipt effort, explicit fee burn or a production fee schedule. Binary I/O evidence belongs
to the separately disclosed older lab profile and is not rebound to the new native recipient library or to a
production activation. Historical pruning, index rebuild and fresh-sync results are not silently rebound either;
revised large-retention and recovery evidence remains open.

## Security limits

Sender public keys, wallet addresses and signatures are clear metadata and make messages non-deniable and
transferable. A leaked view secret exposes every retained ciphertext for that version, including harvested history.
Rotation does not provide forward secrecy or post-compromise recovery. Recipient anonymity, post-quantum protection,
production contact authorization, secure encrypted key backup and guaranteed deletion are not provided. Contact
registration is deferred to on-chain registration. Prototype secret and plaintext files are mode 0600 but not encrypted at rest.
