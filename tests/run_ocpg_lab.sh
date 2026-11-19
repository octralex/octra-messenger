#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
set -euo pipefail

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${OCTRA_NODE_SOURCE:-/srv/octra-node/fakenet-kimi-messenger/devnet-src/lite_node}
SWITCH=${OCTRA_OPAM_SWITCH:-/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml}
PIN=8f785a93a4e7392a0f3e65674f9de89854d33dbc
RUN_ID=${MESSENGER_OCPG_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
VENUE=${MESSENGER_OCPG_VENUE:-/srv/octra-node/fakenet-kimi-messenger/ocpg-lab/run-$RUN_ID}
UNIT_PREFIX=${MESSENGER_UNIT_PREFIX:-octra-kimi-ocpg-lab}
SLICE=${MESSENGER_SLICE:-kimi-ocpg-lab.slice}
RPC_PORT=${MESSENGER_RPC_PORT:-18271}
CHAIN_ID=${MESSENGER_CHAIN_ID:-octra-devnet-9871-cluster}
PROFILE=${MESSENGER_BFT_RELEASE_PROFILE:-}
ADMIT_OPS=${MESSENGER_ADMIT_OPS:-deploy_circle,circle_call}
PREVERIFY_EPOCH=${MESSENGER_PREVERIFY_RECEIPT_ACTIVATION_EPOCH:-1000000000}
LMDB_SOURCE=${MESSENGER_LMDB_SOURCE:-/srv/octra-node/fakenet-kimi-messenger/ocpg-lab/lmdb-source}
KEY_ID=${MESSENGER_ATTEST_KEY_ID:-lab-messenger-ocpg-v1}
KEY_FILE=$VENUE/work/release-key.bin
STARTED=0

cleanup() {
  status=$?
  if [ "$STARTED" = 1 ]; then
    MESSENGER_CHAIN_VENUE="$VENUE" MESSENGER_UNIT_PREFIX="$UNIT_PREFIX" MESSENGER_SLICE="$SLICE" \
      bash "$PROJECT/tests/run_chain_spike.sh" stop >/dev/null 2>&1 || true
  fi
  rm -f "$KEY_FILE"
  exit "$status"
}
trap cleanup EXIT

test "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN"
for patch in "$PROJECT/native/byte-literals.patch" "$PROJECT/native/circle-typed-storage.patch"; do
  if git -C "$SOURCE" apply --reverse --check "$patch" 2>/dev/null; then
    :
  else
    git -C "$SOURCE" apply --check "$patch"
    git -C "$SOURCE" apply "$patch"
  fi
done
mkdir -p "$VENUE/bin" "$VENUE/work" "$VENUE/receipts" "$VENUE/tmp" /srv/octra-node/fakenet-kimi-messenger/link-libs
ln -sf /usr/lib/x86_64-linux-gnu/liblmdb.so.0.0.0 /srv/octra-node/fakenet-kimi-messenger/link-libs/liblmdb.so
ln -sf /srv/octra-node/runtime-libs/libev.so.4 /srv/octra-node/fakenet-kimi-messenger/link-libs/libev.so
ln -sf /srv/octra-node/runtime-libs/libleveldb.so.1d /srv/octra-node/fakenet-kimi-messenger/link-libs/libleveldb.so
ln -sf /srv/octra-node/runtime-libs/libsnappy.so.1 /srv/octra-node/fakenet-kimi-messenger/link-libs/libsnappy.so

eval $(opam env --switch="$SWITCH" --set-switch)
export LIBRARY_PATH=/srv/octra-node/fakenet-kimi-messenger/link-libs
export LD_LIBRARY_PATH=/srv/octra-node/runtime-libs:/srv/octra-node/fakenet-kimi-messenger/link-libs
export TMPDIR="$VENUE/tmp"
if [ ! -f "$LMDB_SOURCE/liblmdb/libraries/liblmdb/mdb.c" ]; then
  opam source --dir "$LMDB_SOURCE" lmdb.1.1.1
fi
LMDB_SRC=$LMDB_SOURCE/liblmdb/libraries/liblmdb
mkdir -p "$VENUE/lmdb-build" "$VENUE/lmdb-lib"
gcc -O2 -fPIC -I"$LMDB_SRC" -c "$LMDB_SRC/mdb.c" -o "$VENUE/lmdb-build/mdb.o"
gcc -O2 -fPIC -I"$LMDB_SRC" -c "$LMDB_SRC/midl.c" -o "$VENUE/lmdb-build/midl.o"
ar rcs "$VENUE/lmdb-lib/liblmdb.a" "$VENUE/lmdb-build/mdb.o" "$VENUE/lmdb-build/midl.o"
export LIBRARY_PATH="$VENUE/lmdb-lib:$LIBRARY_PATH"
LMDB_SHA=$(sha256sum "$VENUE/lmdb-lib/liblmdb.a" | awk '{print $1}')
cp "$PROJECT/tests/segment_spike_driver.ml" "$SOURCE/test/messenger_segment_spike.ml"
sed -i 's/(libraries octra_net octra_vm octra_core zarith/(libraries octra_net octra_circle_runtime octra_vm octra_core zarith/' "$SOURCE/test/dune"
if ! grep -q '(name messenger_segment_spike)' "$SOURCE/test/dune"; then
  printf '\n(test\n (name messenger_segment_spike)\n (modules messenger_segment_spike)\n (libraries octra_net octra_circle_runtime octra_vm octra_core zarith base64 lwt.unix unix digestif yojson))\n' >> "$SOURCE/test/dune"
fi
python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" --profile release -j 2 \
  bin/octra_node.exe bin/octra_pvac_worker.exe test/messenger_segment_spike.exe
install -m 755 "$SOURCE/_build/default/bin/octra_node.exe" "$VENUE/bin/octra_node.exe"
install -m 755 "$SOURCE/_build/default/bin/octra_pvac_worker.exe" "$VENUE/bin/octra_pvac_worker.exe"
install -m 755 "$SOURCE/_build/default/test/messenger_segment_spike.exe" "$VENUE/bin/messenger_segment_spike.exe"

NODE_SHA=$(sha256sum "$VENUE/bin/octra_node.exe" | awk '{print $1}')
WORKER_SHA=$(sha256sum "$VENUE/bin/octra_pvac_worker.exe" | awk '{print $1}')
SEGMENT_SHA=$(sha256sum "$VENUE/bin/messenger_segment_spike.exe" | awk '{print $1}')
SOURCE_ID=$(cat "$SOURCE/SOURCE_COMMIT")
PATCH_SHA=$(sha256sum "$PROJECT/native/byte-literals.patch" | awk '{print $1}')
RUNTIME_PATCH_SHA=$(sha256sum "$PROJECT/native/circle-typed-storage.patch" | awk '{print $1}')

MESSENGER_CHAIN_VENUE="$VENUE" OCTRA_NODE_SOURCE="$SOURCE" \
  MESSENGER_CHAIN_README="$PROJECT/docs/OCPG-LAB.md" \
  MESSENGER_NODE_SHA="$NODE_SHA" MESSENGER_DRIVER_SHA=pending \
  bash "$PROJECT/tests/run_chain_spike.sh" build-driver
DRIVER_SHA=$(sha256sum "$VENUE/bin/chain_driver.exe" | awk '{print $1}')

python3 - "$PROJECT/docs/OCPG-LAB.md" "$SOURCE_ID" "$NODE_SHA" "$WORKER_SHA" "$SEGMENT_SHA" "$DRIVER_SHA" "$PATCH_SHA" "$RUNTIME_PATCH_SHA" "$LMDB_SHA" "$CHAIN_ID" "$PROFILE" "$ADMIT_OPS" "$PREVERIFY_EPOCH" <<'PY'
import sys
from pathlib import Path
path,source,node,worker,segment,driver,patch,runtime_patch,lmdb,chain_id,profile,admit_ops,preverify_epoch=sys.argv[1:]
Path(path).write_text(f"""# Isolated OCPG lab network

Scope: lab network, fleet-generated release key. This is not devnet and is not evidence of a devnet deployment.

- lite_node source pin: `8f785a93a4e7392a0f3e65674f9de89854d33dbc`
- embedded `SOURCE_COMMIT`: `{source}`
- lab compiler fingerprint: `69b1ef589a42dcae1636a9da7d699db83a42b9ce7718de0c87e536d2db4b3fef`
- byte-literal patch SHA-256: `{patch}`
- Circle typed-storage runtime patch SHA-256: `{runtime_patch}`
- node SHA-256: `{node}`
- PVAC worker SHA-256: `{worker}`
- segment driver SHA-256: `{segment}`
- chain driver SHA-256: `{driver}`
- static LMDB archive SHA-256 (lmdb.1.1.1 built in the lab): `{lmdb}`
- chain ID: `{chain_id}`
- release profile: `{profile or "off"}`
- BFT crypto profile: `off`
- admitted lab operations: `{admit_ops}`
- preverify receipt activation epoch: `{preverify_epoch}`
- release key ID: `lab-messenger-ocpg-v1`

The release key is generated for this isolated network, held only in its run directory and deleted after the run.
Its public half configures `OCTRA_PROGRAM_RELEASE_KEYS` identically on all seven isolated validators. No devnet trust
configuration, production key, updater or shared fakenet is changed.

The separately disclosed `native/circle-typed-storage.patch` is also required in this lab. At the pinned source,
`Circle_exec.prepare_octb_call` incorrectly derives storage typing from nested-call permission, so an unset typed
field rejects before the append guards. The patch always uses the certified storage declarations. It is not accepted
upstream, is not a devnet compatibility claim, and must be reviewed separately from the compiler patch and OCPG signer.

The 2,049-byte control uses the ordinary epoch-finalization path. An earlier attempt with preverify active at epoch 0
repeatedly skipped the method-reverting transaction without a terminal rejection receipt. This run does not claim
preverify rejection acceptance.

Build the full chain with `controls/lib/gc_build.py -- dune build --profile release -j 2` at the pinned source, then
run `tests/run_ocpg_lab.sh`. The harness creates an attested OCPG Circle, appends exactly 2,048 bytes, retrieves the
frame publicly without the Circle owner secret, binds the caller to the envelope signer, decrypts through the archive
path at the actual commit epoch, and attempts exactly 2,049 bytes without changing the successful frame. A terminal
rejection is claimed only when it finalizes; a pending transaction produces an explicitly partial report. Every receipt
is labelled `lab network, fleet-generated release key`.
""")
PY
cp "$PROJECT/docs/OCPG-LAB.md" "$VENUE/README.md"

python3 - "$KEY_FILE" "$VENUE/receipts/release-public.json" "$KEY_ID" <<'PY'
import base64,json,sys
from pathlib import Path
from nacl.signing import SigningKey
path,report,key_id=sys.argv[1:]
key=SigningKey.generate()
path=Path(path)
path.write_bytes(bytes(key))
path.chmod(0o600)
Path(report).write_text(json.dumps({
  "key_id": key_id,
  "public_key": base64.b64encode(bytes(key.verify_key)).decode("ascii"),
  "scope": "lab network, fleet-generated release key",
  "private_key_committed": False,
}, indent=2)+"\n")
PY
PUBLIC_KEY=$(python3 -c 'import json; print(json.load(open("'$VENUE'/receipts/release-public.json"))["public_key"])')

export MESSENGER_CHAIN_ID="$CHAIN_ID"
export MESSENGER_PROGRAM_RELEASE_KEYS="$KEY_ID=$PUBLIC_KEY"
export MESSENGER_NODE_SHA="$NODE_SHA"
export MESSENGER_DRIVER_SHA="$DRIVER_SHA"
export MESSENGER_CHAIN_README="$PROJECT/docs/OCPG-LAB.md"
export MESSENGER_NODE_SOURCE_ID="$SOURCE_ID"
export MESSENGER_NODE_BINARY_HASH="$NODE_SHA"
export MESSENGER_PVAC_WORKER_HASH="$WORKER_SHA"
export MESSENGER_BFT_RELEASE_PROFILE="$PROFILE"
export MESSENGER_ADMIT_OPS="$ADMIT_OPS"
export MESSENGER_CRYPTO_PROFILE=
export MESSENGER_PVAC_MIGRATION_ROOT=
export MESSENGER_PVAC_MIGRATION_ACTIVATION_EPOCH=1000000000
export MESSENGER_EMISSION_ACTIVATION_EPOCH=
export MESSENGER_VALIDATOR_ADMISSION_ACTIVATION_EPOCH=
export MESSENGER_EMISSION_GUARD=1
export MESSENGER_PREVERIFY_RECEIPT_ACTIVATION_EPOCH="$PREVERIFY_EPOCH"
export MESSENGER_CHAIN_VENUE="$VENUE"
export MESSENGER_UNIT_PREFIX="$UNIT_PREFIX"
export MESSENGER_SLICE="$SLICE"
export MESSENGER_SLICE="$SLICE"
export OCTRA_NODE_SOURCE="$SOURCE"
export MESSENGER_API_BASE=$((RPC_PORT - 1))
export MESSENGER_P2P_BASE=19250
export MESSENGER_CONSENSUS_BASE=19260
export MESSENGER_FEASIBILITY_RPC="http://127.0.0.1:$RPC_PORT/rpc"

bash "$PROJECT/tests/run_chain_spike.sh" provision
STARTED=1
bash "$PROJECT/tests/run_chain_spike.sh" start 1 2 3 4 5 6 7

python3 - "$VENUE" <<'PY'
import json,os,subprocess,sys,time,urllib.request
prefix=os.environ["MESSENGER_UNIT_PREFIX"]
for _ in range(60):
    for node in range(1,8):
        state=subprocess.run(["systemctl","--user","is-active",f"{prefix}-{node}.service"],
            capture_output=True,text=True).stdout.strip()
        if state == "failed":
            raise RuntimeError(f"isolated lab validator {node} failed during startup")
    try:
        body=json.dumps({"jsonrpc":"2.0","id":1,"method":"node_status","params":[]}).encode()
        request=urllib.request.Request(os.environ["MESSENGER_FEASIBILITY_RPC"],
            data=body,headers={"content-type":"application/json"})
        with urllib.request.urlopen(request,timeout=1) as response:
            status=json.load(response)["result"]
        if (status.get("head_epoch") or 0) >= 1:
            break
    except OSError:
        pass
    time.sleep(1)
else:
    raise RuntimeError("isolated lab did not advance an epoch")
PY

python3 - "$VENUE" <<'PY'
import json,sys
from pathlib import Path
venue=Path(sys.argv[1])
work=venue/"lab-feasibility"
work.mkdir(exist_ok=True)
wallet=json.loads((venue/"nodes/node1/data/wallet.json").read_text())
(work/"funding.json").write_text(json.dumps({"address":wallet["address"],"pub":wallet["pub"]},indent=2)+"\n")
(work/"wallet.json").symlink_to(venue/"nodes/node1/data/wallet.json")
payload=json.loads(Path("/srv/octra-node/fakenet-kimi-messenger/devnet-feasibility/deploy-payload.json").read_text())
payload["activation_epoch"]=0
(work/"deploy-payload.json").write_text(json.dumps(payload,separators=(",",":"))+"\n")
PY

export MESSENGER_ATTEST_KEY_ID="$KEY_ID"
export MESSENGER_ATTEST_KEY_FILE="$KEY_FILE"
export MESSENGER_EXPECTED_ATTEST_PUBLIC_KEY="$PUBLIC_KEY"
export MESSENGER_FEASIBILITY_VENUE="$VENUE"
export MESSENGER_FEASIBILITY_WORK=lab-feasibility
export MESSENGER_FEASIBILITY_RPC="http://127.0.0.1:$RPC_PORT/rpc"
export MESSENGER_FEASIBILITY_CHAIN_ID="$CHAIN_ID"
export MESSENGER_RECIPIENT_CHAIN_ID="$CHAIN_ID"
export MESSENGER_FEASIBILITY_NETWORK_KIND="lab network, fleet-generated release key"
export MESSENGER_NODE_BINARY="$VENUE/bin/octra_node.exe"
export MESSENGER_ENDPOINT=/srv/octra-node/fakenet-kimi-messenger/library-build/default/tests/recipient_endpoint.exe
export MESSENGER_SEGMENT_DRIVER="$VENUE/bin/messenger_segment_spike.exe"
export MESSENGER_CIRCLE_ACTIVATION_EPOCH=0

feasibility_args=()
if [ "${MESSENGER_LAB_ALLOW_PENDING_OVERSIZE:-0}" = 1 ]; then
  feasibility_args=(--allow-pending-oversize)
fi
python3 "$PROJECT/tests/run_devnet_feasibility.py" "${feasibility_args[@]}" > "$VENUE/receipts/lab-feasibility.log" 2>&1
cp "$VENUE/lab-feasibility/feasibility.json" "$VENUE/receipts/lab-feasibility.json"
bash "$PROJECT/tests/run_chain_spike.sh" stop
STARTED=0
python3 - "$VENUE/receipts/lab-feasibility.json" <<'PY'
import json,sys
report=json.load(open(sys.argv[1]))
print(json.dumps({
  "status":report["status"],
  "network_kind":report["network_kind"],
  "circle":report["circle"],
  "package_sha256":report["package"]["package_sha256"],
  "accepted_frame_bytes":report["largest_write"]["accepted_frame_bytes"],
  "rejected_frame_bytes":report["largest_write"]["rejected_frame_bytes"],
  "unchanged_after_oversize_rejection":report["public_circle_view"]["unchanged_after_oversize_rejection"],
  "archive_decryption":report["message_profile"]["fresh_public_retrieval_and_decryption"],
}))
PY
