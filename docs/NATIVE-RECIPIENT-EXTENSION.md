# Native recipient message profile — experimental, open review

Status: thin native message profile over existing Octra X25519/Ed25519/AES-GCM primitives. Independent
cryptographic and implementation review is required. This is not a new PVAC KEM, a production security claim or
a deployed profile.

## Missing operation and selected boundary

Octra already demonstrates recipient-offline amount encryption: an ephemeral sender secret and the recipient's
public view key derive shared material, and AES-GCM encrypts the amount. The missing operation is a canonical
arbitrary-byte message profile with explicit application context, expected-sender authorization, key versions,
replay state and measured framing. It needs a thin OCaml binding, not a new cryptographic primitive or recipient-
secret input.

```text
seal(recipient_public_view_key, sender_signing_secret, context, key_version,
     policy, current_epoch, plaintext) -> randomized envelope
open(recipient_view_secret: Recipient_keys.t, expected_sender, context, key_version,
     policy, current_epoch, replay_state, envelope) -> plaintext or bounded rejection
```

The production `seal` accepts no message ID, ephemeral secret or nonce. It generates all three through Octra's
native RNG. Deterministic variants exist only in `recipient_message_testkit`: a bounded test generator supplies
the fixed ID/ephemeral/nonce byte stream while invoking the same production seal implementation, then unsets that
generator. No production caller can supply those values. Production messaging keys come from
`Recipient_keys.generate`, a dedicated X25519 generator with an opaque type; no Ed25519 wallet seed or
PVAC secret is accepted. `open_envelope` accepts only that typed secret and derives the public key itself; secret
JSON must declare `key_type: octra-x25519-recipient-message-v1`. Positive endpoint flows use generated keys, not
seed-derived testkit keys. Ed25519 is used only for sender/contact authorization.

The sender receives only its own signing secret, authenticated public recipient material and plaintext. The
recipient can remain offline during sealing. No recipient secret, recipient-secret-derived handle or recipient
online helper is accepted by `seal`.

## Construction

- `StealthAddress.generate_ephemeral` supplies an X25519 ephemeral key in production. `ecdh_shared_secret`
  combines it with the recipient public view key. The recipient later uses its view secret and the public
  ephemeral key.
- The AES key is `SHA256(shared || "OCTRA_MESSAGE_V1\000" || recipient_key_hash || ephemeral_public ||
  view_public || context)`. `recipient_key_hash` is derived independently by each endpoint and never serialized
  in the routine envelope.
- AES-GCM uses a fresh 12-byte nonce and the header-only associated payload as associated data. Ciphertext is
  plaintext plus 12 nonce bytes and 16 tag bytes.
- Ed25519 signs the header plus exact ciphertext, covering context, key version, message ID, ephemeral public key,
  sender public key and ciphertext bytes. Expected-sender equality is checked against independently configured
  contact material before signature verification; a self-supplied key is not sufficient.
- Context is `OCMRCV1\000` followed by length-bounded chain, application and registry fields, format version and
  suite. The envelope starts with `OCMMSG1`; associated data is domain-prefixed with `OCMMSG-AUTH1\000`.
- Message IDs are opaque random 16-byte values, independent of plaintext. Reusing the production send path for
  equal plaintexts produces distinct IDs, ephemerals, nonces and envelopes. An uninitialized RNG fails closed with
  no output or state change.
- Recipient key versions and mandatory activation/expiry/revocation/erasure policy are selected per key version,
  with mandatory current epoch. The signed contact binds the current view key and every accepted previous version
  to its own view public key. A previous version must appear in both the accepted and grace lists; an unregistered
  or substituted key is rejected before decryption. Expiry and activation use exact boundary tests. No default live
  policy or epoch 0 is accepted.
- The envelope has a fixed 161-byte header plus context and ciphertext. Current overhead is
  `161 + context_length + 28` bytes. No stable recipient-key hash is transmitted; registration/contact material
  can still identify the recipient.

## Contact and policy authority

The public contact file is 0644 because it is not secret. Its test signature is checked against the pinned test
root, but the root secret is derived from a public constant and stored beside the config it signs. This is a test
fixture, not authenticated contact custody or a security boundary. **B6 is deferred to on-chain registration.**
The current epoch and per-`(recipient key, key_version)` policies also come from the local test authority;
chain-finalized contact and policy acquisition are not completed.

## Replay and persistence

`Receive_store.commit_receive` serializes one lock-protected state replacement containing the dedup row and an
inbox pointer. Each plaintext is stored separately in an fsynced mode-0600 file; the state file contains no
plaintext. Duplicate detection rechecks under the lock. A temporary-file failure before the state rename leaves
the old state unchanged; a crash after rename leaves the committed message, so the next open rejects replay.

Dedup and inbox each have a global 10,000-record cap and a 1,000-record per-sender cap. Plaintext storage has a
512,000,000-byte global cap and a 51,200,000-byte per-sender cap. One sender reaching either per-sender quota does
not prevent a different authorized sender from receiving; global exhaustion still requires an operational
migration. Rows for erased or out-of-grace key versions are pruned from both dedup and inbox. Their replay history
is intentionally forgotten: such a version must not be reactivated in the same dedup domain. Archived plaintext
files are retained and still count toward the global byte cap.

`Outbox_journal.prepare` durably records the exact randomized envelope before submission. Retry returns those exact
bytes after restart, never a re-encryption. Submitted/finalized transitions preserve the bytes. Chain nonce
allocation and actual submission/finality are later integration work.

Previous view secrets are retained during the grace window for unread old-version messages. Rotation does not erase
unread history and is not forward secrecy. An explicit later deletion policy must state when old secrets and unread
ciphertext become inaccessible.

Public opens return only `{"status":"rejected"}`. Detailed local test errors are JSON encoded and stay out of the
public boundary to avoid an error oracle. Prototype secret files and plaintext inbox contents are mode 0600 but
not encrypted at rest; secure key backup and encrypted secret persistence remain integration work.

## Size and admission cap

`max_envelope_bytes` is 3,000,000 bytes. With the maximum 512-byte context, ciphertext is capped at 2,999,327
bytes and plaintext at 2,999,299 bytes. With the current 77-byte context, the exact-cap envelope is 2,999,565
bytes and base64 plus JSON quotes is 3,999,422 bytes. The separate `transaction_overhead_budget` is 194,302
bytes, reserving room below the 4,194,304-byte target for transaction encoding. These are conservative local
caps, not permission to store a whole maximum envelope as one contract value. The existing chain segment accepts
only 2,048-byte frames, so a complete large envelope requires an implemented chunk format and multiple accepted
transactions; no production limit is raised.

At the current 77-byte context, total overhead is 266 bytes. At 1, 2, 4 and 16 KiB, envelopes are 1,290, 2,314,
4,362 and 16,650 bytes. Selected signed sizes and OU are measured in `receipts/chain/fees-and-sizes.json`.
The exact-cap 77-byte-context envelope produced 3,999,863 signed JSON bytes and a 3,999,923-byte RPC request. RPC
accepted it, and the VM rejected the whole envelope at the 2,048-byte frame guard without changing state. This is
transport evidence, not large-message storage. Chunking and bucket choices are not frozen or implemented.

## Rejected alternatives

- PVAC same-key encryption requires the secret mask key and cannot satisfy the secret-free sender boundary.
- A custom PVAC KEM/key wrap or an assertion that arithmetic ciphertext is an AEAD is not established or reviewed.
- Recipient-secret sharing, an online recipient service, shared Circle-owner credentials or grant-only access
  violates the boundary or confuses delivery with decryption.
- Reusing the amount-specific stealth domain without message/application separation is rejected.
- Deterministic production message IDs, plaintext-derived IDs, caller-supplied nonces/ephemerals and wallet signing
  seeds are rejected.
- External messaging protocols or a parallel relay stack are outside the owner direction.

## Security limits and review questions

Messages are non-deniable and transferable because the sender signature is public. `sender_public` is clear
metadata. A leaked view secret decrypts every message for that version, including permanently archived ciphertext.
Forward secrecy, post-compromise recovery and post-quantum confidentiality are not established. Rotation/revocation
does not erase copied keys, plaintext or history. Recipient anonymity is not established.

The expected-sender-signed controls record actual Mirage 2.1.0 behavior. All-zero, true `u = 1` (`01 00…00`),
both order-8 points (`e0eb…` and `5f9c…`), `p - 1`, `p`, and `p + 1` fail key exchange. The separate ordinary
all-`0x01` point and non-canonical all-`0xff` encoding reach AEAD and fail there. Fixed-width framing has no
separate short-ephemeral field. No claim is made that every non-canonical encoding is rejected by the native point
decoder. Executable/library/source identities are bound in the environment receipt.

Review must cover key custody, X25519 conversion and low-order/malformed points, static-recipient compromise,
domain separation, contact/key substitution, chosen-ciphertext/oracle behavior, replay atomicity, nonce and RNG
handling, key rotation/revocation, contact-store integrity and exact size/admission accounting. Small code changes
do not imply a small security change. Independent specialist review is required before calling this a secure mode.

## Prototype and rollback

Prototype only with independent synthetic endpoint keys in the approved isolated venue. No upstream write,
production promotion, validator change, shared-fakenet change or real-value transaction is authorized. Rollback is
removal of the app-local profile and test artifacts; there is no deployed chain state or modified primitive.
Unknown envelope versions and oversized inputs are rejected rather than downgraded.
