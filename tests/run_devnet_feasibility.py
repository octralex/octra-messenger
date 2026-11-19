#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import time
import urllib.error
import urllib.request

VENUE = Path(os.environ.get("MESSENGER_FEASIBILITY_VENUE", "/srv/octra-node/fakenet-kimi-messenger"))
WORK = VENUE / os.environ.get("MESSENGER_FEASIBILITY_WORK", "devnet-feasibility")
PROJECT = Path(__file__).resolve().parent.parent
DRIVER = VENUE / "bin/chain_driver.exe"
ENDPOINT = Path(os.environ.get("MESSENGER_ENDPOINT", str(VENUE / "library-build/default/tests/recipient_endpoint.exe")))
SEGMENT_DRIVER = Path(os.environ.get("MESSENGER_SEGMENT_DRIVER",
    str(VENUE / "devnet-src/lite_node/_build/default/test/messenger_segment_spike.exe")))
RPC = os.environ.get("MESSENGER_FEASIBILITY_RPC", "http://127.0.0.1:18080/rpc")
SOURCE = os.environ.get("MESSENGER_SOURCE_PIN", "8f785a93a4e7392a0f3e65674f9de89854d33dbc")
SOURCE_DIR = Path(os.environ.get("OCTRA_NODE_SOURCE", str(VENUE / "devnet-src/lite_node")))
NODE_BINARY = Path(os.environ.get("MESSENGER_NODE_BINARY", "/srv/octra-node/artifacts/octra_node.devnet.exe"))
CHAIN_ID = os.environ.get("MESSENGER_FEASIBILITY_CHAIN_ID", "octra-devnet-9871-cluster")
NETWORK_KIND = os.environ.get("MESSENGER_FEASIBILITY_NETWORK_KIND", "devnet")


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(10):
        try:
            request = urllib.request.Request(RPC, data=body, headers={"content-type": "application/json"})
            with urllib.request.urlopen(request, timeout=15) as response:
                payload = json.load(response)
        except (TimeoutError, urllib.error.URLError):
            if attempt == 9:
                raise
            time.sleep(0.5)
            continue
        if "error" not in payload:
            return payload["result"]
        if payload["error"].get("code") != -32012:
            raise RuntimeError(payload["error"])
        time.sleep(0.5)
    raise RuntimeError(payload["error"])


def wait_final(tx_hash, allow_pending=False):
    timeout = int(os.environ.get("MESSENGER_TX_FINALITY_TIMEOUT", "360"))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        transaction = rpc("octra_transaction", [tx_hash])
        if transaction and transaction.get("status") in ("confirmed", "rejected"):
            return transaction
        time.sleep(1)
    if allow_pending:
        return rpc("octra_transaction", [tx_hash])
    raise RuntimeError((f"transaction did not finalize within {timeout} seconds", tx_hash))


def next_nonce(address):
    return int(rpc("octra_account", [address])["nonce"]) + 1


def submit(kind, wallet, nonce, ou, target, method, params, output_name, allow_pending=False):
    output = WORK / output_name
    command = [str(DRIVER), kind, RPC, str(wallet), str(nonce), str(ou)]
    if kind == "circle-deploy":
        command += [str(WORK / "deploy-payload.json"), str(output)]
    else:
        command += [target, method, params, str(output)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(("chain driver failed", result.returncode, result.stdout, result.stderr))
    submission = json.loads(result.stdout)
    (WORK / output_name.replace(".json", "-submit.json")).write_text(json.dumps(submission, indent=2) + "\n")
    transaction = wait_final(submission["tx_hash"], allow_pending=allow_pending)
    return submission, transaction


def endpoint(*args):
    result = subprocess.run([str(ENDPOINT), *map(str, args)], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(("recipient endpoint failed", result.returncode, result.stdout, result.stderr))
    return result


def prepare_message():
    root = WORK / ("message-" + str(time.time_ns()))
    alice = root / "alice"
    bob = root / "bob"
    alice.mkdir(parents=True)
    bob.mkdir()
    wallet = json.loads((WORK / "wallet.json").read_text())
    os.environ["MESSENGER_RECIPIENT_EPOCH"] = str(int(rpc("node_status", [])["head_epoch"]))
    secret_path = alice / "sender-secret.json"
    descriptor = os.open(secret_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(json.dumps({"secret": wallet["priv"]}) + "\n")
    endpoint("recipient-init", bob, wallet["pub"])
    plaintext = b"Maintainer v2: encrypted message through a public Octra circle.\n"
    (root / "plaintext.txt").write_bytes(plaintext)
    endpoint("send", bob / "recipient-public.json", secret_path,
             root / "plaintext.txt", root / "message.ocm")
    envelope = (root / "message.ocm").read_bytes()
    assert envelope[:8] == b"OCMMSG\x00\x02", envelope[:8]
    assert len(envelope) == 308 + len(plaintext), len(envelope)
    endpoint("bind-envelope", wallet["address"], wallet["address"], root / "message.ocm")
    (WORK / "current-message").write_text(root.name + "\n")
    return root


def prepare_segment(owner, root):
    template = (PROJECT / "programs/segment_spike.aml").read_text()
    assert template.count("__OWNER__") == 4
    owner_source = root / "segment-owner.aml"
    owner_source.write_text(template.replace("__OWNER__", owner))
    store = root / "segment-store"
    with (root / "segment-runtime.txt").open("w") as output:
        subprocess.run([str(SEGMENT_DRIVER), str(owner_source), str(store), "scoped"],
                       check=True, stdout=output, stderr=subprocess.STDOUT,
                       env=dict(os.environ, MESSENGER_SEGMENT_OWNER=owner))
    package = Path(str(store) + ".ocpg.b64")
    metadata = json.loads(Path(str(store) + ".package.json").read_text())
    assert package.is_file() and package.stat().st_size > 0
    return package, metadata


def static_integer_cost(raw):
    assert raw[:4] == b"OCTB" and len(raw) >= 12
    count = struct.unpack_from("<H", raw, 6)[0]
    position = 12
    total = 0
    for _ in range(count):
        tag = raw[position]
        length = struct.unpack_from("<I", raw, position + 1)[0]
        assert position + 5 + length <= len(raw)
        if tag == 0:
            cells = (length + 31) // 32
            total += cells + cells * cells
        position += 5 + length
    return total


def package_details(encoded, metadata):
    raw = base64.b64decode(encoded, validate=True)
    assert base64.b64encode(raw).decode("ascii") == encoded
    assert raw[:4] == b"OCPG" and len(raw) >= 16
    version, flags, code_size, certificate_size = struct.unpack_from("<HHII", raw, 4)
    assert version == 2 and flags == 0
    assert 16 + code_size + certificate_size == len(raw)
    code = raw[16:16 + code_size]
    static_work = static_integer_cost(code)
    load_work = 16 * len(encoded.encode("ascii"))
    assert metadata["format"] == "OCPG"
    attestation = metadata.get("attestation")
    assert isinstance(attestation, dict), "an accepted OCPG requires the configured compiler attestation"
    assert metadata["decode_deploy"] == "accepted"
    assert attestation["key_id"] == os.environ.get("MESSENGER_ATTEST_KEY_ID", "devnet-program-1")
    assert attestation["public_key"] == os.environ.get("MESSENGER_EXPECTED_ATTEST_PUBLIC_KEY",
        "JelwQefvI87auUsGN9ZC+U7xJQa5z7Q0jrETO6yawqU=")
    assert attestation["trusted"] is True
    assert metadata["embedded_code_and_certificate_match"] is True
    assert metadata["package_bytes"] == len(raw)
    assert metadata["base64_bytes"] == len(encoded.encode("ascii"))
    assert metadata["bytecode_bytes"] == code_size
    assert metadata["certificate_bytes"] == certificate_size
    assert metadata["package_sha256"] == hashlib.sha256(raw).hexdigest()
    assert metadata["bytecode_sha256"] == hashlib.sha256(code).hexdigest()
    assert int(metadata["static_work"]) == static_work
    assert int(metadata["load_work"]) == load_work
    assert int(metadata["total_work"]) == static_work + load_work
    return {
        "format": "OCPG",
        "compiler_fingerprint": metadata["compiler_fingerprint"],
        "package_sha256": metadata["package_sha256"],
        "package_hash": metadata["package_hash"],
        "package_bytes": len(raw),
        "base64_bytes": len(encoded.encode("ascii")),
        "bytecode_bytes": code_size,
        "certificate_bytes": certificate_size,
        "static_work": static_work,
        "load_work": load_work,
        "total_work": static_work + load_work,
        "decode_deploy": "accepted",
        "attestation": attestation,
        "embedded_code_and_certificate_match": True,
    }


def runtime_identity():
    runtime = rpc("octra_runtimeVersion", [])
    status = rpc("node_status", [])
    embedded = (SOURCE_DIR / "SOURCE_COMMIT").read_text().strip()
    binary_hash = hashlib.sha256(NODE_BINARY.read_bytes()).hexdigest()
    assert runtime["source_commit"] == embedded, (runtime["source_commit"], embedded)
    assert runtime["binary_hash"] == binary_hash
    assert runtime["chain_id"] == CHAIN_ID
    return {
        "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "network_kind": NETWORK_KIND,
        "rpc_url": RPC,
        "git_pin": SOURCE,
        "embedded_source_commit": embedded,
        "reported_source_commit": runtime["source_commit"],
        "binary_hash": binary_hash,
        "chain_id": runtime["chain_id"],
        "head_epoch": status["head_epoch"],
        "profile_epoch": runtime["profile_epoch"],
        "consensus_profile": runtime["consensus_profile"],
        "runtime_profile_hash": runtime["runtime_profile_hash"],
        "embedded_identity_mapping_verified": True,
    }


def main():
    if sys.argv[1:] not in ([], ["--resume-read"], ["--allow-pending-oversize"]):
        raise RuntimeError("usage: run_devnet_feasibility.py [--resume-read|--allow-pending-oversize]")
    fresh = sys.argv[1:] != ["--resume-read"]
    allow_pending = sys.argv[1:] == ["--allow-pending-oversize"]
    if allow_pending and NETWORK_KIND == "devnet":
        raise RuntimeError("pending oversize evidence is permitted only for a labelled lab report")
    actual_source = subprocess.run(
        ["git", "-C", str(SOURCE_DIR), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True).stdout.strip()
    assert actual_source == SOURCE, (actual_source, SOURCE)
    observed_runtime = runtime_identity()
    message_root = prepare_message() if fresh else WORK / (WORK / "current-message").read_text().strip()
    expected_envelope = (message_root / "message.ocm").read_bytes()
    expected_plaintext = (message_root / "plaintext.txt").read_bytes()
    frame = base64.b64encode(expected_envelope)
    frame += b" " * (2048 - len(frame))
    assert len(frame) == 2048 and base64.b64decode(frame.strip(), validate=True) == expected_envelope
    (WORK / "frame.txt").write_bytes(frame)
    (WORK / "append-params.json").write_text(json.dumps([frame.decode("ascii")], separators=(",", ":")) + "\n")
    append_argument = json.loads((WORK / "append-params.json").read_text())[0].encode("ascii")
    assert append_argument == frame and len(append_argument) == 2048
    address = json.loads((WORK / "funding.json").read_text())["address"]
    wallet = WORK / "wallet.json"
    bytecode_path, package_metadata = prepare_segment(address, message_root) if fresh else (
        message_root / "segment-store.ocpg.b64",
        json.loads((message_root / "segment-store.package.json").read_text()))
    if not bytecode_path.is_file():
        raise RuntimeError("owner-specific OCPG package is missing; run the fresh segment test first")
    payload = json.loads((WORK / "deploy-payload.json").read_text())
    payload["activation_epoch"] = int(os.environ.get("MESSENGER_CIRCLE_ACTIVATION_EPOCH",
        payload.get("activation_epoch", 0)))
    payload["code_b64"] = bytecode_path.read_text().strip()
    (WORK / "deploy-payload.json").write_text(json.dumps(payload, separators=(",", ":")) + "\n")
    package = package_details(payload["code_b64"], package_metadata)
    declared_ou = max(200000, package["total_work"])
    if not fresh:
        deploy_submission = json.loads((WORK / "signed-deploy-submit.json").read_text())
        append_submission = json.loads((WORK / "signed-append-submit.json").read_text())
        deploy = wait_final(deploy_submission["tx_hash"])
        append = wait_final(append_submission["tx_hash"])
    else:
        nonce = next_nonce(address)
        deploy_submission, deploy = submit("circle-deploy", wallet, nonce, declared_ou, None, None, None, "signed-deploy.json")
        circle = deploy["to"]
        append_submission, append = submit("circle-exec", wallet, next_nonce(address), 1000, circle, "append",
                                           "@" + str(WORK / "append-params.json"), "signed-append.json")
    assert deploy["status"] == "confirmed" and append["status"] == "confirmed", (deploy, append)
    circle = deploy["to"]
    view = json.loads(subprocess.run(
        [str(DRIVER), "circle-view", RPC, circle, "get", "[0]"],
        check=True, capture_output=True, text=True).stdout)
    returned = view["result"]
    assert isinstance(returned, str) and len(returned) == 2048, view
    assert base64.b64decode(returned.strip(), validate=True) == expected_envelope
    info = json.loads(subprocess.run(
        [str(DRIVER), "circle-view", RPC, circle, "info", "[]"],
        check=True, capture_output=True, text=True).stdout)
    assert info["result"] == "1|2048|1|2048|8388608|false", info
    owner_view = json.loads(subprocess.run(
        [str(DRIVER), "circle-view", RPC, circle, "owner", "[]"],
        check=True, capture_output=True, text=True).stdout)
    assert owner_view["result"] == address, owner_view
    sender_view = json.loads(subprocess.run(
        [str(DRIVER), "circle-view", RPC, circle, "sender", "[0]"],
        check=True, capture_output=True, text=True).stdout)
    assert sender_view["result"] == address, sender_view
    if fresh:
        recovered = message_root / "recovered.ocm"
        recovered.write_bytes(base64.b64decode(returned.strip(), validate=True))
        endpoint("bind-envelope", address, sender_view["result"], recovered)
        endpoint("open-archive", message_root / "bob/recipient-secret-v1.json",
                 message_root / "bob/recipient-public.json", recovered, message_root / "recovered.txt",
                 append["epoch"])
        assert (message_root / "recovered.txt").read_bytes() == expected_plaintext
    if fresh:
        frame = (WORK / "frame.txt").read_bytes()
        assert len(frame) == 2048
        oversize_frame = frame + b" "
        assert len(oversize_frame) == 2049
        (WORK / "oversize-append-params.json").write_text(
            json.dumps([oversize_frame.decode("ascii")], separators=(",", ":")))
        oversize_argument = json.loads((WORK / "oversize-append-params.json").read_text())[0].encode("ascii")
        assert oversize_argument == oversize_frame and len(oversize_argument) == 2049
        assert oversize_argument[:-1] == append_argument and oversize_argument[-1:] == b" "
        _, oversize = submit("circle-exec", wallet, next_nonce(address), 1000, circle, "append",
                             "@" + str(WORK / "oversize-append-params.json"), "signed-oversize.json",
                             allow_pending=allow_pending)
    else:
        previous = json.loads((WORK / "feasibility.json").read_text())
        oversize = previous["largest_write"]["rejection"]
        oversize_argument = frame + b" "
    rejection_finalized = oversize["status"] == "rejected"
    if rejection_finalized:
        assert "2048" in oversize["error"]["reason"], oversize
    else:
        assert allow_pending and oversize["status"] == "pending", oversize
    final_view = json.loads(subprocess.run(
        [str(DRIVER), "circle-view", RPC, circle, "get", "[0]"],
        check=True, capture_output=True, text=True).stdout)
    final_info = json.loads(subprocess.run(
        [str(DRIVER), "circle-view", RPC, circle, "info", "[]"],
        check=True, capture_output=True, text=True).stdout)
    assert final_view["result"] == returned
    assert final_info["result"] == info["result"]
    report = {
        "status": ("lab_circle_partial_oversize_not_final" if not rejection_finalized
                   else "lab_circle_feasibility_pass" if NETWORK_KIND != "devnet"
                   else "devnet_circle_feasibility_pass"),
        "network_kind": NETWORK_KIND,
        "source": SOURCE,
        "control_commit": subprocess.run(["git", "-C", str(PROJECT), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True).stdout.strip(),
        "messenger_tree_hash": subprocess.run(["git", "-C", str(PROJECT), "rev-parse", "HEAD:projects/onchain-messenger"],
            check=True, capture_output=True, text=True).stdout.strip(),
        "circle_activation_epoch": payload["activation_epoch"],
        "runtime_identity": observed_runtime,
        "package": package,
        "declared_deploy_ou": declared_ou,
        "circle": circle,
        "message_profile": {
            "codec": "recipient-x25519-aes-gcm",
            "codec_version": 2,
            "plaintext_bytes": len(expected_plaintext),
            "envelope_bytes": len(expected_envelope),
            "envelope_sha256": hashlib.sha256(expected_envelope).hexdigest(),
            "fresh_public_retrieval_and_decryption": fresh,
            "sender_binding": "fixed-header sender bytes bound to contact wallet and on-chain caller before full decode",
        },
        "deploy": {"transaction": deploy, "submission": deploy_submission},
        "write": {"transaction": append, "submission": append_submission},
        "public_circle_view": {
            "result_bytes": len(returned.encode()),
            "trimmed_base64_bytes": len(returned.strip().encode()),
            "decoded_envelope_bytes": len(expected_envelope),
            "info": info["result"],
            "owner": owner_view["result"],
            "sender": sender_view["result"],
            "owner_secret_required": False,
            "lab_base64_patch_required": False,
            "unchanged_after_oversize_rejection": rejection_finalized or None,
            "unchanged_after_oversize_submission": True,
            "final_info": final_info["result"],
        },
        "largest_write": {
            "accepted_frame_bytes": len(append_argument),
            "oversize_frame_bytes": len(oversize_argument),
            "rejected_frame_bytes": len(oversize_argument) if rejection_finalized else None,
            "rejection_finalized": rejection_finalized,
            "accepted_argument_sha256": hashlib.sha256(append_argument).hexdigest(),
            "rejected_argument_sha256": hashlib.sha256(oversize_argument).hexdigest(),
            "rejection": oversize,
            "historical_control_correction": {
                "actual_frame_bytes": 2050,
                "previously_reported_as": 2049,
                "cause": "transport newline followed by an appended space",
            },
            "scope": "selected 2048-byte base64-text-frame layout; not an absolute chain maximum",
            "native_max_inline_value_bytes": 65536,
            "native_max_stable_bytes": 33554432,
        },
        "ou": {
            "circle_deploy_declared": deploy_submission["ou"],
            "circle_deploy_work_estimate": package["total_work"],
            "circle_deploy_base": deploy_submission["ou_cost"],
            "circle_write_declared": append_submission["ou"],
            "circle_write_base": append_submission["ou_cost"],
            "note": "OU is the transaction fee field and native base-cost calculation, not a receipt-effort or explicit fee-burn measurement",
        },
        "devnet_epochs": json.loads((VENUE / "receipts/devnet-epochs.json").read_text())
            if (VENUE / "receipts/devnet-epochs.json").exists() else [],
        "driver_sha256": hashlib.sha256(DRIVER.read_bytes()).hexdigest(),
        "endpoint_executable_sha256": hashlib.sha256(ENDPOINT.read_bytes()).hexdigest(),
        "segment_driver_sha256": hashlib.sha256(SEGMENT_DRIVER.read_bytes()).hexdigest(),
        "segment_owner_source_sha256": hashlib.sha256((message_root / "segment-owner.aml").read_bytes()).hexdigest(),
        "segment_bytecode_sha256": hashlib.sha256(bytecode_path.read_bytes()).hexdigest(),
        "test_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "synthetic_only": True,
    }
    (WORK / "feasibility.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key not in ("deploy", "write", "devnet_epochs")}, indent=2))


if __name__ == "__main__":
    main()
