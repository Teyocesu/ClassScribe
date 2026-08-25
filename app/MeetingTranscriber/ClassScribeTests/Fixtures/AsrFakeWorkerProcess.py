#!/usr/bin/env python3
"""Small framed fake ASR worker used only by process-boundary tests."""

import argparse
import json
import os
import queue
import struct
import sys
import threading
import time

MAX_MESSAGE_BYTES = 1_048_576
PROTOCOL_VERSION = 1


def read_exact(stream, size):
    chunks = []
    remaining = size
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(stream):
    header = read_exact(stream, 4)
    if header is None:
        return None
    (size,) = struct.unpack(">I", header)
    if size == 0 or size > MAX_MESSAGE_BYTES:
        raise ValueError("invalid frame size")
    payload = read_exact(stream, size)
    if payload is None:
        raise EOFError("unexpected EOF")
    return json.loads(payload.decode("utf-8"))


def send_frame(message):
    payload = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(payload) > MAX_MESSAGE_BYTES:
        raise ValueError("message too large")
    sys.stdout.buffer.write(struct.pack(">I", len(payload)))
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()


def envelope(hello, message_type, **fields):
    result = {
        "protocolVersion": PROTOCOL_VERSION,
        "attemptID": hello["attemptID"],
        "jobID": hello["jobID"],
        "messageType": message_type,
    }
    result.update(fields)
    return result


def start_frame_reader():
    events = queue.Queue()

    def read_loop():
        try:
            events.put((read_frame(sys.stdin.buffer), None))
        except BaseException as error:
            events.put((None, error))

    threading.Thread(target=read_loop, daemon=True).start()
    return events


def run(scenario):
    if scenario == "crash-before-handshake":
        os._exit(21)

    hello = read_frame(sys.stdin.buffer)
    if hello is None:
        return 22

    if scenario == "no-handshake":
        time.sleep(5)
        return 0

    if scenario == "incompatible-protocol":
        ready = envelope(hello, "ready")
        ready["protocolVersion"] = PROTOCOL_VERSION + 1
        ready["selectedVersion"] = PROTOCOL_VERSION + 1
        send_frame(ready)
        return 0

    ready = envelope(hello, "ready", selectedVersion=PROTOCOL_VERSION)
    send_frame(ready)

    hang_events = start_frame_reader() if scenario == "hang" else None

    while True:
        if hang_events is not None:
            try:
                frame, error = hang_events.get(timeout=0.05)
            except queue.Empty:
                send_frame(envelope(hello, "heartbeat"))
                continue
            if error is not None:
                raise error
            if frame is None:
                return 0
        else:
            frame = read_frame(sys.stdin.buffer)
            if frame is None:
                return 0

        message_type = frame.get("messageType")
        if message_type == "shutdown":
            return 0
        if message_type == "cancel":
            if scenario == "ignores-cancellation":
                continue
            if scenario == "late-output-after-cancel":
                send_frame(envelope(hello, "result", text="late result"))
                continue
            send_frame(envelope(hello, "cancelled"))
            continue
        if message_type != "start":
            continue

        if scenario == "crash-during-job":
            os._exit(23)
        if scenario == "malformed-raw-frame":
            sys.stdout.buffer.write(b"\x00\x00\x00\x03bad")
            sys.stdout.buffer.flush()
            time.sleep(5)
            continue
        if scenario == "unexpected-eof":
            os.close(sys.stdout.fileno())
            time.sleep(5)
            continue
        if scenario == "no-heartbeat":
            continue
        if scenario == "success":
            send_frame(envelope(hello, "heartbeat"))
            send_frame(envelope(hello, "progress", progress=1.0))
            send_frame(envelope(hello, "result", text="process fake transcript"))
            continue
        if scenario == "delayed-success":
            send_frame(envelope(hello, "heartbeat"))
            send_frame(envelope(hello, "progress", progress=0.25))
            continue
        if scenario in {"hang", "ignores-cancellation", "late-output-after-cancel"}:
            send_frame(envelope(hello, "heartbeat"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True)
    args = parser.parse_args()
    sys.exit(run(args.scenario) or 0)
