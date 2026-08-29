import importlib.util
import pathlib
import unittest
from unittest import mock

PATH = pathlib.Path(__file__).parents[1] / "scripts" / "confluence_probe.py"
SPEC = importlib.util.spec_from_file_location("confluence_probe", PATH)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class Response:
    def __init__(self, status, body=b"{}", headers=None):
        self.status, self.body, self.headers = status, body, headers or {}

    def read(self):
        return self.body


class ProbeTest(unittest.TestCase):
    def test_storage_body_escapes_complete_vtt(self):
        vtt = 'WEBVTT\n\n00:00.000 --> 00:01.000\n<&> "quotes" café\n'
        body = PROBE.storage_body(vtt, "probe&marker")
        self.assertIn("WEBVTT", body)
        self.assertIn("&lt;&amp;&gt;", body)
        self.assertIn('"quotes" café', body)
        self.assertNotIn("<&>", body)
        self.assertIn("probe&amp;marker", body)

    @mock.patch.object(PROBE.request, "urlopen")
    def test_rate_limit_retries_without_exposing_authorization(self, urlopen):
        urlopen.side_effect = [
            PROBE.error.HTTPError("url", 429, "limited", {"Retry-After": "2"}, None),
            Response(200, b'{"ok": true}', {"X-RateLimit-Remaining": "9"})]
        sleeps = []
        client = PROBE.Confluence("https://example.atlassian.net", "user", "secret",
                                  sleeps.append)
        self.assertEqual(client.call("GET", "/page"), {"ok": True})
        self.assertEqual(sleeps, [2])
        self.assertEqual(client.observations[0]["status"], 429)
        self.assertNotIn("authorization", str(client.observations).lower())
        self.assertNotIn("secret", str(client.observations))

    def test_rejects_non_atlassian_credential_destination(self):
        with self.assertRaises(ValueError):
            PROBE.Confluence("https://example.invalid", "user", "secret")


if __name__ == "__main__":
    unittest.main()
