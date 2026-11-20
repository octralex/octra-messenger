# webcli with the messenger app

This directory is octra-labs/webcli at `a9a6ce67a5818fa6913fa0039b9dd62f3aeac4f4` with one addition: a messenger
in the apps list. It is experimental and for devnet only.

## What was added

- `static/messenger.html`, `static/messenger.js`: the app page, and one button in the apps view of
  `static/index.html`.
- `static/messenger-config.json`: the address of the shared directory program on devnet.
- `static/messenger-segment.aml`: a copy of `../programs/segment.aml`, deployed as each user's mailbox.
- `messenger_bridge.py`: seals and opens envelopes by running the `octra_messenger` endpoint.
- `main.cpp`: one route, `POST /api/messenger/(card|seal|open|history)`, which passes the request and the loaded
  wallet's key to the bridge. Everything on chain uses the existing program routes and the wallet's own signing.

## Install

You need what webcli needs (a C++17 compiler, OpenSSL, LevelDB), Python 3, and the OCaml toolchain that builds
lite_node at `8f785a93`. The endpoint links against lite_node, so that build is the heavy part.

```bash
OCTRA_OPAM_SWITCH=/path/to/lite_node/switch ./setup-messenger.sh
./octra_wallet 8420
```

`setup-messenger.sh` builds `octra_wallet` with `make` and the endpoint with `../tests/build_endpoint.sh`. That
script was written for our build host: it expects the lite_node runtime libraries under `/srv/octra-node/runtime-libs`.
On another machine, edit the four `ln -sf` lines and `LD_LIBRARY_PATH` in it to point at your libev, leveldb, snappy
and lmdb. It has only been built on Linux x86-64.

Start the wallet from this directory, open the link it prints, switch the network menu to devnet, then create or
import a wallet and fund it.

## Use

1. Open **apps → messenger** and enter your wallet PIN. It stays in the tab and signs your transactions.
2. Click **create my mailbox** once. This deploys your mailbox program and registers it in the directory.
3. Paste your contact's wallet address and click **open chat**. This publishes a key for that contact in your
   mailbox. Your contact does the same with your address.
4. Send. A message is readable by your contact after its transaction confirms, about one devnet epoch.

**Pay privately** sends OCT with the amount encrypted on chain, using the wallet's stealth transfer. You need a
registered encryption key and an encrypted balance first; do both in the main wallet tab. Building the transfer
takes about a minute. Your contact gets a payment bubble and claims it into their encrypted balance. The claimed
amount is read from the chain, not from the message.

## Limits

- Contact keys are signed by a fixed test key, not by a registration your contact controls. Treat it as a
  demonstration of the flow, not as authenticated contact setup.
- The mailbox holds 1,024 messages of up to 1,000 bytes. There is no rollover in the app yet.
- Sending accounts, timing and message counts are public. See `../docs/PRIVACY.md`.
- Message history and keys are stored unencrypted under `data/messenger/`.
