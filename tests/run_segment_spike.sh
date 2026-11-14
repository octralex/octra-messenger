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

cp "$PROJECT/tests/segment_spike_driver.ml" "$SOURCE/test/messenger_segment_spike.ml"
if ! grep -q '(name messenger_segment_spike)' "$SOURCE/test/dune"; then
  printf '\n(test\n (name messenger_segment_spike)\n (modules messenger_segment_spike)\n (libraries octra_vm octra_core zarith base64 lwt.unix unix digestif yojson))\n' >> "$SOURCE/test/dune"
fi

mkdir -p "$SOURCE/mcl/obj" "$SOURCE/mcl/lib" "$SCRATCH/tmp" "$SCRATCH/link-libs" "$PROJECT/receipts/phase0"
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

dune build --root "$SOURCE" --profile release -j "$JOBS" test/messenger_segment_spike.exe

stamp=$(date -u +%Y%m%dT%H%M%SZ)
for profile in scoped legacy; do
  store="$SCRATCH/store-$profile-$stamp"
  "$SOURCE/_build/default/test/messenger_segment_spike.exe" \
    "$PROJECT/programs/segment_spike.aml" "$store" "$profile" \
    > "$PROJECT/receipts/phase0/segment-runtime-$profile.txt" 2>&1
  tail -1 "$PROJECT/receipts/phase0/segment-runtime-$profile.txt"
done

{
  printf 'source_commit=%s\n' "$PIN"
  printf 'ocaml=%s\n' "$(ocamlc -version)"
  printf 'dune=%s\n' "$(dune --version)"
  printf 'kernel=%s\n' "$(uname -srmo)"
  printf 'driver_sha256=%s\n' "$(sha256sum "$SOURCE/_build/default/test/messenger_segment_spike.exe" | awk '{print $1}')"
  printf 'source_sha256=%s\n' "$(sha256sum "$PROJECT/programs/segment_spike.aml" | awk '{print $1}')"
} > "$PROJECT/receipts/phase0/environment.txt"
