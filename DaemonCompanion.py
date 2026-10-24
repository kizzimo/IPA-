#!/usr/bin/env python3
"""KIZZIMO Daemon Companion v3 — authenticated, LAN-only configuration staging.

This is NOT a device exploit or a daemon controller. It cannot launch a mobile
restore and will never report a draft as applied to iOS.
Python 3.9+. No third-party dependencies.
"""
import argparse
import base64
import binascii
import hashlib
import hmac
import ipaddress
import json
import os
import plistlib
import re
import secrets
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock

VERSION = "3.0.0"
PORT = 8765
MAX_REQUEST = 2_000_000
LABEL_RE = re.compile(r"^[A-Za-z0-9_.-]{4,200}$")
DATA_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "KIZZIMO_DaemonBridge"
STAGE_DIR = DATA_DIR / "staged"
TOKEN_FILE = DATA_DIR / "pairing-token.txt"
WRITE_LOCK = Lock()
PROTECTED = {
    "com.apple.thermalmonitord", "com.apple.locationd", "com.apple.healthd",
    "com.apple.passd", "com.apple.mobile.softwareupdated",
    "com.apple.OTATaskingAgent", "com.apple.softwareupdateservicesd",
    "com.apple.mobile.NRDUpdated", "com.apple.diagnosticd",
    "com.apple.ReportCrash", "com.apple.logd", "com.apple.syslogd",
    "com.apple.ScreenTimeAgent", "com.apple.homed", "com.apple.familycircled",
    "com.apple.racoon",
}
PROTECTED_PREFIX = ("com.apple.logd.", "com.apple.ReportCrash.", "com.apple.Dump")


def blocked(label):
    return label in PROTECTED or label.startswith(PROTECTED_PREFIX)


def get_token(rotate=False):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not rotate and TOKEN_FILE.is_file():
        token = TOKEN_FILE.read_text(encoding="utf-8").strip()
        if len(token) >= 32:
            return token
    token = secrets.token_urlsafe(32)
    TOKEN_FILE.write_text(token + "\n", encoding="utf-8")
    try:
        TOKEN_FILE.chmod(0o600)
    except OSError:
        pass
    return token


def private_ipv4(text):
    try:
        address = ipaddress.ip_address(text)
        return isinstance(address, ipaddress.IPv4Address) and address.is_private and not address.is_loopback
    except ValueError:
        return False


def build_stage(payload):
    if not isinstance(payload, dict):
        raise ValueError("Expected a JSON object")
    changes = payload.get("changes")
    encoded = payload.get("plist_base64")
    preset = payload.get("preset", "Custom")
    source = payload.get("source", "Blank")
    if not isinstance(changes, dict) or len(changes) > 250:
        raise ValueError("Invalid changes object")
    if not isinstance(encoded, str) or len(encoded) > 1_500_000:
        raise ValueError("Invalid plist data")
    if not isinstance(preset, str) or len(preset) > 50:
        raise ValueError("Invalid preset name")
    if not isinstance(source, str) or len(source) > 200:
        raise ValueError("Invalid source name")
    for label, action in changes.items():
        if not isinstance(label, str) or not LABEL_RE.fullmatch(label) or "." not in label:
            raise ValueError("Invalid daemon identifier")
        if action not in ("disable", "enable", "remove"):
            raise ValueError("Invalid daemon choice")
        if blocked(label) and action == "disable":
            raise ValueError("Protected daemon cannot be disabled: " + label)
    try:
        raw = base64.b64decode(encoded, validate=True)
        plist = plistlib.loads(raw)
    except (ValueError, binascii.Error, TypeError, OverflowError) as exc:
        raise ValueError("Invalid XML plist: " + str(exc)) from exc
    if not isinstance(plist, dict) or len(plist) > 1000:
        raise ValueError("Daemon plist must be a small dictionary")
    for label, value in plist.items():
        if not isinstance(label, str) or not LABEL_RE.fullmatch(label):
            raise ValueError("Unexpected key in plist")
        if not isinstance(value, bool):
            raise ValueError("Daemon plist values must be booleans")
        if blocked(label) and value is True:
            raise ValueError("Protected daemon disabled in source plist: " + label)
    for label, action in changes.items():
        expected = {"disable": True, "enable": False}.get(action)
        if action == "remove":
            if label in plist:
                raise ValueError("Remove operation does not match attached plist: " + label)
        elif plist.get(label) is not expected:
            raise ValueError("Attached plist does not match selected operation: " + label)
    # Re-serialise from parsed plist. Never trust a user-provided filesystem path.
    xml = plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=True)
    digest = hashlib.sha256(xml).hexdigest()
    record = {
        "version": VERSION,
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "preset": preset,
        "source": source,
        "changes": changes,
        "entry_count": len(plist),
        "sha256": digest,
        "state": "STAGED_ONLY",
        "ios_daemons_changed": False,
        "restore_executed": False,
        "note": "For review and separate, verified restore workflow. NEVER automatically applied.",
    }
    STAGE_DIR.mkdir(parents=True, exist_ok=True)
    stem = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
    xml_path = STAGE_DIR / (stem + ".plist")
    audit_path = STAGE_DIR / (stem + ".json")
    with WRITE_LOCK:
        xml_path.write_bytes(xml)
        audit_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (DATA_DIR / "latest.plist").write_bytes(xml)
        (DATA_DIR / "latest.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record, xml_path


class Handler(BaseHTTPRequestHandler):
    server_version = "KIZZIMO-DaemonBridge/3"

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args), flush=True)

    def respond(self, code, data):
        encoded = json.dumps(data, sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def authorised(self):
        supplied = self.headers.get("X-Bridge-Token", "")
        return hmac.compare_digest(supplied, self.server.pairing_token)

    def permitted_network(self):
        # Only local RFC1918 or loopback callers; this does not authenticate them.
        try:
            addr = ipaddress.ip_address(self.client_address[0])
            return addr.is_loopback or (isinstance(addr, ipaddress.IPv4Address) and addr.is_private)
        except ValueError:
            return False

    def do_GET(self):
        if not self.permitted_network():
            return self.respond(403, {"message": "Local network clients only"})
        if self.path == "/health":
            return self.respond(200, {
                "version": VERSION, "mode": "STAGING_ONLY",
                "apply_supported": False, "iOS_26_5_1_restore_verified": False,
            })
        if self.path == "/latest":
            if not self.authorised():
                return self.respond(401, {"message": "Pairing token required"})
            filename = DATA_DIR / "latest.json"
            if not filename.exists():
                return self.respond(404, {"message": "Nothing staged"})
            return self.respond(200, json.loads(filename.read_text(encoding="utf-8")))
        return self.respond(404, {"message": "Unknown endpoint"})

    def do_POST(self):
        if not self.permitted_network():
            return self.respond(403, {"message": "Local network clients only"})
        if not self.authorised():
            return self.respond(401, {"message": "Invalid pairing token"})
        if self.path == "/apply":
            return self.respond(409, {
                "message": "Privileged restore is NOT implemented or validated on iOS 26.5.1. No changes applied.",
                "ios_daemons_changed": False,
            })
        if self.path != "/stage":
            return self.respond(404, {"message": "Unknown endpoint"})
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= MAX_REQUEST:
                return self.respond(413, {"message": "Invalid or oversized request"})
            data = self.rfile.read(size)
            payload = json.loads(data)
            record, xml_path = build_stage(payload)
            return self.respond(200, {
                "message": "Saved %d changes in %s; SHA256 %s" % (
                    len(record["changes"]), xml_path.name, record["sha256"][:12]),
                "state": "STAGED_ONLY", "ios_daemons_changed": False,
            })
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            return self.respond(400, {"message": str(exc)})
        except OSError as exc:
            return self.respond(500, {"message": "Cannot save files: " + str(exc)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0", help="Local listener address")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--rotate-token", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        test = {"preset": "Balanced", "source": "Test",
                "changes": {"com.apple.tipsd": "disable"},
                "plist_base64": base64.b64encode(plistlib.dumps({"com.apple.tipsd": True})).decode()}
        record, file = build_stage(test)
        assert record["state"] == "STAGED_ONLY" and file.exists()
        try:
            build_stage({"preset": "bad", "source": "test",
                         "changes": {"com.apple.thermalmonitord": "disable"},
                         "plist_base64": test["plist_base64"]})
        except ValueError:
            pass
        else:
            raise AssertionError("Protected daemon request was accepted!")
        print("PASS: staging files generated; protected daemon request rejected")
        return
    token = get_token(rotate=args.rotate_token)
    with ThreadingHTTPServer((args.host, args.port), Handler) as server:
        server.pairing_token = token
        print("=" * 66)
        print(" KIZZIMO DAEMON COMPANION v%s (STAGING ONLY)" % VERSION)
        print("=" * 66)
        print("Pairing token: " + token)
        print("Port: %d. Windows folder: %s" % (args.port, DATA_DIR))
        print("Use the LAN IPv4 address shown by ipconfig on this PC.")
        print("Connect both devices to the same trusted private network.")
        print("Firewall: if prompted, allow only Private networks.")
        print("THE BRIDGE CANNOT APPLY PROTECTED iOS DAEMON CHANGES.")
        print("Stop: Ctrl+C")
        print("=" * 66)
        try:
            server.serve_forever(poll_interval=0.5)
        except KeyboardInterrupt:
            print("\nStopping companion.")
            server.server_close()


if __name__ == "__main__":
    main()
