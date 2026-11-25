"""Status-only check-ins and a durable alert for each missed window."""

from contextlib import closing
from uuid import uuid4

from .decisions import COPY, message, publish_batch


WINDOW = 24 * 60 * 60


class CheckIns:
    def __init__(self, connect, mail, clock):
        self.connect = connect
        self.mail = mail
        self.clock = clock
        with closing(connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("""
                CREATE TABLE IF NOT EXISTS check_in (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    revision TEXT NOT NULL,
                    last_received REAL,
                    first_partner_since REAL,
                    alerted INTEGER NOT NULL DEFAULT 0 CHECK (alerted IN (0, 1))
                )
            """)
            db.execute("""
                CREATE TABLE IF NOT EXISTS check_in_mail (
                    window TEXT NOT NULL,
                    role TEXT NOT NULL CHECK (role IN ('primary', 'backup')),
                    email TEXT NOT NULL,
                    PRIMARY KEY (window, role)
                )
            """)
            db.execute("INSERT OR IGNORE INTO check_in (singleton, revision) VALUES (1, ?)", (str(uuid4()),))

    def revision(self):
        with closing(self.connect()) as db:
            return db.execute("SELECT revision FROM check_in").fetchone()[0]

    def partner_accepted(self, db):
        # Give the first accepted partner a full window, including when a
        # previously solo installation already has a last-received time.
        count = db.execute("SELECT COUNT(*) FROM invites WHERE token_hash IS NULL").fetchone()[0]
        if count == 1:
            db.execute("UPDATE check_in SET first_partner_since = ?", (self.clock(),))

    def receive(self, revision):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT revision FROM check_in").fetchone()[0] != revision:
                return  # A repeated or superseded check-in cannot reset the clock.
            now = self.clock()
            # A recovering Mac can reach us before the next scheduled sweep.
            self.queue_due(db, now)
            db.execute("UPDATE check_in SET revision = ?, last_received = ?, alerted = 0",
                       (str(uuid4()), now))

    @staticmethod
    def queue_due(db, now):
        revision, last_received, first_partner_since, alerted = db.execute(
            "SELECT revision, last_received, first_partner_since, alerted FROM check_in"
        ).fetchone()
        if alerted or last_received is None:
            return
        window_start = max(last_received, first_partner_since) if first_partner_since is not None else last_received
        if now < window_start + WINDOW:
            return
        queued = db.execute("""
            INSERT INTO check_in_mail (window, role, email)
            SELECT ?, MIN(role), email FROM invites WHERE token_hash IS NULL GROUP BY email
        """, (revision,))
        if queued.rowcount:
            db.execute("UPDATE check_in SET alerted = 1")

    def advance(self):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            self.queue_due(db, self.clock())
        self.deliver()

    def deliver(self):
        copy = COPY["missedCheckIn"]
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            for (window,) in db.execute("SELECT DISTINCT window FROM check_in_mail").fetchall():
                # A replaced partner can no longer receive an undelivered alert.
                recipients = db.execute("""
                    SELECT role, email FROM check_in_mail WHERE window = ?
                    AND email IN (SELECT email FROM invites WHERE token_hash IS NULL)
                """, (window,)).fetchall()
                if recipients:
                    publish_batch(self.mail / ("check-in-" + window), (
                        (role, message(email, copy["subject"], copy["body"]).as_bytes())
                        for role, email in recipients
                    ))
                db.execute("DELETE FROM check_in_mail WHERE window = ?", (window,))
