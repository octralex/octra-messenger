# Native protocol profile status

This document describes implemented transport-independent codecs and measured native spikes. It is not a final
wire specification, a reviewed messaging composition or a production readiness claim. The 2026-11-14 Octra-native
correction supersedes earlier external-protocol exploration.

## Opaque frames and cursors

`lib/protocol/frame.ml` accepts 2,048- or 4,096-byte opaque frames, exposes exact bytes and computes SHA-256
for replay suppression. It has no recipient, conversation, plaintext length, message type or clear session counter.
These buckets remain valid for the storage spike but are not final native-message buckets.

`lib/protocol/session_context.ml` canonically encodes chain, registry, format and suite with fixed field order and
length checks. Unknown versions, zero values, truncation and trailing bytes are rejected. Inclusion-dependent
transaction hash, epoch, sequence and fee are not added to pre-submission associated data. The native suite ID is
not assigned yet.

`lib/protocol/cursor.ml` is the fixed 130-byte epoch/sequence/segment/root encoding. Sequence is bounded to 32 bits
on every host. Roots are 64 lowercase hex characters. A cursor is a scan bookmark, not a completeness proof.
`lib/protocol/page.ml` enforces at most 64 records and 262,144 bytes with exact whole-frame accounting.

## Recipient message profile

`lib/crypto/recipient_message.ml` binds the existing Octra stealth-derived X25519/AES-GCM path to arbitrary
bytes through a thin OCaml profile. `docs/RECIPIENT-ENCRYPTION.md` records the candidate comparison and actual
endpoint evidence; `docs/NATIVE-RECIPIENT-EXTENSION.md` keeps the new profile experimental and open for review.

The sender generates an ephemeral X25519 key and never receives the recipient view secret. The recipient later
uses its own view secret. Expected-sender material is checked independently of the self-supplied envelope key.
The profile also checks recipient key version, native activation/expiry/revocation/erasure policy, replay,
context and exact framing. No stable recipient-key hash is serialized; it is derived locally only for KDF.

The envelope layout is:

```
"OCMMSG1" | context-length:u16-be | ciphertext-length:u32-be | key-version:u32-be
          | message-id:16 | ephemeral-public:32
          | sender-public:32 | signature:64 | context | nonce || ciphertext || GCM-tag
```

The fixed header is 161 bytes (`7 + 2 + 4 + 4 + 16 + 32 + 32 + 64`). AES-GCM adds a 12-byte nonce and 16-byte tag. Current context is 77 bytes, so
envelope overhead is 266 bytes. Header-only associated data authenticates context and capabilities; Ed25519 signs
that header plus exact ciphertext. Wrong recipient, replaced key, wrong context/sender, modified body/header/
capability, truncation/trailing bytes, replay, stale policy, malformed ciphertext and unsupported version reject
without advancing replay state.

At 1, 2, 4 and 16 KiB, complete envelopes are 1,290, 2,314, 4,362 and 16,650 bytes. Base64/JSON representations
are 1,722, 3,090, 5,818 and 22,202 bytes. The selected legacy append has measured signed size and OU. A 1 KiB
message fits 2 KiB, 2 KiB needs 4 KiB, 4 KiB needs 8 KiB, and 16 KiB needs 32 KiB; these are observations, not
a frozen bucket schedule.

The recipient view key is 32 bytes and uses a new independent messaging namespace, not a spending-key seed.
PVAC's much larger arithmetic ciphertext/public key remains a same-key representation baseline only. No PVAC KEM,
recipient-secret sharing or external messaging protocol is used.

The public sender signature makes messages non-deniable and transferable, and `sender_public` is clear metadata.
A leaked view secret exposes every retained message for that version, including previously harvested on-chain
ciphertext. Forward secrecy, post-compromise recovery, recipient anonymity and post-quantum guarantees are
unestablished. Static view keys and public contact/policy records may link recipients. The new profile's domain
separation, contact/key substitution, nonce handling, replay atomicity and rotation/revocation semantics require
independent specialist review.

## Storage and persistence

The AppliedML segment preserves exact bodies with atomic caps, 16-record pages and single-record tail reads under
both compiler profiles. It does not provide a committed page completeness proof or bounded whole-contract append
cost. Pruning, index rebuild and fresh sync are demonstrated, while larger retention and optimization remain open.

`Receive_store.commit_receive` rechecks dedup under a lock, writes each plaintext to its own fsynced mode-0600
file, and atomically replaces a state file containing only dedup rows and pointer metadata. Each side has global
10,000-record and per-sender 1,000-record caps; byte limits are 512,000,000 globally and 51,200,000 per sender.
A second authorized sender can still receive after one sender reaches either per-sender quota. Erased or
out-of-grace dedup and pointer rows are pruned; replay history for those versions is forgotten, so they must not
be reactivated in the same dedup domain. Archived plaintext remains and counts toward the global byte cap.

Crash injection covers before and after rename and subsequent process restart. The durable outbox returns exact
prepared bytes across submitted/finalized transitions. These are local prototype guarantees, not encrypted secret
storage, power-loss certification, chain nonce allocation or chain submission. An ambiguous RPC timeout must
remain `unknown`; a later implementation must not re-encrypt or advance native state on retry. The test contact
signature uses a public-constant-derived secret beside the config; B6 is deferred to on-chain registration.

## Isolated chain profile

The disclosed fakenet profile is a prototype, not a production wire freeze or activation. Its input and output
binary envelope is `{"encoding":"base64","data":"…"}` with one unique pair in either order. Wrong shapes,
duplicates and non-base64 encodings reject at both routes. Input must be canonical base64: malformed, unpadded,
whitespace-bearing and noncanonical pad-bit encodings reject rather than becoming empty strings. Unrelated legacy
objects without either field retain their prior fallback. Valid UTF-8 text responses remain strings; non-UTF-8
values use the same envelope. Empty/ASCII/invalid-byte and split-multibyte controls cover result, event and storage
value paths. Storage keys remain raw legacy strings and are not covered. Clients must accept both value forms.
The compiler source stamp is `6eb1af8241430645904abb6524df5791a11c0ca98eb8a6d859624742d9d8b20f`.

`programs/segment_spike.aml` retains one exact 2,048-byte body per sequence and `seen[sha256(frame)]` rejects an
exact duplicate before any state mutation. Capacity, malformed-frame, closed-segment and closed-append failures do
not change state. `programs/segment_registry.aml` appends immutable descriptors as
`1|address|activation_epoch|1024|8388608|predecessor|1`; `current` identifies the newest segment but cannot
rewrite an accepted body or earlier descriptor. Bounded `MultiExec` messages contain at most eight calls.

The proof covers 102 frames across two segments, not a final segment schedule. At 100 accepted frames in 13 batches,
latency p50 is 7.078 seconds and p95 is 7.368 seconds, total OU is 113,000 and receipt effort is 77,100. Signed JSON
and RPC request totals are 293,111 and 293,891 bytes. Full source identities, rejected attempts, transaction hashes
and growth measurements are in `receipts/chain/`. Sustainable rates, 10,000/100,000-frame retention, committed page
completeness and production admission are not established.
