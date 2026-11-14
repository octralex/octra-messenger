# Recipient encryption disposition

Disposition: **existing Octra-native X25519/AES-GCM recipient path demonstrated through a thin message-profile
binding**. It is experimental and open for independent review, not a production security claim or a claim that
PVAC arithmetic encryption is a KEM. The design is in `docs/NATIVE-RECIPIENT-EXTENSION.md`; measurements are in
`docs/CIPHERTEXT-SIZES.md`.

## Inspected scope

Current identities at verification:

- lite_node `3aab2d992035076dd216ad8808710d3a5a56063a`, also the deployed source commit; running binary SHA-256
  `c56f152ba4eb2372c1ecde446f1ac7feb932b8b3adc900e3701258e0a02ea208`.
- webcli `28208507bf704b9d2726dd48cb6597319c594688`, also the deployed source commit; executable SHA-256
  `93702748d072725ebebf564c55bf35b38ecb481bad4c09f02fef6520e3e6db3a`.
- Deployed `libpvac.so` SHA-256 `fc72588467f5e84f34323de51b50b83bd8cb74c7b91b2cbfb7c150a365984357`.
  The PVAC C API still passes both `pvac_pubkey` and `pvac_seckey` to `pvac_enc_value_seeded`.
- Upstream `main` matched those lite_node and webcli commits when checked before review.

The prior `c49de45c` results remain historical baselines and were not silently treated as current evidence.

## Candidate comparison

| Candidate and exact owning path | Key and trust graph | Arbitrary bytes / offline recipient | Context and integrity | Serialized cost / activation | Disposition and evidence |
| --- | --- | --- | --- | --- | --- |
| `Pvac_ffi.enc_value_seeded` / `enc_values_seeded`; `pvac::enc_value_seeded`; webcli `PvacBridge.encrypt` | Encryption requires the secret key used for the mask. A separate sender cannot use only recipient public material. | Scalar/vector values are supported, but not a secret-free sender. Recipient can decrypt later. | Arithmetic ciphertext and amount proofs are not an application AEAD or expected-sender check. | One-slot ciphertext about 43 KB; PVAC public key 3,128,595 bytes. Native client primitive; chain profile is separate. | **Unsuitable for the required sender boundary.** Same-key representation retained only for measurement. |
| Native key switch / recrypt, `Pvac_ffi.make_evalkey`, `Private_ledger` key-switch plans | Key ownership/migration proofs and evaluation material are required; it transforms encrypted balances. | Not a general message-encryption API. | Migration integrity is not arbitrary-message authorization or replay state. | Evaluation material size not measured; migration rules are chain-specific. | **Unsuitable for v1 messages.** No evidence that it carries arbitrary recipient messages safely. |
| Circle sealed resources and `Circle_sealed` | Passphrase/circle/key IDs and owner-controlled resources. | No public recipient message-encryption operation. | KDF/digest and access checks, not an authenticated arbitrary-message envelope. | No ciphertext output to reuse; sealed-read resource mode. | **Unsuitable as a message cipher.** Do not treat its digest as AEAD. |
| Key policies, grants, object membership, HFHE policy | Lifecycle and access policy rows, not necessarily decryption keys. | Delivery can expire/revoke; does not establish decryption capability. | Activation/expiry/revocation/erasure states and policy checks. | Small policy objects; native Circle operations. | **Supporting lifecycle only.** A grant is not a decryption grant. |
| Outbox/relay/ingress and `delivery_key_id` | Relay claims and delivery policy, not recipient secret geometry. | Offline delivery is possible; no message cryptography is implied. | Intent/status/expiry and payload hashes. | Hash/reference overhead; full ciphertext still must be retained in Octra state. | **Transport support only.** No off-chain body or relay-only substitution. |
| `Crypto.StealthAddress`: `generate_ephemeral`, `ecdh_shared_secret`, `encrypt_stealth_amount`, `decrypt_amount_for_validator`; webcli stealth send | Fresh ephemeral X25519 sender key + recipient public view key; recipient needs only its view secret later. Sender needs no recipient secret. | Existing amount payload. Recipient can be offline. Public view key registration is small. | Existing AES-GCM amount path, with amount-specific domain; arbitrary message domain/profile was missing. | 32-byte view key, 32-byte ephemeral key, 12-byte nonce + 16-byte tag. Existing private-transfer primitive. | **Usable through thin binding.** `Recipient_message` adds domain separation, canonical envelope, expected-sender and policy/replay checks. |

No candidate was rejected by name search alone: the PVAC C API, OCaml FFI, client bridge, key lifecycle, sealed
resources and native stealth calls were traced to implementation and key material requirements.

## Demonstrated key boundary

`tests/run_recipient_spike.sh` starts separate sender and recipient processes with independent synthetic keys.
The sender receives only its own Ed25519 secret, recipient public view material and plaintext. The recipient is
offline for sealing and later opens the envelope with its local view secret. No helper receives the recipient
secret. `strace` records the sender opening only its own secret, public configuration and plaintext; it contains
no `recipient-secret` open.

The sanitized access description is in `receipts/recipient/access.json`; secret files and replay state are not
published. Positive results:

- offline recipient recovers the exact 33-byte plaintext;
- production sends of equal plaintext have distinct random IDs, ephemerals, nonces and envelopes and both decrypt;
- a newly generated recipient key/version 2 succeeds, and a genuinely unread version 1 message opens during grace;
- a dedicated X25519 messaging key is independent of the synthetic Ed25519 identity and its legacy derived view key;
- sender authentication is checked against independently configured expected-sender material, not merely a
  self-supplied public key;
- concurrent duplicates produce one commit, crash-before-rename permits recovery, and crash-after-rename retains
  the inbox record and rejects replay after restart;
- plaintext lives in per-message fsynced files, while state holds only dedup rows and pointer metadata;
- per-sender record and byte quotas reject the exhausted sender but still allow a second authorized sender;
  separate global record and byte caps reject without changing state;
- erased/out-of-grace dedup and pointer rows are pruned, with replay-history loss and archived-plaintext retention
  stated in the profile;
- the durable outbox returns byte-identical envelopes after submitted/finalized transitions;
- the exact plaintext cap round-trips and cap-plus-one is rejected.

Raw output is in `receipts/recipient/endpoint.txt` and `receipts/recipient/sender.strace`. Executable identities,
compiler/lock metadata and native source hashes are in `receipts/recipient/environment.json` and
`receipts/recipient/sizes-environment.json`.

## Negative controls

Every required case rejects with no plaintext output and unchanged dedup-plus-inbox state:

- a coherent independently seeded wrong recipient reaches AEAD; configuration/key mismatch remains a separate guard;
- actual ephemeral byte 33 and message-ID byte 17 mutations fail sender authentication;
- expected-sender re-signed ID, version, context and ephemeral mutations over the old body fail AEAD;
- all-zero, true `u = 1` (`01 00…00`), both order-8 points, `p - 1`, `p` and `p + 1` fail the pinned Mirage
  2.1.0 key exchange; the separate ordinary all-`0x01` and non-canonical all-`0xff` controls reach AEAD and fail
  there; fixed-width framing does not admit a separately encoded 31-byte field;
- wrong chain/application/context, unexpected sender, old version outside grace and contact tampering;
- modified body/header/context/signature, truncation, trailing bytes, unsupported version and malformed ciphertext;
- replay, revoked/erased/not-yet-active/expired policy, key-version overflow and cap-plus-one.

Each detailed test error is matched to its own invocation. The public boundary emits exactly one JSON
`{"status":"rejected"}` object without detailed error text. Authentication and AEAD failures do not produce
plaintext or advance dedup state. Selected-profile chosen-ciphertext/oracle and contact-registry risks still need
independent review.

## Measured representation

The current envelope has a 161-byte fixed header and 77-byte context. AES-GCM adds 12 nonce bytes and 16 tag
bytes, so total overhead is 266 bytes. A 33-byte chat plaintext becomes a 299-byte envelope. At 1, 2, 4 and
16 KiB, envelopes are 1,290, 2,314, 4,362 and 16,650 bytes. Base64/JSON sizes are 1,722, 3,090, 5,818 and
22,202 bytes. The selected 32-byte view key costs 46 bytes including base64 and JSON quotes, versus 3,128,595 bytes and
4,171,462 bytes for the PVAC public key and base64 string.

`receipts/recipient/sizes.csv` contains all lengths and payload classes, including zero length, valid multilingual
UTF-8 assembled from whole codepoints, repetitive/random/embedded-zero data, one cold plus four warm repetitions,
separate warm and overall maxima, allocation and peak RSS. Only positive round trips are in this sweep; negative
controls are in `endpoint.txt`. Selected signed sizes and OU are measured in `receipts/chain/fees-and-sizes.json`.
Bucket candidates are not frozen.

The routine envelope no longer serializes a stable recipient-key hash. The hash remains a locally derived
KDF input only. Public view-key registration, contact versions and traffic patterns can still identify a
recipient; this is improved metadata minimization, not an anonymity guarantee.

## Remaining work

- Independent specialist review of the message-domain/profile, contact/key substitution, static-recipient-key
  compromise, replay atomicity, nonce handling and rotation/revocation semantics.
- Production contact/policy integration, committed feed completeness, explicit fee-burn accounting, and
  10,000/100,000-frame retention plus normal-transaction interference measurements. The isolated registry/segment,
  signed encoding, OU, recovery and 102-frame evidence are complete only for the disclosed prototype profile.
- **B6 is deferred to on-chain contact registration.** The test contact root secret is derived from a public
  constant and stored beside the config it signs; its signature does not establish production contact integrity.
- Encrypted secret persistence, production key recovery and chain-integrated policy/contact acquisition. Local
  secret files and per-message plaintext inbox files are mode 0600, not encrypted at rest. Crash injection is not
  a power-loss certification. The 1,000-record/51,200,000-byte per-sender and 10,000-record/512,000,000-byte
  global caps require an operational migration before global exhaustion. Pruning erased/out-of-grace rows forgets
  their replay history and retains archived plaintext; such versions must not be reactivated in the same domain.
- Messages are non-deniable and transferable. A leaked view secret exposes every retained ciphertext for that
  version, including harvest-now archives. Forward secrecy, post-compromise recovery and post-quantum
  confidentiality remain unestablished. Static view keys and public contact/policy metadata can link recipients
  and accounts.
