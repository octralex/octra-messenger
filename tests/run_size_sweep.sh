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
  mkdir -p "$SCRATCH/devnet-src"
  git clone --shared "$UPSTREAM" "$SOURCE"
fi
git -C "$SOURCE" checkout --quiet --detach "$PIN"
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN"
mkdir -p "$PROJECT/vendor" "$PROJECT/lib/core" "$SCRATCH/tmp" "$SCRATCH/link-libs" "$SCRATCH/receipts" \
  "$PROJECT/receipts/recipient" "$SOURCE/mcl/obj" "$SOURCE/mcl/lib"
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
  tests/recipient_endpoint.exe tests/size_sweep.exe
/usr/bin/time -v "$SCRATCH/library-build/default/tests/size_sweep.exe" > "$PROJECT/receipts/recipient/sizes.csv" 2> "$PROJECT/receipts/recipient/sizes-time.txt"
python3 - "$PROJECT/receipts/recipient/sizes.csv" "$SCRATCH/receipts/sizes-validation.json" <<'PY'
import csv,json,sys
from pathlib import Path
with open(sys.argv[1],newline='') as source:
    lines=[line for line in source if not line.startswith('#')]
rows=list(csv.DictReader(lines))
assert rows and all(None not in row and all(value is not None for value in row.values()) for row in rows)
assert len(rows) == 19, len(rows)
assert all(row['status'] == 'pass' and row['route'] == 'recipient-x25519-aes-gcm' for row in rows)
for row in rows:
    assert float(row['seal_overall_max_ms']) >= float(row['seal_warm_max_ms'])
    assert float(row['seal_overall_max_ms']) >= float(row['seal_cold_ms'])
    assert float(row['open_overall_max_ms']) >= float(row['open_warm_max_ms'])
    assert float(row['open_overall_max_ms']) >= float(row['open_cold_ms'])
    assert int(row['envelope_overhead']) == int(row['envelope_bytes']) - int(row['plaintext_bytes']) == 308
utf8=[row for row in rows if row['kind'] == 'utf8']
assert len(utf8) == 1 and utf8[0]['plaintext_bytes'] == '128'
report={'schema_columns':len(rows[0]),'data_rows':len(rows),'positive_round_trip_rows':len(rows),
  'unsupported_rows':0,'samples_per_measured_case':5,'cold_samples':1,'warm_samples':4,
  'codec_version':2,'header_bytes':194,'context_bytes':86,'envelope_overhead_bytes':308,
  'same_key_pvac_path':'removed from the active library and size sweep',
  'utf8_fixture':'whole UTF-8 codepoints selected to the exact 128-byte length; never byte-sliced',
  'negative_controls':'endpoint.txt only; no negative-control claim is made for size rows',
  'deterministic_seal':'testkit RNG invokes the same production v2 seal; production inputs expose no ID/ephemeral/nonce overrides',
  'csv_sha256':__import__('hashlib').sha256(Path(sys.argv[1]).read_bytes()).hexdigest()}
Path(sys.argv[2]).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
PY
"$PROJECT/tests/write_receipt_environment.sh" "$SCRATCH/library-build/default/tests/recipient_endpoint.exe" "$SCRATCH/library-build/default/tests/size_sweep.exe" "$SCRATCH"
cp "$SCRATCH/receipts/environment.json" "$SCRATCH/receipts/sizes-environment.json" "$SCRATCH/receipts/sizes-validation.json" "$PROJECT/receipts/recipient/"
wc -l "$PROJECT/receipts/recipient/sizes.csv"
cat "$PROJECT/receipts/recipient/sizes-time.txt"
