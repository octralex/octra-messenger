#!/usr/bin/env bash
set -euo pipefail

PIN=3aab2d992035076dd216ad8808710d3a5a56063a
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=${MESSENGER_SCRATCH:-/srv/octra-node/fakenet-kimi-messenger}
SOURCE=${OCTRA_NODE_SOURCE:-$SCRATCH/src/lite_node}
UPSTREAM=${OCTRA_UPSTREAM_CLONE:-/home/kimi/workspace/upstream-heads/lite_node}
SWITCH=${OCTRA_OPAM_SWITCH:-/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml}
JOBS=${BUILD_JOBS:-2}

if [ ! -d "$SOURCE/.git" ]; then
  mkdir -p "$SCRATCH/src"
  git clone --shared "$UPSTREAM" "$SOURCE"
fi
git -C "$SOURCE" checkout --quiet --detach "$PIN"
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN"
for file in recipient_message_core.ml recipient_message.ml recipient_message.mli recipient_message_testkit.ml recipient_keys.ml recipient_keys.mli; do
  cp "$PROJECT/lib/crypto/$file" "$SOURCE/test/$file"
done
for file in receive_store.ml outbox_journal.ml; do
  cp "$PROJECT/lib/storage/$file" "$SOURCE/test/$file"
done
cp "$PROJECT/tests/recipient_endpoint.ml" "$SOURCE/test/recipient_endpoint.ml"
cp "$PROJECT/tests/size_sweep.ml" "$SOURCE/test/size_sweep.ml"
cp "$PROJECT/lib/crypto/pvac_slots.ml" "$SOURCE/test/pvac_slots.ml"
cp "$PROJECT/lib/crypto/pvac_message.ml" "$SOURCE/test/pvac_message.ml"
sed -i 's/(modules size_sweep recipient_message_core recipient_message recipient_message_testkit pvac_slots pvac_message)/(modules size_sweep recipient_message_core recipient_message recipient_message_testkit recipient_keys pvac_slots pvac_message)/' "$SOURCE/test/dune"
if ! grep -q '(name recipient_endpoint)' "$SOURCE/test/dune"; then
  printf '\n(executable\n (name recipient_endpoint)\n (modules recipient_endpoint recipient_message_core recipient_message recipient_message_testkit recipient_keys receive_store outbox_journal)\n (libraries octra_core mirage-crypto mirage-crypto-ec mirage-crypto-rng.unix digestif yojson base64 unix))\n\n(executable\n (name size_sweep)\n (modules size_sweep recipient_message_core recipient_message recipient_message_testkit recipient_keys pvac_slots pvac_message)\n (libraries octra_core pvac_ffi mirage-crypto mirage-crypto-ec mirage-crypto-rng.unix digestif yojson base64 unix))\n' >> "$SOURCE/test/dune"
fi
mkdir -p "$SCRATCH/tmp" "$SCRATCH/link-libs" "$SCRATCH/receipts" "$SOURCE/mcl/obj" "$SOURCE/mcl/lib"
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
python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" --profile release -j "$JOBS" test/recipient_endpoint.exe test/size_sweep.exe
EXE="$SOURCE/_build/default/test/recipient_endpoint.exe"

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
for name,a,b in [('message_id',left[17:33],right[17:33]),('ephemeral',left[33:65],right[33:65]),('nonce',left[-49:-37],right[-49:-37])]:
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
testkit=(root/'lib/crypto/recipient_message_testkit.ml').read_text()
assert '~message_id' in testkit and '~ephemeral_secret' in testkit and '~nonce' in testkit
print('positive=production_seal_randomized_only_deterministic_material_testkit_only')
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
"$EXE" outbox-retry "$CASE/outbox" "$CASE/retry.ocm" >> "$LOG"
cmp "$CASE/outbox/prepared.ocm" "$CASE/retry.ocm"
"$EXE" outbox-mark "$CASE/outbox" submitted >> "$LOG"
"$EXE" outbox-mark "$CASE/outbox" finalized >> "$LOG"
"$EXE" outbox-retry "$CASE/outbox" "$CASE/retry-final.ocm" >> "$LOG"
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
raw[33]^=1
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
raw[17]^=1
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
  expect_fail "aead_$mode" "ciphertext authentication failed" \
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
raw[13]^=1
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
raw[161]^=1
open(path,'wb').write(raw)
PY
expect_fail modified_context "wrong chain, application or registry context" \
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
raw[6]=ord('2')
open(path,'wb').write(raw)
PY
expect_fail unsupported_version "unsupported envelope version" \
  "$CASE/unsupported_version/recipient-secret-v2.json" "$CASE/unsupported_version/recipient-public.json" \
  "$CASE/unsupported_version/message.ocm" "$CASE/unsupported_version/open.txt"

prepare_case modified_signature
python3 - "$CASE/modified_signature/message.ocm" <<'PY'
import sys
path=sys.argv[1]
raw=bytearray(open(path,'rb').read())
raw[97]^=1
open(path,'wb').write(raw)
PY
expect_fail modified_signature "sender authentication failed" \
  "$CASE/modified_signature/recipient-secret-v2.json" "$CASE/modified_signature/recipient-public.json" \
  "$CASE/modified_signature/message.ocm" "$CASE/modified_signature/open.txt"

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
expect_fail unexpected_sender "unexpected sender identity" \
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

truncate -s 2999299 "$CASE/cap-exact.txt"
"$EXE" seal-test "$CASE/bob/recipient-public.json" "$CASE/alice/sender-secret.json" \
  "$CASE/cap-exact.txt" "$CASE/cap-exact.ocm" >> "$LOG"
"$EXE" open "$CASE/bob/recipient-secret-v2.json" "$CASE/bob/recipient-public.json" \
  "$CASE/cap-exact.ocm" "$CASE/cap-exact-open.txt" >> "$LOG"
cmp "$CASE/cap-exact.txt" "$CASE/cap-exact-open.txt"
python3 - "$CASE/cap-exact.ocm" >> "$LOG" <<'PY'
import base64,json,sys
raw=open(sys.argv[1],'rb').read()
assert len(raw) == 161 + 77 + 2999299 + 28
assert len(raw) <= 3000000
assert len(base64.b64encode(raw))+2 <= 4000002
print('positive=plaintext_cap_exact_round_trip envelope_bytes=%d wire_bytes=%d' % (len(raw),len(base64.b64encode(raw))+2))
PY
truncate -s 2999300 "$CASE/cap.txt"
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
assert len(state['dedup']) == 2, state
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
assert len(state['dedup']) == 4 and len(state['inbox']) == 4, state
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
assert len(state['dedup']) == 2 and len(state['inbox']) == 2
record=state['inbox'][-1]
assert 'plaintext' not in record
assert open(os.path.join(os.path.dirname(sys.argv[1]),record['path']),'rb').read() == open(sys.argv[2],'rb').read()
assert record['plaintext_bytes'] == os.path.getsize(sys.argv[2])
print('control=crash_after_rename_committed_before_restart state_before_sha256=%s state_after_sha256=%s' % (sys.argv[3],hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()))
PY
expect_fail crash_after_rename_replay "replay rejected" \
  "$CASE/crash_after_rename/recipient-secret-v2.json" "$CASE/crash_after_rename/recipient-public.json" \
  "$CASE/crash_after_rename/message.ocm" "$CASE/crash_after_rename/open-again.txt"

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
assert len(state['dedup']) == 1 and len(state['inbox']) == 1, state
record=state['inbox'][0]
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
import json,sys
state=json.load(open(sys.argv[1]))
assert state['dedup'][-1]['sender_public'] == sys.argv[2]
assert state['inbox'][-1]['sender_public'] == sys.argv[2]
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
"$PROJECT/tests/write_receipt_environment.sh" "$EXE" "$SOURCE/_build/default/test/size_sweep.exe" "$SCRATCH"
mkdir -p "$PROJECT/receipts/recipient"
cp "$SCRATCH/receipts/endpoint.txt" "$SCRATCH/receipts/sender.strace" \
  "$SCRATCH/receipts/environment.json" "$SCRATCH/receipts/sizes-environment.json" \
  "$SCRATCH/receipts/access.json" "$PROJECT/receipts/recipient/"
cat "$LOG"
