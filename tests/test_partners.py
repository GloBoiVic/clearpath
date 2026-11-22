import email
import hashlib
from http.client import HTTPConnection
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlencode, urlsplit


class PartnerInvitationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.state = Path(directory.name)
        self.process = subprocess.Popen(
            [sys.executable, "-m", "clearpath.partners", "--state-dir", str(self.state), "--port", "0"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.addCleanup(self.stop)
        self.start_line = self.process.stdout.readline()
        match = re.fullmatch(r"Pairing service listening at http://127\.0\.0\.1:(\d+)\n", self.start_line)
        self.assertIsNotNone(match)
        self.port = int(match[1])
        self.key = (self.state / "owner-key").read_text()

    def stop(self):
        self.process.terminate()
        output, _ = self.process.communicate(timeout=5)
        self.assertEqual(output, "")

    def request(self, method, path, data=None, *, owner=True, form=False):
        headers = {"Authorization": "Bearer " + self.key} if owner else {}
        body = None
        if data is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            body = urlencode(data) if form else json.dumps(data)
        connection = HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            return response.status, response.read().decode()
        finally:
            connection.close()

    def invite(self, role, address, revision=0, *, owner=True):
        return self.request("POST", f"/partners/{role}", {
            "email": address + "@example.test", "revision": revision,
        }, owner=owner)[0]

    def slots(self):
        status, body = self.request("GET", "/partners")
        self.assertEqual(status, 200)
        return json.loads(body)

    def link(self, address):
        for path in (self.state / "mail").glob("*.eml"):
            message = email.message_from_bytes(path.read_bytes())
            if message["To"] == address + "@example.test":
                self.assertEqual(message["Subject"], "Clearpath partner invitation")
                return urlsplit(message.get_payload(decode=True).decode().strip().splitlines()[-1])
        self.fail("The synthetic invitation did not reach the sink.")

    def accept(self, link, *, role=None):
        path = "/invite/" + role if role else link.path
        return self.request("POST", path, {"token": link.fragment}, owner=False, form=True)

    def invite_with_headers(self, *, host=None, duplicate_authorization=False,
                            content_type="application/json", body_size=None,
                            transfer_encoding=None):
        body = json.dumps({"email": "guard@example.test", "revision": 0}).encode()
        if body_size is not None:
            body = body.ljust(body_size)
        connection = HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.putrequest("POST", "/partners/primary", skip_host=host is not None)
            if host is not None:
                connection.putheader("Host", host)
            connection.putheader("Authorization", "Bearer " + self.key)
            if duplicate_authorization:
                connection.putheader("Authorization", "Bearer invalid")
            connection.putheader("Content-Type", content_type)
            connection.putheader("Content-Length", str(len(body)))
            if transfer_encoding is not None:
                connection.putheader("Transfer-Encoding", transfer_encoding)
            connection.endheaders(body)
            response = connection.getresponse()
            response.read()
            return response.status
        finally:
            connection.close()

    def assert_invite_refused(self, expected_status, **options):
        self.assertEqual(self.invite_with_headers(**options), expected_status)
        self.assertEqual(self.slots()["primary"]["status"], "empty")
        self.assertFalse(list((self.state / "mail").iterdir()))

    def test_wrong_host_header_refuses_invitation(self):
        self.assert_invite_refused(400, host="untrusted.example.test")

    def test_duplicate_authorization_header_refuses_invitation(self):
        self.assert_invite_refused(401, duplicate_authorization=True)

    def test_oversized_content_length_refuses_invitation(self):
        self.assert_invite_refused(400, body_size=2049)

    def test_transfer_encoding_header_refuses_invitation(self):
        self.assert_invite_refused(400, transfer_encoding="chunked")

    def test_wrong_content_type_refuses_invitation(self):
        self.assert_invite_refused(400, content_type="text/plain")

    def test_both_invitations_correction_acceptance_and_link_rejections(self):
        self.assertEqual(self.invite("primary", "initial"), 201)
        initial = self.link("initial")
        self.assertEqual(self.invite("backup", "backup"), 201)
        backup = self.link("backup")
        self.assertEqual([slot["status"] for slot in self.slots().values()], ["pending", "pending"])

        self.assertEqual(self.invite("primary", "corrected", revision=1), 201)
        corrected = self.link("corrected")
        self.assertEqual(self.invite("primary", "stale", revision=1), 409)
        self.assertEqual(self.accept(initial)[0], 403)
        self.assertEqual(self.accept(corrected, role="backup")[0], 403)
        self.assertEqual(self.invite("backup", "unknown", revision=1, owner=False), 401)
        self.assertEqual(self.request("GET", "/partners", owner=False)[0], 401)
        self.assertEqual(self.accept(corrected._replace(fragment=""))[0], 403)

        status, page = self.request("GET", corrected.path, owner=False)
        self.assertEqual(status, 200)
        self.assertIn("Accept invitation", page)
        self.assertEqual(self.slots()["primary"]["status"], "pending")
        status, page = self.accept(corrected)
        self.assertEqual(status, 200)
        self.assertIn("Invitation accepted", page)
        self.assertEqual(self.accept(corrected)[0], 403)
        self.assertEqual(self.invite("primary", "locked", revision=3), 409)
        self.assertEqual(self.accept(backup)[0], 200)
        self.assertEqual(self.slots()["primary"]["email"], "corrected@example.test")
        self.assertEqual(self.slots()["backup"]["status"], "accepted")

    def test_expired_link_is_rejected_and_only_hash_is_stored(self):
        self.assertEqual(self.invite("backup", "later"), 201)
        link = self.link("later")
        with sqlite3.connect(self.state / "pairing.sqlite3") as db:
            stored, = db.execute("SELECT token_hash FROM invites").fetchone()
            self.assertTrue(stored == hashlib.sha256(link.fragment.encode()).digest())
            db.execute("UPDATE invites SET expires_at = 0")
        self.assertEqual(self.slots()["backup"]["status"], "expired")
        self.assertEqual(self.accept(link)[0], 403)
        self.assertEqual(self.slots()["backup"]["status"], "expired")

    def test_sink_failure_preserves_previous_invitation(self):
        self.assertEqual(self.invite("primary", "before"), 201)
        previous = self.link("before")
        (self.state / "mail").rename(self.state / "moved")
        self.assertEqual(self.invite("primary", "after", revision=1), 503)
        self.assertEqual(self.slots()["primary"]["email"], "before@example.test")
        self.assertEqual(self.accept(previous)[0], 200)


class PairingStartupTests(unittest.TestCase):
    def test_state_directory_readable_by_group_or_others_prevents_startup(self):
        for mode in (0o740, 0o704):
            with self.subTest(mode=oct(mode)), tempfile.TemporaryDirectory() as directory:
                state = Path(directory)
                state.chmod(mode)
                with subprocess.Popen(
                    [sys.executable, "-m", "clearpath.partners",
                     "--state-dir", directory, "--port", "0"],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                ) as process:
                    # The first line is the startup result. A service that
                    # starts despite unsafe permissions must be terminated.
                    result = process.stdout.readline()
                    if result:
                        process.terminate()
                    _, error = process.communicate(timeout=5)
                    self.assertEqual(result, "")
                    self.assertEqual(process.returncode, 1)
                    self.assertEqual(error.strip(), "Could not start the pairing service.")
                self.assertFalse(list(state.iterdir()))
