#!/usr/bin/env bash
set -euo pipefail

VENUE=${MESSENGER_CHAIN_VENUE:-/srv/octra-node/fakenet-kimi-messenger}
SOURCE=${OCTRA_NODE_SOURCE:-$VENUE/node-src/lite_node}
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DRIVER=$VENUE/bin/chain_driver.exe
SWITCH=${OCTRA_OPAM_SWITCH:-/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml}
NODE_SHA=8846d2a9f3240d2aedfecb49553f082c284c2b951a6ddb7a9b60afe09800ef18
DRIVER_SHA=a86b7baf83c86ab813c3198bc0ed6fdb1f9b04bb1af7741a49f39220def8077e

verify_disclosure() {
  test -f "$VENUE/README.md"
  cmp "$VENUE/README.md" "$PROJECT/docs/FAKENET.md"
  printf '%s  %s\n' "$NODE_SHA" "$VENUE/bin/octra_node.exe" "$DRIVER_SHA" "$DRIVER" | sha256sum -c -
}

python_with_nacl() {
  if python3 -c 'import nacl' 2>/dev/null; then
    printf 'python3\n'
  else
    printf '/tmp/octra-upgrade-venv/bin/python\n'
  fi
}

provision() {
  verify_disclosure
  for node in 1 2 3 4 5 6 7; do
    if systemctl --user is-active --quiet "octra-kimi-msgnet-$node"; then
      printf 'refusing to provision over active node %s\n' "$node" >&2
      exit 1
    fi
  done
  PYTHONPATH="$SOURCE/controls/lib" "$(python_with_nacl)" - "$VENUE" "$SOURCE" <<'PY'
import json,os,socket,stat,sys
from pathlib import Path
from validator_common import ensure_wallet
venue=Path(sys.argv[1])
source=Path(sys.argv[2])
for port in list(range(18171,18178))+list(range(19151,19158))+list(range(19161,19168)):
    sock=socket.socket()
    try:
        sock.bind(('127.0.0.1',port))
    except OSError as error:
        raise SystemExit(f'port {port} is unavailable: {error}')
    finally:
        sock.close()
validators=[]
for index in range(1,8):
    data=venue/'nodes'/f'node{index}'/'data'
    data.mkdir(parents=True,exist_ok=True,mode=0o700)
    wallet=ensure_wallet(data/'wallet.json')
    validators.append({'address':wallet['address'],'pub':wallet['pub']})
entries=','.join(f"{row['address']}:{row['pub']}" for row in validators)
exporter=f"{validators[0]['address']}:{validators[0]['pub']}"
peers=','.join(f'127.0.0.1:{19160+index}' for index in range(1,8))
bootstrap=','.join(f'127.0.0.1:{19150+index}' for index in range(1,8))
common={
    'NO_COLOR':'1',
    'OCTRA_CHAIN_ID':'octra-fakenet-kimi-msgnet',
    'OCTRA_VALIDATORS':entries,
    'OCTRA_CONSENSUS_MODE':'bft',
    'OCTRA_PEERS':peers,
    'OCTRA_BOOTSTRAP_PEERS':bootstrap,
    'OCTRA_ADVERTISE_HOST':'127.0.0.1',
    'OCTRA_STATE_SYNC_ENABLE':'1',
    'OCTRA_STATE_SYNC_EXPORTERS':exporter,
    'OCTRA_PVAC_MIGRATION_ACTIVATION_EPOCH':'1',
    'OCTRA_EMISSION_ACTIVATION_EPOCH':'64',
    'OCTRA_VALIDATOR_ADMISSION_ACTIVATION_EPOCH':'64',
    'OCTRA_CONSENSUS_ALLOW_DYNAMIC_PEERS':'1',
    'OCTRA_BFT_RELEASE_PROFILE':'',
    'OCTRA_BFT_CRYPTO_PROFILE':'private_v1',
    'OCTRA_BFT_ADMIT_OPS':'deploy,program_deploy,call,program_exec,multi_exec',
    'OCTRA_PREVERIFY_RECEIPT_ACTIVATION_EPOCH':'0',
    'OCTRA_PRIVATE_RESULT_ACTIVATION_EPOCH':'0',
    'OCTRA_BFT_PENDING_NONCE_WINDOW':'1500',
    'OCTRA_SOURCE_COMMIT':'3aab2d992035076dd216ad8808710d3a5a56063a',
    'OCTRA_BINARY_HASH':'d7488394c787109c5b323ca74c3adf9cb496682f632ab6b3e448e9a02a01a2bc',
    'OCTRA_PVAC_VERIFY_WORKER':str(venue/'bin'/'octra_pvac_worker.exe'),
    'OCTRA_PVAC_VERIFY_WORKER_HASH':'2939f29cfbbac4b35500cc4207032334b3c78357c0bf9b772ecec8ef376944a7',
    'OCTRA_PVAC_VERIFY_WORKERS':'1',
    'OCTRA_PROOF_POOL_WORKERS':'1',
    'OCTRA_LOG_LEVEL':'info',
}
for index,row in enumerate(validators,1):
    values=common | {
        'OCTRA_API_PORT':str(18170+index),
        'OCTRA_P2P_PORT':str(19150+index),
        'OCTRA_CONSENSUS_PORT':str(19160+index),
        'OCTRA_ADVERTISE_PORT':str(19150+index),
        'OCTRA_DATA_DIR':str(venue/'nodes'/f'node{index}'/'data'),
    }
    path=venue/'nodes'/f'node{index}'/'node.env'
    path.write_text(''.join(f'{key}={values[key]}\n' for key in sorted(values)))
    path.chmod(0o600)
(venue/'nodes.config').write_text('')
(venue/'receipts'/'validators.json').write_text(json.dumps(validators,indent=2)+'\n')
print(json.dumps({'status':'provisioned','validators':len(validators),'private_keys_printed':False}))
PY
  systemctl --user set-property kimi-msgnet.slice CPUQuota=200% MemoryMax=4G
}

start_nodes() {
  verify_disclosure
  systemctl --user set-property kimi-msgnet.slice CPUQuota=200% MemoryMax=4G
  for node in "$@"; do
    test -f "$VENUE/nodes/node$node/node.env"
    systemctl --user reset-failed "octra-kimi-msgnet-$node" 2>/dev/null || true
    systemd-run --user --slice=kimi-msgnet.slice --unit="octra-kimi-msgnet-$node" \
      --property="WorkingDirectory=$VENUE" \
      --property="EnvironmentFile=$VENUE/nodes/node$node/node.env" \
      --property="Environment=LD_LIBRARY_PATH=/srv/octra-node/runtime-libs:$VENUE/link-libs" \
      --property="StandardOutput=append:$VENUE/nodes/node$node/node.log" \
      --property="StandardError=append:$VENUE/nodes/node$node/node.log" \
      "$VENUE/bin/octra_node.exe" --init
  done
}

stop_nodes() {
  for node in 1 2 3 4 5 6 7; do
    systemctl --user stop "octra-kimi-msgnet-$node" 2>/dev/null || true
  done
}

build_driver() {
  cp "$PROJECT/tests/chain_driver.ml" "$SOURCE/test/chain_driver.ml"
  if ! grep -q '(name chain_driver)' "$SOURCE/test/dune"; then
    printf '\n(executable\n (name chain_driver)\n (modules chain_driver)\n (libraries octra_core lwt.unix cohttp-lwt-unix yojson base64 digestif mirage-crypto-rng.unix unix))\n' >> "$SOURCE/test/dune"
  fi
  eval $(opam env --switch="$SWITCH" --set-switch)
  export LIBRARY_PATH="$VENUE/link-libs"
  export LD_LIBRARY_PATH="/srv/octra-node/runtime-libs:$VENUE/link-libs"
  export TMPDIR="$VENUE/tmp"
  python3 "$SOURCE/controls/lib/gc_build.py" -- dune build --root "$SOURCE" --profile release -j 2 test/chain_driver.exe
  install -m 755 "$SOURCE/_build/default/test/chain_driver.exe" "$DRIVER"
}

case "${1:-}" in
  provision) provision ;;
  start)
    shift
    if [ "$#" -eq 0 ]; then set -- 1 2 3 4 5 6; fi
    start_nodes "$@"
    ;;
  stop) stop_nodes ;;
  build-driver) build_driver ;;
  *)
    printf 'usage: %s provision|start [nodes]|stop|build-driver\n' "$0" >&2
    exit 2
    ;;
esac
