#!/usr/bin/env python3
"""Deye Cloud spike: calls the read-only OpenAPI endpoints once and saves *redacted* responses
as test fixtures, so the app's field mapping is built from real data instead of guesses.

Secrets (AppSecret, password) are read with getpass and never written to disk or printed.
The access token stays in memory only. Serial numbers, station ids, e-mails, names, addresses,
coordinates and tokens are replaced with placeholders before anything is saved.

Usage:
    python3 -I scripts/deye_spike.py [--region eu|us|india] [--device-sn SN] [--date YYYY-MM-DD]

Only standard library. Endpoints follow the official sample code
(github.com/DeyeCloudDevelopers/deye-openapi-client-sample-code); `/device/measurePoints`
request body is not documented there, so that call is best-effort and its error is saved too.
"""
import argparse
import datetime as dt
import getpass
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE_URLS = {
    "eu": "https://eu1-developer.deyecloud.com/v1.0",
    "us": "https://us1-developer.deyecloud.com/v1.0",
    "india": "https://india-developer.deyecloud.com/v1.0",
}
OUT_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "Packages", "EnergyCore", "Tests", "EnergyCoreTests", "Fixtures", "DeyeCloud",
)

# --- Redaction ---------------------------------------------------------------------------

SENSITIVE_KEY = re.compile(
    r"(sn$|serial|stationid|deviceid|loggerid|collector|email|mobile|phone|token|secret|password"
    r"|address|^lat|^lon|^lng|lat$|lng$|lon$|latitude|longitude|location|owner|username|stationname|devicename"
    r"|userid|companyid|appid|parentid|^uid$|^id$)",
    re.IGNORECASE,
)
# Keys that look sensitive by pattern but carry data we need (measure point names etc.).
KEEP_KEYS = {"key", "unit", "value", "measurepoint", "measurepoints"}


class Redactor:
    def __init__(self):
        self.mapping = {}

    def placeholder(self, value, key):
        text = str(value)
        if text not in self.mapping:
            self.mapping[text] = f"<{key}-{len(self.mapping) + 1}>"
        return self.mapping[text]

    def redact(self, obj, key=""):
        if isinstance(obj, dict):
            return {k: self.redact(v, k) for k, v in obj.items()}
        if isinstance(obj, list):
            return [self.redact(v, key) for v in obj]
        if key and key.lower() not in KEEP_KEYS and SENSITIVE_KEY.search(key) and obj not in (None, "", 0):
            return self.placeholder(obj, key)
        if isinstance(obj, str):
            # Sensitive values seen elsewhere (e.g. a serial inside a message string).
            for raw, ph in self.mapping.items():
                if len(raw) >= 4 and raw in obj:
                    obj = obj.replace(raw, ph)
        return obj

    def scrub_text(self, text):
        for raw, ph in self.mapping.items():
            if len(raw) >= 4:
                text = text.replace(raw, ph)
        return text


# --- HTTP --------------------------------------------------------------------------------

def post(url, body, token=None, timeout=20):
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), json.loads(resp.read().decode() or "null")
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {"_raw": raw[:2000]}
        return e.code, dict(e.headers), payload
    except (urllib.error.URLError, TimeoutError) as e:
        return 0, {}, {"_error": str(e)}


def find_values(obj, key_pred):
    """All (key, value) pairs in nested JSON whose key satisfies key_pred."""
    found = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if key_pred(k) and not isinstance(v, (dict, list)):
                found.append((k, v))
            found.extend(find_values(v, key_pred))
    elif isinstance(obj, list):
        for v in obj:
            found.extend(find_values(v, key_pred))
    return found


def find_dicts_with(obj, key):
    out = []
    if isinstance(obj, dict):
        if key in obj:
            out.append(obj)
        for v in obj.values():
            out.extend(find_dicts_with(v, key))
    elif isinstance(obj, list):
        for v in obj:
            out.extend(find_dicts_with(v, key))
    return out


# --- Main --------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region", choices=BASE_URLS, default="eu")
    ap.add_argument("--device-sn", help="Inverter SN (otherwise picked from /device/list)")
    ap.add_argument("--date", help="Day for /device/history, YYYY-MM-DD (default: today)")
    args = ap.parse_args()
    base = BASE_URLS[args.region]

    app_id = os.environ.get("DEYE_APP_ID") or input("AppId: ").strip()
    app_secret = os.environ.get("DEYE_APP_SECRET") or getpass.getpass("AppSecret (hidden): ").strip()
    email = os.environ.get("DEYE_EMAIL") or input("Deye Cloud e-mail: ").strip()
    password_hash = hashlib.sha256(getpass.getpass("Deye Cloud password (hidden): ").encode()).hexdigest()

    red = Redactor()
    for secret, label in ((app_id, "appId"), (app_secret, "appSecret"), (email, "email")):
        red.placeholder(secret, label)
    os.makedirs(OUT_DIR, exist_ok=True)
    summary = {"region": args.region, "calls": []}

    def save(name, path, body, status, headers, payload):
        rate_headers = {k: v for k, v in headers.items() if re.search(r"rate|limit|retry", k, re.I)}
        record = {
            "endpoint": path,
            "request": red.redact(body),
            "httpStatus": status,
            "rateLimitHeaders": rate_headers,
            "response": red.redact(payload),
        }
        file = os.path.join(OUT_DIR, f"{name}.json")
        with open(file, "w", encoding="utf-8") as f:
            f.write(red.scrub_text(json.dumps(record, ensure_ascii=False, indent=2)))
        summary["calls"].append({"name": name, "endpoint": path, "httpStatus": status})
        print(f"  {path:<28} HTTP {status}  -> Fixtures/DeyeCloud/{name}.json")

    print(f"\nRegion {args.region}: {base}")

    # 1. Token
    status, headers, payload = post(f"{base}/account/token?appId={app_id}",
                                    {"appSecret": app_secret, "email": email, "password": password_hash})
    tokens = [v for k, v in find_values(payload, lambda k: "token" in k.lower() and "refresh" not in k.lower())
              if isinstance(v, str) and len(v) > 20]
    for k, v in find_values(payload, lambda k: "token" in k.lower()):
        red.placeholder(v, k)
    save("01_account_token", "/account/token", {"appSecret": "<hidden>", "email": email, "password": "<sha256>"},
         status, headers, payload)
    if not tokens:
        print("\nNo access token in the response. Check AppId/AppSecret, e-mail, password and region.")
        print("The redacted response is in Fixtures/DeyeCloud/01_account_token.json")
        return 1
    token = tokens[0]
    summary["tokenFields"] = sorted({k for k, _ in find_values(payload, lambda k: True)})

    # 2. Stations and devices
    body = {"page": 1, "size": 20}
    status, headers, stations = post(f"{base}/station/list", body, token)
    station_ids = [d.get("id") or d.get("stationId") for d in
                   find_dicts_with(stations, "id") + find_dicts_with(stations, "stationId")]
    station_ids = [s for s in dict.fromkeys(station_ids) if s]
    for s in station_ids:
        red.placeholder(s, "stationId")
    # A bare "name" key is kept generally (measure points may use it), but station names are personal.
    for d in find_dicts_with(stations, "id") + find_dicts_with(stations, "stationId"):
        if isinstance(d.get("name"), str) and d["name"]:
            red.placeholder(d["name"], "stationName")
    save("02_station_list", "/station/list", body, status, headers, stations)

    status, headers, devices = post(f"{base}/device/list", body, token)
    device_dicts = find_dicts_with(devices, "deviceSn")
    for d in device_dicts:
        red.placeholder(d["deviceSn"], "deviceSn")
    save("03_device_list", "/device/list", body, status, headers, devices)

    if station_ids:
        body = {"stationId": station_ids[0]}
        save("04_station_latest", "/station/latest", body, *post(f"{base}/station/latest", body, token))

    # /device/list is business-only ("auth invalid token" on personal accounts), so also ask
    # the station-level endpoint from the official sample: /station/listWithDevice.
    body = {"page": 1, "size": 20, "deviceType": "INVERTER"}
    status, headers, with_devices = post(f"{base}/station/listWithDevice", body, token)
    station_devices = find_dicts_with(with_devices, "deviceSn")
    for d in station_devices:
        red.placeholder(d["deviceSn"], "deviceSn")
    save("03b_station_list_with_device", "/station/listWithDevice", body, status, headers, with_devices)
    device_dicts += station_devices

    # Pick the inverter: explicit arg → a device whose type mentions INVERTER → the first one.
    sn = args.device_sn
    if sn:
        red.placeholder(sn, "deviceSn")
    else:
        inverters = [d for d in device_dicts if "INVERTER" in str(d.get("deviceType", "INVERTER")).upper()]
        # Prefer an online inverter (connectStatus 1) with the freshest data.
        inverters.sort(key=lambda d: (d.get("connectStatus") == 1, d.get("collectionTime") or 0), reverse=True)
        chosen = (inverters or device_dicts or [None])[0]
        sn = chosen and chosen["deviceSn"]
        if len({d["deviceSn"] for d in inverters}) > 1:
            print("  Several inverters found:")
            for d in inverters:
                mark = "->" if d is chosen else "  "
                print(f"   {mark} {red.placeholder(d['deviceSn'], 'deviceSn')} connectStatus={d.get('connectStatus')}"
                      f" collectionTime={d.get('collectionTime')}")
            print("  Pass --device-sn to choose another.")
    if not sn:
        print("\nNo device found in /device/list. Re-run with --device-sn <inverter SN>.")
        return 1

    # 3. Realtime
    body = {"deviceList": [sn]}
    status, headers, latest = post(f"{base}/device/latest", body, token)
    save("05_device_latest", "/device/latest", body, status, headers, latest)
    summary["latestDataKeys"] = sorted({str(v) for k, v in find_values(latest, lambda k: k == "key")})

    # 4. Measure points (request body not documented: try the obvious shape)
    body = {"deviceSn": sn}
    status, headers, points = post(f"{base}/device/measurePoints", body, token)
    save("06_device_measure_points", "/device/measurePoints", body, status, headers, points)
    point_names = [v for v in (points.get("measurePoints") if isinstance(points, dict) else None) or []
                   if isinstance(v, str)]

    # 5. Day frames for yesterday and today. The first run showed that 50 points is "list too long"
    # (code 2101007), so start with the points the app needs and halve the list until it is accepted.
    # Second run: 10 points rejected, 5 accepted; GridStatus is never returned in frames.
    wanted = ["SOC", "BatteryPower", "TotalConsumptionPower", "GridRelayStatus", "GridVoltageL1L2"]
    if point_names:
        wanted = [p for p in wanted if p in point_names]
    today = dt.date.fromisoformat(args.date) if args.date else dt.date.today()
    accepted = None
    for offset, label in ((1, "yesterday"), (0, "today")):
        day = (today - dt.timedelta(days=offset)).isoformat()
        points_now = accepted or wanted
        while True:
            body = {"deviceSn": sn, "granularity": 1, "startAt": day, "endAt": day, "measurePoints": points_now}
            status, headers, history = post(f"{base}/device/history", body, token)
            too_long = isinstance(history, dict) and str(history.get("code")) == "2101007"
            if too_long and len(points_now) > 1:
                print(f"  /device/history rejected {len(points_now)} points, retrying with {len(points_now) // 2}")
                points_now = points_now[: len(points_now) // 2]
                continue
            break
        if not too_long:
            accepted = points_now
        save(f"07_device_history_{label}", "/device/history", body, status, headers, history)

        stamps = sorted({int(float(v)) for k, v in find_values(history, lambda k: "time" in k.lower())
                         if isinstance(v, (int, float)) or (isinstance(v, str) and re.fullmatch(r"\d+(\.\d+)?", v))})
        if len(stamps) > 2:
            steps = sorted(b - a for a, b in zip(stamps, stamps[1:]) if b > a)
            summary[f"history_{label}"] = {
                "frames": len(stamps),
                "medianStepSeconds": steps[len(steps) // 2] if steps else None,
                "maxStepSeconds": steps[-1] if steps else None,
            }
        relay_values = sorted({str(v) for k, v in find_values(history, lambda k: k in ("value",))
                               if isinstance(v, str) and not re.fullmatch(r"-?\d+(\.\d+)?", v)})
        if relay_values:
            summary[f"history_{label}_textValues"] = relay_values
    summary["historyAcceptedPoints"] = accepted

    # 6. Realtime again at the end: catches GridRelayStatus if the grid came back meanwhile.
    body = {"deviceList": [sn]}
    save("08_device_latest_again", "/device/latest", body, *post(f"{base}/device/latest", body, token))

    with open(os.path.join(OUT_DIR, "00_summary.json"), "w", encoding="utf-8") as f:
        f.write(red.scrub_text(json.dumps(summary, ensure_ascii=False, indent=2)))
    print("\nDone. Summary: Fixtures/DeyeCloud/00_summary.json")
    print("Files contain no secrets or serial numbers, but please glance through them before sharing anywhere.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
