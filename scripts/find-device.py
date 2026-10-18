"""Prints "<udid> <platform>" for a connected physical device from `xcrun devicectl list devices --json-output`.

Usage: find-device.py <devices.json> <name or identifier>. Prints nothing when no physical device matches.
"""
import json
import sys

wanted = sys.argv[2]
with open(sys.argv[1]) as handle:
    devices = json.load(handle)["result"]["devices"]
for device in devices:
    hardware = device.get("hardwareProperties", {})
    names = {device.get("deviceProperties", {}).get("name"), hardware.get("udid"), device.get("identifier")}
    if hardware.get("reality") == "physical" and wanted in names:
        print(hardware.get("udid"), hardware.get("platform"))
        break
