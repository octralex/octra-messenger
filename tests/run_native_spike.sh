#!/usr/bin/env bash
set -euo pipefail

PIN=c49de45cf49ebbc2e5c0697eb956cbcada5845e7
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=${MESSENGER_SCRATCH:-/var/lib/octra/kimi-work/scratch/onchain-messenger-phase0}
SOURCE=${OCTRA_NODE_SOURCE:-$SCRATCH/lite_node}
UPSTREAM=${OCTRA_UPSTREAM_CLONE:-/home/kimi/workspace/upstream-heads/lite_node}
SWITCH=${OCTRA_OPAM_SWITCH:-/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml}
JOBS=${BUILD_JOBS:-2}

if [ ! -d "$SOURCE/.git" ]; then
  mkdir -p "$SCRATCH"
  git clone --shared "$UPSTREAM" "$SOURCE"
fi
git -C "$SOURCE" checkout --quiet --detach "$PIN"
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN"

cp "$PROJECT/lib/crypto/pvac_message.ml" "$SOURCE/test/pvac_message.ml"
cp "$PROJECT/tests/native_spike_driver.ml" "$SOURCE/test/messenger_native_spike.ml"
if ! grep -q '(name messenger_native_spike)' "$SOURCE/test/dune"; then
  printf '\n(executable\n (name messenger_native_spike)\n (modules messenger_native_spike pvac_message)\n (libraries pvac_ffi mirage-crypto-ec digestif unix))\n' >> "$SOURCE/test/dune"
fi

mkdir -p "$SCRATCH/tmp" "$SCRATCH/link-libs" "$PROJECT/receipts/native"
ln -sf /usr/lib/x86_64-linux-gnu/liblmdb.so.0.0.0 "$SCRATCH/link-libs/liblmdb.so"
ln -sf /srv/octra-node/runtime-libs/libev.so.4 "$SCRATCH/link-libs/libev.so"
ln -sf /srv/octra-node/runtime-libs/libleveldb.so.1d "$SCRATCH/link-libs/libleveldb.so"
ln -sf /srv/octra-node/runtime-libs/libsnappy.so.1 "$SCRATCH/link-libs/libsnappy.so"

eval $(opam env --switch="$SWITCH" --set-switch)
export LIBRARY_PATH="$SCRATCH/link-libs"
export LD_LIBRARY_PATH="/srv/octra-node/runtime-libs:$SCRATCH/link-libs"
export TMPDIR="$SCRATCH/tmp"

dune build --root "$SOURCE" --profile release -j "$JOBS" test/messenger_native_spike.exe
/usr/bin/time -v "$SOURCE/_build/default/test/messenger_native_spike.exe" > "$PROJECT/receipts/native/spike.txt" 2>&1

{
  printf 'source_commit=%s\n' "$PIN"
  printf 'webcli_commit=28208507bf704b9d2726dd48cb6597319c594688\n'
  printf 'ocaml=%s\n' "$(ocamlc -version)"
  printf 'dune=%s\n' "$(dune --version)"
  printf 'kernel=%s\n' "$(uname -srmo)"
  printf 'driver_sha256=%s\n' "$(sha256sum "$SOURCE/_build/default/test/messenger_native_spike.exe" | awk '{print $1}')"
  printf 'module_sha256=%s\n' "$(sha256sum "$PROJECT/lib/crypto/pvac_message.ml" | awk '{print $1}')"
} > "$PROJECT/receipts/native/environment.txt"
cat "$PROJECT/receipts/native/spike.txt"
