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
  tests/recipient_endpoint.exe tests/size_sweep.exe
EXE="$SCRATCH/library-build/default/tests/recipient_endpoint.exe"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
CASE="$SCRATCH/work/case-$stamp"
mkdir -p "$CASE/alice" "$CASE/bob"
LOG="$SCRATCH/receipts/endpoint.txt"
: > "$LOG"
SENDER_PUBLIC=$("$EXE" sender-init "$CASE/alice" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["sender_public"])')
"$EXE" recipient-init "$CASE/bob" "$SENDER_PUBLIC" >> "$LOG"
python3 - "$CASE/bob/recipient-secret-v1.json" >> "$LOG" <<'PY'
import json,sys
secret=json.load(open(sys.argv[1]))
assert secret['key_type'] == 'octra-x25519-recipient-message-v1'
assert secret['view_secret'] != secret['view_public']
print('positive=recipient_init_generated_dedicated_x25519_key')
PY
mkdir -p "$CASE/key-loader"
cp "$CASE/bob/recipient-secret-v1.json" "$CASE/key-loader/valid.json"
python3 - "$EXE" "$CASE/key-loader" >> "$LOG" <<'PY'
import json,subprocess,sys
from pathlib import Path
exe=Path(sys.argv[1])
root=Path(sys.argv[2])
valid=json.loads((root/'valid.json').read_text())
(root/'malformed.json').write_text('{not json\n')
for name,change in [
    ('wrong_type', {'key_type':'octra-wallet-ed25519-v1'}),
    ('bad_secret_base64', {'view_secret':'not base64'}),
    ('bad_public_base64', {'view_public':'not base64'}),
    ('mismatched_public', {'view_public':valid['view_secret']}),
]:
    row=dict(valid)
    row.update(change)
    (root/(name+'.json')).write_text(json.dumps(row)+'\n')
for name in ['missing','malformed','wrong_type','bad_secret_base64','bad_public_base64','mismatched_public']:
    result=subprocess.run([str(exe),'key-read-test',str(root/(name+'.json'))],check=True,capture_output=True,text=True)
    reply=json.loads(result.stdout)
    assert reply['status']=='key_rejected' and reply['reason'], (name,reply)
result=subprocess.run([str(exe),'key-read-test',str(root/'valid.json')],check=True,capture_output=True,text=True)
assert json.loads(result.stdout)['status']=='key_loaded', result.stdout
print('positive=key_loader_returns_expected_errors_without_throwing cases=6 valid_control=pass')
PY
printf 'recipient is offline during seal\n' > "$CASE/plaintext.txt"
"$EXE" seal-test "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/message.ocm" >> "$LOG"
"$EXE" open "$CASE/bob/recipient-secret-v1.json" "$CASE/bob/recipient-public.json" \
  "$CASE/message.ocm" "$CASE/opened.txt" >> "$LOG"
cmp "$CASE/plaintext.txt" "$CASE/opened.txt"
printf 'positive=recipient_offline_secret_free_sender\n' >> "$LOG"

"$EXE" send "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/random-a.ocm" >> "$LOG"
"$EXE" send "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/random-b.ocm" >> "$LOG"
python3 - "$CASE/random-a.ocm" "$CASE/random-b.ocm" >> "$LOG" <<'PY'
import sys
left=open(sys.argv[1],'rb').read()
right=open(sys.argv[2],'rb').read()
assert left != right
for name,a,b in [('message_id',left[34:50],right[34:50]),('ephemeral',left[50:82],right[50:82]),('nonce',left[-49:-37],right[-49:-37])]:
    assert a != b, name
print('positive=default_rng_distinct_ids_ephemerals_nonces_envelopes')
PY
"$EXE" open "$CASE/bob/recipient-secret-v1.json" "$CASE/bob/recipient-public.json" "$CASE/random-a.ocm" "$CASE/random-a.txt" >> "$LOG"
"$EXE" open "$CASE/bob/recipient-secret-v1.json" "$CASE/bob/recipient-public.json" "$CASE/random-b.ocm" "$CASE/random-b.txt" >> "$LOG"
cmp "$CASE/plaintext.txt" "$CASE/random-a.txt"
cmp "$CASE/plaintext.txt" "$CASE/random-b.txt"
before=$(sha256sum "$CASE/bob/receive-state.json" | awk '{print $1}')
if "$EXE" send-uninitialized "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/uninitialized.ocm" > "$CASE/uninitialized.log" 2>&1; then
  printf 'uninitialized RNG unexpectedly succeeded\n' >&2
  exit 1
fi
python3 - "$CASE/uninitialized.log" <<'PY'
import json,sys
lines=[line for line in open(sys.argv[1]) if line.strip()]
assert len(lines) == 1 and json.loads(lines[0]) == {'status':'rejected'}, lines
PY
test ! -e "$CASE/uninitialized.ocm"
after=$(sha256sum "$CASE/bob/receive-state.json" | awk '{print $1}')
test "$before" = "$after"
cat "$CASE/uninitialized.log" >> "$LOG"
printf 'control=uninitialized_rng_failed_closed receive_state_sha256=%s\n' "$after" >> "$LOG"

strace -f -qq -e trace=open,openat -o "$SCRATCH/receipts/sender.strace" \
  "$EXE" send "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/straced.ocm" >> "$LOG"
"$EXE" open "$CASE/bob/recipient-secret-v1.json" "$CASE/bob/recipient-public.json" \
  "$CASE/straced.ocm" "$CASE/straced.txt" >> "$LOG"
cmp "$CASE/plaintext.txt" "$CASE/straced.txt"
python3 - "$SCRATCH/receipts/sender.strace" >> "$LOG" <<'PY'
import sys
raw=open(sys.argv[1]).read()
assert 'recipient-secret' not in raw
assert 'contact-secret' not in raw
assert 'messaging-secret' not in raw
assert 'sender-secret.json' in raw and 'recipient-public.json' in raw
print('positive=production_sender_no_recipient_secret_access')
PY
python3 - "$PROJECT" >> "$LOG" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
for name in ['lib/crypto/recipient_message.mli','lib/crypto/recipient_message.ml']:
    text=(root/name).read_text()
    for parameter in ['~message_id','~ephemeral_secret','~nonce']:
        assert parameter not in text, (name,parameter)
core=(root/'lib/crypto/recipient_message_core.ml').read_text()
seal=core.split('let seal ',1)[1].split('plaintext =',1)[0]
for parameter in ['~message_id','~ephemeral_secret','~nonce']:
    assert parameter not in seal, parameter
testkit=(root/'tests/testkit/recipient_message_testkit.ml').read_text()
assert '~message_id' in testkit and '~ephemeral_secret' in testkit and '~nonce' in testkit
print('positive=production_seal_randomized_only_deterministic_material_testkit_only')
PY

mkdir -p "$CASE/other-channel"
"$EXE" recipient-init "$CASE/other-channel" "$SENDER_PUBLIC" >> "$LOG"
before_bob=$(python3 - "$CASE/alice/outbox/outbox.json" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
assert len(state['channels']) == 1, state
print(int(state['channels'][0]['next_sequence']) - 1)
PY
)
for ((i=0; i<1025; i++)); do
  "$EXE" send "$CASE/other-channel/recipient-public.json" "$CASE/alice/sender-secret.json" \
    "$CASE/plaintext.txt" "$CASE/other-channel/message.ocm" >> "$LOG"
done
"$EXE" send "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/bob/after-contacts.ocm" >> "$LOG"
"$EXE" send "$CASE/other-channel/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/other-channel/last.ocm" >> "$LOG"
"$EXE" open "$CASE/bob/recipient-secret-v1.json" "$CASE/bob/recipient-public.json" \
  "$CASE/bob/after-contacts.ocm" "$CASE/bob/after-contacts.txt" >> "$LOG"
"$EXE" open "$CASE/other-channel/recipient-secret-v1.json" "$CASE/other-channel/recipient-public.json" \
  "$CASE/other-channel/last.ocm" "$CASE/other-channel/last.txt" >> "$LOG"
cmp "$CASE/plaintext.txt" "$CASE/bob/after-contacts.txt"
cmp "$CASE/plaintext.txt" "$CASE/other-channel/last.txt"
python3 - "$CASE/bob/after-contacts.ocm" "$CASE/other-channel/last.ocm" "$before_bob" >> "$LOG" <<'PY'
import sys
bob=open(sys.argv[1],'rb').read()
other=open(sys.argv[2],'rb').read()
assert int.from_bytes(bob[18:26],'big') == int(sys.argv[3]) + 1
assert int.from_bytes(other[18:26],'big') == 1026
assert bob[114:130] != other[114:130]
print('positive=per_contact_counter_survives_1025_other_channel_sends')
PY

printf 'unread v1 after rotation\n' > "$CASE/unread-v1.txt"
"$EXE" seal-test "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/unread-v1.txt" "$CASE/unread-v1.ocm" >> "$LOG"
mkdir -p "$CASE/v1-seal" "$CASE/messaging-key"
cp "$CASE/bob/recipient-public.json" "$CASE/bob/contact-root.json" "$CASE/v1-seal/"
printf 'old version outside grace\n' > "$CASE/v1-seal/old.txt"
"$EXE" seal-test "$CASE/v1-seal/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/v1-seal/old.txt" "$CASE/v1-seal/old.ocm" >> "$LOG"
"$EXE" generate-messaging-key "$CASE/messaging-key" "$CASE/alice/sender-secret.json" >> "$LOG"
test "$(stat -c %a "$CASE/messaging-key/messaging-secret.json")" = 600
printf 'positive=dedicated_x25519_key_independent_from_ed25519\n' >> "$LOG"
"$EXE" binding-test "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" >> "$LOG"

"$EXE" rotate "$CASE/bob" >> "$LOG"
printf 'rotated recipient key\n' > "$CASE/rotated.txt"
"$EXE" seal-test "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/rotated.txt" "$CASE/rotated.ocm" >> "$LOG"
"$EXE" open "$CASE/bob/recipient-secret-v2.json" "$CASE/bob/recipient-public.json" \
  "$CASE/rotated.ocm" "$CASE/rotated-open.txt" >> "$LOG"
cmp "$CASE/rotated.txt" "$CASE/rotated-open.txt"
"$EXE" open "$CASE/bob/recipient-secret-v1.json" "$CASE/bob/recipient-public.json" \
  "$CASE/unread-v1.ocm" "$CASE/old-open.txt" >> "$LOG"
cmp "$CASE/unread-v1.txt" "$CASE/old-open.txt"
printf 'positive=rotation_preserves_unread_previous_version\n' >> "$LOG"

mkdir -p "$CASE/outbox"
"$EXE" outbox-prepare "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/outbox" >> "$LOG"
OUTBOX_ID=$(python3 -c 'import json; state=json.load(open("'$CASE'/outbox/outbox.json")); print(state["channels"][0]["records"][-1]["record_id"])')
"$EXE" outbox-retry "$CASE/outbox" "$OUTBOX_ID" "$CASE/retry.ocm" >> "$LOG"
cmp "$CASE/outbox/prepared.ocm" "$CASE/retry.ocm"
"$EXE" outbox-mark "$CASE/outbox" "$OUTBOX_ID" submitted >> "$LOG"
"$EXE" outbox-mark "$CASE/outbox" "$OUTBOX_ID" finalized >> "$LOG"
"$EXE" outbox-retry "$CASE/outbox" "$OUTBOX_ID" "$CASE/retry-final.ocm" >> "$LOG"
cmp "$CASE/outbox/prepared.ocm" "$CASE/retry-final.ocm"
printf 'positive=outbox_retry_byte_identical\n' >> "$LOG"

prepare_case() {
  local name=$1
  local source=${2:-$CASE/bob}
  mkdir -p "$CASE/$name"
  cp "$source"/recipient-secret-v*.json "$source/recipient-public.json" "$source/contact-root.json" "$source/contact-secret.json" "$CASE/$name/"
  printf 'baseline for %s\n' "$name" > "$CASE/$name/baseline.txt"
  "$EXE" seal-test "$CASE/$name/recipient-public.json" "$CASE/alice/sender-secret.json" \
    "$CASE/$name/baseline.txt" "$CASE/$name/baseline.ocm" >> "$LOG"
  "$EXE" open-test "$CASE/$name/recipient-secret-v1.json" "$CASE/$name/recipient-public.json" \
    "$CASE/$name/baseline.ocm" "$CASE/$name/baseline-open.txt" >> "$LOG"
  cmp "$CASE/$name/baseline.txt" "$CASE/$name/baseline-open.txt"
  printf 'negative control %s\n' "$name" > "$CASE/$name/new.txt"
  "$EXE" seal-test "$CASE/$name/recipient-public.json" "$CASE/alice/sender-secret.json" \
    "$CASE/$name/new.txt" "$CASE/$name/message.ocm" >> "$LOG"
}

expect_fail() {
  local name=$1
  local expected=$2
  local secret=$3
  local config=$4
  local envelope=$5
  local output=$6
  local directory detailed_log public_log before after
  directory=$(dirname "$secret")
  detailed_log="$CASE/$name.open-test.log"
  public_log="$CASE/$name.open-public.log"
  before=$(sha256sum "$directory/receive-state.json" 2>/dev/null | awk '{print $1}' || true)
  if "$EXE" open-test "$secret" "$config" "$envelope" "$output" > "$detailed_log" 2>&1; then
    printf 'control=%s unexpectedly accepted\n' "$name" >&2
    exit 1
  fi
  python3 - "$detailed_log" "$expected" <<'PY'
import json,sys
lines=[line for line in open(sys.argv[1]) if line.strip()]
assert lines, 'missing detailed rejection'
record=json.loads(lines[-1])
assert record['status'] == 'error', record
assert sys.argv[2] in record['reason'], (sys.argv[2],record)
PY
  if "$EXE" open "$secret" "$config" "$envelope" "$output" > "$public_log" 2>&1; then
    printf 'control=%s normalized open unexpectedly accepted\n' "$name" >&2
    exit 1
  fi
  python3 - "$public_log" <<'PY'
import json,sys
lines=[line for line in open(sys.argv[1]) if line.strip()]
assert len(lines) == 1, lines
assert json.loads(lines[0]) == {'status':'rejected'}, lines
PY
  test ! -e "$output"
  after=$(sha256sum "$directory/receive-state.json" 2>/dev/null | awk '{print $1}' || true)
  if [ "$before" != "$after" ]; then
    printf 'control=%s changed receive state after failure\n' "$name" >&2
    exit 1
  fi
  cat "$detailed_log" "$public_log" >> "$LOG"
  printf 'control=%s rejected guard=%s receive_state_sha256=%s\n' "$name" "$expected" "${after:-missing}" >> "$LOG"
}

expect_exec() {
  local name=$1 expected=$2 directory=$3
  shift 3
  local log before after
  log="$CASE/$name.exec.log"
  before=$(sha256sum "$directory/receive-state.json" 2>/dev/null | awk '{print $1}' || true)
  if "$EXE" "$@" > "$log" 2>&1; then
    printf 'control=%s unexpectedly accepted\n' "$name" >&2
    exit 1
  fi
  python3 - "$log" "$expected" <<'PY'
import json,sys
lines=[line for line in open(sys.argv[1]) if line.strip()]
assert lines, 'missing detailed rejection'
record=json.loads(lines[-1])
assert record['status'] == 'error', record
assert sys.argv[2] in record['reason'], (sys.argv[2],record)
PY
  after=$(sha256sum "$directory/receive-state.json" 2>/dev/null | awk '{print $1}' || true)
  if [ "$before" != "$after" ]; then
    printf 'control=%s changed receive state after failure\n' "$name" >&2
    exit 1
  fi
  cat "$log" >> "$LOG"
  printf 'control=%s rejected guard=%s receive_state_sha256=%s\n' "$name" "$expected" "${after:-missing}" >> "$LOG"
}

prepare_case outbox_crash_before_seal
expect_exec outbox_crash_before_seal "injected outbox crash before sealing" "$CASE/outbox_crash_before_seal" \
  outbox-fail-before-seal "$CASE/outbox_crash_before_seal/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_crash_before_seal/new.txt" "$CASE/outbox_crash_before_seal"
INCOMPLETE_ID=$(python3 -c 'import json; state=json.load(open("'$CASE'/outbox_crash_before_seal/outbox.json")); print(state["channels"][0]["records"][0]["record_id"])')
expect_exec outbox_incomplete_retry "outbox sequence is not sealed" "$CASE/outbox_crash_before_seal" \
  outbox-retry "$CASE/outbox_crash_before_seal" "$INCOMPLETE_ID" "$CASE/outbox_crash_before_seal/incomplete.ocm"
test ! -e "$CASE/outbox_crash_before_seal/incomplete.ocm"
expect_exec outbox_incomplete_mark "outbox sequence is not sealed" "$CASE/outbox_crash_before_seal" \
  outbox-mark "$CASE/outbox_crash_before_seal" "$INCOMPLETE_ID" submitted
"$EXE" outbox-prepare "$CASE/outbox_crash_before_seal/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_crash_before_seal/new.txt" "$CASE/outbox_crash_before_seal" >> "$LOG"
"$EXE" open-test "$CASE/outbox_crash_before_seal/recipient-secret-v2.json" \
  "$CASE/outbox_crash_before_seal/recipient-public.json" "$CASE/outbox_crash_before_seal/prepared.ocm" \
  "$CASE/outbox_crash_before_seal/open.txt" >> "$LOG"
cmp "$CASE/outbox_crash_before_seal/new.txt" "$CASE/outbox_crash_before_seal/open.txt"
python3 - "$CASE/outbox_crash_before_seal/outbox.json" >> "$LOG" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
channel=state['channels'][0]
assert int(channel['next_sequence']) == 3, state
assert [row['sequence'] for row in channel['records']] == [1,2], state
assert channel['records'][0]['status'] == 'allocating' and 'envelope' not in channel['records'][0]
assert channel['records'][1]['status'] == 'prepared'
print('positive=outbox_allocation_durable_before_seal_crash_no_sequence_reuse')
PY

prepare_case outbox_bounds
mkdir -p "$CASE/outbox_bounds/outbox"
"$EXE" outbox-prepare "$CASE/outbox_bounds/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_bounds/new.txt" "$CASE/outbox_bounds/outbox" >> "$LOG"
python3 - "$CASE/outbox_bounds/outbox/outbox.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['channels'][0]['next_sequence']='9223372036854775806'
open(path,'w').write(json.dumps(state)+'\n')
PY
"$EXE" outbox-prepare "$CASE/outbox_bounds/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_bounds/new.txt" "$CASE/outbox_bounds/outbox" >> "$LOG"
cp "$CASE/outbox_bounds/outbox/prepared.ocm" "$CASE/outbox_bounds/penultimate.ocm"
"$EXE" outbox-prepare "$CASE/outbox_bounds/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_bounds/new.txt" "$CASE/outbox_bounds/outbox" >> "$LOG"
python3 - "$CASE/outbox_bounds/outbox/outbox.json" >> "$LOG" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
channel=state['channels'][0]
sequences=[int(row['sequence']) for row in channel['records']]
assert sequences == [1,9223372036854775806,9223372036854775807], sequences
assert len(set(sequences)) == len(sequences)
assert channel['next_sequence'] == 'exhausted', channel['next_sequence']
print('positive=outbox_last_usable_allocation_then_explicit_exhaustion')
PY
LAST_ID=$(python3 -c 'import json; state=json.load(open("'$CASE'/outbox_bounds/outbox/outbox.json")); print(state["channels"][0]["records"][-1]["record_id"])')
PENULTIMATE_ID=$(python3 -c 'import json; state=json.load(open("'$CASE'/outbox_bounds/outbox/outbox.json")); print(state["channels"][0]["records"][-2]["record_id"])')
for restart in 1 2; do
  before=$(sha256sum "$CASE/outbox_bounds/outbox/outbox.json" | awk '{print $1}')
  expect_exec "outbox_exhausted_$restart" "outbox channel exhausted" "$CASE/outbox_bounds/outbox" \
    outbox-fail-before-seal "$CASE/outbox_bounds/recipient-public.json" "$CASE/alice/sender-secret.json" \
    "$CASE/outbox_bounds/new.txt" "$CASE/outbox_bounds/outbox"
  after=$(sha256sum "$CASE/outbox_bounds/outbox/outbox.json" | awk '{print $1}')
  test "$before" = "$after"
done
"$EXE" outbox-retry "$CASE/outbox_bounds/outbox" "$LAST_ID" "$CASE/outbox_bounds/retry-last.ocm" >> "$LOG"
cmp "$CASE/outbox_bounds/outbox/prepared.ocm" "$CASE/outbox_bounds/retry-last.ocm"
"$EXE" outbox-retry "$CASE/outbox_bounds/outbox" "$PENULTIMATE_ID" "$CASE/outbox_bounds/retry-penultimate.ocm" >> "$LOG"
cmp "$CASE/outbox_bounds/penultimate.ocm" "$CASE/outbox_bounds/retry-penultimate.ocm"
printf 'positive=outbox_exhaustion_refusal_no_sealer_no_journal_change_retries_byte_identical_after_restart\n' >> "$LOG"
for invalid in 0 -1 9223372036854775808 not-a-counter; do
  safe=${invalid//-/_}
  cp -R "$CASE/outbox_bounds/outbox" "$CASE/outbox_bounds/invalid-$safe"
  python3 - "$CASE/outbox_bounds/invalid-$safe/outbox.json" "$invalid" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['channels'][0]['next_sequence']=sys.argv[2]
open(path,'w').write(json.dumps(state)+'\n')
PY
  before=$(sha256sum "$CASE/outbox_bounds/invalid-$safe/outbox.json" | awk '{print $1}')
  expect_exec "outbox_invalid_$safe" "invalid outbox next_sequence" "$CASE/outbox_bounds/invalid-$safe" \
    outbox-fail-before-seal "$CASE/outbox_bounds/recipient-public.json" "$CASE/alice/sender-secret.json" \
    "$CASE/outbox_bounds/new.txt" "$CASE/outbox_bounds/invalid-$safe"
  after=$(sha256sum "$CASE/outbox_bounds/invalid-$safe/outbox.json" | awk '{print $1}')
  test "$before" = "$after"
done
printf 'control=invalid_outbox_counters_refused_before_seal_or_mutation cases=4\n' >> "$LOG"

prepare_case outbox_compat
mkdir -p "$CASE/outbox_compat/outbox"
"$EXE" outbox-prepare "$CASE/outbox_compat/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_compat/new.txt" "$CASE/outbox_compat/outbox" >> "$LOG"
cp "$CASE/outbox_compat/outbox/prepared.ocm" "$CASE/outbox_compat/first.ocm"
COMPAT_ID=$(python3 -c 'import json; state=json.load(open("'$CASE'/outbox_compat/outbox/outbox.json")); print(state["channels"][0]["records"][0]["record_id"])')
python3 - "$CASE/outbox_compat/outbox/outbox.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['channels'][0]['next_sequence']=2
open(path,'w').write(json.dumps(state)+'\n')
PY
"$EXE" outbox-prepare "$CASE/outbox_compat/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_compat/new.txt" "$CASE/outbox_compat/outbox" >> "$LOG"
"$EXE" outbox-retry "$CASE/outbox_compat/outbox" "$COMPAT_ID" "$CASE/outbox_compat/retry-first.ocm" >> "$LOG"
cmp "$CASE/outbox_compat/first.ocm" "$CASE/outbox_compat/retry-first.ocm"
python3 - "$CASE/outbox_compat/outbox/outbox.json" "$COMPAT_ID" >> "$LOG" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
channel=state['channels'][0]
assert [int(row['sequence']) for row in channel['records']] == [1,2], channel
assert channel['records'][0]['record_id'] == sys.argv[2]
assert channel['records'][0]['status'] == 'prepared'
print('positive=old_integer_journal_resumes_without_id_or_pending_receipt_changes')
PY

prepare_case outbox_recovery
mkdir -p "$CASE/outbox_recovery/outbox"
"$EXE" outbox-prepare "$CASE/outbox_recovery/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_recovery/new.txt" "$CASE/outbox_recovery/outbox" >> "$LOG"
cp "$CASE/outbox_recovery/outbox/prepared.ocm" "$CASE/outbox_recovery/first.ocm"
"$EXE" open-test "$CASE/outbox_recovery/recipient-secret-v1.json" \
  "$CASE/outbox_recovery/recipient-public.json" "$CASE/outbox_recovery/first.ocm" \
  "$CASE/outbox_recovery/first-open.txt" >> "$LOG"
python3 - "$CASE/outbox_recovery/outbox/outbox.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['channels'][0]['next_sequence']=1
open(path,'w').write(json.dumps(state)+'\n')
PY
"$EXE" outbox-recover "$CASE/outbox_recovery/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_recovery/outbox" 1 >> "$LOG"
before=$(sha256sum "$CASE/outbox_recovery/outbox/outbox.json" | awk '{print $1}')
"$EXE" outbox-recover "$CASE/outbox_recovery/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_recovery/outbox" 0 >> "$LOG"
after=$(sha256sum "$CASE/outbox_recovery/outbox/outbox.json" | awk '{print $1}')
test "$before" = "$after"
"$EXE" outbox-prepare "$CASE/outbox_recovery/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_recovery/new.txt" "$CASE/outbox_recovery/outbox" >> "$LOG"
"$EXE" open-test "$CASE/outbox_recovery/recipient-secret-v1.json" \
  "$CASE/outbox_recovery/recipient-public.json" "$CASE/outbox_recovery/outbox/prepared.ocm" \
  "$CASE/outbox_recovery/recovered-open.txt" >> "$LOG"
cmp "$CASE/outbox_recovery/new.txt" "$CASE/outbox_recovery/recovered-open.txt"
python3 - "$CASE/outbox_recovery/outbox/outbox.json" >> "$LOG" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
channel=state['channels'][0]
assert [int(row['sequence']) for row in channel['records']] == [1,2], channel
assert int(channel['next_sequence']) == 3, channel['next_sequence']
assert channel['records'][0]['status'] == 'prepared'
print('positive=restored_backup_recovers_observed_high_water_without_instance_reset_or_replay')
PY
before=$(sha256sum "$CASE/outbox_recovery/outbox/outbox.json" | awk '{print $1}')
expect_exec outbox_recovery_negative "outbox recovery high-water outside limits" "$CASE/outbox_recovery/outbox" \
  outbox-recover "$CASE/outbox_recovery/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/outbox_recovery/outbox" -1
after=$(sha256sum "$CASE/outbox_recovery/outbox/outbox.json" | awk '{print $1}')
test "$before" = "$after"

mkdir -p "$CASE/other"
"$EXE" recipient-init "$CASE/other" "$SENDER_PUBLIC" >/dev/null
"$EXE" rotate "$CASE/other" >> "$LOG"
prepare_case wrong_recipient_coherent "$CASE/other"
cp "$CASE/bob/recipient-public.json" "$CASE/wrong_recipient_coherent/seal-config.json"
"$EXE" seal-test "$CASE/wrong_recipient_coherent/seal-config.json" "$CASE/alice/sender-secret.json"   "$CASE/wrong_recipient_coherent/new.txt" "$CASE/wrong_recipient_coherent/message.ocm" >> "$LOG"
expect_fail wrong_recipient_coherent "ciphertext authentication failed" \
  "$CASE/wrong_recipient_coherent/recipient-secret-v1.json" "$CASE/wrong_recipient_coherent/recipient-public.json" \
  "$CASE/wrong_recipient_coherent/message.ocm" "$CASE/wrong_recipient_coherent/open.txt"

prepare_case config_mismatch
python3 - "$CASE/config_mismatch/recipient-public.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['view_public']='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/config_mismatch" >> "$LOG"
expect_fail config_mismatch "recipient key replaced or unregistered" \
  "$CASE/config_mismatch/recipient-secret-v2.json" "$CASE/config_mismatch/recipient-public.json" \
  "$CASE/config_mismatch/message.ocm" "$CASE/config_mismatch/open.txt"

prepare_case modified_capability
python3 - "$CASE/modified_capability/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
raw[50]^=1
open(path,'wb').write(raw)
PY
expect_fail modified_capability "sender authentication failed" \
  "$CASE/modified_capability/recipient-secret-v2.json" "$CASE/modified_capability/recipient-public.json" \
  "$CASE/modified_capability/message.ocm" "$CASE/modified_capability/open.txt"

prepare_case modified_message_id
python3 - "$CASE/modified_message_id/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
raw[34]^=1
open(path,'wb').write(raw)
PY
expect_fail modified_message_id "sender authentication failed" \
  "$CASE/modified_message_id/recipient-secret-v2.json" "$CASE/modified_message_id/recipient-public.json" \
  "$CASE/modified_message_id/message.ocm" "$CASE/modified_message_id/open.txt"

for mode in id version context ephemeral; do
  prepare_case "aead_$mode"
  "$EXE" corrupt "$mode" "$CASE/aead_$mode/message.ocm" "$CASE/alice/sender-secret.json" "$CASE/aead_$mode/resigned.ocm" >> "$LOG"
  if [ "$mode" = version ]; then
    cp "$CASE/aead_$mode/recipient-secret-v2.json" "$CASE/aead_$mode/recipient-secret-v3.json"
    python3 - "$CASE/aead_$mode/recipient-public.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['key_version']=3
data['accepted_previous_versions']=[1,2]
data['grace_previous_versions']=[1,2]
data['policies']['3']={'activate_after_epoch':'0','expire_after_epoch':None,'revoked':False,'erased':False}
open(path,'w').write(json.dumps(data)+'\n')
PY
    "$EXE" resign-config "$CASE/aead_$mode" >> "$LOG"
    version=3
  elif [ "$mode" = context ]; then
    python3 - "$CASE/aead_$mode/recipient-public.json" <<'PY'
import base64,json,sys
path=sys.argv[1]
data=json.load(open(path))
data['context']=base64.b64encode(base64.b64decode(data['context'])+b'|modified').decode()
open(path,'w').write(json.dumps(data)+'\n')
PY
    "$EXE" resign-config "$CASE/aead_$mode" >> "$LOG"
    version=2
  else
    version=2
  fi
  if [ "$mode" = version ]; then
    expected="ciphertext authentication failed"
  elif [ "$mode" = context ]; then
    expected="ciphertext authentication failed"
  else
    expected="ciphertext authentication failed"
  fi
  expect_fail "aead_$mode" "$expected" \
    "$CASE/aead_$mode/recipient-secret-v$version.json" "$CASE/aead_$mode/recipient-public.json" \
    "$CASE/aead_$mode/resigned.ocm" "$CASE/aead_$mode/open.txt"
done

for mode in zero-ephemeral ordinary-ones-ephemeral u-one-ephemeral order-eight-a-ephemeral order-eight-b-ephemeral low-order-ephemeral p-ephemeral p-plus-one-ephemeral noncanonical-ephemeral; do
  prepare_case "$mode"
  "$EXE" corrupt "$mode" "$CASE/$mode/message.ocm" "$CASE/alice/sender-secret.json" "$CASE/$mode/resigned.ocm" >> "$LOG"
  if [ "$mode" = ordinary-ones-ephemeral ] || [ "$mode" = noncanonical-ephemeral ]; then
    expected="ciphertext authentication failed"
  else
    expected="recipient key exchange failed"
  fi
  expect_fail "$mode" "$expected" "$CASE/$mode/recipient-secret-v2.json" "$CASE/$mode/recipient-public.json" \
    "$CASE/$mode/resigned.ocm" "$CASE/$mode/open.txt"
done

prepare_case wrong_context
python3 - "$CASE/wrong_context/recipient-public.json" <<'PY'
import base64,json,sys
path=sys.argv[1]
data=json.load(open(path))
raw=bytearray(base64.b64decode(data['context']))
raw[-1]^=1
data['context']=base64.b64encode(raw).decode()
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/wrong_context" >> "$LOG"
expect_fail wrong_context "wrong chain, application or registry context" \
  "$CASE/wrong_context/recipient-secret-v2.json" "$CASE/wrong_context/recipient-public.json" \
  "$CASE/wrong_context/message.ocm" "$CASE/wrong_context/open.txt"

prepare_case modified_body
python3 - "$CASE/modified_body/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
raw[-1]^=1
open(path,'wb').write(raw)
PY
expect_fail modified_body "sender authentication failed" \
  "$CASE/modified_body/recipient-secret-v2.json" "$CASE/modified_body/recipient-public.json" \
  "$CASE/modified_body/message.ocm" "$CASE/modified_body/open.txt"

prepare_case modified_header
python3 - "$CASE/modified_header/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
raw[14]^=1
open(path,'wb').write(raw)
PY
expect_fail modified_header "recipient key version is not accepted" \
  "$CASE/modified_header/recipient-secret-v2.json" "$CASE/modified_header/recipient-public.json" \
  "$CASE/modified_header/message.ocm" "$CASE/modified_header/open.txt"

prepare_case modified_context
python3 - "$CASE/modified_context/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
raw[194]^=1
open(path,'wb').write(raw)
PY
expect_fail modified_context "sender authentication failed" \
  "$CASE/modified_context/recipient-secret-v2.json" "$CASE/modified_context/recipient-public.json" \
  "$CASE/modified_context/message.ocm" "$CASE/modified_context/open.txt"

prepare_case truncation
python3 - "$CASE/truncation/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=open(path,'rb').read()
open(path,'wb').write(raw[:-1])
PY
expect_fail truncation "envelope trailing or truncated bytes" \
  "$CASE/truncation/recipient-secret-v2.json" "$CASE/truncation/recipient-public.json" \
  "$CASE/truncation/message.ocm" "$CASE/truncation/open.txt"

prepare_case trailing
python3 - "$CASE/trailing/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=open(path,'rb').read()
open(path,'ab').write(b'\0')
PY
expect_fail trailing "envelope trailing or truncated bytes" \
  "$CASE/trailing/recipient-secret-v2.json" "$CASE/trailing/recipient-public.json" \
  "$CASE/trailing/message.ocm" "$CASE/trailing/open.txt"

for policy in revoked erased not-yet-active expiration-boundary; do
  prepare_case "$policy"
  python3 - "$CASE/$policy/recipient-public.json" "$policy" <<'PY'
import json,sys
path,policy=sys.argv[1:]
data=json.load(open(path))
for value in data['policies'].values():
    if policy == 'revoked': value['revoked']=True
    elif policy == 'erased': value['erased']=True
    elif policy == 'not-yet-active': value['activate_after_epoch']='11'
    elif policy == 'expiration-boundary': value['expire_after_epoch']='10'
open(path,'w').write(json.dumps(data)+'\n')
PY
  "$EXE" resign-config "$CASE/$policy" >> "$LOG"
  expect_fail "$policy" "recipient key policy is stale" \
    "$CASE/$policy/recipient-secret-v2.json" "$CASE/$policy/recipient-public.json" \
    "$CASE/$policy/message.ocm" "$CASE/$policy/open.txt"
done

prepare_case activation-boundary
python3 - "$CASE/activation-boundary/recipient-public.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
for value in data['policies'].values(): value['activate_after_epoch']='10'
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/activation-boundary" >> "$LOG"
printf 'activation boundary allowed\n' > "$CASE/activation-boundary/allowed.txt"
"$EXE" seal-test "$CASE/activation-boundary/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/activation-boundary/allowed.txt" "$CASE/activation-boundary/allowed.ocm" >> "$LOG"
"$EXE" open "$CASE/activation-boundary/recipient-secret-v2.json" "$CASE/activation-boundary/recipient-public.json" \
  "$CASE/activation-boundary/allowed.ocm" "$CASE/activation-boundary/open.txt" >> "$LOG"
cmp "$CASE/activation-boundary/allowed.txt" "$CASE/activation-boundary/open.txt"
printf 'positive=policy_activation_boundary_allowed\n' >> "$LOG"

prepare_case stale_policy
python3 - "$CASE/stale_policy/recipient-public.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
for value in data['policies'].values(): value['expire_after_epoch']='9'
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/stale_policy" >> "$LOG"
expect_fail stale_policy "recipient key policy is stale" \
  "$CASE/stale_policy/recipient-secret-v2.json" "$CASE/stale_policy/recipient-public.json" \
  "$CASE/stale_policy/message.ocm" "$CASE/stale_policy/open.txt"

prepare_case malformed_ciphertext
"$EXE" corrupt body "$CASE/malformed_ciphertext/message.ocm" "$CASE/alice/sender-secret.json" \
  "$CASE/malformed_ciphertext/resigned.ocm" >> "$LOG"
expect_fail malformed_ciphertext "ciphertext authentication failed" \
  "$CASE/malformed_ciphertext/recipient-secret-v2.json" "$CASE/malformed_ciphertext/recipient-public.json" \
  "$CASE/malformed_ciphertext/resigned.ocm" "$CASE/malformed_ciphertext/open.txt"

prepare_case unsupported_version
python3 - "$CASE/unsupported_version/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
raw[6]=0
raw[7]=3
open(path,'wb').write(raw)
PY
expect_fail unsupported_version "unsupported version 3" \
  "$CASE/unsupported_version/recipient-secret-v2.json" "$CASE/unsupported_version/recipient-public.json" \
  "$CASE/unsupported_version/message.ocm" "$CASE/unsupported_version/open.txt"

prepare_case modified_signature
python3 - "$CASE/modified_signature/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
assert len(raw) >= 194 and 130 + 64 <= 194, len(raw)
raw[130]^=1
open(path,'wb').write(raw)
PY
expect_fail modified_signature "sender authentication failed" \
  "$CASE/modified_signature/recipient-secret-v2.json" "$CASE/modified_signature/recipient-public.json" \
  "$CASE/modified_signature/message.ocm" "$CASE/modified_signature/open.txt"

prepare_case modified_sender_instance
python3 - "$CASE/modified_sender_instance/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
assert len(raw) >= 194, len(raw)
raw[114]^=1
open(path,'wb').write(raw)
PY
expect_fail modified_sender_instance "sender authentication failed" \
  "$CASE/modified_sender_instance/recipient-secret-v2.json" "$CASE/modified_sender_instance/recipient-public.json" \
  "$CASE/modified_sender_instance/message.ocm" "$CASE/modified_sender_instance/open.txt"

prepare_case contact_tamper
python3 - "$CASE/contact_tamper/recipient-public.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['expected_sender_public']='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
open(path,'w').write(json.dumps(data)+'\n')
PY
expect_fail contact_tamper "contact authorization failed" \
  "$CASE/contact_tamper/recipient-secret-v2.json" "$CASE/contact_tamper/recipient-public.json" \
  "$CASE/contact_tamper/message.ocm" "$CASE/contact_tamper/open.txt"

mkdir -p "$CASE/attacker"
ATTACKER_PUBLIC=$("$EXE" sender-init "$CASE/attacker" 2 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["sender_public"])')
python3 - "$CASE/bob/recipient-public.json" "$ATTACKER_PUBLIC" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['expected_sender_public']=sys.argv[2]
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/bob" >> "$LOG"
"$EXE" seal-test "$CASE/bob/recipient-public.json" "$CASE/attacker/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/attacker.ocm" >> "$LOG"
python3 - "$CASE/bob/recipient-public.json" "$SENDER_PUBLIC" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['expected_sender_public']=sys.argv[2]
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/bob" >> "$LOG"
expect_fail unexpected_sender "sender authentication failed" \
  "$CASE/bob/recipient-secret-v2.json" "$CASE/bob/recipient-public.json" \
  "$CASE/attacker.ocm" "$CASE/bob/attacker-open.txt"

prepare_case old_version_after_rotation
python3 - "$CASE/old_version_after_rotation/recipient-public.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['accepted_previous_versions']=[]
data['grace_previous_versions']=[]
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/old_version_after_rotation" >> "$LOG"
expect_fail old_version_after_rotation "recipient key version is not accepted" \
  "$CASE/old_version_after_rotation/recipient-secret-v2.json" "$CASE/old_version_after_rotation/recipient-public.json" \
  "$CASE/v1-seal/old.ocm" "$CASE/old_version_after_rotation/open.txt"

prepare_case replay
"$EXE" open-test "$CASE/replay/recipient-secret-v2.json" "$CASE/replay/recipient-public.json" \
  "$CASE/replay/message.ocm" "$CASE/replay/first-open.txt" >> "$LOG"
cmp "$CASE/replay/new.txt" "$CASE/replay/first-open.txt"
expect_fail replay_duplicate "replay rejected" \
  "$CASE/replay/recipient-secret-v2.json" "$CASE/replay/recipient-public.json" \
  "$CASE/replay/message.ocm" "$CASE/replay/second-open.txt"

prepare_case key_version_overflow
python3 - "$CASE/key_version_overflow/recipient-public.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['key_version']=4294967296
data['policies'][str(data['key_version'])]={'activate_after_epoch':'0','expire_after_epoch':None,'revoked':False,'erased':False}
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/key_version_overflow" >> "$LOG"
before=$(sha256sum "$CASE/key_version_overflow/receive-state.json" | awk '{print $1}')
if "$EXE" seal-test "$CASE/key_version_overflow/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/plaintext.txt" "$CASE/key_version_overflow/overflow.ocm" > "$CASE/key-version-overflow.log" 2>&1; then
  printf 'key version overflow unexpectedly accepted\n' >&2
  exit 1
fi
python3 - "$CASE/key-version-overflow.log" "key version outside uint32" <<'PY'
import json,sys
record=json.loads(open(sys.argv[1]).read())
assert record['status'] == 'error' and sys.argv[2] in record['reason'], record
PY
test ! -e "$CASE/key_version_overflow/overflow.ocm"
after=$(sha256sum "$CASE/key_version_overflow/receive-state.json" | awk '{print $1}')
test "$before" = "$after"
cat "$CASE/key-version-overflow.log" >> "$LOG"
printf 'control=key_version_overflow rejected guard=key_version_uint32 receive_state_sha256=%s\n' "$after" >> "$LOG"

truncate -s 2999266 "$CASE/cap-exact.txt"
"$EXE" seal-test "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/cap-exact.txt" "$CASE/cap-exact.ocm" >> "$LOG"
"$EXE" open-test "$CASE/bob/recipient-secret-v2.json" "$CASE/bob/recipient-public.json" \
  "$CASE/cap-exact.ocm" "$CASE/cap-exact-open.txt" >> "$LOG"
cmp "$CASE/cap-exact.txt" "$CASE/cap-exact-open.txt"
python3 - "$CASE/cap-exact.ocm" >> "$LOG" <<'PY'
import base64,json,sys
raw=open(sys.argv[1],'rb').read()
assert len(raw) == 194 + 86 + 2999266 + 28
assert len(raw) <= 3000000
assert len(base64.b64encode(raw))+2 <= 4000002
print('positive=plaintext_cap_exact_round_trip envelope_bytes=%d wire_bytes=%d' % (len(raw),len(base64.b64encode(raw))+2))
PY
truncate -s 2999267 "$CASE/cap.txt"
before=$(sha256sum "$CASE/bob/receive-state.json" | awk '{print $1}')
if "$EXE" seal-test "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/cap.txt" "$CASE/cap.ocm" > "$CASE/plaintext-cap.log" 2>&1; then
  printf 'plaintext above admission cap unexpectedly accepted\n' >&2
  exit 1
fi
python3 - "$CASE/plaintext-cap.log" "plaintext outside limits" <<'PY'
import json,sys
record=json.loads(open(sys.argv[1]).read())
assert record['status'] == 'error' and sys.argv[2] in record['reason'], record
PY
test ! -e "$CASE/cap.ocm"
after=$(sha256sum "$CASE/bob/receive-state.json" | awk '{print $1}')
test "$before" = "$after"
cat "$CASE/plaintext-cap.log" >> "$LOG"
printf 'control=plaintext_cap_plus_one rejected guard=plaintext_outside_limits receive_state_sha256=%s\n' "$after" >> "$LOG"

prepare_case concurrent
before=$(sha256sum "$CASE/concurrent/receive-state.json" | awk '{print $1}')
set +e
"$EXE" open-test "$CASE/concurrent/recipient-secret-v2.json" "$CASE/concurrent/recipient-public.json" \
  "$CASE/concurrent/message.ocm" "$CASE/concurrent/first.txt" >> "$LOG" 2>&1 &
first=$!
"$EXE" open-test "$CASE/concurrent/recipient-secret-v2.json" "$CASE/concurrent/recipient-public.json" \
  "$CASE/concurrent/message.ocm" "$CASE/concurrent/second.txt" >> "$LOG" 2>&1 &
second=$!
wait "$first"
first_status=$?
wait "$second"
second_status=$?
set -e
python3 - "$CASE/concurrent/receive-state.json" "$CASE/concurrent/new.txt" "$before" "$first_status" "$second_status" "$CASE/concurrent/first.txt" "$CASE/concurrent/second.txt" >> "$LOG" <<'PY'
import base64,hashlib,json,os,sys
state_path,plain_path,before,first_status,second_status=sys.argv[1:6]
outputs=sys.argv[6:]
state=json.load(open(state_path))
assert len(state['windows']) == 1, state
assert len(state['inbox']) == 2, state
assert sorted([int(first_status),int(second_status)]) == [0,2], (first_status,second_status)
existing=[path for path in outputs if os.path.exists(path)]
assert len(existing) == 1, existing
plaintext=open(plain_path,'rb').read()
assert open(existing[0],'rb').read() == plaintext
record=state['inbox'][-1]
assert 'plaintext' not in record
assert open(os.path.join(os.path.dirname(state_path),record['path']),'rb').read() == plaintext
assert record['plaintext_bytes'] == len(plaintext)
print('positive=concurrent_duplicate_one_commit state_before_sha256=%s state_after_sha256=%s' % (before,hashlib.sha256(open(state_path,'rb').read()).hexdigest()))
PY
printf 'distinct concurrent message A\n' > "$CASE/concurrent/lost-a.txt"
printf 'distinct concurrent message B\n' > "$CASE/concurrent/lost-b.txt"
for name in lost-a lost-b; do
  "$EXE" seal-test "$CASE/concurrent/recipient-public.json" "$CASE/alice/sender-secret.json" \
    "$CASE/concurrent/$name.txt" "$CASE/concurrent/$name.ocm" >> "$LOG"
done
set +e
"$EXE" open-test "$CASE/concurrent/recipient-secret-v2.json" "$CASE/concurrent/recipient-public.json" \
  "$CASE/concurrent/lost-a.ocm" "$CASE/concurrent/lost-a-open.txt" >> "$LOG" 2>&1 &
first=$!
"$EXE" open-test "$CASE/concurrent/recipient-secret-v2.json" "$CASE/concurrent/recipient-public.json" \
  "$CASE/concurrent/lost-b.ocm" "$CASE/concurrent/lost-b-open.txt" >> "$LOG" 2>&1 &
second=$!
wait "$first"
first_status=$?
wait "$second"
second_status=$?
set -e
python3 - "$CASE/concurrent" "$first_status" "$second_status" >> "$LOG" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
assert [int(sys.argv[2]),int(sys.argv[3])] == [0,0], (sys.argv[2],sys.argv[3])
state=json.loads((root/'receive-state.json').read_text())
assert len(state['windows']) == 1 and len(state['inbox']) == 4, state
for name in ['lost-a','lost-b']:
    assert (root/(name+'-open.txt')).read_bytes() == (root/(name+'.txt')).read_bytes()
print('positive=concurrent_distinct_messages_no_lost_update')
PY

prepare_case crash_after_temp
before=$(sha256sum "$CASE/crash_after_temp/receive-state.json" | awk '{print $1}')
if "$EXE" open-fail-after-temp "$CASE/crash_after_temp/recipient-secret-v2.json" \
  "$CASE/crash_after_temp/recipient-public.json" "$CASE/crash_after_temp/message.ocm" \
  "$CASE/crash_after_temp/open.txt" >> "$LOG" 2>&1; then
  printf 'crash after temp unexpectedly accepted\n' >&2
  exit 1
fi
test ! -e "$CASE/crash_after_temp/open.txt"
after=$(sha256sum "$CASE/crash_after_temp/receive-state.json" | awk '{print $1}')
test "$before" = "$after"
"$EXE" open-test "$CASE/crash_after_temp/recipient-secret-v2.json" "$CASE/crash_after_temp/recipient-public.json" \
  "$CASE/crash_after_temp/message.ocm" "$CASE/crash_after_temp/restarted.txt" >> "$LOG"
cmp "$CASE/crash_after_temp/new.txt" "$CASE/crash_after_temp/restarted.txt"
printf 'control=crash_after_temp_no_commit_then_restart_recover state_sha256=%s\n' "$after" >> "$LOG"
expect_fail crash_after_temp_replay "replay rejected" \
  "$CASE/crash_after_temp/recipient-secret-v2.json" "$CASE/crash_after_temp/recipient-public.json" \
  "$CASE/crash_after_temp/message.ocm" "$CASE/crash_after_temp/replayed.txt"

prepare_case crash_after_rename
before=$(sha256sum "$CASE/crash_after_rename/receive-state.json" | awk '{print $1}')
if "$EXE" open-crash-after-rename "$CASE/crash_after_rename/recipient-secret-v2.json" \
  "$CASE/crash_after_rename/recipient-public.json" "$CASE/crash_after_rename/message.ocm" \
  "$CASE/crash_after_rename/open.txt" >> "$LOG" 2>&1; then
  printf 'crash after rename unexpectedly accepted\n' >&2
  exit 1
fi
test ! -e "$CASE/crash_after_rename/open.txt"
python3 - "$CASE/crash_after_rename/receive-state.json" "$CASE/crash_after_rename/new.txt" "$before" >> "$LOG" <<'PY'
import hashlib,json,os,sys
state=json.load(open(sys.argv[1]))
assert len(state['windows']) == 1 and len(state['inbox']) == 2
record=state['inbox'][-1]
assert 'plaintext' not in record
assert open(os.path.join(os.path.dirname(sys.argv[1]),record['path']),'rb').read() == open(sys.argv[2],'rb').read()
assert record['plaintext_bytes'] == os.path.getsize(sys.argv[2])
print('control=crash_after_rename_committed_before_restart state_before_sha256=%s state_after_sha256=%s' % (sys.argv[3],hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()))
PY
expect_fail crash_after_rename_replay "replay rejected" \
  "$CASE/crash_after_rename/recipient-secret-v2.json" "$CASE/crash_after_rename/recipient-public.json" \
  "$CASE/crash_after_rename/message.ocm" "$CASE/crash_after_rename/open-again.txt"

prepare_case receive_limit
expect_exec receive_limit "envelope exceeds receive limit" "$CASE/receive_limit" \
  open-limited "$CASE/receive_limit/recipient-secret-v2.json" "$CASE/receive_limit/recipient-public.json" \
  "$CASE/receive_limit/message.ocm" "$CASE/receive_limit/open.txt"
test ! -e "$CASE/receive_limit/open.txt"

prepare_case production_receive_cap
truncate -s 65228 "$CASE/production_receive_cap/exact.txt"
"$EXE" seal-test "$CASE/production_receive_cap/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/production_receive_cap/exact.txt" "$CASE/production_receive_cap/exact.ocm" >> "$LOG"
"$EXE" open "$CASE/production_receive_cap/recipient-secret-v2.json" \
  "$CASE/production_receive_cap/recipient-public.json" "$CASE/production_receive_cap/exact.ocm" \
  "$CASE/production_receive_cap/exact-open.txt" >> "$LOG"
cmp "$CASE/production_receive_cap/exact.txt" "$CASE/production_receive_cap/exact-open.txt"
truncate -s 65229 "$CASE/production_receive_cap/over.txt"
"$EXE" seal-test "$CASE/production_receive_cap/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/production_receive_cap/over.txt" "$CASE/production_receive_cap/over.ocm" >> "$LOG"
before=$(sha256sum "$CASE/production_receive_cap/receive-state.json" | awk '{print $1}')
if "$EXE" open "$CASE/production_receive_cap/recipient-secret-v2.json" \
  "$CASE/production_receive_cap/recipient-public.json" "$CASE/production_receive_cap/over.ocm" \
  "$CASE/production_receive_cap/over-open.txt" > "$CASE/production_receive_cap/over.log" 2>&1; then
  printf 'production default receive cap unexpectedly accepted 65537 bytes\n' >&2
  exit 1
fi
python3 - "$CASE/production_receive_cap/over.log" "$CASE/production_receive_cap/exact.ocm" \
  "$CASE/production_receive_cap/over.ocm" >> "$LOG" <<'PY'
import json,os,sys
assert json.loads(open(sys.argv[1]).read()) == {'status':'rejected'}
assert os.path.getsize(sys.argv[2]) == 65536
assert os.path.getsize(sys.argv[3]) == 65537
print('positive=production_receive_cap_exact_65536')
print('control=production_receive_cap_65537_rejected')
PY
test ! -e "$CASE/production_receive_cap/over-open.txt"
after=$(sha256sum "$CASE/production_receive_cap/receive-state.json" | awk '{print $1}')
test "$before" = "$after"

prepare_case store_prune_test
"$EXE" store-prune-test "$CASE/store_prune_test" >> "$LOG"
python3 - "$CASE/store_prune_test/receive-state.json" >> "$LOG" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
assert len(state['windows']) == 1 and len(state['inbox']) == 2, state
assert state['windows'][0]['high_water'] == 3, state
print('positive=replay_after_pruning_high_water_retained')
PY

prepare_case malformed_windows
python3 - "$CASE/malformed_windows/receive-state.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['windows']={}
open(path,'w').write(json.dumps(state)+'\n')
PY
expect_fail malformed_windows "invalid receive state field windows" \
  "$CASE/malformed_windows/recipient-secret-v2.json" "$CASE/malformed_windows/recipient-public.json" \
  "$CASE/malformed_windows/message.ocm" "$CASE/malformed_windows/open.txt"

prepare_case out_of_order_inside
"$EXE" receive-seed "$CASE/out_of_order_inside" 1 2 "$SENDER_PUBLIC" 2048 >> "$LOG"
"$EXE" seal-test "$CASE/out_of_order_inside/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/out_of_order_inside/new.txt" "$CASE/out_of_order_inside/out-of-order.ocm" 2047 >> "$LOG"
"$EXE" open-test "$CASE/out_of_order_inside/recipient-secret-v2.json" "$CASE/out_of_order_inside/recipient-public.json" \
  "$CASE/out_of_order_inside/out-of-order.ocm" "$CASE/out_of_order_inside/out-of-order.txt" >> "$LOG"
cmp "$CASE/out_of_order_inside/new.txt" "$CASE/out_of_order_inside/out-of-order.txt"
printf 'positive=out_of_order_inside_window\n' >> "$LOG"

prepare_case out_of_window
"$EXE" receive-seed "$CASE/out_of_window" 1 2 "$SENDER_PUBLIC" 2048 >> "$LOG"
"$EXE" seal-test "$CASE/out_of_window/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/out_of_window/new.txt" "$CASE/out_of_window/outside.ocm" 1024 >> "$LOG"
expect_fail out_of_window "sender sequence rollback" \
  "$CASE/out_of_window/recipient-secret-v2.json" "$CASE/out_of_window/recipient-public.json" \
  "$CASE/out_of_window/outside.ocm" "$CASE/out_of_window/open.txt"

prepare_case forward_jump
"$EXE" seal-test "$CASE/forward_jump/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/forward_jump/new.txt" "$CASE/forward_jump/forward.ocm" 4097 >> "$LOG"
"$EXE" open-test "$CASE/forward_jump/recipient-secret-v2.json" "$CASE/forward_jump/recipient-public.json" \
  "$CASE/forward_jump/forward.ocm" "$CASE/forward_jump/open.txt" >> "$LOG"
cmp "$CASE/forward_jump/new.txt" "$CASE/forward_jump/open.txt"
python3 - "$CASE/forward_jump/receive-state.json" >> "$LOG" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
assert any(row['high_water'] == 4097 for row in state['windows']), state
print('positive=large_forward_jump_advances_window')
PY

seal_sequence() {
  local name=$1 sequence=$2
  "$EXE" seal-test "$CASE/$name/recipient-public.json" "$CASE/alice/sender-secret.json" \
    "$CASE/$name/new.txt" "$CASE/$name/$sequence.ocm" "$sequence" >> "$LOG"
}
open_sequence() {
  local name=$1 sequence=$2
  "$EXE" open-test "$CASE/$name/recipient-secret-v1.json" "$CASE/$name/recipient-public.json" \
    "$CASE/$name/$sequence.ocm" "$CASE/$name/$sequence.txt" >> "$LOG"
  cmp "$CASE/$name/new.txt" "$CASE/$name/$sequence.txt"
}
for distance in 1 1023 1024 4097; do
  name="forward_distance_$distance"
  prepare_case "$name"
  sequence=$((1 + distance))
  seal_sequence "$name" "$sequence"
  open_sequence "$name" "$sequence"
  python3 - "$CASE/$name/receive-state.json" "$sequence" "$distance" >> "$LOG" <<'PY'
import base64,json,sys
state=json.load(open(sys.argv[1]))
sequence,distance=map(int,sys.argv[2:])
assert len(state['windows']) == 1, state['windows']
window=state['windows'][0]
bitmap=base64.b64decode(window['bitmap'],validate=True)
expected=1 if distance >= 1024 else (1 | (1 << distance))
assert window['high_water'] == sequence, window
assert len(bitmap) == 128 and int.from_bytes(bitmap,'little') == expected, (distance,window)
print('positive=forward_distance_int64 distance=%d high_water=%d bitmap_bits=%d' % (distance,sequence,expected))
PY
done

prepare_case forward_max
seal_sequence forward_max 2
open_sequence forward_max 2
seal_sequence forward_max 3
open_sequence forward_max 3
mkdir -p "$CASE/forward_max_other"
"$EXE" recipient-init "$CASE/forward_max_other" "$SENDER_PUBLIC" >> "$LOG"
printf 'independent contact\n' > "$CASE/forward_max_other/new.txt"
"$EXE" seal-test "$CASE/forward_max_other/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/forward_max_other/new.txt" "$CASE/forward_max_other/7.ocm" 7 >> "$LOG"
"$EXE" open-test "$CASE/forward_max_other/recipient-secret-v1.json" \
  "$CASE/forward_max_other/recipient-public.json" "$CASE/forward_max_other/7.ocm" \
  "$CASE/forward_max_other/7.txt" >> "$LOG"
seal_sequence forward_max 9223372036854775806
open_sequence forward_max 9223372036854775806
seal_sequence forward_max 9223372036854775807
open_sequence forward_max 9223372036854775807
expect_fail forward_max_duplicate "replay rejected" "$CASE/forward_max/recipient-secret-v1.json" \
  "$CASE/forward_max/recipient-public.json" "$CASE/forward_max/9223372036854775807.ocm" \
  "$CASE/forward_max/duplicate.txt"
seal_sequence forward_max 9223372036854774783
expect_fail forward_max_too_old "sender sequence rollback" "$CASE/forward_max/recipient-secret-v1.json" \
  "$CASE/forward_max/recipient-public.json" "$CASE/forward_max/9223372036854774783.ocm" \
  "$CASE/forward_max/too-old.txt"
seal_sequence forward_max 9223372036854775805
open_sequence forward_max 9223372036854775805
python3 - "$CASE/forward_max/receive-state.json" "$CASE/forward_max_other/receive-state.json" >> "$LOG" <<'PY'
import base64,json,sys
state=json.load(open(sys.argv[1]))
other=json.load(open(sys.argv[2]))
window=state['windows'][0]
bits=int.from_bytes(base64.b64decode(window['bitmap'],validate=True),'little')
assert window['high_water'] == 9223372036854775807 and bits == 7, (window,bits)
assert other['windows'][0]['high_water'] == 7, other['windows']
assert int.from_bytes(base64.b64decode(other['windows'][0]['bitmap'],validate=True),'little') == 1
print('positive=populated_window_max_int_next_unseen_duplicate_too_old independent_contact=unchanged')
PY

for name in corrupt_hw_zero corrupt_hw_negative corrupt_hw_overflow corrupt_bitmap_short corrupt_bitmap_long corrupt_bitmap_base64; do
  prepare_case "$name"
done
python3 - "$CASE" <<'PY'
import base64,json,sys
from pathlib import Path
root=Path(sys.argv[1])
for name,value in [('corrupt_hw_zero',0),('corrupt_hw_negative',-1),('corrupt_hw_overflow','9223372036854775808')]:
    path=root/name/'receive-state.json'
    state=json.loads(path.read_text())
    state['windows'][0]['high_water']=value
    path.write_text(json.dumps(state)+'\n')
for name,size in [('corrupt_bitmap_short',127),('corrupt_bitmap_long',129)]:
    path=root/name/'receive-state.json'
    state=json.loads(path.read_text())
    state['windows'][0]['bitmap']=base64.b64encode(bytes(size)).decode()
    path.write_text(json.dumps(state)+'\n')
path=root/'corrupt_bitmap_base64'/'receive-state.json'
state=json.loads(path.read_text())
state['windows'][0]['bitmap']='not base64'
path.write_text(json.dumps(state)+'\n')
PY
expect_fail corrupt_hw_zero "invalid receive replay high-water" "$CASE/corrupt_hw_zero/recipient-secret-v1.json" \
  "$CASE/corrupt_hw_zero/recipient-public.json" "$CASE/corrupt_hw_zero/message.ocm" "$CASE/corrupt_hw_zero/open.txt"
expect_fail corrupt_hw_negative "invalid receive replay high-water" "$CASE/corrupt_hw_negative/recipient-secret-v1.json" \
  "$CASE/corrupt_hw_negative/recipient-public.json" "$CASE/corrupt_hw_negative/message.ocm" "$CASE/corrupt_hw_negative/open.txt"
expect_fail corrupt_hw_overflow "invalid integer field high_water" "$CASE/corrupt_hw_overflow/recipient-secret-v1.json" \
  "$CASE/corrupt_hw_overflow/recipient-public.json" "$CASE/corrupt_hw_overflow/message.ocm" "$CASE/corrupt_hw_overflow/open.txt"
expect_fail corrupt_bitmap_short "invalid receive replay bitmap size" "$CASE/corrupt_bitmap_short/recipient-secret-v1.json" \
  "$CASE/corrupt_bitmap_short/recipient-public.json" "$CASE/corrupt_bitmap_short/message.ocm" "$CASE/corrupt_bitmap_short/open.txt"
expect_fail corrupt_bitmap_long "invalid receive replay bitmap size" "$CASE/corrupt_bitmap_long/recipient-secret-v1.json" \
  "$CASE/corrupt_bitmap_long/recipient-public.json" "$CASE/corrupt_bitmap_long/message.ocm" "$CASE/corrupt_bitmap_long/open.txt"
expect_fail corrupt_bitmap_base64 "invalid receive replay bitmap encoding" "$CASE/corrupt_bitmap_base64/recipient-secret-v1.json" \
  "$CASE/corrupt_bitmap_base64/recipient-public.json" "$CASE/corrupt_bitmap_base64/message.ocm" "$CASE/corrupt_bitmap_base64/open.txt"

prepare_case future_epoch
"$EXE" seal-epoch-test "$CASE/future_epoch/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/future_epoch/new.txt" "$CASE/future_epoch/future.ocm" 13 >> "$LOG"
expect_fail future_epoch "sender epoch exceeds live future tolerance" \
  "$CASE/future_epoch/recipient-secret-v2.json" "$CASE/future_epoch/recipient-public.json" \
  "$CASE/future_epoch/future.ocm" "$CASE/future_epoch/open.txt"

prepare_case future_tolerance
"$EXE" seal-epoch-test "$CASE/future_tolerance/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/future_tolerance/new.txt" "$CASE/future_tolerance/future.ocm" 12 >> "$LOG"
"$EXE" open-test "$CASE/future_tolerance/recipient-secret-v2.json" "$CASE/future_tolerance/recipient-public.json" \
  "$CASE/future_tolerance/future.ocm" "$CASE/future_tolerance/open.txt" >> "$LOG"
cmp "$CASE/future_tolerance/new.txt" "$CASE/future_tolerance/open.txt"
printf 'positive=live_future_tolerance_two_epochs\n' >> "$LOG"

prepare_case stale_epoch
python3 - "$CASE/stale_epoch/recipient-public.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['current_epoch']=100
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/stale_epoch" >> "$LOG"
"$EXE" seal-epoch-test "$CASE/stale_epoch/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/stale_epoch/new.txt" "$CASE/stale_epoch/stale.ocm" 0 >> "$LOG"
expect_fail stale_epoch "sender epoch is stale for live delivery" \
  "$CASE/stale_epoch/recipient-secret-v2.json" "$CASE/stale_epoch/recipient-public.json" \
  "$CASE/stale_epoch/stale.ocm" "$CASE/stale_epoch/open.txt"
"$EXE" open-archive-test "$CASE/stale_epoch/recipient-secret-v2.json" "$CASE/stale_epoch/recipient-public.json" \
  "$CASE/stale_epoch/stale.ocm" "$CASE/stale_epoch/archive.txt" 100 >> "$LOG"
cmp "$CASE/stale_epoch/new.txt" "$CASE/stale_epoch/archive.txt"
printf 'positive=archive_uses_commit_epoch_not_live_age\n' >> "$LOG"
"$EXE" seal-epoch-test "$CASE/stale_epoch/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/stale_epoch/new.txt" "$CASE/stale_epoch/future-after-commit.ocm" 13 >> "$LOG"
expect_exec stale_archive_future "sender epoch is after frame commit epoch" "$CASE/stale_epoch" \
  open-archive-test "$CASE/stale_epoch/recipient-secret-v2.json" "$CASE/stale_epoch/recipient-public.json" \
  "$CASE/stale_epoch/future-after-commit.ocm" "$CASE/stale_epoch/future.txt" 12

prepare_case sender_instance
"$EXE" corrupt sender-instance "$CASE/sender_instance/message.ocm" "$CASE/alice/sender-secret.json" \
  "$CASE/sender_instance/resigned.ocm" >> "$LOG"
expect_fail sender_instance "ciphertext authentication failed" \
  "$CASE/sender_instance/recipient-secret-v2.json" "$CASE/sender_instance/recipient-public.json" \
  "$CASE/sender_instance/resigned.ocm" "$CASE/sender_instance/open.txt"

prepare_case rollback_after_restart
"$EXE" outbox-prepare "$CASE/rollback_after_restart/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/rollback_after_restart/new.txt" "$CASE/rollback_after_restart" >> "$LOG"
"$EXE" open-test "$CASE/rollback_after_restart/recipient-secret-v2.json" "$CASE/rollback_after_restart/recipient-public.json" \
  "$CASE/rollback_after_restart/prepared.ocm" "$CASE/rollback_after_restart/first.txt" >> "$LOG"
cmp "$CASE/rollback_after_restart/new.txt" "$CASE/rollback_after_restart/first.txt"
python3 - "$CASE/rollback_after_restart/outbox.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['channels'][0]['next_sequence']=1
open(path,'w').write(json.dumps(data)+'\n')
PY
printf 'restart reuses a rolled-back counter\n' > "$CASE/rollback_after_restart/restart.txt"
"$EXE" outbox-prepare "$CASE/rollback_after_restart/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/rollback_after_restart/restart.txt" "$CASE/rollback_after_restart" >> "$LOG"
expect_fail rollback_after_restart "replay rejected" \
  "$CASE/rollback_after_restart/recipient-secret-v2.json" "$CASE/rollback_after_restart/recipient-public.json" \
  "$CASE/rollback_after_restart/prepared.ocm" "$CASE/rollback_after_restart/open.txt"

prepare_case v1_rewrap
python3 - "$CASE/v1_rewrap/message.ocm" "$CASE/v1_rewrap/rewrap-a.ocm" "$CASE/v1_rewrap/rewrap-b.ocm" <<'PY'
import sys
raw=bytearray(open(sys.argv[1],'rb').read())
for index,path in enumerate(sys.argv[2:],1):
    raw[6]=0
    raw[7]=1
    raw[18:26]=index.to_bytes(8,'big')
    open(path,'wb').write(raw)
PY
expect_fail v1_rewrap_a "unsupported version 1" \
  "$CASE/v1_rewrap/recipient-secret-v2.json" "$CASE/v1_rewrap/recipient-public.json" \
  "$CASE/v1_rewrap/rewrap-a.ocm" "$CASE/v1_rewrap/open-a.txt"
expect_fail v1_rewrap_b "unsupported version 1" \
  "$CASE/v1_rewrap/recipient-secret-v2.json" "$CASE/v1_rewrap/recipient-public.json" \
  "$CASE/v1_rewrap/rewrap-b.ocm" "$CASE/v1_rewrap/open-b.txt"
python3 - "$CASE/v1_rewrap/message.ocm" "$CASE/v1_rewrap/legacy-tag.ocm" <<'PY'
import sys
raw=open(sys.argv[1],'rb').read()
open(sys.argv[2],'wb').write(b'OCMMSG1'+raw[7:])
PY
expect_fail v1_legacy_tag "unsupported version 12546" \
  "$CASE/v1_rewrap/recipient-secret-v2.json" "$CASE/v1_rewrap/recipient-public.json" \
  "$CASE/v1_rewrap/legacy-tag.ocm" "$CASE/v1_rewrap/open-legacy.txt"

prepare_case downgrade
python3 - "$CASE/downgrade/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
raw[6]=0
raw[7]=1
open(path,'wb').write(raw)
PY
expect_fail downgrade "unsupported version 1" \
  "$CASE/downgrade/recipient-secret-v2.json" "$CASE/downgrade/recipient-public.json" \
  "$CASE/downgrade/message.ocm" "$CASE/downgrade/open.txt"

prepare_case dedup_prune
python3 - "$CASE/dedup_prune/recipient-public.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['accepted_previous_versions']=[]
data['grace_previous_versions']=[]
open(path,'w').write(json.dumps(data)+'\n')
PY
"$EXE" resign-config "$CASE/dedup_prune" >> "$LOG"
"$EXE" receive-seed "$CASE/dedup_prune" 10000 1 >> "$LOG"
"$EXE" open-test "$CASE/dedup_prune/recipient-secret-v2.json" "$CASE/dedup_prune/recipient-public.json" \
  "$CASE/dedup_prune/message.ocm" "$CASE/dedup_prune/open.txt" >> "$LOG"
cmp "$CASE/dedup_prune/new.txt" "$CASE/dedup_prune/open.txt"
python3 - "$CASE/dedup_prune" >> "$LOG" <<'PY'
import json,os,sys
root=sys.argv[1]
state=json.load(open(os.path.join(root,'receive-state.json')))
assert len(state['windows']) == 11 and len(state['inbox']) == 1, state
record=state['inbox'][-1]
assert 'plaintext' not in record
assert open(os.path.join(root,record['path']),'rb').read() == open(os.path.join(root,'new.txt'),'rb').read()
assert os.path.isfile(os.path.join(root,'messages','seed.bin'))
print('positive=dedup_out_of_grace_pruning_allows_receive plaintext_files_fsynced state_has_pointers_only')
PY

mkdir -p "$CASE/charlie"
CHARLIE_PUBLIC=$("$EXE" sender-init "$CASE/charlie" 3 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["sender_public"])')
positive_other_sender() {
  local name=$1
  python3 - "$CASE/$name/recipient-public.json" "$CHARLIE_PUBLIC" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
data['expected_sender_public']=sys.argv[2]
open(path,'w').write(json.dumps(data)+'\n')
PY
  "$EXE" resign-config "$CASE/$name" >> "$LOG"
  "$EXE" seal-test "$CASE/$name/recipient-public.json" "$CASE/charlie/sender-secret.json" \
    "$CASE/$name/new.txt" "$CASE/$name/other.ocm" >> "$LOG"
  "$EXE" open-test "$CASE/$name/recipient-secret-v2.json" "$CASE/$name/recipient-public.json" \
    "$CASE/$name/other.ocm" "$CASE/$name/other-open.txt" >> "$LOG"
  cmp "$CASE/$name/new.txt" "$CASE/$name/other-open.txt"
  python3 - "$CASE/$name/receive-state.json" "$CHARLIE_PUBLIC" >> "$LOG" <<'PY'
import base64,hashlib,json,struct,sys
state=json.load(open(sys.argv[1]))
record=state['inbox'][-1]
def field(value):
    return struct.pack('>I',len(value))+value
raw=(b'octra:msg:replay-window:v2\0'+struct.pack('>H',2)+
     field(base64.b64decode(record['context']))+
     field(base64.b64decode(record['recipient_view_public']))+
     struct.pack('>I',record['key_version'])+
     field(base64.b64decode(sys.argv[2]))+
     field(base64.b64decode(record['sender_instance'])))
assert len(state['windows']) == 2, state['windows']
assert state['windows'][-1]['key'] == hashlib.sha256(raw).hexdigest()
assert state['windows'][0]['key'] != state['windows'][1]['key']
assert record['sender_public'] == sys.argv[2]
PY
  printf 'positive=%s_does_not_block_other_sender\n' "$name" >> "$LOG"
}

prepare_case sender_dedup_cap
"$EXE" receive-seed "$CASE/sender_dedup_cap" 1000 2 "$SENDER_PUBLIC" >> "$LOG"
expect_fail sender_dedup_cap "receive sender state capacity reached" \
  "$CASE/sender_dedup_cap/recipient-secret-v2.json" "$CASE/sender_dedup_cap/recipient-public.json" \
  "$CASE/sender_dedup_cap/message.ocm" "$CASE/sender_dedup_cap/open.txt"
positive_other_sender sender_dedup_cap

prepare_case sender_byte_cap
"$EXE" receive-seed "$CASE/sender_byte_cap" 1 2 "$SENDER_PUBLIC" >> "$LOG"
truncate -s 51200001 "$CASE/sender_byte_cap/messages/seed.bin"
expect_fail sender_byte_cap "receive sender byte capacity reached" \
  "$CASE/sender_byte_cap/recipient-secret-v2.json" "$CASE/sender_byte_cap/recipient-public.json" \
  "$CASE/sender_byte_cap/message.ocm" "$CASE/sender_byte_cap/open.txt"
positive_other_sender sender_byte_cap

prepare_case dedup_cap
"$EXE" receive-seed "$CASE/dedup_cap" 10000 2 >> "$LOG"
expect_fail dedup_cap "receive state capacity reached" \
  "$CASE/dedup_cap/recipient-secret-v2.json" "$CASE/dedup_cap/recipient-public.json" \
  "$CASE/dedup_cap/message.ocm" "$CASE/dedup_cap/open.txt"

prepare_case byte_cap
"$EXE" receive-seed "$CASE/byte_cap" 1 2 >> "$LOG"
truncate -s 512000001 "$CASE/byte_cap/messages/seed.bin"
expect_fail byte_cap "receive byte capacity reached" \
  "$CASE/byte_cap/recipient-secret-v2.json" "$CASE/byte_cap/recipient-public.json" \
  "$CASE/byte_cap/message.ocm" "$CASE/byte_cap/open.txt"

prepare_case multi_device
mkdir -p "$CASE/device-a" "$CASE/device-b"
cp "$CASE/alice/sender-secret.json" "$CASE/device-a/sender-secret.json"
cp "$CASE/alice/sender-secret.json" "$CASE/device-b/sender-secret.json"
"$EXE" send "$CASE/multi_device/recipient-public.json" "$CASE/device-a/sender-secret.json" \
  "$CASE/multi_device/new.txt" "$CASE/multi_device/device-a.ocm" >> "$LOG"
"$EXE" send "$CASE/multi_device/recipient-public.json" "$CASE/device-b/sender-secret.json" \
  "$CASE/multi_device/new.txt" "$CASE/multi_device/device-b.ocm" >> "$LOG"
"$EXE" open-test "$CASE/multi_device/recipient-secret-v2.json" "$CASE/multi_device/recipient-public.json" \
  "$CASE/multi_device/device-a.ocm" "$CASE/multi_device/device-a.txt" >> "$LOG"
"$EXE" open-test "$CASE/multi_device/recipient-secret-v2.json" "$CASE/multi_device/recipient-public.json" \
  "$CASE/multi_device/device-b.ocm" "$CASE/multi_device/device-b.txt" >> "$LOG"
cmp "$CASE/multi_device/new.txt" "$CASE/multi_device/device-a.txt"
cmp "$CASE/multi_device/new.txt" "$CASE/multi_device/device-b.txt"
python3 - "$CASE/multi_device/device-a.ocm" "$CASE/multi_device/device-b.ocm" \
  "$CASE/multi_device/receive-state.json" >> "$LOG" <<'PY'
import json,sys
left=open(sys.argv[1],'rb').read()
right=open(sys.argv[2],'rb').read()
assert int.from_bytes(left[18:26],'big') == 1
assert int.from_bytes(right[18:26],'big') == 1
assert left[114:130] != right[114:130]
state=json.load(open(sys.argv[3]))
assert len(state['windows']) == 3, state['windows']
print('positive=two_devices_same_identity_independent_channels')
PY

python3 - "$LOG" <<'PY'
import json,sys
for line in open(sys.argv[1]):
    line=line.strip()
    if line.startswith('{'):
        json.loads(line)
print('receipts=valid_json')
PY

printf 'controls=all_failures_preserve_receive_state\n' >> "$LOG"
python3 - "$CASE" "$SCRATCH/receipts/sender.strace" <<'PY'
import hashlib,json,sys
from pathlib import Path
case,trace=sys.argv[1:]
receipt={
  'sender_process_inputs':[
    'own synthetic Ed25519 secret',
    'signed recipient public view key, version, context, policy and epoch',
    'pinned test contact root (public-constant-derived fixture; B6 deferred to on-chain registration)',
    'plaintext',
    'production native RNG; no caller message ID, ephemeral secret or nonce'
  ],
  'sender_recipient_secret_input':False,
  'recipient_offline_during_seal':True,
  'sender_strace':'sender.strace contains no recipient-secret, messaging-secret or contact-secret open',
  'sender_strace_sha256':hashlib.sha256(Path(trace).read_bytes()).hexdigest(),
  'case_directory':case,
  'secret_files':'Synthetic endpoint secrets and receive state remain in the isolated VPS case directory and are not published.',
  'key_custody':'Recipient messaging secrets are dedicated X25519 keys; Ed25519 is only the synthetic sender/contact identity. No wallet seed is used.'
}
Path(case).parent.parent.joinpath('receipts','access.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
"$PROJECT/tests/write_receipt_environment.sh" "$EXE" "$SCRATCH/library-build/default/tests/size_sweep.exe" "$SCRATCH"
mkdir -p "$PROJECT/receipts/recipient"
cp "$SCRATCH/receipts/endpoint.txt" "$SCRATCH/receipts/sender.strace" \
  "$SCRATCH/receipts/environment.json" "$SCRATCH/receipts/sizes-environment.json" \
  "$SCRATCH/receipts/access.json" "$PROJECT/receipts/recipient/"
cat "$LOG"
