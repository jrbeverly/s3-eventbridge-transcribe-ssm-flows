#!/usr/bin/env python3
"""Credential-safe Confluence Cloud page API probe."""

import argparse
import base64
import html
import json
import os
import time
import uuid
from urllib import error, parse, request


def storage_body(vtt, marker):
    return ("<p>Confluence API probe <code>" + html.escape(marker) + "</code></p>"
            + "<pre>" + html.escape(vtt, quote=False) + "</pre>")


class Confluence:
    def __init__(self, base_url, email, token, sleep=time.sleep):
        self.base_url = base_url.rstrip("/")
        parsed = parse.urlparse(self.base_url)
        if (parsed.scheme != "https" or not parsed.hostname
                or not parsed.hostname.endswith(".atlassian.net")
                or parsed.path or parsed.params or parsed.query or parsed.fragment):
            raise ValueError("CONFLUENCE_BASE_URL must be an https://*.atlassian.net origin")
        encoded = base64.b64encode(f"{email}:{token}".encode()).decode()
        self.authorization = "Basic " + encoded
        self.sleep = sleep
        self.observations = []

    def call(self, method, path, payload=None, expected=(200,)):
        body = None if payload is None else json.dumps(payload).encode()
        for attempt in range(2):
            req = request.Request(self.base_url + path, data=body, method=method)
            req.add_header("Accept", "application/json")
            req.add_header("Authorization", self.authorization)
            if body is not None:
                req.add_header("Content-Type", "application/json")
            try:
                response = request.urlopen(req, timeout=30)
                status, headers, raw = response.status, response.headers, response.read()
            except error.HTTPError as exc:
                status, headers, raw = exc.code, exc.headers, exc.read()
            observation = {"method": method, "path": path.split("?", 1)[0],
                           "status": status}
            for source, target in (("Retry-After", "retry_after"),
                                   ("X-RateLimit-Limit", "rate_limit"),
                                   ("X-RateLimit-Remaining", "rate_remaining"),
                                   ("X-RateLimit-Reset", "rate_reset")):
                if headers.get(source) is not None:
                    observation[target] = headers[source]
            self.observations.append(observation)
            if status == 429 and attempt == 0:
                retry_after = headers.get("Retry-After", "1")
                delay = int(retry_after) if retry_after.isdigit() else 1
                self.sleep(min(max(delay, 1), 60))
                continue
            if status not in expected:
                raise RuntimeError(
                    f"Confluence {method} {observation['path']} returned HTTP {status}")
            return json.loads(raw) if raw else None
        raise AssertionError("unreachable")


def run(client, space_id, vtt):
    marker = "probe-" + uuid.uuid4().hex
    title = "API probe " + marker
    minimal = storage_body("WEBVTT\n", marker)
    created = client.call("POST", "/wiki/api/v2/pages", {
        "spaceId": space_id, "status": "current", "title": title,
        "body": {"representation": "storage", "value": minimal}})
    page_id = created["id"]
    fetched = client.call("GET", f"/wiki/api/v2/pages/{page_id}?body-format=storage")
    if fetched["title"] != title:
        raise RuntimeError("retrieved page identity did not match the created page")
    complete = storage_body(vtt, marker)
    updated = client.call("PUT", f"/wiki/api/v2/pages/{page_id}", {
        "id": page_id, "status": "current", "title": title,
        "body": {"representation": "storage", "value": complete},
        "version": {"number": fetched["version"]["number"] + 1,
                    "message": "Confluence API probe"}})
    client.call("POST", f"/wiki/rest/api/content/{page_id}/label",
                [{"prefix": "global", "name": marker}], expected=(200, 201))
    cql = parse.quote(f'type=page and label="{marker}"')
    found = client.call("GET", f"/wiki/rest/api/content/search?cql={cql}&limit=2")
    if [item["id"] for item in found["results"]] != [page_id]:
        raise RuntimeError("probe label did not uniquely rediscover the page")

    # Establish optimistic-update failure behavior without exposing its body.
    client.call("PUT", f"/wiki/api/v2/pages/{page_id}", {
        "id": page_id, "status": "current", "title": title,
        "body": {"representation": "storage", "value": complete},
        "version": {"number": fetched["version"]["number"]}},
        expected=(400, 409))
    return {"page_id": page_id, "label": marker,
            "created_version": fetched["version"]["number"],
            "updated_version": updated["version"]["number"],
            "vtt_utf8_bytes": len(vtt.encode()),
            "storage_utf8_bytes": len(complete.encode()),
            "observations": client.observations}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("vtt", help="complete representative VTT file")
    args = parser.parse_args()
    required = ["CONFLUENCE_BASE_URL", "CONFLUENCE_EMAIL", "CONFLUENCE_API_TOKEN",
                "CONFLUENCE_SPACE_ID"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        parser.error("missing environment variables: " + ", ".join(missing))
    with open(args.vtt, encoding="utf-8") as stream:
        vtt = stream.read()
    if not vtt.startswith("WEBVTT"):
        parser.error("the representative payload must be a complete WEBVTT file")
    client = Confluence(os.environ["CONFLUENCE_BASE_URL"],
                        os.environ["CONFLUENCE_EMAIL"],
                        os.environ["CONFLUENCE_API_TOKEN"])
    print(json.dumps(run(client, os.environ["CONFLUENCE_SPACE_ID"], vtt), indent=2))


if __name__ == "__main__":
    main()
