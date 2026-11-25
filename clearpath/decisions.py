"""Durable, single-use partner decisions for the loopback pairing service."""

from contextlib import closing
from email.message import EmailMessage
import hashlib
import re
import secrets
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from uuid import UUID

from .policy import domain


LIFETIME = 7 * 24 * 60 * 60
TOKEN = re.compile(r"[A-Za-z0-9_-]{43}", re.ASCII)


def digest(token):
    return hashlib.sha256(token.encode("ascii")).digest()


def valid_id(value):
    if not isinstance(value, str) or len(value) != 36:
        return False
    try:
        parsed = UUID(value)
        return parsed.version == 4 and str(parsed) == value
    except ValueError:
        return False


def valid_domain(value):
    try:
        return (isinstance(value, str) and value.isascii()
                and len(value) <= 253 and domain(value) == value)
    except ValueError:
        return False


def boot_identity():
    try:
        if sys.platform == "darwin":
            boot = subprocess.check_output(
                ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
                stderr=subprocess.DEVNULL, text=True, timeout=2,
            )
        else:
            boot = Path("/proc/sys/kernel/random/boot_id").read_text()
        return str(UUID(boot.strip()))
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def trusted_clock(connect):
    # Use trusted UTC to anchor a service-host boot. Within that boot, a wall
    # clock step cannot change the window, even across a service restart.
    boot = boot_identity()
    clock_id = getattr(time, "CLOCK_BOOTTIME", time.CLOCK_MONOTONIC)

    def elapsed():
        return time.clock_gettime(clock_id)

    epoch, anchor = time.time(), elapsed()
    if boot is not None:
        with closing(connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("INSERT OR IGNORE INTO decision_clock VALUES (1, ?, ?, ?)", (boot, epoch, anchor))
            saved_boot, saved_epoch, saved_anchor = db.execute(
                "SELECT boot, epoch, anchor FROM decision_clock"
            ).fetchone()
            if saved_boot == boot:
                epoch, anchor = saved_epoch, saved_anchor
            else:
                db.execute("UPDATE decision_clock SET boot = ?, epoch = ?, anchor = ?", (boot, epoch, anchor))
    return lambda: epoch + (elapsed() - anchor)


class Decisions:
    def __init__(self, connect, mail, clock):
        self.connect = connect
        self.mail = mail
        with closing(connect()) as db:
            db.executescript("""
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS requests (
                    id TEXT PRIMARY KEY,
                    domain TEXT NOT NULL,
                    deadline REAL,
                    outcome TEXT NOT NULL CHECK (outcome IN ('pending', 'approved', 'denied', 'timed_out'))
                );
                CREATE TABLE IF NOT EXISTS decision_recipients (
                    request_id TEXT NOT NULL REFERENCES requests(id),
                    role TEXT NOT NULL CHECK (role IN ('primary', 'backup')),
                    email TEXT NOT NULL,
                    token_hash BLOB UNIQUE,
                    PRIMARY KEY (request_id, role)
                );
                CREATE TABLE IF NOT EXISTS decision_mail (
                    request_id TEXT NOT NULL REFERENCES requests(id),
                    role TEXT NOT NULL,
                    expired INTEGER NOT NULL CHECK (expired IN (0, 1)),
                    message BLOB NOT NULL,
                    PRIMARY KEY (request_id, role, expired)
                );
                CREATE TABLE IF NOT EXISTS decision_clock (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    boot TEXT NOT NULL,
                    epoch REAL NOT NULL,
                    anchor REAL NOT NULL
                );
                COMMIT;
            """)
        self.clock = clock if clock is not None else trusted_clock(connect)

    def submit(self, request_id, domain, origin):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            saved = self.record(db, request_id)
            if saved is not None:
                return saved["domain"] == domain
            partners = db.execute(
                "SELECT role, email FROM invites WHERE token_hash IS NULL AND expires_at IS NULL"
            ).fetchall()
            deadline = None if partners else self.clock() + LIFETIME
            db.execute("INSERT INTO requests VALUES (?, ?, ?, 'pending')", (request_id, domain, deadline))
            for role, address in partners:
                token = secrets.token_urlsafe(32)
                db.execute("INSERT INTO decision_recipients VALUES (?, ?, ?, ?)",
                           (request_id, role, address, digest(token)))
                self.queue_mail(db, request_id, role, address, domain, origin + "/decision#" + token)
        return True

    @staticmethod
    def record(db, request_id):
        row = db.execute(
            "SELECT domain, outcome FROM requests WHERE id = ?", (request_id,)
        ).fetchone()
        return {"id": request_id, "domain": row[0], "outcome": row[1]} if row else None

    def status(self, request_id):
        with closing(self.connect()) as db:
            return self.record(db, request_id)

    def preview(self, token):
        with closing(self.connect()) as db:
            row = db.execute("""
                SELECT domain FROM requests JOIN decision_recipients ON id = request_id
                WHERE token_hash = ? AND outcome = 'pending' AND deadline > ?
            """, (digest(token), self.clock())).fetchone()
            return {"domain": row[0]} if row else None

    def decide(self, token, outcome):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("""
                SELECT id FROM requests JOIN decision_recipients ON id = request_id
                WHERE token_hash = ? AND outcome = 'pending' AND deadline > ?
            """, (digest(token), self.clock())).fetchone()
            if row is None:
                return False
            self.resolve(db, row[0], outcome)
            return True

    @staticmethod
    def resolve(db, request_id, outcome):
        db.execute("UPDATE requests SET outcome = ? WHERE id = ?", (outcome, request_id))
        db.execute("UPDATE decision_recipients SET token_hash = NULL WHERE request_id = ?", (request_id,))

    def advance(self):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            for request_id, domain in db.execute(
                "SELECT id, domain FROM requests WHERE outcome = 'pending' AND deadline <= ?", (self.clock(),)
            ).fetchall():
                self.resolve(db, request_id, "timed_out")
                for role, address in db.execute(
                    "SELECT role, email FROM decision_recipients WHERE request_id = ?", (request_id,)
                ):
                    self.queue_mail(db, request_id, role, address, domain)
        self.deliver()

    @staticmethod
    def queue_mail(db, request_id, role, address, domain, link=None):
        message = EmailMessage()
        message["From"] = "clearpath@example.test"
        message["To"] = address
        if link:
            message["Subject"] = "Clearpath site removal request"
            message.set_content(f"Clearpath received a request to unblock {domain}.\n"
                                "The selected block covers the domain and its subdomains.\n"
                                "Open the link to confirm your decision within seven days. "
                                "If nobody responds, Clearpath will apply the request.\n\n"
                                f"{link}", cte="8bit")
        else:
            message["Subject"] = "Clearpath site removal deadline passed"
            message.set_content(f"Seven days passed without a decision on the request to unblock {domain}. "
                                "Clearpath can now apply the request.", cte="8bit")
        db.execute("INSERT INTO decision_mail VALUES (?, ?, ?, ?)",
                   (request_id, role, int(link is None), message.as_bytes()))

    def deliver(self):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            for request_id, expired in db.execute(
                "SELECT DISTINCT request_id, expired FROM decision_mail"
            ).fetchall():
                batch = self.mail / (request_id + ("-expired" if expired else ""))
                if not batch.is_dir():
                    with tempfile.TemporaryDirectory(dir=self.mail) as directory:
                        draft = Path(directory) / "batch"
                        draft.mkdir(mode=0o700)
                        for role, message in db.execute("""
                            SELECT role, message FROM decision_mail WHERE request_id = ? AND expired = ?
                        """, (request_id, expired)):
                            (draft / (role + ".eml")).write_bytes(message)
                        draft.rename(batch)
                if not expired:
                    db.execute("UPDATE requests SET deadline = ? WHERE id = ? AND deadline IS NULL",
                               (self.clock() + LIFETIME, request_id))
                db.execute("DELETE FROM decision_mail WHERE request_id = ? AND expired = ?", (request_id, expired))
