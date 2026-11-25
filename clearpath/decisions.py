"""Durable, single-use partner decisions for the loopback pairing service."""

from contextlib import closing
from email.message import EmailMessage
import hashlib
import json
import re
import secrets
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from uuid import UUID, uuid4

from .policy import domain


COPY = json.loads(Path(__file__).with_name("partner-copy.json").read_text(encoding="utf-8"))
LIFETIME = 7 * 24 * 60 * 60
TOKEN = re.compile(r"[A-Za-z0-9_-]{43}", re.ASCII)
# Partner changes reuse the request record. Their subject lives in partner_changes.
PENDING = "SELECT id FROM requests WHERE outcome = 'pending'"


def message(address, subject, content):
    result = EmailMessage()
    result["From"] = "clearpath@example.test"
    result["To"] = address
    result["Subject"] = subject
    result.set_content(content, cte="8bit")
    return result


def invitation(role, address, link):
    invited = COPY["invited"].format(role=role)
    return message(address, COPY["title"], f"{invited}. {COPY['email']}\n\n{link}")


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
                CREATE TABLE IF NOT EXISTS partner_changes (
                    request_id TEXT PRIMARY KEY REFERENCES requests(id),
                    role TEXT NOT NULL CHECK (role IN ('primary', 'backup')),
                    revision INTEGER NOT NULL,
                    current TEXT NOT NULL,
                    email TEXT NOT NULL
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
            """)
            # Requests from before partner changes are all site removals.
            if "kind" not in {column[1] for column in db.execute("PRAGMA table_info(requests)")}:
                db.execute("""
                    ALTER TABLE requests ADD COLUMN kind TEXT NOT NULL DEFAULT 'site-removal'
                    CHECK (kind IN ('site-removal', 'partner-change'))
                """)
            db.execute("COMMIT")
        self.clock = clock if clock is not None else trusted_clock(connect)

    def submit(self, request_id, domain, origin):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            saved = db.execute("SELECT domain, kind FROM requests WHERE id = ?", (request_id,)).fetchone()
            if saved is not None:
                return saved == (domain, "site-removal")
            self.open(db, request_id, "site-removal", domain, lambda address, token: message(
                address, "Clearpath site removal request",
                f"Clearpath received a request to unblock {domain}.\n"
                "The selected block covers the domain and its subdomains.\n"
                "Open the link to confirm your decision within seven days. "
                "If nobody responds, Clearpath will apply the request.\n\n"
                f"{origin}/decision#{token}"))
        return True

    def open(self, db, request_id, kind, domain, compose):
        partners = db.execute(
            "SELECT role, email FROM invites WHERE token_hash IS NULL AND expires_at IS NULL"
        ).fetchall()
        deadline = None if partners else self.clock() + LIFETIME
        db.execute("INSERT INTO requests VALUES (?, ?, ?, 'pending', ?)",
                   (request_id, domain, deadline, kind))
        for role, address in partners:
            token = secrets.token_urlsafe(32)
            db.execute("INSERT INTO decision_recipients VALUES (?, ?, ?, ?)",
                       (request_id, role, address, digest(token)))
            self.queue_mail(db, request_id, role, 0, compose(address, token))

    def change_partner(self, role, email, revision, origin):
        """Ask the accepted partners to approve replacing an accepted partner."""
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute(
                "SELECT email FROM invites WHERE role = ? AND revision = ? AND token_hash IS NULL",
                (role, revision),
            ).fetchone()
            if current is None or db.execute(
                f"SELECT 1 FROM partner_changes WHERE request_id IN ({PENDING})"
            ).fetchone():
                return False
            request_id = str(uuid4())
            # The replaced partner is accepted, so the request always has a recipient.
            self.open(db, request_id, "partner-change", "", lambda address, token: message(
                address, COPY["change"]["subject"],
                COPY["change"]["request"].format(role=role, current=current[0], email=email)
                + f"\n\n{origin}/partner-change#{token}"))
            db.execute("INSERT INTO partner_changes VALUES (?, ?, ?, ?, ?)",
                       (request_id, role, revision, current[0], email))
        return True

    @staticmethod
    def changes(db):
        """The latest partner change per role that has not been applied."""
        return {role: {"email": email, "outcome": outcome} for role, email, outcome in db.execute("""
            SELECT role, email, outcome FROM partner_changes JOIN requests ON id = request_id
            WHERE partner_changes.rowid IN (SELECT MAX(rowid) FROM partner_changes GROUP BY role)
                AND outcome IN ('pending', 'denied')
        """)}

    def status(self, request_id):
        with closing(self.connect()) as db:
            row = db.execute(
                "SELECT domain, outcome FROM requests WHERE id = ? AND kind = 'site-removal'", (request_id,)
            ).fetchone()
            return {"id": request_id, "domain": row[0], "outcome": row[1]} if row else None

    def preview(self, token):
        with closing(self.connect()) as db:
            row = db.execute("""
                SELECT domain, change.role, change.current, change.email FROM requests
                JOIN decision_recipients AS recipient ON id = recipient.request_id
                LEFT JOIN partner_changes AS change ON id = change.request_id
                WHERE token_hash = ? AND outcome = 'pending' AND deadline > ?
            """, (digest(token), self.clock())).fetchone()
            if row is None:
                return None
            if row[1] is None:
                return {"domain": row[0]}
            return {"role": row[1], "current": row[2], "email": row[3]}

    def decide(self, token, outcome, origin):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("""
                SELECT id, kind FROM requests JOIN decision_recipients ON id = request_id
                WHERE token_hash = ? AND outcome = 'pending' AND deadline > ?
            """, (digest(token), self.clock())).fetchone()
            if row is None:
                return False
            self.resolve(db, row[0], outcome)
            applied = row[1] == "partner-change" and outcome == "approved"
            if applied:
                self.apply_change(db, row[0], origin, timed_out=False)
        if applied:
            try:
                self.deliver()
            except OSError:
                pass  # The durable outbox is retried by the service loop.
        return True

    @staticmethod
    def resolve(db, request_id, outcome):
        db.execute("UPDATE requests SET outcome = ? WHERE id = ?", (outcome, request_id))
        db.execute("UPDATE decision_recipients SET token_hash = NULL WHERE request_id = ?", (request_id,))

    def apply_change(self, db, request_id, origin, *, timed_out):
        role, revision, current, email = db.execute(
            "SELECT role, revision, current, email FROM partner_changes WHERE request_id = ?", (request_id,)
        ).fetchone()
        token = secrets.token_urlsafe(32)
        replaced = db.execute("""
            UPDATE invites SET email = ?, revision = revision + 1, token_hash = ?, expires_at = ?
            WHERE role = ? AND revision = ? AND email = ? AND token_hash IS NULL
        """, (email, digest(token), int(time.time()) + LIFETIME, role, revision, current))
        if replaced.rowcount != 1:
            # Only an applied change alters an accepted slot, and one change is open at a time.
            raise sqlite3.IntegrityError("The partner changed while the request was open.")
        # The replaced partner loses every open link and stops receiving request mail.
        db.execute(f"DELETE FROM decision_mail WHERE expired = 0 AND role = ? AND request_id IN ({PENDING})",
                   (role,))
        db.execute(f"DELETE FROM decision_recipients WHERE role = ? AND email = ? AND request_id IN ({PENDING})",
                   (role, current))
        # A request whose only queued link was withdrawn starts its window now.
        db.execute(f"""
            UPDATE requests SET deadline = ? WHERE id IN ({PENDING}) AND deadline IS NULL
                AND id NOT IN (SELECT request_id FROM decision_mail WHERE expired = 0)
        """, (self.clock() + LIFETIME,))
        copy = COPY["change"]
        self.queue_mail(db, request_id, "new-partner", 1,
                        invitation(role, email, f"{origin}/invite/{role}#{token}"))
        self.queue_mail(db, request_id, "replaced-partner", 1, message(
            current, copy["appliedSubject"], copy["replaced"].format(role=role, email=email)))
        if timed_out:
            for (address,) in db.execute(
                "SELECT email FROM decision_recipients WHERE request_id = ? AND role != ?", (request_id, role)
            ).fetchall():
                self.queue_mail(db, request_id, "other-partner", 1, message(
                    address, copy["appliedSubject"], copy["timedOut"].format(role=role, email=email)))

    def advance(self, origin):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            for request_id, domain, kind in db.execute(
                "SELECT id, domain, kind FROM requests WHERE outcome = 'pending' AND deadline <= ?",
                (self.clock(),),
            ).fetchall():
                self.resolve(db, request_id, "timed_out")
                if kind == "partner-change":
                    self.apply_change(db, request_id, origin, timed_out=True)
                    continue
                for role, address in db.execute(
                    "SELECT role, email FROM decision_recipients WHERE request_id = ?", (request_id,)
                ).fetchall():
                    self.queue_mail(db, request_id, role, 1, message(
                        address, "Clearpath site removal deadline passed",
                        f"Seven days passed without a decision on the request to unblock {domain}. "
                        "Clearpath can now apply the request."))
        self.deliver()

    @staticmethod
    def queue_mail(db, request_id, role, expired, mail):
        db.execute("INSERT INTO decision_mail VALUES (?, ?, ?, ?)",
                   (request_id, role, expired, mail.as_bytes()))

    def deliver(self):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            for request_id, expired, kind in db.execute("""
                SELECT DISTINCT request_id, expired, kind FROM decision_mail JOIN requests ON id = request_id
            """).fetchall():
                suffix = ("-applied" if kind == "partner-change" else "-expired") if expired else ""
                batch = self.mail / (request_id + suffix)
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
