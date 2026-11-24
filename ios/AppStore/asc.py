"""Small App Store Connect API helper for CI.

  python3 asc.py team <bundle-id> <AuthKey.p8>

Prints the Team ID (the bundle ID's seed ID), registering the bundle ID first if it is missing.
APPLE_TEAM_ID in the environment wins. Reads ASC_KEY_ID and ASC_ISSUER_ID from the environment.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token(key_path):
    with open(key_path) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(tok, method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"},
                                 data=json.dumps(body).encode() if body else None)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        print(f"::error::App Store Connect API {method} {path}: HTTP {e.code} {detail}", file=sys.stderr)
        raise SystemExit(1)


def team(bundle_id, key_path):
    if os.environ.get("APPLE_TEAM_ID"):
        return os.environ["APPLE_TEAM_ID"].strip()
    tok = token(key_path)
    q = urllib.parse.urlencode({"filter[identifier]": bundle_id, "limit": 50})
    found = [b for b in call(tok, "GET", "/bundleIds?" + q)["data"] if b["attributes"]["identifier"] == bundle_id]
    if not found:
        print(f"registering bundle ID {bundle_id}", file=sys.stderr)
        made = call(tok, "POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": bundle_id, "name": "TV", "platform": "IOS"}}})
        found = [made["data"]]
    return found[0]["attributes"].get("seedId", "")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "team":
        print(team(sys.argv[2], sys.argv[3]))
    else:
        print(__doc__)
        raise SystemExit(2)
