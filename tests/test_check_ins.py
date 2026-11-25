from contextlib import closing
from email import policy
from email.parser import BytesParser
from http.client import HTTPConnection
import json
from pathlib import Path
import tempfile
from threading import Thread
import unittest
from unittest.mock import patch
from urllib.parse import urlencode, urlsplit

from clearpath.decisions import publish_batch
from clearpath.partners import Pairing, PairingServer


DAY = 24 * 60 * 60


class CheckInTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.state = Path(directory.name)
        self.mail = self.state / "mail"
        self.now = 2_000_000_000
        self.start()
        self.addCleanup(self.stop)

    def start(self, *, automatic=True):
        self.server = PairingServer(0, Pairing(self.state, clock=lambda: self.now))
        if not automatic:
            self.server.advance_at = float("inf")
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path, payload=None, *, owner=True, form=False):
        headers = {}
        if owner:
            headers["Authorization"] = "Bearer " + (self.state / "owner-key").read_text()
        if payload is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            payload = urlencode(payload) if form else json.dumps(payload)
        with closing(HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)) as connection:
            connection.request("GET" if payload is None else "POST", path, payload, headers)
            response = connection.getresponse()
            return response.status, response.read()

    def invite(self, role):
        self.assertEqual(self.request("/partners/" + role, {
            "email": role + "@example.test", "revision": 0,
        })[0], 201)

    def accept(self, role):
        for path in self.mail.glob("*.eml"):
            mail = self.message(path)
            if mail["To"] == role + "@example.test":
                link = urlsplit(mail.get_content().strip().splitlines()[-1])
                self.assertEqual(self.request(link.path, {"token": link.fragment}, owner=False, form=True)[0], 200)
                return
        self.fail("The invitation did not reach the mail sink.")

    @staticmethod
    def message(path):
        return BytesParser(policy=policy.default).parsebytes(path.read_bytes())

    def revision(self):
        status, data = self.request("/check-in")
        self.assertEqual(status, 200)
        reply = json.loads(data)
        self.assertEqual(set(reply), {"revision"})
        return reply["revision"]

    def check_in(self, revision=None, *, owner=True):
        return self.request("/check-in", {"revision": revision or self.revision()}, owner=owner)[0]

    def alerts(self):
        # The owners' status request also runs the same advance pass as the idle service.
        self.assertEqual(self.request("/partners")[0], 200)
        return [self.message(path) for path in self.mail.glob("check-in-*/*.eml")]

    def test_24_hours_duplicate_delivery_unauthorized_updates_and_recovery(self):
        for role in ("primary", "backup"):
            self.invite(role)
            self.accept(role)
        self.assertEqual(self.request("/check-in", owner=False)[0], 401)
        first = self.revision()
        self.assertEqual(self.check_in(first), 204)
        second = self.revision()
        self.assertNotEqual(first, second)
        self.now += DAY - 1
        self.assertEqual(self.check_in(first), 204)
        self.assertEqual(self.check_in(second, owner=False), 401)
        self.assertEqual(self.request("/check-in", {"revision": second, "domain": "private.example"})[0], 400)
        self.assertEqual(self.alerts(), [])

        self.stop()
        self.now += 1
        self.start()
        self.assertEqual(self.revision(), second)
        for _ in range(2):
            alerts = self.alerts()
            self.assertCountEqual([mail["To"] for mail in alerts], ["primary@example.test", "backup@example.test"])
            for mail in alerts:
                content = mail.get_content()
                self.assertIn("hasn't checked in for 24 hours", content)
                self.assertIn("may simply be off", content)
                self.assertIn("check in with", content)
                self.assertNotIn("private.example", mail.as_string())

        self.now += DAY
        self.assertEqual(self.check_in(first), 204)
        self.assertEqual(len(self.alerts()), 2)
        self.assertEqual(self.check_in(second), 204)
        self.now += DAY - 1
        self.assertEqual(len(self.alerts()), 2)
        self.now += 1
        self.assertEqual(len(self.alerts()), 4)

    def test_solo_and_pending_invitations_do_not_generate_alerts(self):
        self.assertEqual(self.request("/setup", {"solo": True})[0], 201)
        self.assertEqual(self.check_in(), 204)
        self.now += DAY * 2
        self.assertEqual(self.alerts(), [])
        self.invite("primary")
        self.assertEqual(self.alerts(), [])
        self.accept("primary")
        self.assertEqual(self.alerts(), [])
        self.now += DAY
        self.assertEqual([mail["To"] for mail in self.alerts()], ["primary@example.test"])

    def test_first_contact_arms_and_recovery_queues_an_unprocessed_outage(self):
        self.invite("primary")
        self.accept("primary")
        self.now += DAY * 2
        self.assertEqual(self.alerts(), [])
        self.assertEqual(self.check_in(), 204)
        revision = self.revision()
        self.stop()
        self.now += DAY
        self.start(automatic=False)
        self.assertEqual(self.check_in(revision), 204)
        self.assertEqual([mail["To"] for mail in self.alerts()], ["primary@example.test"])

    def test_outbox_retry_after_publication_does_not_send_mail_twice(self):
        self.invite("primary")
        self.accept("primary")
        self.assertEqual(self.check_in(), 204)
        batch = self.mail / ("check-in-" + self.revision())
        self.stop()
        self.now += DAY
        self.start(automatic=False)

        def publish_then_fail(path, messages):
            publish_batch(path, messages)
            raise OSError("Interrupted before acknowledging the batch")

        with patch("clearpath.check_ins.publish_batch", side_effect=publish_then_fail) as publish:
            self.assertEqual(len(self.alerts()), 1)
            publish.assert_called_once()
        alert = batch / "primary.eml"
        published = alert.stat()
        self.stop()
        self.start(automatic=False)
        self.assertEqual(len(self.alerts()), 1)
        self.assertEqual(alert.stat().st_ino, published.st_ino)
        self.assertEqual(alert.stat().st_mtime_ns, published.st_mtime_ns)
