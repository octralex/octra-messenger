#!/usr/bin/env python3
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request

VENUE = Path("/srv/octra-node/fakenet-kimi-messenger")
PROJECT = Path(__file__).resolve().parents[1]
DRIVER = VENUE / "bin/chain_driver.exe"
RPC = "http://127.0.0.1:18171/rpc"
ADDRESS = json.loads((VENUE / "receipts/deploy-address.json").read_text())["address"]
WALLET = json.loads((VENUE / "receipts/validators.json").read_text())[0]["address"]
RESUME_COMPLETE = False


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(10):
        try:
            request = urllib.request.Request(RPC, data=body, headers={"content-type": "application/json"})
            with urllib.request.urlopen(request, timeout=10) as response:
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


def info():
    return rpc("contract_call", [ADDRESS, "info", [], WALLET])["result"]


def next_nonce():
    return int(rpc("octra_account", [WALLET])["nonce"]) + 1


def wait_final(tx_hash):
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline:
        time.sleep(2)
        transaction = rpc("octra_transaction", [tx_hash])
        if transaction and transaction.get("status") in ("confirmed", "rejected"):
            return transaction
    raise RuntimeError(("transaction did not finalize within 360 seconds", tx_hash))


def result_record(name, expected, submission, transaction):
    assert transaction["status"] == expected, (name, transaction)
    return {"name": name, "expected": expected, "transaction": transaction,
            "submission": submission, "info_after": info()}


def submit(name, params, expected, raw_params=None):
    submission = VENUE / "receipts" / f"binary-control-{name}-submit.json"
    if RESUME_COMPLETE:
        record = json.loads(submission.read_text())
        return result_record(name, expected, record, wait_final(record["tx_hash"]))
    nonce = next_nonce()
    output = VENUE / "work" / f"binary-control-{name}.json"
    params_text = raw_params if raw_params is not None else json.dumps(params)
    params_argument = params_text
    if len(params_text.encode()) > 100_000:
        params_path = VENUE / "work" / f"binary-control-{name}-params.json"
        params_path.write_text(params_text)
        params_argument = "@" + str(params_path)
    result = subprocess.run(
        [str(DRIVER), "legacy-exec", RPC, str(VENUE / "nodes/node1/data/wallet.json"),
         str(nonce), "1000", ADDRESS, "append", params_argument, str(output)],
        check=True, capture_output=True, text=True)
    submission.write_text(result.stdout)
    record = json.loads(result.stdout)
    return result_record(name, expected, record, wait_final(record["tx_hash"]))


def main():
    global RESUME_COMPLETE
    RESUME_COMPLETE = sys.argv[1:] == ["--resume-complete"]
    frame = (VENUE / "work/chain-spike/frame.bin").read_bytes()
    canonical = base64.b64encode(frame).decode()
    latest = sorted((VENUE / "work").glob("case-*/cap-exact.ocm"), key=lambda path: path.stat().st_mtime)[-1]
    maximum = latest.read_bytes()
    results = []
    resume = [] if RESUME_COMPLETE else sys.argv[1:]
    if resume not in ([], ["--resume-rejected-malformed"], ["--resume-nonce-gap"]):
        raise RuntimeError("usage: run_binary_controls.py [--resume-rejected-malformed|--resume-nonce-gap|--resume-complete]")
    if resume:
        submission = json.loads((VENUE / "receipts/binary-control-malformed-submit.json").read_text())
        results.append(result_record("malformed", "rejected", submission, rpc("octra_transaction", [submission["tx_hash"]])))
    else:
        results.append(submit("malformed", [{"encoding": "base64", "data": "not base64"}], "rejected"))
    canonical_name = "canonical-nonce-26" if resume == ["--resume-nonce-gap"] else "canonical"
    results.append(submit(canonical_name, [{"encoding": "base64", "data": canonical}], "confirmed"))
    if resume == ["--resume-nonce-gap"]:
        queued = json.loads((VENUE / "receipts/binary-control-canonical-submit.json").read_text())
        assert queued["rpc_result"]["nonce"] == 27, queued
        results.append(result_record("canonical-queued-27", "confirmed", queued, wait_final(queued["tx_hash"])))
    results.append(submit("unpadded", [{"encoding": "base64", "data": canonical.rstrip("=")}], "rejected"))
    results.append(submit("canonical-again", [{"encoding": "base64", "data": canonical}], "confirmed"))
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    assert canonical.endswith("=") and not canonical.endswith("==")
    position = len(canonical) - 2
    value = alphabet.index(canonical[position])
    noncanonical = canonical[:position] + alphabet[(value & 0x3c) | 1] + canonical[position + 1:]
    assert noncanonical != canonical and base64.b64decode(noncanonical) == frame
    results.append(submit("noncanonical-pad-bits", [{"encoding": "base64", "data": noncanonical}], "rejected"))
    results.append(submit("wrong-shape", [{"encoding": "hex", "data": canonical}], "rejected"))
    duplicate = '[{"encoding":"base64","data":' + json.dumps(canonical) + ',"data":' + json.dumps(canonical) + '}]'
    results.append(submit("duplicate-key", None, "rejected", raw_params=duplicate))
    results.append(submit("canonical-after-shapes", [{"encoding": "base64", "data": canonical}], "confirmed"))
    maximum_result = submit("maximum", [{"encoding": "base64", "data": base64.b64encode(maximum).decode()}], "rejected")
    results.append(maximum_result)
    for row in results:
        if row["name"] in ("malformed", "unpadded", "noncanonical-pad-bits", "wrong-shape", "duplicate-key"):
            assert row["transaction"]["error"]["type"] == "program_exec_exception", row
    submission = maximum_result["submission"]
    assert submission["signed_json_bytes"] < 4_194_304, submission
    assert submission["rpc_request_bytes"] < 4_194_304, submission
    assert submission["rpc_result"]["status"] == "accepted", submission
    error = maximum_result["transaction"]["error"]
    assert error["type"] == "program_exec_failed" and error["reason"] == "execution reverted [frame must be 2048 bytes]", error
    assert maximum_result["info_after"] == results[-2]["info_after"], (results[-2]["info_after"], maximum_result["info_after"])
    source_commit = subprocess.check_output(["git", "-C", str(PROJECT), "rev-parse", "HEAD"], text=True).strip()
    report = {
        "status": "base64_controls_pass",
        "test_source_commit": source_commit,
        "test_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "chain_driver_sha256": hashlib.sha256(DRIVER.read_bytes()).hexdigest(),
        "node_sha256": "8846d2a9f3240d2aedfecb49553f082c284c2b951a6ddb7a9b60afe09800ef18",
        "node_patch_sha256": "0f10cf5d5d0d58ccfc93351aec9dca466acd19d1142f6266c38cd4bb6dc42c07",
        "compiler_source_stamp": "6eb1af8241430645904abb6524df5791a11c0ca98eb8a6d859624742d9d8b20f",
        "command": " ".join(["python3", "tests/run_binary_controls.py", *sys.argv[1:]]),
        "malformed_rejected": True,
        "canonical_accepted": True,
        "unpadded_rejected": True,
        "noncanonical_pad_bits_rejected": True,
        "wrong_shape_rejected": True,
        "duplicate_keys_rejected": True,
        "canonical_after_shapes_accepted": True,
        "canonical_second_encoding_accepted": True,
        "maximum_signed_json_bytes": submission["signed_json_bytes"],
        "maximum_rpc_request_bytes": submission["rpc_request_bytes"],
        "maximum_envelope_bytes": len(maximum),
        "maximum_base64_json_bytes": len(base64.b64encode(maximum)) + 2,
        "maximum_transaction_under_4_mib": True,
        "maximum_rpc_accepted": True,
        "maximum_final_status": "rejected",
        "maximum_rejection_reason": error["reason"],
        "maximum_rejected_by_segment_frame_cap_without_storage": True,
        "results": results,
    }
    (VENUE / "receipts/binary-controls.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "results"}))


if __name__ == "__main__":
    main()
