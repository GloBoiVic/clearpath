import email
from http.client import HTTPConnection
import json
from pathlib import Path
import sqlite3
import tempfile
from threading import Thread
import unittest
from urllib.parse import urlencode, urlsplit
from uuid import uuid4

from clearpath.partners import Pairing, PairingServer

WEEK = 7 * 24 * 60 * 60


class PartnerChanges(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.state = Path(directory.name)
        self.mail = self.state / "mail"
        self.now = 2_000_000_000
        self.start()

    def start(self):
        server = PairingServer(0, Pairing(self.state, clock=lambda: self.now))
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.server = server
        self.addCleanup(self.stop, server, thread)

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
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            body = urlencode(body) if form else json.dumps(body)
        connection = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request(method, path, body, headers)
            result = connection.getresponse()
            return result.status, result.read().decode()
        finally:
            connection.close()

    def owner(self, method, path, body=None):
        return self.request(method, path, body, owner=True)

    def slots(self):
        status, body = self.owner("GET", "/partners")
        self.assertEqual(status, 200)
        return json.loads(body)

    def setup_state(self):
        status, body = self.owner("GET", "/setup")
        self.assertEqual(status, 200)
        return json.loads(body)

    def finish(self, solo):
        return self.owner("POST", "/setup", {"solo": solo})[0]

    def invite(self, role, name, revision=0):
        return self.owner("POST", "/partners/" + role, {"email": name + "@example.test", "revision": revision})[0]

    def change(self, role, name, revision):
        return self.owner("POST", f"/partners/{role}/change",
                          {"email": name + "@example.test", "revision": revision})[0]

    def all_mail(self):
        return [email.message_from_bytes(path.read_bytes()) for path in self.mail.rglob("*.eml")]

    def links(self, name, subject):
        address = name + "@example.test"
        found = []
        for message in self.all_mail():
            if message["To"] == address and message["Subject"] == subject:
                found.append(urlsplit(message.get_payload(decode=True).decode().strip().splitlines()[-1]))
        return found

    def link(self, name, subject):
        found = self.links(name, subject)
        self.assertEqual(len(found), 1, (name, subject))
        return found[0]

    def accept(self, link):
        return self.request("POST", link.path, {"token": link.fragment}, form=True)[0]

    def partner(self, role, name, revision=0):
        self.assertEqual(self.invite(role, name, revision), 201)
        self.assertEqual(self.accept(self.links(name, "Clearpath partner invitation")[-1]), 200)

    def vote(self, link, choice):
        return self.request("POST", "/decision/confirm", {"token": link.fragment, "choice": choice}, form=True)

    def preview(self, link):
        status, body = self.request("POST", "/decision/preview", {"token": link.fragment}, form=True)
        return status, json.loads(body) if status == 200 else None

    def removal(self, request_id):
        status, body = self.owner("POST", "/requests/site-removal", {"id": request_id, "domain": "blocked.example"})
        self.assertEqual(status, 200)
        return json.loads(body)["outcome"]

    def notices(self, request_id):
        batch = self.mail / (request_id + "-applied")
        return {path.stem: email.message_from_bytes(path.read_bytes()) for path in batch.glob("*.eml")}

    def change_id(self):
        with sqlite3.connect(self.state / "pairing.sqlite3") as db:
            return db.execute("SELECT request_id FROM partner_changes ORDER BY rowid DESC").fetchone()[0]

    def test_setup_with_no_partner_requires_the_solo_acknowledgement_and_cannot_be_redone(self):
        self.assertEqual(self.request("POST", "/setup", {"solo": True})[0], 401)
        self.assertEqual(self.request("GET", "/setup")[0], 401)
        self.assertEqual(self.setup_state(), {"complete": False, "solo": False})
        self.assertEqual(self.finish(False), 409)
        self.assertEqual(self.owner("POST", "/setup", {"solo": "yes"})[0], 400)
        self.assertEqual(self.finish(True), 201)
        self.assertEqual(self.setup_state(), {"complete": True, "solo": True})
        self.assertEqual(self.finish(True), 409)
        # The lock is in force: a solo removal waits the full seven days.
        request_id = str(uuid4())
        self.assertEqual(self.removal(request_id), "pending")
        self.now += WEEK - 1
        self.assertEqual(self.removal(request_id), "pending")
        self.now += 1
        self.assertEqual(self.removal(request_id), "timed_out")

    def test_pending_invitation_stays_freely_correctable_after_setup(self):
        self.assertEqual(self.invite("primary", "first"), 201)
        self.assertEqual(self.finish(True), 409)
        self.assertEqual(self.finish(False), 201)
        self.assertEqual(self.setup_state(), {"complete": True, "solo": False})
        self.assertEqual(self.invite("primary", "second", revision=1), 201)
        self.assertEqual(self.change("primary", "third", revision=2), 409)
        self.assertEqual(self.accept(self.link("first", "Clearpath partner invitation")), 403)
        self.assertEqual(self.accept(self.link("second", "Clearpath partner invitation")), 200)
        self.assertEqual(self.slots()["primary"]["status"], "accepted")

    def test_other_partner_approves_replacement_and_stale_links_cannot_undo_it(self):
        self.partner("primary", "old")
        self.partner("backup", "backup")
        self.assertEqual(self.finish(False), 201)
        revision = self.slots()["primary"]["revision"]
        old_invite = self.link("old", "Clearpath partner invitation")
        removal_id = str(uuid4())
        self.assertEqual(self.removal(removal_id), "pending")
        old_removal = self.link("old", "Clearpath site removal request")

        self.assertEqual(self.invite("primary", "direct", revision), 409)
        self.assertEqual(self.request("POST", "/partners/primary/change",
                                      {"email": "new@example.test", "revision": revision})[0], 401)
        self.assertEqual(self.change("primary", "new", revision - 1), 409)
        self.assertEqual(self.change("primary", "new", revision), 201)
        self.assertEqual(self.change("backup", "other", self.slots()["backup"]["revision"]), 409)
        slots = self.slots()
        self.assertEqual(slots["primary"]["status"], "accepted")
        self.assertEqual(slots["primary"]["change"], {"email": "new@example.test", "outcome": "pending"})

        old_change = self.link("old", "Clearpath partner change request")
        backup_change = self.link("backup", "Clearpath partner change request")
        self.assertEqual(old_change.path, "/partner-change")
        content = next(m for m in self.all_mail() if m["Subject"] == "Clearpath partner change request")
        self.assertIn("replace the primary partner old@example.test with new@example.test",
                      content.get_payload(decode=True).decode())
        status, page = self.request("GET", "/partner-change")
        self.assertEqual(status, 200)
        self.assertIn("Review partner change", page)
        self.assertIn('data-kind="partner-change"', page)
        self.assertEqual(self.preview(backup_change), (200, {
            "role": "primary", "current": "old@example.test", "email": "new@example.test",
        }))
        self.assertEqual(self.slots()["primary"]["change"]["outcome"], "pending")

        status, page = self.vote(backup_change, "approve")
        self.assertEqual(status, 200)
        self.assertIn("Request approved", page)
        slots = self.slots()
        self.assertEqual(slots["primary"]["email"], "new@example.test")
        self.assertEqual(slots["primary"]["status"], "pending")
        self.assertNotIn("change", slots["primary"])
        notices = self.notices(self.change_id())
        self.assertEqual(set(notices), {"new-partner", "replaced-partner"})
        self.assertEqual(notices["replaced-partner"]["To"], "old@example.test")
        self.assertIn("You are no longer the Clearpath primary partner. new@example.test has been invited",
                      notices["replaced-partner"].get_payload(decode=True).decode())

        # Every link the replaced partner holds is dead, and the decision is final.
        self.assertEqual(self.vote(old_change, "deny")[0], 403)
        self.assertEqual(self.vote(backup_change, "deny")[0], 403)
        self.assertEqual(self.vote(old_removal, "approve")[0], 403)
        self.assertEqual(self.preview(old_removal), (403, None))
        self.assertEqual(self.accept(old_invite), 403)
        self.assertEqual(self.slots()["primary"]["email"], "new@example.test")

        self.assertEqual(self.accept(self.link("new", "Clearpath partner invitation")), 200)
        self.assertEqual(self.slots()["primary"]["status"], "accepted")
        # The open removal still belongs to the remaining partner.
        self.assertEqual(self.vote(self.link("backup", "Clearpath site removal request"), "deny")[0], 200)
        self.assertEqual(self.removal(removal_id), "denied")

    def test_denied_change_keeps_the_partner_and_the_replaced_partner_can_approve_a_later_one(self):
        self.partner("primary", "old")
        revision = self.slots()["primary"]["revision"]
        self.assertEqual(self.change("primary", "first", revision), 201)
        self.assertEqual(self.vote(self.link("old", "Clearpath partner change request"), "deny")[0], 200)
        slots = self.slots()
        self.assertEqual((slots["primary"]["email"], slots["primary"]["status"]), ("old@example.test", "accepted"))
        self.assertEqual(slots["primary"]["change"], {"email": "first@example.test", "outcome": "denied"})
        self.assertEqual(self.links("first", "Clearpath partner invitation"), [])
        self.assertEqual(self.notices(self.change_id()), {})

        self.assertEqual(self.change("primary", "second", revision), 201)
        links = self.links("old", "Clearpath partner change request")
        self.assertEqual(len(links), 2)
        self.assertEqual(self.vote(links[0], "approve")[0] + self.vote(links[1], "approve")[0], 403 + 200)
        self.assertEqual(self.slots()["primary"]["email"], "second@example.test")
        self.assertEqual(set(self.notices(self.change_id())), {"new-partner", "replaced-partner"})

    def test_unanswered_change_applies_after_seven_days_and_late_votes_fail(self):
        self.partner("primary", "old")
        self.partner("backup", "backup")
        self.assertEqual(self.change("primary", "new", self.slots()["primary"]["revision"]), 201)
        late = self.link("backup", "Clearpath partner change request")
        self.now += WEEK - 1
        self.assertEqual(self.slots()["primary"]["change"]["outcome"], "pending")
        self.now += 1
        slots = self.slots()
        self.assertEqual((slots["primary"]["email"], slots["primary"]["status"]), ("new@example.test", "pending"))
        notices = self.notices(self.change_id())
        self.assertEqual(set(notices), {"new-partner", "replaced-partner", "other-partner"})
        self.assertEqual(notices["other-partner"]["To"], "backup@example.test")
        self.assertIn("Seven days passed without a decision, so Clearpath replaced the primary partner",
                      notices["other-partner"].get_payload(decode=True).decode())
        self.assertEqual(self.vote(late, "deny")[0], 403)
        self.assertEqual(self.slots()["primary"]["email"], "new@example.test")

    def test_replacement_restarts_the_window_for_a_removal_whose_only_link_was_withdrawn(self):
        self.partner("primary", "old")
        self.assertEqual(self.change("primary", "new", self.slots()["primary"]["revision"]), 201)
        change = self.link("old", "Clearpath partner change request")
        offline = self.state / "offline"
        self.mail.rename(offline)
        removal_id = str(uuid4())
        self.assertEqual(self.owner("POST", "/requests/site-removal",
                                    {"id": removal_id, "domain": "blocked.example"})[0], 503)
        offline.rename(self.mail)
        # The removal link to the replaced partner is still queued when the change applies.
        self.assertEqual(self.vote(change, "approve")[0], 200)
        self.assertEqual(self.removal(removal_id), "pending")
        self.assertEqual(list(self.mail.glob(removal_id + "/*.eml")), [])
        self.now += WEEK
        self.assertEqual(self.removal(removal_id), "timed_out")

    def test_requests_saved_before_partner_changes_open_as_site_removals(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            Pairing(state, clock=lambda: 0)
            with sqlite3.connect(state / "pairing.sqlite3") as db:
                db.executescript("""
                    DROP TABLE partner_changes;
                    CREATE TABLE old AS SELECT id, domain, deadline, outcome FROM requests;
                    DROP TABLE requests;
                    CREATE TABLE requests (
                        id TEXT PRIMARY KEY, domain TEXT NOT NULL, deadline REAL,
                        outcome TEXT NOT NULL CHECK (outcome IN ('pending', 'approved', 'denied', 'timed_out'))
                    );
                    DROP TABLE old;
                    DROP TABLE setup;
                """)
                saved = str(uuid4())
                db.execute("INSERT INTO requests VALUES (?, 'blocked.example', 5, 'pending')", (saved,))
            pairing = Pairing(state, clock=lambda: 0)
            self.assertEqual(pairing.decisions.status(saved),
                             {"id": saved, "domain": "blocked.example", "outcome": "pending"})
            self.assertEqual(pairing.setup(), {"complete": False, "solo": False})


if __name__ == "__main__":
    unittest.main()
