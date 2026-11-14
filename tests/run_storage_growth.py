#!/usr/bin/env python3
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

VENUE = Path("/srv/octra-node/fakenet-kimi-messenger")
PROJECT = Path("/home/kimi/workspace/octra-egregore/projects/onchain-messenger")
RPC = "http://127.0.0.1:18171/rpc"
DRIVER = VENUE / "bin/chain_driver.exe"
PRUNE = VENUE / "bin/prune_driver.exe"
WALLET = VENUE / "nodes/node1/data/wallet.json"
ADDRESS = json.loads((VENUE / "receipts/validators.json").read_text())[0]["address"]
DATA = VENUE / "nodes/node1/data"
RUN_ID = os.environ.get("MESSENGER_STORAGE_RUN_ID", "storage-growth")
WORK = VENUE / "work" / RUN_ID
RECEIPTS = VENUE / "receipts"
ENV = os.environ.copy()
ENV["LD_LIBRARY_PATH"] = f"/srv/octra-node/runtime-libs:{VENUE / 'link-libs'}"


def utc_now():
    return subprocess.check_output(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], text=True).strip()


def rpc(method, params, url=RPC):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for _ in range(10):
        request = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.load(response)
        if "error" not in payload:
            return payload["result"]
        if payload["error"].get("code") != -32012:
            raise RuntimeError(payload["error"])
        time.sleep(0.5)
    raise RuntimeError(payload["error"])


def wait_transaction(tx_hash):
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline:
        transaction = rpc("octra_transaction", [tx_hash])
        if transaction["status"] in ("confirmed", "rejected"):
            return transaction
        if transaction["status"] == "dropped":
            raise RuntimeError(transaction)
        time.sleep(1)
    raise RuntimeError(("transaction did not finalize within 360 seconds", tx_hash))


def submit(kind, nonce, ou, params, output_name, payload=None):
    output = WORK / output_name
    command = [str(DRIVER), kind, RPC, str(WALLET)]
    if kind == "legacy-deploy":
        command += [str(nonce), str(ou), str(payload), json.dumps(params), str(output)]
    elif kind == "multi":
        command += [str(nonce), str(ou), json.dumps(params), str(output)]
    else:
        raise ValueError(kind)
    for attempt in range(10):
        result = subprocess.run(command, capture_output=True, text=True, env=ENV)
        if result.returncode == 0:
            break
        if kind == "legacy-deploy" and not output.exists() and "-32012" in result.stderr and attempt < 9:
            time.sleep(0.5)
            continue
        raise RuntimeError(f"{kind} failed: {result.stderr.strip() or result.stdout.strip()}")
    submission = json.loads(result.stdout)
    assert submission["ou"] == submission["ou_cost"] == str(ou), submission
    (RECEIPTS / f"{RUN_ID}-{output_name.replace('.json', '')}-submit.json").write_text(
        json.dumps(submission, indent=2) + "\n")
    transaction = wait_transaction(submission["tx_hash"])
    assert transaction["status"] == "confirmed", transaction
    signed = json.loads(output.read_text())
    return submission, transaction, signed["timestamp"]


def du_bytes(kind, path):
    value = subprocess.check_output(["du", kind, str(path)], text=True).split()[0]
    return int(value)


def checkpoint(phase, frames, batch=None, include_rpc=True):
    point = {
        "phase": phase,
        "batch": batch,
        "frames": frames,
        "observed_at": utc_now(),
        "unix_time": time.time(),
        "apparent_bytes": du_bytes("-sb", DATA),
        "allocated_bytes": du_bytes("-sB1", DATA),
        "subdirectory_apparent_bytes": {
            child.name: du_bytes("-sb", child) for child in sorted(DATA.iterdir()) if child.is_dir()
        },
    }
    if include_rpc:
        status = rpc("node_status", [])
        point["head_epoch"] = status["head_epoch"]
        point["state_root"] = status["state_root"]
    return point


def regression(points, field):
    x = [point["frames"] for point in points]
    y = [point[field] for point in points]
    mean_x = sum(x) / len(x)
    mean_y = sum(y) / len(y)
    denominator = sum((value - mean_x) ** 2 for value in x)
    slope = sum((x[i] - mean_x) * (y[i] - mean_y) for i in range(len(x))) / denominator
    intercept = mean_y - slope * mean_x
    total = sum((value - mean_y) ** 2 for value in y)
    residual = sum((y[i] - (intercept + slope * x[i])) ** 2 for i in range(len(x)))
    return {
        "samples": len(points),
        "slope_bytes_per_frame": slope,
        "intercept_bytes": intercept,
        "r_squared": None if total == 0 else 1 - residual / total,
    }


def encoded_bytes(value):
    if isinstance(value, dict) and value.get("encoding") == "base64":
        return base64.b64decode(value["data"], validate=True)
    if isinstance(value, str):
        return value.encode()
    raise ValueError(value)


def wait_node():
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline:
        try:
            status = rpc("node_status", [])
            if status["head_epoch"] > 0:
                return status
        except (OSError, RuntimeError):
            pass
        time.sleep(1)
    raise RuntimeError("node 1 did not return to RPC readiness within 360 seconds")


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    assert not any(WORK.iterdir()), f"refusing to overwrite non-empty run directory {WORK}"
    original_batches = []
    for path in sorted((VENUE / "work/load-spike/batches").glob("*.json")):
        original_batches.append(json.loads(path.read_text())["calls"])
    assert len(original_batches) == 13
    assert sum(len(calls) for calls in original_batches) == 100
    frames = [base64.b64decode(call["params"][0]["data"], validate=True)
              for calls in original_batches for call in calls]
    assert all(len(frame) == 2048 for frame in frames)
    nonce = int(rpc("octra_account", [ADDRESS])["nonce"]) + 1
    checkpoints = [checkpoint("before_deploy", 0)]
    submission, transaction, _ = submit(
        "legacy-deploy", nonce, 200000, [], "deploy.json",
        VENUE / "work/load-spike/legacy-bytecode.b64")
    address = transaction["to"]
    deployment = {"submission": submission, "tx_hash": submission["tx_hash"],
                  "epoch": transaction["epoch"], "address": address}
    (RECEIPTS / f"{RUN_ID}-deploy-address.json").write_text(json.dumps(deployment, indent=2) + "\n")
    assert rpc("contract_call", [address, "info", [], ADDRESS])["result"] == "1|2048|0|0|8388608|false"
    checkpoints.append(checkpoint("baseline_after_deploy", 0))
    batches = []
    for index, original in enumerate(original_batches):
        calls = [{**call, "to": address} for call in original]
        before = checkpoint(f"batch_{index:02d}_before", sum(len(row) for row in original_batches[:index]), index)
        checkpoints.append(before)
        submission, transaction, signed_timestamp = submit(
            "multi", nonce + index + 1, 1000 * (len(calls) + 1), {"calls": calls}, f"batch-{index:02d}.json")
        frames_done = sum(len(row) for row in original_batches[:index + 1])
        after = checkpoint(f"batch_{index:02d}_after", frames_done, index)
        checkpoints.append(after)
        batches.append({
            "batch": index,
            "calls": len(calls),
            "frames_before": before["frames"],
            "frames_after": frames_done,
            "tx_hash": submission["tx_hash"],
            "epoch": transaction["epoch"],
            "nonce": transaction["nonce"],
            "ou": submission["ou"],
            "signed_json_bytes": submission["signed_json_bytes"],
            "rpc_request_bytes": submission["rpc_request_bytes"],
            "signed_timestamp": signed_timestamp,
            "finalized_timestamp": after["unix_time"],
            "apparent_growth_bytes": after["apparent_bytes"] - before["apparent_bytes"],
            "allocated_growth_bytes": after["allocated_bytes"] - before["allocated_bytes"],
            "head_epochs_observed": [before.get("head_epoch"), after.get("head_epoch")],
        })
        expected = f"1|2048|{frames_done}|{frames_done * 2048}|8388608|false"
        assert rpc("contract_call", [address, "info", [], ADDRESS])["result"] == expected
    before_gc = checkpoints[-1]
    gc_epoch = rpc("node_status", [])["head_epoch"]
    gc_console = RECEIPTS / f"{RUN_ID}-pack-gc-console.txt"
    subprocess.run(["systemctl", "--user", "stop", "octra-kimi-msgnet-1"], check=True)
    rollback = VENUE / "nodes/node1" / f"data.pre-{RUN_ID}"
    assert not rollback.exists(), rollback
    subprocess.run(["cp", "-a", str(DATA), str(rollback)], check=True)
    try:
        with gc_console.open("w") as console:
            subprocess.run([str(PRUNE), str(DATA / "irmin_store"), str(gc_epoch)],
                           check=True, stdout=console, stderr=subprocess.STDOUT, env=ENV, timeout=300)
        gc_lines = [json.loads(line) for line in gc_console.read_text().splitlines() if line.startswith("{")]
        assert gc_lines[-1] == {"status": "complete"}, gc_lines
        checkpoints.append(checkpoint("after_pack_gc_node_stopped", 100, include_rpc=False))
    finally:
        subprocess.run([str(PROJECT / "tests/run_chain_spike.sh"), "start", "1"],
                       check=True, capture_output=True, text=True, env=ENV)
    wait_node()
    checkpoints.append(checkpoint("after_restart_before_reads", 100))
    assert rpc("contract_call", [address, "info", [], ADDRESS])["result"] == "1|2048|100|204800|8388608|false"
    for sequence, expected in enumerate(frames):
        actual = encoded_bytes(rpc("contract_call", [address, "get", [sequence], ADDRESS])["result"])
        assert actual == expected, sequence
    checkpoints.append(checkpoint("after_restart_and_100_exact_reads", 100))
    series = [checkpoints[1]] + [point for point in checkpoints if point["phase"].endswith("_after")
                                 and point["batch"] is not None]
    assert len(series) == 14 and series[-1]["frames"] == 100
    after_gc = next(point for point in checkpoints if point["phase"] == "after_pack_gc_node_stopped")
    after_restart = next(point for point in checkpoints if point["phase"] == "after_restart_before_reads")
    after_reads = checkpoints[-1]
    source_commit = subprocess.check_output(["git", "-C", str(PROJECT), "rev-parse", "HEAD"], text=True).strip()
    report = {
        "status": "storage_growth_100_frames_and_pack_gc_pass",
        "run_id": RUN_ID,
        "observed_at": utc_now(),
        "venue": str(VENUE),
        "chain_id": "octra-fakenet-kimi-msgnet",
        "node_sha256": "8846d2a9f3240d2aedfecb49553f082c284c2b951a6ddb7a9b60afe09800ef18",
        "node_patch_sha256": "0f10cf5d5d0d58ccfc93351aec9dca466acd19d1142f6266c38cd4bb6dc42c07",
        "compiler_source_stamp": "6eb1af8241430645904abb6524df5791a11c0ca98eb8a6d859624742d9d8b20f",
        "test_source_commit": source_commit,
        "test_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "chain_driver_sha256": hashlib.sha256(DRIVER.read_bytes()).hexdigest(),
        "prune_driver_sha256": hashlib.sha256(PRUNE.read_bytes()).hexdigest(),
        "segment": address,
        "accepted_frames": 100,
        "stored_body_bytes_per_frame": 2048,
        "baseline": "after deployment and before the first message batch; deployment growth reported separately",
        "measurement": "du -sb apparent bytes and du -sB1 allocated bytes for the complete node-1 data directory",
        "deployment_apparent_growth_bytes": checkpoints[1]["apparent_bytes"] - checkpoints[0]["apparent_bytes"],
        "deployment_allocated_growth_bytes": checkpoints[1]["allocated_bytes"] - checkpoints[0]["allocated_bytes"],
        "apparent_regression": regression(series, "apparent_bytes"),
        "allocated_regression": regression(series, "allocated_bytes"),
        "end_to_end_apparent_growth_bytes": before_gc["apparent_bytes"] - checkpoints[1]["apparent_bytes"],
        "end_to_end_apparent_growth_bytes_per_frame": (before_gc["apparent_bytes"] - checkpoints[1]["apparent_bytes"]) / 100,
        "end_to_end_allocated_growth_bytes": before_gc["allocated_bytes"] - checkpoints[1]["allocated_bytes"],
        "end_to_end_allocated_growth_bytes_per_frame": (before_gc["allocated_bytes"] - checkpoints[1]["allocated_bytes"]) / 100,
        "pack_gc_epoch": gc_epoch,
        "rollback_copy": f"nodes/node1/data.pre-{RUN_ID} retained in the isolated venue",
        "pack_gc_apparent_reclaimed_bytes": before_gc["apparent_bytes"] - after_gc["apparent_bytes"],
        "pack_gc_allocated_reclaimed_bytes": before_gc["allocated_bytes"] - after_gc["allocated_bytes"],
        "post_pack_gc_apparent_delta_from_baseline_bytes": after_gc["apparent_bytes"] - checkpoints[1]["apparent_bytes"],
        "post_pack_gc_apparent_delta_from_baseline_bytes_per_frame": (after_gc["apparent_bytes"] - checkpoints[1]["apparent_bytes"]) / 100,
        "post_pack_gc_allocated_delta_from_baseline_bytes": after_gc["allocated_bytes"] - checkpoints[1]["allocated_bytes"],
        "post_pack_gc_allocated_delta_from_baseline_bytes_per_frame": (after_gc["allocated_bytes"] - checkpoints[1]["allocated_bytes"]) / 100,
        "restart_before_reads_apparent_growth_after_gc_bytes": after_restart["apparent_bytes"] - after_gc["apparent_bytes"],
        "restart_before_reads_allocated_growth_after_gc_bytes": after_restart["allocated_bytes"] - after_gc["allocated_bytes"],
        "post_restart_before_reads_apparent_delta_from_baseline_bytes": after_restart["apparent_bytes"] - checkpoints[1]["apparent_bytes"],
        "exact_read_apparent_growth_bytes": after_reads["apparent_bytes"] - after_restart["apparent_bytes"],
        "exact_read_allocated_growth_bytes": after_reads["allocated_bytes"] - after_restart["allocated_bytes"],
        "post_restart_and_reads_apparent_delta_from_baseline_bytes": after_reads["apparent_bytes"] - checkpoints[1]["apparent_bytes"],
        "retained_frames_verified_exactly_after_restart": 100,
        "batches": batches,
        "checkpoints": checkpoints,
        "limits": [
            "Whole-directory growth includes consensus, WAL, indexes and empty epochs observed during each interval.",
            "Sequential batches measure finality-cadence storage behavior, not sustainable throughput.",
            "Pack GC also collects older chain history, so its delta from baseline is not message-only growth.",
            "One hundred frames are not the 10,000/100,000-frame acceptance runs or a production capacity claim.",
        ],
    }
    (RECEIPTS / f"{RUN_ID}.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key not in ("batches", "checkpoints")}, indent=2))


if __name__ == "__main__":
    main()
