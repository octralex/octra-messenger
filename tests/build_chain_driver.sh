#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
set -euo pipefail

# Builds tests/chain_driver.ml inside a lite_node checkout at the pinned commit.
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${OCTRA_NODE_SOURCE:?set OCTRA_NODE_SOURCE to a lite_node checkout at 8f785a93}
OUTPUT=${1:?usage: build_chain_driver.sh OUTPUT}
JOBS=${BUILD_JOBS:-2}

cp "$PROJECT/tests/chain_driver.ml" "$SOURCE/test/chain_driver.ml"
if ! grep -q '(name chain_driver)' "$SOURCE/test/dune"; then
  printf '\n(executable\n (name chain_driver)\n (modules chain_driver)\n (libraries octra_net octra_core octra_vm lwt.unix cohttp-lwt-unix yojson base64 digestif mirage-crypto-rng.unix unix))\n' >> "$SOURCE/test/dune"
fi
python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" --profile release -j "$JOBS" test/chain_driver.exe
install -m 755 "$SOURCE/_build/default/test/chain_driver.exe" "$OUTPUT"
