# Privacy statement

Target product language, valid only after the corresponding behavior is implemented and tested:

> Messages are end-to-end encrypted and stored on Octra. Sending accounts and transaction activity are public.
> Initial contact setup may reveal who is contacting whom.

A genuine recipient-only native path is now demonstrated through a thin binding: the sender uses an ephemeral
X25519 key and recipient public view material, while the recipient opens later with its own view secret. That is
not a deployed messenger, a chain-availability proof or an independent security audit.

## Native direction

- HFHE-PVAC and the closest existing Octra primitives remain mandatory. The selected route uses existing
  X25519, AES-GCM and Ed25519, with OCaml orchestration. No external messaging protocol is imported.
- Complete message ciphertext and required bootstrap/control records must remain in Octra state. A hash, relay
  body or external object-store pointer is not fully on-chain storage.
- Plaintext, private keys and recovery material remain with authorized endpoints. The sender never receives the
  recipient view secret. Validators and relays must not acquire endpoint decryption secrets.
- PVAC arithmetic encryption is measured separately as a same-key representation. It is not presented as a KEM
  or a substitute for the selected recipient path.
- Bounded common-feed scanning is demonstrated for 102 frames across two segments, with identical index rebuild
  and local recipient decryption. Production polling schedules, jitter, finality/completeness proofs and scale are
  not completed. Public view keys, bootstrap, grants, contact versions and policies may reveal recipients.

## Public and observable information

- Sending account, Ed25519 key/signature, account nonce, fee, target program, inclusion order and funding trail.
- Recipient view-key registration, key versions, initial contact setup, rotation and reply timing.
- Padded bucket or chunk count, native serialization size, timing, retries and account-linked ordering.
- RPC provider IP, submission origin, connection times, scan ranges and byte counts. Fresh/intermittent clients
  have distinctive catch-up patterns even without recipient-specific queries.
- A public view key or policy row can link a known recipient to ciphertext and accounts. No recipient-hiding
  claim follows merely from omitting a recipient field.

## Security properties still unestablished

Forward secrecy, post-compromise recovery and post-quantum confidentiality are not demonstrated. Static view
keys do not become forward-secret through rotation. Revocation/erasure does not retract copied keys or plaintext.
Native lifecycle objects can cancel future delivery without proving secure recovery or historical deletion.

Origin and integrity are implemented for the signed recipient envelope and AES-GCM body, not for PVAC arithmetic
ciphertext alone or a final production profile. The recipient-local receive store commits a dedup row and inbox
pointer after writing a per-message fsynced plaintext file, the outbox preserves exact retry bytes, and the
isolated segment rejects exact duplicate frames before mutation. Per-sender quotas prevent one sender from
exhausting the entire local allocation, but global caps can still be exhausted by multiple senders. Pruning
erased/out-of-grace rows forgets their replay history; such versions must not be reactivated in the same dedup
domain. Archived plaintext remains and counts toward the global byte cap.

Independent review of the new profile, contact registry, nonce handling and rotation is still required. B6 is
deferred to on-chain registration: the test contact-root secret is derived from a public constant and stored beside
its config, so the test signature is not production contact authentication. Secret key files and per-message
plaintext inbox files are mode 0600 but not encrypted at rest.

Messages are non-deniable and transferable: anyone with an envelope can show its public sender signature to a third
party. A leaked view secret decrypts every retained message for that version, including ciphertext harvested before
the leak and kept permanently on chain. Rotation does not provide forward secrecy or post-compromise recovery.

## Size and metadata evidence

The current recipient envelope has 161-byte header + 77-byte context + 28-byte nonce/tag. At 1, 2, 4 and 16 KiB,
envelopes are 1,290, 2,314, 4,362 and 16,650 bytes. The recipient view public key is 32 bytes, versus a
3,128,595-byte PVAC public key in the same-key representation. Full measurements are in
`docs/CIPHERTEXT-SIZES.md`; selected signed sizes and OU are measured in `receipts/chain/fees-and-sizes.json`.

HFHE does not hide sending accounts, transaction metadata or network timing. No anonymous sender, private social
graph, global traffic-analysis resistance, censorship immunity, guaranteed deletion or Signal-equivalent security
is claimed. Stronger anonymity needs separately reviewed unlinkable authorization/fees and network anonymity.

Accepted ciphertext and copies held by recipients, nodes, archives, backups or attackers cannot be erased later.
Local reporting and block lists affect display, not chain storage. Endpoint compromise, local plaintext history,
retained keys, swap, crash dumps and recipient disclosure remain outside chain confidentiality.
