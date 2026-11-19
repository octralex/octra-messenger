# Native recipient message profile v2 — experimental, open review

Status: a thin OCaml profile over existing Octra X25519, Ed25519, AES-GCM, `Oce1` and `Hash_domain` primitives.
Independent cryptographic and implementation review is required. This is not a PVAC KEM, a production security claim
or a deployed profile. The same-key PVAC spike is deleted from the active library; no other messaging protocol or
package is introduced.

## Selected native boundary

Octra already has recipient-offline stealth encryption: an ephemeral X25519 sender secret and a public recipient
view key derive shared material. `Recipient_message` adds a canonical arbitrary-byte profile with expected-sender
authorization, per-channel replay state, live/archive epoch rules and measured framing. The production library is
`octra_messenger`, built against `octra_net` and `octra_core`; the core is private and the testkit is separate.

```text
seal(recipient_public_view_key, sender_wallet_secret, context, key_version,
     sequence, sender_epoch, sender_instance, policy, current_epoch, plaintext)
  -> randomized v2 envelope

open(recipient_view_secret: Recipient_keys.t,
     expected_sender_address, sender_public_for_address,
     context, key_version, policy, freshness, atomic_receive, envelope)
  -> plaintext or bounded rejection
```

Production `seal` accepts no message ID, ephemeral secret or nonce. Those values come from Octra's native RNG.
`Recipient_keys.generate` creates dedicated X25519 keys. The public open API accepts only the typed secret and derives
its public key. Tagged key loading and atomic writes live in `Recipient_keys`; raw construction is not exported.

The sender receives only its own wallet signing secret, public recipient material and plaintext. The recipient is
offline for sealing. No recipient secret or online recipient helper is accepted by `seal`.

## Construction and opening order

- `StealthAddress.generate_ephemeral` and `ecdh_shared_secret` supply the X25519 exchange. HMAC-SHA256
  extract-and-expand uses the shared secret and OCE1-encoded recipient/ephemeral/view/context/sequence/epoch/instance
  fields. No custom parallel encoder exists.
- AES-GCM uses a fresh 12-byte nonce and 16-byte tag. `Hash_domain.hash_encoded "octra:msg:sig:v2"` hashes the exact
  header and ciphertext for the wallet signature; `octra:msg:ad:v2` authenticates the header-only associated payload.
- The 194-byte header contains explicit codec version, u64 sender sequence, u64 sender epoch and a 16-byte sender
  instance. The current OCE1 context is 86 bytes and nonce/tag adds 28, for 308 bytes overhead. No recipient-key hash
  is on the routine wire, although registration and traffic can identify recipients.
- Opening enforces structural checks and the receive-size cap, resolves the expected Ed25519 key from the contact
  registry by wallet address, verifies the address binding and signature, then checks sender equality, context,
  recipient key version and policy. Only then does ECDH and AEAD run. The default receive cap is 64 KiB; the
  3,000,000-byte encoding cap is raised explicitly for large tests.
- Only v2 readers and writers exist. Unknown versions, v1 rewraps, old `OCMMSG1`/`OCMCTX`/`OCMCUR` forms and trailing
  bytes reject. `Session_context` is the single context codec and preserves version in the decoded value.

## Replay, outbox and persistence

Each channel is `(codec, context, recipient key/version, sender key, sender instance)`. The random 16-byte instance
is generated and persisted per outbox contact, so two devices using one wallet do not collide and activity on other
contacts does not skip this channel's sequence. It is not a forward-secrecy or anonymity mechanism.

The outbox persists the next positive signed-64-bit sequence and an `allocating` record before calling the sealer
with that exact sequence and instance. Sequences 1 through `Int64.max_int` are usable, followed by an explicit
`exhausted` state. Invalid or exhausted counters refuse allocation before sealing or journal mutation; no wrap,
reset or instance rotation occurs. Sealed records retain byte-identical retry, and valid old integer journals resume
without ID or pending-receipt changes. Recovery takes a verified observed channel high-water, never lowers the
counter or rotates the instance, and sets `max(local_next, observed + 1)` (or `exhausted` at the maximum). A failed
seal leaves a gap and an incomplete record, never reuse. Record IDs bind channel, instance and sequence for
byte-identical retry and status transitions; an incomplete allocation cannot be returned as an empty envelope or
marked submitted.

The receive window is a permanent per-channel 1,024-bit bitmap keyed by `octra:msg:replay-window:v2`.
`octra:msg:replay:v2` additionally includes sequence and epoch. Stored high-water values must be positive and
bitmaps exactly 128 bytes. All stored windows are validated before mutation. Forward distance is bounded in `int64`
before host-`int` conversion; at or beyond the window width it clears the bitmap before marking the new high-water.
Any forward jump advances the high-water mark;
duplicates and sequences at or below `high_water - 1024` reject. Out-of-order delivery inside the window is allowed.
High-water marks are never pruned, so retention grows across channels and key rotations and needs migration.

After AEAD succeeds, one lock-protected state replacement writes a per-message fsynced plaintext file, updated window
and pointer-only inbox record. Concurrent duplicates have one acceptance. Per-sender caps are 1,000 records and
51,200,000 bytes; global caps are 10,000 records and 512,000,000 bytes. Ten authorized contacts can exhaust the
global cap. Crash-before-rename may leave an orphan plaintext file counted until that path is retried, and each
receive scans the whole message directory.

Previous view secrets remain available during the signed grace window for unread old key versions. Rotation does
not erase history or establish forward secrecy. Test contact signatures use a public-constant-derived root secret:
**contact registration is deferred to on-chain registration**, not production contact authentication. Current per-version policies come
from a local test authority until chain integration.

## Live and archive epochs

Live mode uses the receiver's finalized epoch: at most 64 epochs old and at most two epochs ahead. Archive mode uses
the frame's on-chain commit epoch and accepts any age when `sender_epoch <= commit_epoch`; a later sender epoch
rejects. Policy is evaluated at the corresponding reference epoch. Signature, replay and atomic persistence checks
apply in both modes, so archive access cannot re-admit a replay.

Public opens return only `{"status":"rejected"}`. Detailed local test errors stay separate. Prototype secret and
plaintext files are mode 0600 but not encrypted at rest. Storage failures remain distinct from decryption failures;
unexpected exceptions are not normalized into a generic decryption error.

## On-chain binding

Native `CircleDeploy` does not execute the AML constructor, so segment and registry templates embed the owner before
compilation. `append` and `publish` compare `to_string(caller)` with that constant; no race-prone initialization call
exists. Segment frames store `caller`, and clients require it to match the contact wallet and fixed-header sender key
before full decoding. Non-owner writes reject without state mutation. Registry and segment tests cover owner-only
publish/append, granted writers, descriptors, exact dedup and restart reads in both compiler profiles.

The tested frame is 2,048 bytes of base64 text, so large-message chunking is still open. Exact frame bodies are
retained once and deduplicated by the `octra:msg:frame:v2` digest used by `Frame.hash`. Registry descriptors use
bounded OCE1 fields with truncation and trailing-byte rejection. The lab-only `\xHH` lexer patch supplies binary
prefixes without a new VM opcode.

## Sizes and evidence

At 1, 2, 4 and 16 KiB, envelopes are 1,332, 2,356, 4,404 and 16,692 bytes: 194-byte header, 86-byte context and
28-byte nonce/tag overhead. The exact-cap 86-byte-context envelope is 2,999,574 bytes and its base64-plus-quotes
form is 3,999,434 bytes. The production receive default is 65,536 bytes; this context allows 65,228 plaintext bytes
and rejects the 65,537-byte envelope produced by one more byte.

Fresh receipts bind source, executables, compiler/dependencies and commands. Measurements cover v1 rewrap rejection,
wrong senders, low-order points, modified signatures, replay after pruning, large forward jumps, restart rollback,
out-of-order and outside-window sequences, live future tolerance, stale/future archive epochs, concurrent duplicates,
multi-device identity, 1,025 other-contact sends, cap-plus-one and downgrade rejection. They are lab controls, not
production acceptance.

## Security limits

Messages are non-deniable and transferable because the wallet signature is public. `sender_public` and
`sender_instance` are clear metadata. A leaked view secret decrypts every retained message for that version,
including permanently archived ciphertext. Forward secrecy, post-compromise recovery, recipient anonymity and
post-quantum confidentiality are not established. Rotation/revocation does not erase copied keys, plaintext or
history. Stronger anonymity needs separately reviewed unlinkable authorization/fees and network anonymity; FHE does
not supply that.

Independent specialist review must cover key custody, low-order/malformed points, static-recipient compromise,
KDF/signature composition, channel allocation, replay atomicity, nonce/RNG behavior, version negotiation, contact
registration, on-chain sender binding and exact size/admission accounting. No upstream write, production promotion,
validator change, shared-fakenet change or real-value transaction is authorized.
