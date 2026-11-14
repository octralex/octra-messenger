#!/usr/bin/env bash
set -euo pipefail

VENUE=${MESSENGER_CHAIN_VENUE:-/srv/octra-node/fakenet-kimi-messenger}
SOURCE=${OCTRA_NODE_SOURCE:-$VENUE/node-src/lite_node}
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SWITCH=${OCTRA_OPAM_SWITCH:-/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml}

cp "$PROJECT/tests/messenger_binary_io.ml" "$SOURCE/test/test_messenger_binary_io.ml"
if ! grep -q '(name test_messenger_binary_io)' "$SOURCE/test/dune"; then
  printf '\n(test\n (name test_messenger_binary_io)\n (modules test_messenger_binary_io)\n (libraries octra_vm octra_node_runtime yojson base64))\n' >> "$SOURCE/test/dune"
fi
mkdir -p "$VENUE/tmp" "$VENUE/receipts"
eval $(opam env --switch="$SWITCH" --set-switch)
export LIBRARY_PATH="$VENUE/link-libs"
export LD_LIBRARY_PATH="/srv/octra-node/runtime-libs:$VENUE/link-libs"
export TMPDIR="$VENUE/tmp"
python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" --profile release -j 2 test/test_messenger_binary_io.exe
"$SOURCE/_build/default/test/test_messenger_binary_io.exe" | tee "$VENUE/receipts/binary-io-unit.txt"
