"""Small App Store Connect API helper for CI.

  python3 asc.py team    <bundle-id> <AuthKey.p8>   prints the Team ID (registers the bundle ID if missing)
  python3 asc.py prepare <bundle-id> <AuthKey.p8>   readies version for review: newest processed build,
                                                    review notes + contact, content rights, free price,
                                                    all territories
  python3 asc.py submit  <bundle-id> <AuthKey.p8>   submits the prepared version for App Review

Reads ASC_KEY_ID and ASC_ISSUER_ID (and APPLE_TEAM_ID, REVIEW_FIRST_NAME, REVIEW_LAST_NAME,
REVIEW_PHONE, REVIEW_EMAIL, VERSION) from the environment. App Privacy answers cannot be set
through the API: they are given once in App Store Connect.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"
HERE = os.path.dirname(os.path.abspath(__file__))


class Client:
    def __init__(self, key_path):
        with open(key_path) as f:
            self.key = f.read()
        self.tok = None
        self.made = 0

    def token(self):
        now = int(time.time())
        if not self.tok or now - self.made > 600:
            self.tok = jwt.encode(
                {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                self.key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
            self.made = now
        return self.tok

    def call(self, method, path, body=None, ok_missing=False, fatal=True):
        url = path if path.startswith("http") else API + path
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                     headers={"Authorization": "Bearer " + self.token(),
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if ok_missing and e.code == 404:
                return None
            detail = e.read().decode(errors="replace")[:800]
            msg = f"App Store Connect API {method} {path.split('?')[0]}: HTTP {e.code} {detail}"
            if fatal:
                print("::error::" + msg, file=sys.stderr)
                raise SystemExit(1)
            print("::warning::" + msg, file=sys.stderr)
            return None

    def all(self, path):
        out, url = [], path
        while url:
            page = self.call("GET", url)
            out += page.get("data", [])
            url = page.get("links", {}).get("next")
        return out


def q(params):
    return "?" + urllib.parse.urlencode(params)


def app_id(c, bundle_id):
    apps = c.call("GET", "/v1/apps" + q({"filter[bundleId]": bundle_id}))["data"]
    apps = [a for a in apps if a["attributes"]["bundleId"] == bundle_id]
    if not apps:
        print(f"::error::no app with bundle ID {bundle_id} in App Store Connect", file=sys.stderr)
        raise SystemExit(1)
    return apps[0]["id"]


def editable_version(c, aid):
    versions = c.call("GET", f"/v1/apps/{aid}/appStoreVersions" + q({"filter[platform]": "IOS", "limit": 20}))["data"]
    editable = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
    for v in versions:
        state = v["attributes"].get("appVersionState") or v["attributes"].get("appStoreState")
        if state in editable:
            return v
    print("::error::no App Store version waiting for submission (already in review?)", file=sys.stderr)
    raise SystemExit(1)


# MARK: commands

def team(bundle_id, key_path):
    if os.environ.get("APPLE_TEAM_ID"):
        return os.environ["APPLE_TEAM_ID"].strip()
    c = Client(key_path)
    found = [b for b in c.call("GET", "/v1/bundleIds" + q({"filter[identifier]": bundle_id, "limit": 50}))["data"]
             if b["attributes"]["identifier"] == bundle_id]
    if not found:
        print(f"registering bundle ID {bundle_id}", file=sys.stderr)
        made = c.call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": bundle_id, "name": "TV", "platform": "IOS"}}})
        found = [made["data"]]
    return found[0]["attributes"].get("seedId", "")


def prepare(bundle_id, key_path):
    c = Client(key_path)
    aid = app_id(c, bundle_id)
    v = editable_version(c, aid)
    vid, vstr = v["id"], v["attributes"]["versionString"]
    print(f"version {vstr}: {v['attributes'].get('appVersionState') or v['attributes'].get('appStoreState')}")

    # 1. newest processed build of this version
    build = None
    for _ in range(40):          # up to 20 minutes for Apple to finish processing
        builds = c.call("GET", "/v1/builds" + q({"filter[app]": aid, "filter[preReleaseVersion.version]": vstr,
                                                  "sort": "-uploadedDate", "limit": 10}))["data"]
        valid = [b for b in builds if b["attributes"].get("processingState") == "VALID" and not b["attributes"].get("expired")]
        if valid:
            build = valid[0]
            break
        state = builds[0]["attributes"].get("processingState") if builds else "no builds yet"
        print(f"waiting for the build to finish processing ({state})…")
        time.sleep(30)
    if not build:
        print("::error::no processed build for this version yet: run again later", file=sys.stderr)
        raise SystemExit(1)
    if build["attributes"].get("usesNonExemptEncryption") is None:
        c.call("PATCH", f"/v1/builds/{build['id']}", {"data": {"type": "builds", "id": build["id"],
               "attributes": {"usesNonExemptEncryption": False}}}, fatal=False)
    c.call("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build",
           {"data": {"type": "builds", "id": build["id"]}})
    print(f"build {build['attributes']['version']} selected")

    # 2. App Review information
    with open(os.path.join(HERE, "listing/metadata/review_information/notes.txt")) as f:
        notes = f.read().strip()
    attrs = {"notes": notes, "demoAccountRequired": False}
    for env, key in (("REVIEW_FIRST_NAME", "contactFirstName"), ("REVIEW_LAST_NAME", "contactLastName"),
                     ("REVIEW_PHONE", "contactPhone"), ("REVIEW_EMAIL", "contactEmail")):
        if os.environ.get(env, "").strip():
            attrs[key] = os.environ[env].strip()
    missing = [k for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail") if k not in attrs]
    detail = c.call("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail", ok_missing=True)
    if detail and detail.get("data"):
        did = detail["data"]["id"]
        have = detail["data"]["attributes"]
        missing = [k for k in missing if not have.get(k)]
        c.call("PATCH", f"/v1/appStoreReviewDetails/{did}",
               {"data": {"type": "appStoreReviewDetails", "id": did, "attributes": attrs}})
    else:
        c.call("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
               "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    print("review notes saved" + (f"; contact still missing: {', '.join(missing)}" if missing else " with contact"))

    # 3. content rights: the app plays third-party streams the user adds
    c.call("PATCH", f"/v1/apps/{aid}", {"data": {"type": "apps", "id": aid,
           "attributes": {"contentRightsDeclaration": "USES_THIRD_PARTY_CONTENT"}}}, fatal=False)
    print("content rights declared")

    # 4. free
    schedule = c.call("GET", f"/v1/apps/{aid}/appPriceSchedule", ok_missing=True, fatal=False)
    if not (schedule and schedule.get("data")):
        points = c.call("GET", f"/v1/apps/{aid}/appPricePoints" + q({"filter[territory]": "USA", "limit": 200}))["data"]
        free = [p for p in points if float(p["attributes"].get("customerPrice") or 0) == 0]
        if free:
            c.call("POST", "/v1/appPriceSchedules", {
                "data": {"type": "appPriceSchedules", "relationships": {
                    "app": {"data": {"type": "apps", "id": aid}},
                    "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                    "manualPrices": {"data": [{"type": "appPrices", "id": "${price0}"}]}}},
                "included": [{"type": "appPrices", "id": "${price0}", "attributes": {"startDate": None},
                              "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free[0]["id"]}}}}]},
                fatal=False)
            print("price: free")
    else:
        print("price already set")

    # 5. every territory, and new ones automatically
    avail = c.call("GET", f"/v1/apps/{aid}/appAvailabilityV2", ok_missing=True, fatal=False)
    if not (avail and avail.get("data")):
        territories = [t["id"] for t in c.all("/v1/territories?limit=200")]
        c.call("POST", "/v2/appAvailabilities", {
            "data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
                     "relationships": {
                         "app": {"data": {"type": "apps", "id": aid}},
                         "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": f"${{{t}}}"} for t in territories]}}},
            "included": [{"type": "territoryAvailabilities", "id": f"${{{t}}}", "attributes": {"available": True},
                          "relationships": {"territory": {"data": {"type": "territories", "id": t}}}} for t in territories]},
            fatal=False)
        print(f"available in {len(territories)} countries and regions")
    else:
        print("availability already set")

    print("\nOnly App Privacy is left for App Store Connect (it cannot be set through the API)."
          + ("" if not missing else " Also the App Review contact."))


def submit(bundle_id, key_path):
    c = Client(key_path)
    aid = app_id(c, bundle_id)
    v = editable_version(c, aid)
    vid = v["id"]
    subs = c.call("GET", "/v1/reviewSubmissions" + q({"filter[app]": aid, "filter[platform]": "IOS",
                                                       "filter[state]": "READY_FOR_REVIEW,UNRESOLVED_ISSUES"}))["data"]
    if subs:
        sid = subs[0]["id"]
    else:
        sid = c.call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
                     "attributes": {"platform": "IOS"},
                     "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}})["data"]["id"]
    items = c.call("GET", f"/v1/reviewSubmissions/{sid}/items")["data"]
    if not items:
        c.call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sid}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    c.call("PATCH", f"/v1/reviewSubmissions/{sid}", {"data": {"type": "reviewSubmissions", "id": sid,
           "attributes": {"submitted": True}}})
    print(f"version {v['attributes']['versionString']} submitted for App Review")


if __name__ == "__main__":
    cmds = {"team": lambda b, k: print(team(b, k)), "prepare": prepare, "submit": submit}
    if len(sys.argv) == 4 and sys.argv[1] in cmds:
        cmds[sys.argv[1]](sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        raise SystemExit(2)
