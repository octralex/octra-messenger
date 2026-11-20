# On-chain messenger

An OCaml implementation of an on-chain Octra messenger built on lite_node's own primitives. It is experimental: do
not use it for real conversations or on mainnet. `docs/SCHEME.md` is the one-page description.

## What is here

- `lib/` is one dune library, `octra_messenger`, on `octra_net` and `octra_core`.
  - `crypto/`: the envelope. A fresh X25519 ephemeral key per message, HMAC-SHA256 key derivation, AES-GCM, and an
    Ed25519 signature by the sender's Octra wallet key. Opening verifies the signature against the key resolved from
    the contact's wallet address before anything else is checked.
  - `protocol/`: frame, context, cursor and page codecs, the freshness rule and the channel identity.
  - `storage/`: the outbox journal (a sequence is persisted before sealing) and the receive store (one locked,
    fsynced commit of plaintext, replay window and inbox record).
  - `chain/`: binds a frame's on-chain caller to the envelope's sender key.
- `programs/` holds the segment and registry programs. They are deployed from source, so no release signature or
  node change is needed.
- `tests/` holds the endpoint, size and protocol suites, the transaction driver and the devnet run.
- `receipts/` holds the outputs of those runs.

All hashes and signing payloads use `Octra_net.Hash_domain` with `Octra_net.Oce1` fields and their own
`octra:msg:<object>:v2` label. Codecs carry a type tag and a u16 version and dispatch on it. Only v2 exists.

## State

- The library suites pass at lite_node `8f785a93`: the recipient endpoint controls, 5,001 protocol cases and a
  19-row size sweep.
- The full path runs on devnet: deploy both programs, append a 2,048-byte frame, read it back through the public
  view, bind the stored caller to the signer and decrypt. The same run records terminal rejections for a duplicate
  frame, a 2,049-byte frame, a non-writer append, non-owner grant, close and publish, and an append after close.
  See `receipts/devnet/devnet-program.json`.

Not done: contact and key registration on chain, chunking of large messages, packing several envelopes per frame,
encrypted key storage and backup, retention and load measurements, a client and a relay. There is no forward
secrecy, post-compromise recovery, recipient anonymity or post-quantum protection.

## Run

The suites build against a lite_node checkout at the pinned commit with its OCaml switch.

```bash
tests/run_recipient_spike.sh      # endpoint suite
tests/run_size_sweep.sh           # size sweep
tests/build_chain_driver.sh       # transaction driver
tests/run_devnet_program.py       # devnet run, needs two funded test wallets
```

`run_devnet_program.py` reads `MESSENGER_DEVNET_WORK` (a directory holding `owner-wallet.json` and
`other-wallet.json`), `MESSENGER_CHAIN_DRIVER`, `MESSENGER_ENDPOINT` and optionally `MESSENGER_DEVNET_RPC`.

## Documents

- `docs/SCHEME.md`: the scheme on one page.
- `docs/PROTOCOL.md`: codecs, signature and replay rules, storage and the on-chain programs.
- `docs/PRIVACY.md`: what an observer sees.
- `docs/CIPHERTEXT-SIZES.md`: measured envelope sizes.
