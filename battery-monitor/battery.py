#!/usr/bin/env python3
"""Read Keychron mouse battery over raw HID. Prints JSON, pure stdlib.

Protocol (Keychron 8K dongle, VID 0x3434, config collection usage page 0xFFC1):
write [0xB3, 0x06] zero-padded to 64B, read frames until [0xB4, 0x06, ...].
Reply body byte 19: low 7 bits = percent, high bit = charging.
"""

import json
import os
import select
import sys

VID = "00003434"
USAGE_PAGE_CONFIG = 0xFFC1
LONG_OUT, LONG_IN, CMD_GET_BLOCK = 0xB3, 0xB4, 0x06
FRAME_LEN = 64  # 1 report-id byte + 63 payload
TIMEOUT_MS = 1000


def first_usage_page(desc: bytes):
    for i in range(len(desc) - 2):
        if desc[i] == 0x06:
            return desc[i + 1] | (desc[i + 2] << 8)
    return None


def hid_name(uevent: str) -> str:
    line = next((l for l in uevent.splitlines() if l.startswith("HID_NAME=")), "")
    name = line[len("HID_NAME="):].strip()
    # Kernel often doubles the vendor ("Keychron Keychron K6"); collapse repeats.
    words = name.split()
    deduped = [w for i, w in enumerate(words) if i == 0 or w != words[i - 1]]
    return " ".join(deduped) or "Keychron device"


def config_nodes():
    out = []
    try:
        entries = sorted(os.listdir("/sys/class/hidraw"))
    except FileNotFoundError:
        return out
    for node in entries:
        dev = f"/sys/class/hidraw/{node}/device"
        try:
            uevent = open(f"{dev}/uevent").read()
            desc = open(f"{dev}/report_descriptor", "rb").read()
        except OSError:
            continue
        hid_id = next((l for l in uevent.splitlines() if l.startswith("HID_ID=")), "")
        if VID not in hid_id.upper():
            continue
        if first_usage_page(desc) == USAGE_PAGE_CONFIG:
            out.append((f"/dev/{node}", hid_name(uevent)))
    return out


def probe(path):
    fd = os.open(path, os.O_RDWR)
    try:
        frame = bytes([LONG_OUT, CMD_GET_BLOCK]) + bytes(FRAME_LEN - 2)
        os.write(fd, frame)
        poller = select.poll()
        poller.register(fd, select.POLLIN)
        deadline = TIMEOUT_MS
        while deadline > 0:
            ready = poller.poll(min(deadline, 200))
            deadline -= 200
            if not ready:
                continue
            r = os.read(fd, FRAME_LEN)
            # Discard live input reports / foreign replies.
            if len(r) > 20 and r[0] == LONG_IN and r[1] == CMD_GET_BLOCK:
                raw = r[20]  # body[19]: report id + cmd echo shift offsets by 1
                return {"percent": raw & 127, "charging": raw >> 7 == 1}
        return None
    finally:
        os.close(fd)


def main():
    nodes = config_nodes()
    if not nodes:
        print(json.dumps({"error": "no-device"}))
        return 1
    for path, name in nodes:
        try:
            result = probe(path)
        except OSError:
            result = None
        if result is not None:
            result["name"] = name
            print(json.dumps(result))
            return 0
    # Nodes exist but none answered (idle transport) or permission denied.
    print(json.dumps({"error": "no-reply"}))
    return 1


if __name__ == "__main__":
    sys.exit(main())
