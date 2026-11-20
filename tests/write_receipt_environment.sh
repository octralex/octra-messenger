#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
set -euo pipefail

ENDPOINT_EXE=$1
SIZE_EXE=$2
VENUE=$3
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONTROL_COMMIT=${CONTROL_COMMIT:-$(git -C "$PROJECT" rev-parse HEAD)}
TREE=$(git -C "$PROJECT" rev-parse HEAD:./)
SOURCE=${OCTRA_NODE_SOURCE:-$VENUE/src/lite_node}
SWITCH=${OCTRA_OPAM_SWITCH:-/srv/octra-node/libv_litecore/runtime_data/toolchains/ocaml}
export PROJECT CONTROL_COMMIT TREE VENUE ENDPOINT_EXE SIZE_EXE SOURCE SWITCH

python3 - <<'PY'
import hashlib,json,os,subprocess
from pathlib import Path

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def command(args):
    return subprocess.check_output(args,text=True).strip()

switch=Path(os.environ['SWITCH'])/'_opam'/'lib'
source=Path(os.environ['SOURCE'])
common={
  'receipt_schema':3,
  'control_commit':os.environ['CONTROL_COMMIT'],
  'messenger_tree_hash':os.environ['TREE'],
  'lite_node_commit':command(['git','-C',str(source),'rev-parse','HEAD']),
  'lite_node_crypto_ml_sha256':sha(source/'lib/core/crypto.ml'),
  'webcli_commit':'28208507bf704b9d2726dd48cb6597319c594688',
  'webcli_executable_sha256':sha('/srv/octra-node/webcli/octra_wallet'),
  'lite_node_running_executable_sha256':sha('/srv/octra-node/artifacts/octra_node.devnet.exe'),
  'venue':os.environ['VENUE'],
  'build_command':f"python3 {source}/controls/lib/gc_build.py -- dune build --root {os.environ['PROJECT']} --build-dir {os.environ['VENUE']}/library-build --profile release -j 2 tests/recipient_endpoint.exe tests/size_sweep.exe",
  'ocaml':command(['ocamlc','-version']),
  'dune':command(['dune','--version']),
  'opam_lock_sha256':sha('/srv/octra-node/libv_litecore/octra_node.opam.locked'),
  'mirage_crypto_version':command(['opam','show','mirage-crypto','--field=version']),
  'mirage_crypto_ec_version':command(['opam','show','mirage-crypto-ec','--field=version']),
  'mirage_crypto_rng_version':command(['opam','show','mirage-crypto-rng','--field=version']),
  'mirage_dune_package_sha256':sha(switch/'mirage-crypto/dune-package'),
  'mirage_ec_dune_package_sha256':sha(switch/'mirage-crypto-ec/dune-package'),
  'mirage_crypto_ml_sha256':sha(switch/'mirage-crypto/mirage_crypto.ml'),
  'mirage_crypto_mli_sha256':sha(switch/'mirage-crypto/mirage_crypto.mli'),
  'mirage_ec_ml_sha256':sha(switch/'mirage-crypto-ec/mirage_crypto_ec.ml'),
  'mirage_ec_mli_sha256':sha(switch/'mirage-crypto-ec/mirage_crypto_ec.mli'),
  'mirage_rng_ml_sha256':sha(switch/'mirage-crypto-rng/rng.ml'),
  'mirage_rng_mli_sha256':sha(switch/'mirage-crypto-rng/mirage_crypto_rng.mli'),
  'mirage_crypto_a_sha256':sha(switch/'mirage-crypto/mirage_crypto.a'),
  'mirage_ec_stubs_a_sha256':sha(switch/'mirage-crypto-ec/libmirage_crypto_ec_stubs.a'),
  'pvac_library_sha256':sha('/srv/octra-node/webcli/pvac/build/libpvac.so'),
  'pvac_c_api_cpp_sha256':sha('/srv/octra-node/webcli-src/pvac/pvac_c_api.cpp'),
  'pvac_encrypt_hpp_sha256':sha('/srv/octra-node/webcli-src/pvac/include/pvac/ops/encrypt.hpp'),
  'kernel':command(['uname','-srmo']),
  'cpu_arch_flags':'-march=x86-64-v3 -maes',
  'synthetic_keys_only':True,
}
endpoint=common | {
  'endpoint_executable_sha256':sha(os.environ['ENDPOINT_EXE']),
  'endpoint_command':'tests/run_recipient_spike.sh',
  'receipt':'receipts/recipient/endpoint.txt',
}
sizes=common | {
  'size_sweep_executable_sha256':sha(os.environ['SIZE_EXE']),
  'size_command':'tests/run_size_sweep.sh',
  'receipt':'receipts/recipient/sizes.csv',
  'samples_per_case':5,
  'cold_samples_per_case':1,
  'warm_samples_per_case':4,
  'maxima':'warm repetitions and overall cold+warm are reported separately',
}
Path(os.environ['VENUE'],'receipts','environment.json').write_text(json.dumps(endpoint,indent=2)+'\n')
Path(os.environ['VENUE'],'receipts','sizes-environment.json').write_text(json.dumps(sizes,indent=2)+'\n')
PY
