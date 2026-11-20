#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
set -euo pipefail

# Builds the messenger endpoint against lite_node at the pinned commit and installs it at OUTPUT.
OUTPUT=${1:?usage: build_endpoint.sh OUTPUT}

PIN=8f785a93a4e7392a0f3e65674f9de89854d33dbc
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=${MESSENGER_SCRATCH:?set MESSENGER_SCRATCH to a build directory}
SOURCE=${OCTRA_NODE_SOURCE:-$SCRATCH/devnet-src/lite_node}
UPSTREAM=${OCTRA_UPSTREAM_CLONE:-https://github.com/octra-labs/lite_node}
SWITCH=${OCTRA_OPAM_SWITCH:-/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml}
JOBS=${BUILD_JOBS:-2}

if [ ! -d "$SOURCE/.git" ]; then
  mkdir -p "$SCRATCH/devnet-src"
  git clone "$UPSTREAM" "$SOURCE"
fi
git -C "$SOURCE" checkout --quiet --detach "$PIN"
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN"
mkdir -p "$PROJECT/vendor" "$PROJECT/lib/core" "$SCRATCH/tmp" "$SCRATCH/link-libs" "$SCRATCH/receipts" \
  "$SOURCE/mcl/obj" "$SOURCE/mcl/lib"
rm -rf "$PROJECT/vendor/lite_node" "$PROJECT/lib/core/circle_wasm_native"
mkdir -p "$PROJECT/vendor/lite_node"
tar -C "$SOURCE" --exclude='./.git' --exclude='./_build' -cf - . | tar -C "$PROJECT/vendor/lite_node" -xf -
rm -f "$PROJECT/vendor/lite_node/dune-project"
sed -i 's/(:standard \\ runtime_data)/lib net logging crypto_guard pvac_ffi zk_ffi/' "$PROJECT/vendor/lite_node/dune"
rm -rf "$PROJECT/pvac"
sed -Ei 's|ROOT=\$\(cd [^)]* && pwd\)|ROOT=$(cd %{workspace_root}/vendor/lite_node \&\& pwd)|' "$PROJECT/vendor/lite_node/lib/core/dune"
cp -a "$SOURCE/pvac" "$PROJECT/"
for native in core net log crypto_guard consensus; do
  case "$native" in
    core) path=lib/core ;;
    net) path=net ;;
    log) path=logging ;;
    crypto_guard) path=crypto_guard ;;
    consensus) path=lib/consensus ;;
    pvac_ffi) path=pvac_ffi ;;
    zk_ffi) path=zk_ffi ;;
  esac
  sed -i "s/^ (name octra_${native})$/ (name octra_${native})\n (public_name octra_${native})/" "$PROJECT/vendor/lite_node/$path/dune"
done
sed -i 's/^ (name pvac_ffi)$/ (name pvac_ffi)\n (public_name pvac_ffi)/' "$PROJECT/vendor/lite_node/pvac_ffi/dune"
sed -i 's/^ (name zk_ffi)$/ (name zk_ffi)\n (public_name zk_ffi)/' "$PROJECT/vendor/lite_node/zk_ffi/dune"
if [ ! -f "$SOURCE/mcl/lib/libmcl.a" ]; then
  make -C "$SOURCE/mcl" MCL_FP_BIT=256 MCL_FR_BIT=256 lib/libmcl.a -j"$JOBS"
fi
ln -sf /usr/lib/x86_64-linux-gnu/liblmdb.so.0.0.0 "$SCRATCH/link-libs/liblmdb.so"
ln -sf /srv/octra-node/runtime-libs/libev.so.4 "$SCRATCH/link-libs/libev.so"
ln -sf /srv/octra-node/runtime-libs/libleveldb.so.1d "$SCRATCH/link-libs/libleveldb.so"
ln -sf /srv/octra-node/runtime-libs/libsnappy.so.1 "$SCRATCH/link-libs/libsnappy.so"
eval $(opam env --switch="$SWITCH" --set-switch)
export LIBRARY_PATH="$SCRATCH/link-libs"
export LD_LIBRARY_PATH="/srv/octra-node/runtime-libs:$SCRATCH/link-libs"
export TMPDIR="$SCRATCH/tmp"
export OCTRA_NODE_SOURCE="$SOURCE"
export OCTRA_SRC_ROOT="$SOURCE"
export CARGO_HOME="$SCRATCH/cargo-home"
python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$PROJECT" \
  --build-dir "$SCRATCH/library-build" --profile release -j "$JOBS" \
  tests/recipient_endpoint.exe
install -m 755 "$SCRATCH/library-build/default/tests/recipient_endpoint.exe" "$OUTPUT"
