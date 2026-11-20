#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
"""Messenger bridge for the webcli messenger app: seals and opens envelopes with the octra_messenger endpoint."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

ENDPOINT = os.environ.get("MESSENGER_ENDPOINT", "./messenger_endpoint")
CHAIN_ID = os.environ.get("MESSENGER_CHAIN_ID", "octra-devnet-9871-cluster")
FRAME_BYTES = 2048
MAX_TEXT_BYTES = 1000
ADDRESS = re.compile(r"^oct[1-9A-HJ-NP-Za-km-z]{44}$")


def fail(reason):
    print(json.dumps({"error": reason}))
    sys.exit(0)


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(10):
        request = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.load(response)
        if "error" not in payload:
            return payload["result"]
        if payload["error"].get("code") != -32012:
            fail("rpc: " + str(payload["error"].get("message")))
        time.sleep(0.5)
    fail("rpc busy")


def endpoint(arguments, environment=None):
    result = subprocess.run([ENDPOINT, *map(str, arguments)], capture_output=True, text=True,
                            env=dict(os.environ, MESSENGER_RECIPIENT_CHAIN_ID=CHAIN_ID, **(environment or {})))
    return result.returncode == 0, result.stdout.strip()


def private_write(path, text):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(text)


def history_path(base, contact):
    return base / "history" / (contact + ".jsonl")


def read_history(base, contact):
    path = history_path(base, contact)
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def append_history(base, contact, entry):
    path = history_path(base, contact)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as output:
        output.write(json.dumps(entry) + "\n")


def next_incoming(entries):
    sequences = [entry["sequence"] for entry in entries if entry["direction"] == "in"]
    return max(sequences) + 1 if sequences else 0


def contact_root(base):
    root = base / "root"
    if not (root / "contact-root.json").exists():
        root.mkdir(parents=True, exist_ok=True)
        ok, _ = endpoint(["recipient-init", root, base64.b64encode(bytes(32)).decode()],
                         {"MESSENGER_RECIPIENT_EPOCH": "0"})
        if not ok:
            fail("contact root setup failed")
    return (root / "contact-root.json").read_text()


def card(request, base):
    contact = request["body"]["contact"]
    directory = base / "in" / contact
    if not (directory / "recipient-public.json").exists():
        public = rpc(request["rpc_url"], "octra_publicKey", [contact]).get("public_key")
        if not public:
            fail("contact has no public key on chain yet")
        epoch = int(rpc(request["rpc_url"], "node_status", [])["head_epoch"])
        directory.mkdir(parents=True, exist_ok=True)
        ok, _ = endpoint(["recipient-init", directory, public], {"MESSENGER_RECIPIENT_EPOCH": str(epoch)})
        if not ok:
            fail("recipient key setup failed")
    return {"card": (directory / "recipient-public.json").read_text().strip()}


def seal(request, base):
    body = request["body"]
    contact, text = body["contact"], body["text"]
    raw_text = text.encode()
    if not raw_text or len(raw_text) > MAX_TEXT_BYTES:
        fail("message must be 1 to %d bytes" % MAX_TEXT_BYTES)
    try:
        config = json.loads(body["card"])
    except (ValueError, TypeError):
        fail("contact card is not valid")
    if config.get("expected_sender_public") != request["wallet"]["pub"]:
        fail("contact card was issued for another sender")
    directory = base / "out" / contact
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "recipient-public.json").write_text(body["card"])
    (directory / "contact-root.json").write_text(contact_root(base))
    secret = base64.b64decode(request["wallet"]["priv"])[:32]
    private_write(base / "sender-secret.json", json.dumps({"secret": base64.b64encode(secret).decode()}))
    private_write(directory / "plaintext.txt", text)
    ok, _ = endpoint(["send", directory / "recipient-public.json", base / "sender-secret.json",
                      directory / "plaintext.txt", directory / "message.ocm"])
    os.unlink(directory / "plaintext.txt")
    if not ok:
        fail("sealing was rejected")
    encoded = base64.b64encode((directory / "message.ocm").read_bytes()).decode()
    if len(encoded) > FRAME_BYTES:
        fail("message does not fit one frame")
    append_history(base, contact, {"direction": "out", "text": text, "time": time.time()})
    return {"frame": encoded + " " * (FRAME_BYTES - len(encoded))}


def open_frame(request, base):
    body = request["body"]
    contact, sequence = body["contact"], int(body["sequence"])
    entries = read_history(base, contact)
    if sequence < next_incoming(entries):
        return {"skipped": True}
    directory = base / "in" / contact
    entry = {"direction": "in", "sequence": sequence, "epoch": int(body["epoch"]), "time": time.time()}
    try:
        envelope = base64.b64decode(body["frame"].strip(), validate=True)
    except ValueError:
        envelope = None
    if envelope is None or not (directory / "recipient-public.json").exists():
        entry["error"] = "frame is not an envelope for this contact"
    else:
        path = directory / "incoming.ocm"
        path.write_bytes(envelope)
        bound, _ = endpoint(["bind-envelope", contact, body["sender"], path])
        if not bound:
            entry["error"] = "on-chain writer does not match the envelope signer"
        else:
            output = directory / "incoming.txt"
            opened, _ = endpoint(["open-archive", directory / "recipient-secret-v1.json",
                                  directory / "recipient-public.json", path, output, entry["epoch"]])
            if opened:
                entry["text"] = output.read_text(errors="replace")
                os.unlink(output)
            else:
                entry["error"] = "envelope rejected"
    append_history(base, contact, entry)
    return entry


def history(request, base):
    entries = read_history(base, request["body"]["contact"])
    return {"entries": entries, "next_incoming": next_incoming(entries)}


def main():
    request = json.loads(Path(sys.argv[1]).read_text())
    contact = request["body"].get("contact", "")
    if not ADDRESS.match(contact):
        fail("contact address is not valid")
    base = Path("data") / "messenger" / request["wallet"]["address"]
    base.mkdir(parents=True, exist_ok=True)
    os.chmod(base, 0o700)
    operations = {"card": card, "seal": seal, "open": open_frame, "history": history}
    print(json.dumps(operations[request["op"]](request, base)))


if __name__ == "__main__":
    main()
