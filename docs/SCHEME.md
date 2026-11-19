# Messenger scheme v2 — experimental, for design review

**Status:** experimental native library, not secure messaging or a production profile. The same-key PVAC path is
removed. This page is for the maintainer's design read; the demo is not built until that read is done.

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

## Library and on-chain binding

`octra_messenger` builds in place against `octra_net` and `octra_core`; the core remains private and the testkit is
a separate test-only library. Public modules have `.mli` interfaces and SPDX headers. Tagged typed-key loading and
atomic secret-file writes live in the library; raw key construction and deterministic fixtures are not exported.

Native circle deployment does not run the AML constructor. Segment and registry bytecode therefore embed the owner
address at deployment. Segment append accepts that owner or an owner-granted writer; registry publication is
owner-only. Each frame stores its caller. Before full envelope decoding, the client binds that caller to the contact
wallet and fixed-header sender key. Non-owner writes reject without state mutation. Exact frame bodies are retained
once. Their dedup key is the
64-character hex `octra:msg:frame:v2` digest over the domain separator, OCE1 length prefix and exact frame bytes,
identical to `Frame.hash`.

Registry descriptors are bounded OCE1: `u16` format version, length-prefixed segment address, `u64` activation epoch,
`u32` record cap, `u64` byte cap, tagged optional previous `u64` segment ID and `u8` flags. Decoders reject trailing
bytes and every truncation. The registry descriptor format is version 1, independent of envelope codec version 2.

The pinned VM has no binary string escape or OCE1 instruction. The lab therefore tests the minimal
`native/byte-literals.patch`: `\xHH` parsing in the two existing lexer profiles and the corresponding compiler
fingerprint. It introduces no opcode, host primitive or state-rule change. Upstream acceptance is not claimed.

The isolated Circle test also requires `native/circle-typed-storage.patch`. At the pinned source,
`Circle_exec.prepare_octb_call` enables certified storage declarations only when nested calls are enabled, causing
unset typed fields to reject before method guards. The two-line correction always uses those declarations and leaves
nested-call authorization unchanged. It is a lab-only runtime correction, not accepted upstream behavior or evidence
of devnet compatibility. It needs separate native review before a devnet deployment can be proposed.

Circle deployment uses the supported `Program_package.compile_sources_at` route to produce an `OCPG` package with
embedded bytecode and certificate. The package also needs a compiler attestation from the configured release key;
source-only validation is not deployment acceptance. Preflight checks both embedded values against the compiler
result and calls `Code_check.decode_deploy`. The declared deployment OU covers the final base64 package's load work
plus its static integer cost, alongside the normal minimum. Raw legacy `OCTB` is not an admissible Circle package
once scalar work is active.

## Open packing question for the maintainer

An hourly single-transaction commit is not yet an established eight-append Circle batch. The demonstrated path is
one `circle_call` with one 2,048-byte frame; lite_node's configurable eight-call `MultiExec` limit does not prove a
Circle batching API. At the measured 372-byte envelope size, five raw envelopes occupy 1,860 bytes before packing
framing; four base64 envelopes occupy 1,984 bytes before framing. Raw-byte transport and a packing format need their
own evidence. Should David prefer several raw envelopes per frame, or a hash-only commitment? Hash-only commitment
moves bodies off-chain and changes availability. An aggregate transaction across wallets also needs a new reviewed
sender-binding model; the current frame has one caller bound to the envelope signer.

## Not provided

No forward secrecy, post-compromise recovery, sender/recipient anonymity, post-quantum protection or guaranteed
deletion. Signatures are public and non-deniable. A leaked view secret exposes retained history. Contact
registration is deferred to on-chain registration; prototype contact roots are not production trust anchors. Plaintext and secret files
are mode 0600 but unencrypted. Crash orphans and an O(n) receive-directory scan remain. Large-message chunking,
committed feed completeness, revised pruning/fresh-sync evidence, explicit fee burn, retention and sustained-load
measurements, and production readiness remain open.
