# Privacy statement — experimental v2

Target product language, valid only after the corresponding behavior is implemented and independently reviewed:

> Messages are end-to-end encrypted and stored on Octra. Sending accounts and transaction activity are public.
> Initial contact setup may reveal who is contacting whom.

A recipient-only native path is demonstrated in the lab through a thin X25519/AES-GCM/Ed25519 binding. The sender
uses an ephemeral X25519 key and public recipient view material; the recipient opens later with a typed view secret.
That is not a deployed messenger, independent security acceptance or anonymity guarantee. The same-key PVAC spike
is removed from the active message path.

## Public and observable information

- Sending account, on-chain writer address, wallet Ed25519 key/signature, account nonce, fee, target circle,
  inclusion order and funding trail. Signatures make messages non-deniable and transferable to a third party.
- Recipient view-key registration, key versions, initial contact setup, rotation, reply timing and traffic volume.
- The random 16-byte sender instance, sequence and sender epoch. A stable instance per outbox contact links messages
  on that channel and distinguishes devices using one wallet; it is not an unlinkable authorization mechanism.
- Padded bucket/chunk count, native serialization size, retries, commit epochs and account-linked ordering. Archive
  reads do not hide these values or provide a freshness guarantee by themselves.
- Relay/RPC provider IP, submission origin, connection times, long-poll ranges and byte counts. Fresh/intermittent
  clients have distinctive catch-up patterns even without recipient-specific queries.
- Public view keys, contact cards and policies can link a known recipient to ciphertext and accounts. Omitting a
  recipient field or stable recipient-key hash does not provide recipient anonymity.

## Cryptographic and replay boundaries

The sender never receives the recipient view secret. Validators and relays must not acquire endpoint decryption
secrets. The receiver resolves the expected wallet key from its contact registry by address and verifies that binding
and the signature before context, version, policy, ECDH or AEAD runs. `octra:msg:sig:v2` is a labelled digest of the
exact header and ciphertext, not a transaction serialization.

Replay identity is a tagged OCE1/SHA-256 digest of the full channel, sequence and epoch, not the random message ID or
a sender/message-ID pair. Each outbox contact has an independent monotonic sequence and sender instance, so other
contacts and same-wallet devices do not consume one shared counter. Any forward jump advances the permanent window;
duplicates and old out-of-window sequences reject. Pruning inbox rows cannot erase replay history, but permanent
windows grow across channels and rotations and require an operational migration policy.

Live delivery uses bounded age and a two-epoch future tolerance. Archive reads use the frame's on-chain commit
epoch and reject only a sender epoch after that commit. Archive mode is not a replay bypass and does not make
ciphertext, sender metadata, timing or traffic private.

Cross-device history and relayed messages can have different commit states. A relayed message that never commits
must remain marked `uncommitted`; delivery is not proof of chain inclusion. A relay restart does not erase
already-committed history, but an offline mailbox is not a durability guarantee. An uncommitted message can be
lost if the sender's only device dies.

## Security properties still unestablished

Forward secrecy, post-compromise recovery and post-quantum confidentiality are not demonstrated. Static view keys
do not become forward-secret through rotation. Revocation/erasure cannot retract copied keys, plaintext or history.
A leaked view secret decrypts every retained ciphertext for that version, including harvest-now archives.

Contact registration is deferred to on-chain registration. Demo contact cards are public-constant-derived test fixtures, not
a production trust root. Local policy acquisition is not a finalized chain authority. Secret key files and
per-message plaintext inbox files are mode 0600 but not encrypted at rest. Crash injection is not power-loss
certification, and an orphan plaintext file can remain after a crash before state rename.

HFHE does not hide sending accounts, transaction metadata or network timing. No anonymous sender, private social
graph, global traffic-analysis resistance, censorship immunity, guaranteed deletion or Signal-equivalent security
is claimed. Stronger anonymity needs separately reviewed unlinkable authorization/fees and network anonymity.
Accepted ciphertext and copies held by recipients, nodes, archives, backups or attackers cannot be erased later.
Local reporting and block lists affect display, not chain storage. Endpoint compromise, retained keys, swap,
crash dumps and recipient disclosure remain outside chain confidentiality.
