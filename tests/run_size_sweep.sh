#!/usr/bin/env bash
set -euo pipefail

PIN=3aab2d992035076dd216ad8808710d3a5a56063a
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=${MESSENGER_SCRATCH:-/srv/octra-node/fakenet-kimi-messenger}
SOURCE=${OCTRA_NODE_SOURCE:-$SCRATCH/src/lite_node}
SWITCH=${OCTRA_OPAM_SWITCH:-/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml}
JOBS=${BUILD_JOBS:-2}

git -C "$SOURCE" checkout --quiet --detach "$PIN"
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN"
for file in recipient_message_core.ml recipient_message.ml recipient_message.mli recipient_message_testkit.ml pvac_slots.ml pvac_message.ml; do
  cp "$PROJECT/lib/crypto/$file" "$SOURCE/test/$file"
done
cp "$PROJECT/tests/size_sweep.ml" "$SOURCE/test/size_sweep.ml"
sed -i 's/(modules size_sweep recipient_message_core recipient_message recipient_message_testkit pvac_slots pvac_message)/(modules size_sweep recipient_message_core recipient_message recipient_message_testkit recipient_keys pvac_slots pvac_message)/' "$SOURCE/test/dune"
if ! grep -q '(name size_sweep)' "$SOURCE/test/dune"; then
  printf '\n(executable\n (name size_sweep)\n (modules size_sweep recipient_message_core recipient_message recipient_message_testkit recipient_keys pvac_slots pvac_message)\n (libraries octra_core pvac_ffi mirage-crypto mirage-crypto-ec mirage-crypto-rng.unix digestif yojson base64 unix))\n' >> "$SOURCE/test/dune"
fi
mkdir -p "$SCRATCH/tmp" "$SCRATCH/link-libs" "$SCRATCH/receipts" "$PROJECT/receipts/recipient" "$SOURCE/mcl/obj" "$SOURCE/mcl/lib"
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
python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" --profile release -j "$JOBS" test/size_sweep.exe
/usr/bin/time -v "$SOURCE/_build/default/test/size_sweep.exe" > "$PROJECT/receipts/recipient/sizes.csv" 2> "$PROJECT/receipts/recipient/sizes-time.txt"
python3 - "$PROJECT/receipts/recipient/sizes.csv" "$SCRATCH/receipts/sizes-validation.json" <<'PY'
import csv,json,sys
from pathlib import Path
with open(sys.argv[1],newline='') as source:
    lines=[line for line in source if not line.startswith('#')]
rows=list(csv.DictReader(lines))
assert rows and all(None not in row and all(value is not None for value in row.values()) for row in rows)
assert len(rows) == 52, len(rows)
positive=[row for row in rows if row['status'] in ('pass','same-key-holder')]
unsupported=[row for row in rows if row['status'] == 'not-measured-time-budget']
assert len(positive) == 46 and len(unsupported) == 6
for row in positive:
    assert float(row['seal_overall_max_ms']) >= float(row['seal_warm_max_ms'])
    assert float(row['seal_overall_max_ms']) >= float(row['seal_cold_ms'])
    assert float(row['open_overall_max_ms']) >= float(row['open_warm_max_ms'])
    assert float(row['open_overall_max_ms']) >= float(row['open_cold_ms'])
recipient=[row for row in positive if row['route'] == 'recipient-x25519-aes-gcm']
assert len(recipient) == 19
for row in recipient:
    assert int(row['envelope_overhead']) == int(row['envelope_bytes']) - int(row['plaintext_bytes'])
utf8=[row for row in recipient if row['kind'] == 'utf8']
assert len(utf8) == 1 and utf8[0]['plaintext_bytes'] == '128'
report={'schema_columns':len(rows[0]),'data_rows':len(rows),'positive_round_trip_rows':len(positive),
  'unsupported_rows':len(unsupported),'samples_per_measured_case':5,'cold_samples':1,'warm_samples':4,
  'utf8_fixture':'whole UTF-8 codepoints repeated, then ASCII fill; 128 bytes; never byte-sliced',
  'negative_controls':'endpoint.txt only; no negative-control claim is made for size rows',
  'deterministic_seal':'testkit RNG invokes the same production seal; production inputs expose no ID/ephemeral/nonce overrides',
  'csv_sha256':__import__('hashlib').sha256(Path(sys.argv[1]).read_bytes()).hexdigest()}
Path(sys.argv[2]).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
PY
"$PROJECT/tests/write_receipt_environment.sh" "$SOURCE/_build/default/test/recipient_endpoint.exe" "$SOURCE/_build/default/test/size_sweep.exe" "$SCRATCH"
cp "$SCRATCH/receipts/environment.json" "$SCRATCH/receipts/sizes-environment.json" "$SCRATCH/receipts/sizes-validation.json" "$PROJECT/receipts/recipient/"
wc -l "$PROJECT/receipts/recipient/sizes.csv"
cat "$PROJECT/receipts/recipient/sizes-time.txt"
