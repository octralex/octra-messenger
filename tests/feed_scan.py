#!/usr/bin/env python3
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import urllib.request

FRAME_BYTES = 2048
PAGE_RECORDS = 16


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=15) as response:
        payload = json.load(response)
    if "error" in payload:
        raise RuntimeError(payload["error"])
    return payload["result"]


def encoded_bytes(value):
    if isinstance(value, dict) and value.get("encoding") == "base64":
        raw = base64.b64decode(value["data"], validate=True)
    elif isinstance(value, str):
        raw = value.encode()
    else:
        raise ValueError("unsupported byte response")
    return raw


def digest_value(value):
    raw = encoded_bytes(value)
    if len(raw) == 64 and all(chr(byte) in "0123456789abcdef" for byte in raw):
        return bytes.fromhex(raw.decode("ascii"))
    return raw


def info(url, address, caller):
    raw = rpc(url, "contract_call", [address, "info", [], caller])["result"]
    version, frame_bytes, count, used, capacity, closed = raw.split("|")
    assert version == "1" and int(frame_bytes) == FRAME_BYTES
    return {
        "count": int(count),
        "used_bytes": int(used),
        "capacity_bytes": int(capacity),
        "closed": closed == "true",
    }


def get_frame(url, address, sequence, caller):
    value = rpc(url, "contract_call", [address, "get", [sequence], caller])["result"]
    raw = encoded_bytes(value)
    assert len(raw) == FRAME_BYTES
    expected = digest_value(
        rpc(url, "contract_call", [address, "content_hash", [sequence], caller])["result"]
    )
    assert hashlib.sha256(raw).digest() == expected, (sequence, hashlib.sha256(raw).hexdigest(), expected.hex())
    return raw


def scan(url, registry):
    caller = "oct00000000000000000000000000000000000000000000"
    count = int(rpc(url, "contract_call", [registry, "count", [], caller])["result"])
    current = rpc(url, "contract_call", [registry, "current", [], caller])["result"]
    descriptors = []
    records = []
    page_count = 0
    for segment_id in range(count):
        descriptor = rpc(url, "contract_call", [registry, "descriptor", [segment_id], caller])["result"]
        fields = descriptor.split("|")
        assert len(fields) == 7 and fields[0] == "1" and fields[-1] == "1"
        _, address, activation, max_records, max_bytes, predecessor, _ = fields
        assert int(max_records) == 1024 and int(max_bytes) == 8388608
        assert int(predecessor) == segment_id - 1
        metadata = info(url, address, caller)
        assert metadata["used_bytes"] == metadata["count"] * FRAME_BYTES
        assert metadata["count"] <= int(max_records)
        assert metadata["used_bytes"] <= metadata["capacity_bytes"]
        if segment_id == count - 1:
            assert current == address
        frames = []
        full_pages = metadata["count"] // PAGE_RECORDS
        for start in range(0, full_pages * PAGE_RECORDS, PAGE_RECORDS):
            raw = encoded_bytes(rpc(url, "contract_call", [address, "page", [start], caller])["result"])
            assert len(raw) == PAGE_RECORDS * FRAME_BYTES
            frames.extend(raw[offset:offset + FRAME_BYTES] for offset in range(0, len(raw), FRAME_BYTES))
            page_count += 1
        for sequence in range(full_pages * PAGE_RECORDS, metadata["count"]):
            frames.append(get_frame(url, address, sequence, caller))
            page_count += 1
        assert len(frames) == metadata["count"]
        for sequence, frame in enumerate(frames):
            digest = hashlib.sha256(frame).hexdigest()
            expected = digest_value(
                rpc(url, "contract_call", [address, "content_hash", [sequence], caller])["result"]
            )
            assert digest == expected.hex()
            records.append({
                "segment_id": segment_id,
                "segment": address,
                "sequence": sequence,
                "frame_sha256": digest,
            })
        descriptors.append({
            "segment_id": segment_id,
            "address": address,
            "activation_epoch": int(activation),
            "predecessor": int(predecessor),
            **metadata,
        })
    return {
        "schema": "messenger-feed-index-v1",
        "registry": registry,
        "current": current,
        "descriptors": descriptors,
        "records": records,
        "rpc_calls_bounded": page_count + 2 * count + 2 + len(records),
    }


def write_atomic(path, value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    with temporary.open("wb") as handle:
        handle.write(raw)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    return hashlib.sha256(raw).hexdigest()


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: feed_scan.py RPC_URL REGISTRY_ADDRESS OUTPUT_JSON")
    index = scan(sys.argv[1], sys.argv[2])
    digest = write_atomic(Path(sys.argv[3]), index)
    print(json.dumps({
        "status": "feed_index_rebuilt",
        "index_sha256": digest,
        "segments": len(index["descriptors"]),
        "frames": len(index["records"]),
        "rpc_calls_bounded": index["rpc_calls_bounded"],
    }))


if __name__ == "__main__":
    main()
