#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
"""Deploy the segment and registry programs from source on devnet and run the full message path."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request

PROJECT = Path(__file__).resolve().parent.parent
WORK = Path(os.environ["MESSENGER_DEVNET_WORK"])
DRIVER = Path(os.environ["MESSENGER_CHAIN_DRIVER"])
ENDPOINT = Path(os.environ["MESSENGER_ENDPOINT"])
RPC = os.environ.get("MESSENGER_DEVNET_RPC", "http://127.0.0.1:18080/rpc")
CHAIN_ID = "octra-devnet-9871-cluster"
DEPLOY_OU = int(os.environ.get("MESSENGER_DEPLOY_OU", "1000000"))
CALL_OU = int(os.environ.get("MESSENGER_CALL_OU", "100000"))
FRAME_BYTES = 2048
LABEL = b"octra:msg:segment-dedup:v1:"


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    payload = None
    for attempt in range(20):
        try:
            request = urllib.request.Request(RPC, data=body, headers={"content-type": "application/json"})
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.load(response)
        except (TimeoutError, urllib.error.URLError):
            if attempt == 19:
                raise
            time.sleep(0.5)
            continue
        if "error" not in payload:
            return payload["result"]
        if payload["error"].get("code") != -32012:
            raise RuntimeError(payload["error"])
        time.sleep(0.5)
    raise RuntimeError(payload["error"])


def wait_final(tx_hash):
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        transaction = rpc("octra_transaction", [tx_hash])
        if transaction and transaction.get("status") in ("confirmed", "rejected"):
            return transaction
        time.sleep(1)
    raise RuntimeError(("transaction did not reach a terminal status", tx_hash))


def next_nonce(address):
    return int(rpc("octra_account", [address])["nonce"]) + 1


def run_driver(arguments, name):
    result = subprocess.run([str(DRIVER), *arguments], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(("chain driver failed", name, result.returncode, result.stdout, result.stderr))
    submission = json.loads(result.stdout)
    (WORK / (name + "-submit.json")).write_text(json.dumps(submission, indent=2) + "\n")
    transaction = wait_final(submission["tx_hash"])
    (WORK / (name + "-final.json")).write_text(json.dumps(transaction, indent=2) + "\n")
    return submission, transaction


def deploy(wallet, name, package, envelope):
    address = json.loads(wallet.read_text())["address"]
    package_path = WORK / (name + "-package.b64")
    package_path.write_text(package)
    envelope_path = WORK / (name + "-envelope.b64")
    envelope_path.write_text(envelope)
    return run_driver(["program-deploy", RPC, str(wallet), str(next_nonce(address)), str(DEPLOY_OU),
                       str(package_path), str(envelope_path), "[]", str(WORK / (name + "-signed.json"))], name)


def call(wallet, target, method, params, name):
    address = json.loads(wallet.read_text())["address"]
    params_path = WORK / (name + "-params.json")
    params_path.write_text(json.dumps(params, separators=(",", ":")))
    return run_driver(["exec", RPC, str(wallet), str(next_nonce(address)), str(CALL_OU), target, method,
                       "@" + str(params_path), str(WORK / (name + "-signed.json"))], name)


def view(target, method, params):
    return rpc("octra_programCall", [target, method, params])["result"]


def expect_confirmed(transaction, name):
    assert transaction["status"] == "confirmed", (name, transaction)


def expect_rejected(transaction, reason, name):
    assert transaction["status"] == "rejected", (name, transaction)
    assert reason in json.dumps(transaction.get("error")), (name, transaction)


def endpoint(*arguments):
    result = subprocess.run([str(ENDPOINT), *map(str, arguments)], capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def endpoint_ok(*arguments):
    code, stdout, stderr = endpoint(*arguments)
    if code != 0:
        raise RuntimeError(("recipient endpoint failed", arguments[0], stdout, stderr))
    return stdout


def compile_program(name):
    source = (PROJECT / "programs" / (name + ".aml")).read_text()
    compiled = rpc("octra_compileAml", [source])
    package = compiled["deploy_payload"]
    return package, compiled["program_envelope"], {
        "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "compiler_version": compiled["version"],
        "instructions": compiled["instructions"],
        "bytecode_bytes": compiled["size"],
        "package_base64_bytes": len(package),
        "package_sha256": hashlib.sha256(base64.b64decode(package, validate=True)).hexdigest(),
    }


def seal(root, wallet, bob, text):
    plaintext = root / "plaintext.txt"
    plaintext.write_bytes(text)
    endpoint_ok("send", bob / "recipient-public.json", root / "sender-secret.json", plaintext, root / "message.ocm")
    envelope = (root / "message.ocm").read_bytes()
    assert envelope[:8] == b"OCMMSG\x00\x02" and len(envelope) == 308 + len(text)
    encoded = base64.b64encode(envelope)
    frame = encoded + b" " * (FRAME_BYTES - len(encoded))
    assert len(frame) == FRAME_BYTES
    return envelope, frame


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    owner_wallet = WORK / "owner-wallet.json"
    other_wallet = WORK / "other-wallet.json"
    owner = json.loads(owner_wallet.read_text())
    other = json.loads(other_wallet.read_text())
    status = rpc("node_status", [])
    runtime = rpc("octra_runtimeVersion", [])
    assert status.get("chain_id", CHAIN_ID) == CHAIN_ID, status
    report = {"network_kind": "devnet", "chain_id": CHAIN_ID, "rpc_url": RPC,
              "runtime": {key: runtime.get(key) for key in ("source_commit", "binary_hash", "version")},
              "start_epoch": status["head_epoch"], "deploy_ou": DEPLOY_OU, "call_ou": CALL_OU,
              "owner": owner["address"], "other": other["address"], "controls": {}}

    segment_package, segment_envelope, report["segment_package"] = compile_program("segment")
    _, deployed = deploy(owner_wallet, "segment-deploy", segment_package, segment_envelope)
    expect_confirmed(deployed, "segment deploy")
    segment = deployed["to"]
    report["segment"] = {"address": segment, "deploy_tx": deployed["tx_hash"], "deploy_epoch": deployed["epoch"]}
    assert view(segment, "owner", []) == owner["address"]
    assert int(view(segment, "count", [])) == 0

    root = WORK / "message"
    bob = root / "bob"
    bob.mkdir(parents=True)
    descriptor = os.open(root / "sender-secret.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(json.dumps({"secret": owner["priv"]}) + "\n")
    os.environ["MESSENGER_RECIPIENT_EPOCH"] = str(int(rpc("node_status", [])["head_epoch"]))
    endpoint_ok("recipient-init", bob, owner["pub"])
    text = b"Messenger v2: encrypted message through a source-admitted Octra program.\n"
    envelope, frame = seal(root, owner, bob, text)
    endpoint_ok("bind-envelope", owner["address"], owner["address"], root / "message.ocm")

    _, appended = call(owner_wallet, segment, "append", [frame.decode("ascii")], "append")
    expect_confirmed(appended, "append")
    returned = view(segment, "get", [0])
    assert isinstance(returned, str) and returned.encode("ascii") == frame, returned
    stored_sender = view(segment, "sender", [0])
    assert stored_sender == owner["address"]
    assert int(view(segment, "count", [])) == 1 and int(view(segment, "used_bytes", [])) == FRAME_BYTES
    assert int(view(segment, "epoch_of", [0])) == appended["epoch"]
    expected_key = hashlib.sha256(LABEL + frame).hexdigest()
    assert view(segment, "dedup_key", [frame.decode("ascii")]) == expected_key
    recovered = root / "recovered.ocm"
    recovered.write_bytes(base64.b64decode(returned.strip(), validate=True))
    assert recovered.read_bytes() == envelope
    endpoint_ok("bind-envelope", owner["address"], stored_sender, recovered)
    endpoint_ok("open-archive", bob / "recipient-secret-v1.json", bob / "recipient-public.json",
                recovered, root / "recovered.txt", appended["epoch"])
    assert (root / "recovered.txt").read_bytes() == text
    report["message"] = {"plaintext_bytes": len(text), "envelope_bytes": len(envelope),
                         "envelope_sha256": hashlib.sha256(envelope).hexdigest(),
                         "frame_bytes": len(frame), "frame_dedup_key": expected_key,
                         "append_tx": appended["tx_hash"], "append_epoch": appended["epoch"],
                         "public_read_equals_frame": True, "stored_sender_equals_signer": True,
                         "archive_decryption_equals_plaintext": True}

    def unchanged():
        return (view(segment, "get", [0]) == returned and int(view(segment, "count", [])) == report_count[0]
                and view(segment, "sender", [0]) == owner["address"])

    report_count = [1]
    _, duplicate = call(owner_wallet, segment, "append", [frame.decode("ascii")], "duplicate")
    expect_rejected(duplicate, "duplicate frame", "duplicate")
    oversize = frame + b" "
    assert len(oversize) == FRAME_BYTES + 1 and oversize[:-1] == frame
    _, oversized = call(owner_wallet, segment, "append", [oversize.decode("ascii")], "oversize")
    expect_rejected(oversized, "2048", "oversize")
    second_root = WORK / "message-2"
    second_root.mkdir()
    (second_root / "sender-secret.json").write_text((root / "sender-secret.json").read_text())
    os.chmod(second_root / "sender-secret.json", 0o600)
    second_envelope, second_frame = seal(second_root, owner, bob, b"second frame, written by a granted writer\n")
    _, stranger = call(other_wallet, segment, "append", [second_frame.decode("ascii")], "non-writer")
    expect_rejected(stranger, "not segment writer", "non-writer")
    _, stranger_grant = call(other_wallet, segment, "grant_writer", [other["address"]], "non-owner-grant")
    expect_rejected(stranger_grant, "not segment owner", "non-owner grant")
    assert unchanged()
    report["controls"].update({
        "duplicate_frame": {"tx": duplicate["tx_hash"], "status": duplicate["status"], "error": duplicate.get("error")},
        "oversize_2049": {"tx": oversized["tx_hash"], "status": oversized["status"], "error": oversized.get("error"),
                          "argument_bytes": len(oversize)},
        "non_writer_append": {"tx": stranger["tx_hash"], "status": stranger["status"], "error": stranger.get("error")},
        "non_owner_grant": {"tx": stranger_grant["tx_hash"], "status": stranger_grant["status"],
                            "error": stranger_grant.get("error")},
        "frame_and_count_unchanged_after_rejections": True})

    _, granted = call(owner_wallet, segment, "grant_writer", [other["address"]], "grant")
    expect_confirmed(granted, "grant")
    _, written = call(other_wallet, segment, "append", [second_frame.decode("ascii")], "writer-append")
    expect_confirmed(written, "writer append")
    report_count[0] = 2
    assert view(segment, "sender", [1]) == other["address"] and unchanged()
    fetched = second_root / "fetched.ocm"
    fetched.write_bytes(base64.b64decode(view(segment, "get", [1]).strip(), validate=True))
    assert fetched.read_bytes() == second_envelope
    code, stdout, stderr = endpoint("bind-envelope", owner["address"], other["address"], fetched)
    assert code != 0, "an envelope signed by one wallet was bound to another on-chain writer"
    report["controls"]["granted_writer"] = {
        "grant_tx": granted["tx_hash"], "append_tx": written["tx_hash"], "stored_sender": other["address"],
        "client_binding_rejects_signer_writer_mismatch": True}

    card = json.dumps({"example": "card for " + other["address"]})
    _, stranger_card = call(other_wallet, segment, "set_card", [owner["address"], card], "non-owner-card")
    expect_rejected(stranger_card, "not segment owner", "non-owner card")
    assert view(segment, "has_card", [owner["address"]]) is False
    _, carded = call(owner_wallet, segment, "set_card", [other["address"], card], "card")
    expect_confirmed(carded, "card")
    assert view(segment, "has_card", [other["address"]]) is True and view(segment, "card", [other["address"]]) == card
    assert view(segment, "has_card", [owner["address"]]) is False
    report["controls"]["card"] = {"set_tx": carded["tx_hash"], "non_owner_set": {
        "tx": stranger_card["tx_hash"], "status": stranger_card["status"], "error": stranger_card.get("error")}}

    _, stranger_close = call(other_wallet, segment, "close", [], "non-owner-close")
    expect_rejected(stranger_close, "not segment owner", "non-owner close")
    _, closed = call(owner_wallet, segment, "close", [], "close")
    expect_confirmed(closed, "close")
    assert view(segment, "closed", []) is True
    third_root = WORK / "message-3"
    third_root.mkdir()
    (third_root / "sender-secret.json").write_text((root / "sender-secret.json").read_text())
    os.chmod(third_root / "sender-secret.json", 0o600)
    _, third_frame = seal(third_root, owner, bob, b"third frame, after close\n")
    _, after_close = call(owner_wallet, segment, "append", [third_frame.decode("ascii")], "append-after-close")
    expect_rejected(after_close, "segment closed", "append after close")
    assert unchanged()
    report["controls"]["close"] = {
        "non_owner_close": {"tx": stranger_close["tx_hash"], "status": stranger_close["status"]},
        "close_tx": closed["tx_hash"],
        "append_after_close": {"tx": after_close["tx_hash"], "status": after_close["status"],
                               "error": after_close.get("error")}}

    registry_package, registry_envelope, report["registry_package"] = compile_program("registry")
    _, registry_deployed = deploy(owner_wallet, "registry-deploy", registry_package, registry_envelope)
    expect_confirmed(registry_deployed, "registry deploy")
    registry = registry_deployed["to"]
    assert view(registry, "owner", []) == owner["address"] and int(view(registry, "count", [])) == 0
    _, stranger_publish = call(other_wallet, registry, "publish", [segment, 0], "non-owner-publish")
    expect_rejected(stranger_publish, "not registry owner", "non-owner publish")
    assert int(view(registry, "count", [])) == 0
    _, published = call(owner_wallet, registry, "publish", [segment, deployed["epoch"]], "publish")
    expect_confirmed(published, "publish")
    assert int(view(registry, "count", [])) == 1 and view(registry, "current", []) == segment
    assert view(registry, "segment", [0]) == segment
    assert int(view(registry, "activation_epoch", [0])) == deployed["epoch"]
    report["registry"] = {"address": registry, "deploy_tx": registry_deployed["tx_hash"],
                          "publish_tx": published["tx_hash"],
                          "non_owner_publish": {"tx": stranger_publish["tx_hash"], "status": stranger_publish["status"],
                                                "error": stranger_publish.get("error")}}

    directory_package, directory_envelope, report["directory_package"] = compile_program("directory")
    _, directory_deployed = deploy(owner_wallet, "directory-deploy", directory_package, directory_envelope)
    expect_confirmed(directory_deployed, "directory deploy")
    directory = directory_deployed["to"]
    assert view(directory, "has", [owner["address"]]) is False
    _, registered = call(owner_wallet, directory, "register", [segment], "register")
    expect_confirmed(registered, "register")
    assert view(directory, "has", [owner["address"]]) is True and view(directory, "has", [other["address"]]) is False
    assert view(directory, "segment_of", [owner["address"]]) == segment
    report["directory"] = {"address": directory, "deploy_tx": directory_deployed["tx_hash"],
                           "register_tx": registered["tx_hash"]}

    transactions = sorted(WORK.glob("*-final.json"))
    report["transactions"] = {path.name[:-len("-final.json")]: {
        key: json.loads(path.read_text()).get(key) for key in ("tx_hash", "status", "epoch", "ou", "effort_used", "fee")}
        for path in transactions}
    report["end_epoch"] = rpc("node_status", [])["head_epoch"]
    report["status"] = "devnet_program_pass"
    (WORK / "devnet-program.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"status": report["status"], "segment": segment, "registry": registry}))


if __name__ == "__main__":
    main()
