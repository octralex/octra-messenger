#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
set -euo pipefail

PIN=8f785a93a4e7392a0f3e65674f9de89854d33dbc
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=${MESSENGER_SCRATCH:-/srv/octra-node/fakenet-kimi-messenger}
SOURCE=${OCTRA_NODE_SOURCE:-$SCRATCH/devnet-src/lite_node}
UPSTREAM=${OCTRA_UPSTREAM_CLONE:-/home/kimi/workspace/upstream-heads/lite_node}
SWITCH=${OCTRA_OPAM_SWITCH:-/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml}
JOBS=${BUILD_JOBS:-2}

if [ ! -d "$SOURCE/.git" ]; then
  mkdir -p "$SCRATCH"
  git clone --shared "$UPSTREAM" "$SOURCE"
fi
git -C "$SOURCE" checkout --quiet --detach "$PIN"
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN"
for patch in "$PROJECT/native/byte-literals.patch" "$PROJECT/native/circle-typed-storage.patch"; do
  if git -C "$SOURCE" apply --reverse --check "$patch" 2>/dev/null; then
    :
  else
    git -C "$SOURCE" apply --check "$patch"
    git -C "$SOURCE" apply "$patch"
  fi
done

cp "$PROJECT/tests/segment_spike_driver.ml" "$SOURCE/test/messenger_segment_spike.ml"
sed -i 's/(modules messenger_segment_spike encode)/(modules messenger_segment_spike)/' "$SOURCE/test/dune"
sed -i 's/(libraries octra_vm octra_core zarith base64 lwt.unix unix digestif yojson)/(libraries octra_net octra_circle_runtime octra_vm octra_core zarith base64 lwt.unix unix digestif yojson)/' "$SOURCE/test/dune"
sed -i 's/(libraries octra_net octra_vm octra_core zarith/(libraries octra_net octra_circle_runtime octra_vm octra_core zarith/' "$SOURCE/test/dune"
if ! grep -q '(name messenger_segment_spike)' "$SOURCE/test/dune"; then
  printf '\n(test\n (name messenger_segment_spike)\n (modules messenger_segment_spike)\n (libraries octra_net octra_circle_runtime octra_vm octra_core zarith base64 lwt.unix unix digestif yojson))\n' >> "$SOURCE/test/dune"
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

python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" --profile release -j "$JOBS" test/messenger_segment_spike.exe

stamp=$(date -u +%Y%m%dT%H%M%SZ)
export MESSENGER_REGISTRY_SOURCE="$PROJECT/programs/segment_registry.aml"
for profile in scoped legacy; do
  store="$SCRATCH/store-$profile-$stamp"
  "$SOURCE/_build/default/test/messenger_segment_spike.exe" \
    "$PROJECT/programs/segment_spike.aml" "$store" "$profile" \
    > "$PROJECT/receipts/phase0/segment-runtime-$profile.txt" 2>&1
  tail -1 "$PROJECT/receipts/phase0/segment-runtime-$profile.txt"
done
cp "$store.bytecode.b64" "$SCRATCH/segment-bytecode-v2.b64"

{
  printf 'source_commit=%s\n' "$PIN"
  printf 'control_commit=%s\n' "$(git -C "$PROJECT" rev-parse HEAD)"
  printf 'messenger_tree_hash=%s\n' "$(git -C "$PROJECT" rev-parse HEAD:projects/onchain-messenger)"
  printf 'runner_sha256=%s\n' "$(sha256sum "$PROJECT/tests/run_segment_spike.sh" | awk '{print $1}')"
  printf 'ocaml=%s\n' "$(ocamlc -version)"
  printf 'dune=%s\n' "$(dune --version)"
  printf 'kernel=%s\n' "$(uname -srmo)"
  printf 'driver_sha256=%s\n' "$(sha256sum "$SOURCE/_build/default/test/messenger_segment_spike.exe" | awk '{print $1}')"
  printf 'source_sha256=%s\n' "$(sha256sum "$PROJECT/programs/segment_spike.aml" | awk '{print $1}')"
  printf 'registry_source_sha256=%s\n' "$(sha256sum "$PROJECT/programs/segment_registry.aml" | awk '{print $1}')"
  printf 'byte_literals_patch_sha256=%s\n' "$(sha256sum "$PROJECT/native/byte-literals.patch" | awk '{print $1}')"
  printf 'circle_typed_storage_patch_sha256=%s\n' "$(sha256sum "$PROJECT/native/circle-typed-storage.patch" | awk '{print $1}')"
  printf 'circle_typed_storage_scope=lab_runtime_only_upstream_acceptance_not_claimed\n'
  printf 'byte_literals_scope=lab_compiler_only_no_new_vm_opcode\n'
} > "$PROJECT/receipts/phase0/environment.txt"
