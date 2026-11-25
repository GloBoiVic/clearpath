import email
from http.client import HTTPConnection
import json
from pathlib import Path
import secrets
import tempfile
from threading import Thread
import unittest
from unittest.mock import patch
from urllib.parse import urlencode, urlsplit
from uuid import uuid4

from clearpath.partners import Pairing, PairingServer
from clearpath.decisions import trusted_clock


class DecisionClockTests(unittest.TestCase):
    def test_wall_clock_steps_do_not_change_deadlines_across_service_restarts_on_same_boot(self):
        with tempfile.TemporaryDirectory() as directory:
            pairing = Pairing(Path(directory), clock=lambda: 1_000)
            with patch("clearpath.decisions.boot_identity", return_value="boot-a"), \
                    patch("clearpath.decisions.time.time", return_value=1_000) as wall, \
                    patch("clearpath.decisions.time.clock_gettime", return_value=50) as elapsed:
                original = trusted_clock(pairing.connect)
                wall.return_value = 3_000_000_000
                elapsed.return_value = 60
                self.assertEqual(original(), 1_010)
                self.assertEqual(trusted_clock(pairing.connect)(), 1_010)
                wall.return_value = 10
                elapsed.return_value = 70
                self.assertEqual(trusted_clock(pairing.connect)(), 1_020)


class RemovalRequests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.state = Path(directory.name)
        self.now = 2_000_000_000
        self.start()

    def start(self):
        self.server = PairingServer(0, Pairing(self.state, clock=lambda: self.now))
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop, self.server, self.thread)

    @staticmethod
    def stop(server, thread):
        server.shutdown()
        server.server_close()
        thread.join()

    def request(self, method, path, body=None, *, owner=False, form=False):
        headers = {}
        if owner:
            headers["Authorization"] = "Bearer " + (self.state / "owner-key").read_text()
        if body is not None:
            headers["Content-Type"] = ("application/x-www-form-urlencoded" if form else "application/json")
            body = urlencode(body) if form else json.dumps(body)
        connection = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request(method, path, body, headers)
            result = connection.getresponse()
            return result.status, result.read().decode()
        finally:
            connection.close()

    def tokens(self, request_id):
        messages = (self.state / "mail" / request_id).glob("*.eml")
        return {message["To"]: urlsplit(message.get_payload(decode=True).decode().strip().splitlines()[-1]).fragment
                for path in messages for message in [email.message_from_bytes(path.read_bytes())]}

    def partners(self):
        for role in ("primary", "backup"):
            self.assertEqual(self.request("POST", "/partners/" + role, {
                "email": role + "@example.test", "revision": 0,
            }, owner=True)[0], 201)
        for path in self.state.joinpath("mail").glob("*.eml"):
            message = email.message_from_bytes(path.read_bytes())
            link = urlsplit(message.get_payload(decode=True).decode().strip().splitlines()[-1])
            self.assertEqual(self.request("POST", link.path, {"token": link.fragment}, form=True)[0], 200)

    def removal(self, request_id, domain="blocked.example", *, owner=True):
        return self.request("POST", "/requests/site-removal", {"id": request_id, "domain": domain}, owner=owner)

    def status(self, request_id, domain="blocked.example"):
        status, body = self.removal(request_id, domain)
        self.assertEqual(status, 200)
        return json.loads(body)["outcome"]

    def vote(self, token, choice):
        return self.request("POST", "/decision/confirm", {"token": token, "choice": choice}, form=True)[0]

    def test_link_open_and_preview_are_read_only_and_first_confirmation_wins(self):
        self.partners()
        request_id = str(uuid4())
        self.assertEqual(self.removal(request_id, owner=False)[0], 401)
        self.assertEqual(self.status(request_id), "pending")
        tokens = self.tokens(request_id)
        self.assertEqual(set(tokens), {"primary@example.test", "backup@example.test"})
        status, page = self.request("GET", "/decision")
        self.assertEqual(status, 200)
        self.assertIn('action="/decision/confirm"', page)
        status, body = self.request("POST", "/decision/preview", {"token": tokens["backup@example.test"]}, form=True)
        self.assertEqual((status, json.loads(body)), (200, {"domain": "blocked.example"}))
        self.assertEqual(self.status(request_id), "pending")
        self.assertEqual(self.vote(secrets.token_urlsafe(32), "approve"), 403)
        self.assertEqual(self.vote(tokens["backup@example.test"], "deny"), 200)
        self.assertEqual(self.vote(tokens["primary@example.test"], "approve"), 403)
        self.assertEqual(self.vote(tokens["backup@example.test"], "deny"), 403)
        self.assertEqual(self.status(request_id), "denied")
        self.assertEqual(self.removal(request_id, "other.example")[0], 409)
        second = str(uuid4())
        self.assertEqual(self.status(second), "pending")
        self.assertEqual(self.vote(tokens["primary@example.test"], "approve"), 403)
        self.assertEqual(self.status(second), "pending")
        self.assertEqual(self.vote(self.tokens(second)["primary@example.test"], "approve"), 200)
        self.assertEqual(self.status(second), "approved")

    def test_deadline_survives_restart_and_late_tokens_cannot_reverse_it(self):
        solo = str(uuid4())
        self.assertEqual(self.status(solo), "pending")
        self.assertEqual(self.tokens(solo), {})
        self.partners()
        paired = str(uuid4())
        self.assertEqual(self.status(paired), "pending")
        token = self.tokens(paired)["primary@example.test"]
        self.now += 7 * 24 * 60 * 60 - 1
        self.assertEqual(self.status(solo), "pending")
        self.assertEqual(self.status(paired), "pending")
        old = self.server
        self.stop(old, self.thread)
        self.now += 1
        self.start()
        self.assertEqual(self.vote(token, "deny"), 403)
        self.assertEqual(self.status(solo), "timed_out")
        self.assertEqual(self.status(paired), "timed_out")
        self.assertEqual(len(list((self.state / "mail" / (paired + "-expired")).glob("*.eml"))), 2)
        self.now -= 60
        self.assertEqual(self.vote(token, "deny"), 403)
        self.assertEqual(self.status(paired), "timed_out")

    def test_failed_mail_sink_retries_both_messages_and_waits_the_full_window(self):
        self.partners()
        request_id = str(uuid4())
        mail = self.state / "mail"
        offline = self.state / "offline"
        mail.rename(offline)
        self.assertEqual(self.removal(request_id)[0], 503)
        self.now += 8 * 24 * 60 * 60
        offline.rename(mail)
        self.assertEqual(self.status(request_id), "pending")
        tokens = self.tokens(request_id)
        self.assertEqual(len(tokens), 2)
        self.assertEqual(self.status(request_id), "pending")
        self.assertEqual(self.tokens(request_id), tokens)
        self.assertEqual(self.vote(tokens["backup@example.test"], "deny"), 200)
        self.assertEqual(self.status(request_id), "denied")
