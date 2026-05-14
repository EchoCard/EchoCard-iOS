#!/usr/bin/env python3
"""
APNs push sender (token-based auth with .p8 key).

Requirements:
  pip install pyjwt httpx cryptography

Examples (paths relative to ios repo root):
  python3 scripts/apns_push.py incoming-call \\
    --device-token <DEVICE_TOKEN> \\
    --team-id <TEAM_ID> \\
    --key-id 3B777RS7JC \\
    --p8-file Secrets/APNs/AuthKey_3B777RS7JC.p8 \\
    --bundle-id greater.longshu.CallMateTool
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Dict

try:
    import httpx
except Exception:
    httpx = None

try:
    import jwt
except Exception:
    jwt = None

_SCRIPT_DIR = Path(__file__).resolve().parent
_REPO_ROOT = _SCRIPT_DIR.parent
DEFAULT_BUNDLE_ID = "greater.longshu.CallMateTool"
DEFAULT_KEY_ID = "3B777RS7JC"
DEFAULT_P8_FILE = str(_REPO_ROOT / "Secrets/APNs/AuthKey_3B777RS7JC.p8")


def build_apns_jwt(team_id: str, key_id: str, p8_file: str) -> str:
    if jwt is None:
        raise RuntimeError("Missing dependency: pyjwt. Install with: pip install pyjwt cryptography")
    private_key = Path(p8_file).read_text(encoding="utf-8")
    now = int(time.time())
    token = jwt.encode(
        {"iss": team_id, "iat": now},
        private_key,
        algorithm="ES256",
        headers={"alg": "ES256", "kid": key_id},
    )
    if isinstance(token, bytes):
        return token.decode("utf-8")
    return token


def send_apns(
    *,
    jwt_token: str,
    bundle_id: str,
    device_token: str,
    payload: Dict[str, Any],
    push_type: str,
    priority: str,
    sandbox: bool,
) -> None:
    host = "api.sandbox.push.apple.com" if sandbox else "api.push.apple.com"
    url = f"https://{host}/3/device/{device_token}"
    headers = {
        "authorization": f"bearer {jwt_token}",
        "apns-topic": bundle_id,
        "apns-push-type": push_type,
        "apns-priority": priority,
        "apns-id": str(uuid.uuid4()),
        "content-type": "application/json",
    }

    # Preferred: httpx + http2
    if httpx is not None:
        try:
            with httpx.Client(http2=True, timeout=15.0) as client:
                resp = client.post(url, headers=headers, json=payload)
            print(f"[APNS] status={resp.status_code}")
            if resp.status_code != 200:
                try:
                    print("[APNS] error:", json.dumps(resp.json(), ensure_ascii=False))
                except Exception:
                    print("[APNS] error(raw):", resp.text)
                raise SystemExit(1)
            print("[APNS] success")
            return
        except ImportError:
            # httpx installed without HTTP/2 extras (h2 missing).
            print("[APNS] httpx http2 dependency missing, fallback to curl --http2")

    # Fallback: curl --http2 (works on macOS default curl)
    payload_json = json.dumps(payload, ensure_ascii=False)
    cmd = [
        "curl",
        "--silent",
        "--show-error",
        "--http2",
        "-X",
        "POST",
        url,
        "-H",
        f"authorization: bearer {jwt_token}",
        "-H",
        f"apns-topic: {bundle_id}",
        "-H",
        f"apns-push-type: {push_type}",
        "-H",
        f"apns-priority: {priority}",
        "-H",
        f"apns-id: {headers['apns-id']}",
        "-H",
        "content-type: application/json",
        "-d",
        payload_json,
        "-D",
        "-",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    output = (result.stdout or "") + (result.stderr or "")
    status_code = None
    for line in output.splitlines():
        lower = line.lower()
        if lower.startswith("apns-id:"):
            continue
        if line.startswith("HTTP/"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                status_code = int(parts[1])
    if status_code is None:
        print("[APNS] curl output:")
        print(output.strip())
        raise SystemExit(1)
    print(f"[APNS] status={status_code}")
    body = output.split("\r\n\r\n")[-1].strip() if "\r\n\r\n" in output else output.strip().splitlines()[-1]
    if status_code != 200:
        if body:
            print("[APNS] error(raw):", body)
        raise SystemExit(1)
    print("[APNS] success")


def build_incoming_call_payload(args: argparse.Namespace) -> Dict[str, Any]:
    return {
        "aps": {"content-available": 1},
        "event": "incoming_call",
        "call_id": args.call_id,
        "caller_name": args.caller_name,
        "caller_number": args.caller_number,
        "status_text": args.status_text,
        "tts_text": args.tts_text,
        "can_handoff": args.can_handoff,
        "can_hangup": args.can_hangup,
    }


def build_ble_forward_payload(args: argparse.Namespace) -> Dict[str, Any]:
    params: Dict[str, Any] = {}
    if args.ble_params:
        parsed = json.loads(args.ble_params)
        if not isinstance(parsed, dict):
            raise ValueError("--ble-params must be a JSON object")
        params = parsed
    return {
        "aps": {"content-available": 1},
        "event": "ble_forward",
        "ble_cmd": args.ble_cmd,
        "ble_params": params,
        "ble_expect_ack": args.ble_expect_ack,
        "ble_auto_connect": args.ble_auto_connect,
    }


def build_raw_payload(args: argparse.Namespace) -> Dict[str, Any]:
    raw = Path(args.payload_file).read_text(encoding="utf-8")
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError("payload file root must be a JSON object")
    return payload


def build_dial_phone_payload(args: argparse.Namespace) -> Dict[str, Any]:
    return {
        "aps": {"content-available": 1},
        "event": "dial_phone",
        "phone_number": args.phone_number,
        "ble_auto_connect": args.ble_auto_connect,
        "ble_expect_ack": args.ble_expect_ack,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Send APNs push with .p8 key")
    parser.add_argument("--device-token", required=True, help="Target iOS device token")
    parser.add_argument("--team-id", required=True, help="Apple Developer Team ID")
    parser.add_argument("--key-id", default=DEFAULT_KEY_ID, help="APNs Key ID")
    parser.add_argument("--p8-file", default=DEFAULT_P8_FILE, help=".p8 private key path")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID, help="App bundle id / apns-topic")
    parser.add_argument("--sandbox", action="store_true", help="Use APNs sandbox host")

    sub = parser.add_subparsers(dest="mode", required=True)

    incoming = sub.add_parser("incoming-call", help="Send incoming_call payload")
    incoming.add_argument("--call-id", default=f"call_{int(time.time())}")
    incoming.add_argument("--caller-name", default="测试来电")
    incoming.add_argument("--caller-number", default="13800138000")
    incoming.add_argument("--status-text", default="来电中")
    incoming.add_argument("--tts-text", default="")
    incoming.add_argument("--can-handoff", action=argparse.BooleanOptionalAction, default=True)
    incoming.add_argument("--can-hangup", action=argparse.BooleanOptionalAction, default=True)

    ble = sub.add_parser("ble-forward", help="Send ble_forward payload")
    ble.add_argument("--ble-cmd", required=True, help="BLE command, e.g. sync_time / dial")
    ble.add_argument("--ble-params", default="{}", help="JSON object string for BLE params")
    ble.add_argument("--ble-expect-ack", action=argparse.BooleanOptionalAction, default=True)
    ble.add_argument("--ble-auto-connect", action=argparse.BooleanOptionalAction, default=True)

    raw = sub.add_parser("raw", help="Send raw JSON payload from file")
    raw.add_argument("--payload-file", required=True, help="Path to JSON payload file")

    dial = sub.add_parser("dial-phone", help="Send phone dial payload with number")
    dial.add_argument("--phone-number", required=True, help="Phone number to dial")
    dial.add_argument("--ble-expect-ack", action=argparse.BooleanOptionalAction, default=True)
    dial.add_argument("--ble-auto-connect", action=argparse.BooleanOptionalAction, default=True)

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        jwt_token = build_apns_jwt(args.team_id, args.key_id, args.p8_file)
    except RuntimeError as e:
        print(f"[ERROR] {e}")
        raise SystemExit(2)

    if args.mode == "incoming-call":
        payload = build_incoming_call_payload(args)
        push_type = "background"
        priority = "5"
    elif args.mode == "ble-forward":
        payload = build_ble_forward_payload(args)
        push_type = "background"
        priority = "5"
    elif args.mode == "raw":
        payload = build_raw_payload(args)
        push_type = "background"
        priority = "5"
    elif args.mode == "dial-phone":
        payload = build_dial_phone_payload(args)
        push_type = "background"
        priority = "5"
    else:
        raise ValueError(f"Unsupported mode: {args.mode}")

    try:
        send_apns(
            jwt_token=jwt_token,
            bundle_id=args.bundle_id,
            device_token=args.device_token,
            payload=payload,
            push_type=push_type,
            priority=priority,
            sandbox=args.sandbox,
        )
    except RuntimeError as e:
        print(f"[ERROR] {e}")
        raise SystemExit(2)


if __name__ == "__main__":
    main()
