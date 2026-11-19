#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
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
{
  printf 'control_commit=%s\n' "$(git -C "$PROJECT" rev-parse HEAD)"
  printf 'messenger_tree_hash=%s\n' "$(git -C "$PROJECT" rev-parse HEAD:projects/onchain-messenger)"
  printf 'base_source_commit=%s\n' "$(git -C "$SOURCE" rev-parse HEAD)"
  printf 'driver_sha256=%s\n' "$(sha256sum "$SOURCE/_build/default/test/test_messenger_binary_io.exe" | awk '{print $1}')"
  printf 'runner_sha256=%s\n' "$(sha256sum "$PROJECT/tests/run_binary_io_tests.sh" | awk '{print $1}')"
  sha256sum "$SOURCE/test/test_messenger_binary_io.ml" \
    "$SOURCE/lib/vm/runtime/program_input.ml" "$SOURCE/lib/vm/runtime/contract.ml" \
    "$SOURCE/lib/vm/runtime/receipt_view.ml" "$SOURCE/lib/vm/rpc/contract_rpc.ml" \
    "$SOURCE/node_runtime/rpc_view.ml"
} > "$VENUE/receipts/binary-io-environment.txt"
