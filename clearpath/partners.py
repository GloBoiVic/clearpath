"""Single-pairing service with local, synthetic email delivery."""

import argparse
from contextlib import closing
from email.message import EmailMessage
from html import escape
from hmac import compare_digest
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import sys
import tempfile
import time
from urllib.parse import parse_qs, urlsplit

from .decisions import Decisions, TOKEN, digest, valid_domain, valid_id

COPY = json.loads(Path(__file__).with_name("partner-copy.json").read_text(encoding="utf-8"))


ROLES = ("primary", "backup")
INVITE_LIFETIME = 7 * 24 * 60 * 60
ADDRESS = re.compile(r"[A-Za-z0-9_+%-]+(?:\.[A-Za-z0-9_+%-]+)*@example\.test")
# Fragments stay in the browser. Only the explicit form submit sends the token.
INVITE_SCRIPT = b"""
const token = location.hash.slice(1);
history.replaceState(null, "", location.pathname);
document.querySelector("input").value = token;
document.querySelector("button").disabled = !/^[A-Za-z0-9_-]{43}$/.test(token);
"""


DECISION_SCRIPT = """
const description = document.querySelector("p");
const input = document.querySelector("input");
const buttons = document.querySelectorAll("button");
let preview = 0;

function showRequest() {
    const current = ++preview;
    const token = location.hash.slice(1);
    history.replaceState(null, "", location.pathname);
    input.value = "";
    buttons.forEach(button => { button.disabled = true; });
    const unavailable = () => {
        if (current === preview) description.textContent = "This request is no longer available.";
    };
    if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
        unavailable();
        return;
    }
    description.textContent = "Checking your decision link…";
    fetch("/decision/preview", { method: "POST", body: new URLSearchParams({ token }) })
        .then(response => {
            if (!response.ok) throw new Error();
            return response.json();
        })
        .then(({ domain }) => {
            if (current !== preview) return;
            description.textContent = "Confirm your decision on the request to unblock " + domain + ".";
            input.value = token;
            buttons.forEach(button => { button.disabled = false; });
        })
        .catch(unavailable);
}
window.addEventListener("hashchange", showRequest);
showRequest();
"""


def private_directory(path):
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Use a private directory owned by the current user.")


class Pairing:
    def __init__(self, directory, clock=None):
        private_directory(directory)
        self.database = directory / "pairing.sqlite3"
        self.mail = directory / "mail"
        private_directory(self.mail)
        key_file = directory / "owner-key"
        fresh = not key_file.exists() and not self.database.exists()
        if fresh:
            with key_file.open("x", encoding="ascii") as stream:
                stream.write(secrets.token_urlsafe(32))
        self.database_uri = self.database.absolute().as_uri()
        self.owner_key = key_file.read_text(encoding="ascii")
        if not TOKEN.fullmatch(self.owner_key):
            raise ValueError("Invalid owner key.")
        with closing(sqlite3.connect(
            self.database_uri + ("?mode=rwc" if fresh else "?mode=rw"), uri=True
        )) as db:
            if fresh:
                db.execute("""
                    CREATE TABLE invites (
                        role TEXT PRIMARY KEY CHECK (role IN ('primary', 'backup')),
                        email TEXT NOT NULL,
                        revision INTEGER NOT NULL CHECK (revision > 0),
                        token_hash BLOB UNIQUE,
                        expires_at INTEGER,
                        CHECK ((token_hash IS NULL) = (expires_at IS NULL))
                    )
                """)
            else:
                db.execute("SELECT role, email, revision, token_hash, expires_at FROM invites LIMIT 0")
        self.decisions = Decisions(self.connect, self.mail, clock)

    def connect(self):
        return sqlite3.connect(self.database_uri + "?mode=rw", uri=True)

    def status(self):
        slots = {role: {"status": "empty", "revision": 0} for role in ROLES}
        with closing(self.connect()) as db:
            for role, email, revision, expires in db.execute(
                "SELECT role, email, revision, expires_at FROM invites"
            ):
                status = "accepted" if expires is None else (
                    "expired" if expires <= time.time() else "pending"
                )
                slots[role] = {"email": email, "revision": revision, "status": status}
        return slots

    def invite(self, role, email, revision, origin):
        token = secrets.token_urlsafe(32)
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute(
                "SELECT revision, token_hash FROM invites WHERE role = ?", (role,)
            ).fetchone()
            if current is None:
                if revision != 0:
                    return False
            elif current[0] != revision or current[1] is None:
                return False
            db.execute("""
                INSERT INTO invites VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (role) DO UPDATE SET
                    email = excluded.email, revision = excluded.revision,
                    token_hash = excluded.token_hash, expires_at = excluded.expires_at
                """, (role, email, revision + 1, digest(token),
                      int(time.time()) + INVITE_LIFETIME))
            self.deliver(role, email, f"{origin}/invite/{role}#{token}")
        return True

    def deliver(self, role, email, link):
        message = EmailMessage()
        message["From"] = "clearpath@example.test"
        message["To"] = email
        message["Subject"] = COPY["title"]
        invitation = COPY["invited"].format(role=role)
        message.set_content(f"{invitation}. {COPY['email']}\n\n{link}", cte="8bit")
        # Publish only a complete message. If the database transaction rolls back,
        # the delivered link cannot authorize acceptance.
        with tempfile.NamedTemporaryFile(dir=self.mail, delete=False) as stream:
            draft = Path(stream.name)
            try:
                stream.write(message.as_bytes())
                stream.close()
                draft.rename(draft.with_suffix(".eml"))
            finally:
                draft.unlink(missing_ok=True)

    def accept(self, role, token):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            updated = db.execute("""
                UPDATE invites SET token_hash = NULL, expires_at = NULL,
                    revision = revision + 1
                WHERE role = ? AND token_hash = ? AND expires_at > ?
            """, (role, digest(token), time.time()))
            return updated.rowcount == 1


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def trusted_host(self):
        # The server never uses Host to generate links.
        return self.headers.get_all("Host") == [self.server.authority]

    def respond(self, status, body="", content_type="text/plain"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; script-src 'self'; connect-src 'self'; form-action 'self'; "
            "base-uri 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(data)

    def page(self, status, title, content=""):
        title = escape(title)
        self.respond(
            status, f'<!doctype html><html lang="en"><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>{title}</title><main><h1>{title}</h1>{content}</main></html>',
            "text/html",
        )

    def owner(self):
        values = self.headers.get_all("Authorization", [])
        prefix = "Bearer "
        return len(values) == 1 and values[0].startswith(prefix) and compare_digest(
            values[0][len(prefix):].encode("latin-1"), self.server.owner_key
        )

    def body(self, content_type):
        lengths = self.headers.get_all("Content-Length", [])
        if (self.headers.get("Transfer-Encoding") or len(lengths) != 1
                or not re.fullmatch(r"[0-9]{1,4}", lengths[0])
                or not 0 < int(lengths[0]) <= 2048
                or self.headers.get_content_type() != content_type):
            raise ValueError
        return self.rfile.read(int(lengths[0])).decode("utf-8")

    def role(self, prefix):
        return next((role for role in ROLES if self.path == prefix + role), None)

    def do_GET(self):
        if not self.trusted_host():
            self.respond(HTTPStatus.BAD_REQUEST)
        elif self.path == "/partners":
            if not self.owner():
                self.respond(HTTPStatus.UNAUTHORIZED)
                return
            try:
                data = json.dumps(self.server.pairing.status())
            except (sqlite3.Error, KeyError):
                self.respond(HTTPStatus.SERVICE_UNAVAILABLE)
                return
            self.respond(HTTPStatus.OK, data, "application/json")
        elif self.path == "/invitation.js":
            self.respond(HTTPStatus.OK, INVITE_SCRIPT, "text/javascript")
        elif self.path == "/decision.js":
            self.respond(HTTPStatus.OK, DECISION_SCRIPT, "text/javascript")
        elif self.path == "/decision":
            self.page(
                HTTPStatus.OK, "Review site removal",
                '<p>Checking your decision link…</p>'
                '<form method="post" action="/decision/confirm">'
                '<input type="hidden" name="token">'
                '<button name="choice" value="deny" disabled>Deny</button> '
                '<button name="choice" value="approve" disabled>Approve</button></form>'
                '<script src="/decision.js" defer></script>',
            )
        elif self.path.startswith("/requests/site-removal/"):
            self.removal_status(self.path.removeprefix("/requests/site-removal/"))
        elif role := self.role("/invite/"):
            self.page(
                HTTPStatus.OK, COPY["title"],
                f'<p>{escape(COPY["invited"].format(role=role))}</p>'
                f'<form method="post" action="/invite/{role}">'
                f'<input type="hidden" name="token">'
                f'<button disabled>{escape(COPY["accept"])}</button></form>'
                '<script src="/invitation.js" defer></script>',
            )
        else:
            self.respond(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if not self.trusted_host():
            self.respond(HTTPStatus.BAD_REQUEST)
            return
        if self.path == "/requests/site-removal":
            self.submit_removal()
            return
        if self.path in ("/decision/preview", "/decision/confirm"):
            self.submit_decision(preview=self.path.endswith("/preview"))
            return
        role = self.role("/partners/")
        if role:
            self.submit_invite(role)
            return
        role = self.role("/invite/")
        if role:
            self.submit_acceptance(role)
            return
        self.respond(HTTPStatus.NOT_FOUND)

    def submit_invite(self, role):
        if not self.owner():
            self.respond(HTTPStatus.UNAUTHORIZED)
            return
        try:
            form = json.loads(self.body("application/json"))
            if not isinstance(form, dict) or set(form) != {"email", "revision"}:
                raise ValueError
            email, revision = form["email"], form["revision"]
            if (not isinstance(email, str) or len(email) > 77 or not ADDRESS.fullmatch(email)
                    or type(revision) is not int or not 0 <= revision < 2**63 - 1):
                raise ValueError
            changed = self.server.pairing.invite(role, email, revision, self.server.origin)
        except ValueError:
            self.respond(HTTPStatus.BAD_REQUEST)
        except (OSError, sqlite3.Error):
            self.respond(HTTPStatus.SERVICE_UNAVAILABLE)
        else:
            self.respond(HTTPStatus.CREATED if changed else HTTPStatus.CONFLICT)

    def submit_acceptance(self, role):
        try:
            form = parse_qs(self.body("application/x-www-form-urlencoded"), strict_parsing=True)
            tokens = form.get("token", [])
            accepted = (set(form) == {"token"} and len(tokens) == 1
                        and TOKEN.fullmatch(tokens[0])
                        and self.server.pairing.accept(role, tokens[0]))
        except ValueError:
            accepted = False
        except sqlite3.Error:
            self.page(HTTPStatus.SERVICE_UNAVAILABLE, COPY["unavailable"])
            return
        if accepted:
            self.page(HTTPStatus.OK, COPY["accepted"])
        else:
            self.page(HTTPStatus.FORBIDDEN, COPY["unavailable"])

    def submit_removal(self):
        if not self.owner():
            self.respond(HTTPStatus.UNAUTHORIZED)
            return
        try:
            form = json.loads(self.body("application/json"))
            if (not isinstance(form, dict) or set(form) != {"id", "domain"}
                    or not valid_id(form["id"]) or not valid_domain(form["domain"])):
                raise ValueError
            decisions = self.server.pairing.decisions
            if not decisions.submit(form["id"], form["domain"], self.server.origin):
                self.respond(HTTPStatus.CONFLICT)
                return
        except (ValueError, RecursionError):
            self.respond(HTTPStatus.BAD_REQUEST)
            return
        except sqlite3.Error:
            self.respond(HTTPStatus.SERVICE_UNAVAILABLE)
            return
        self.removal_status(form["id"])

    def removal_status(self, request_id):
        if not self.owner():
            self.respond(HTTPStatus.UNAUTHORIZED)
            return
        if not valid_id(request_id):
            self.respond(HTTPStatus.NOT_FOUND)
            return
        decisions = self.server.pairing.decisions
        try:
            decisions.advance()
            result = decisions.status(request_id)
        except (OSError, sqlite3.Error):
            self.respond(HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if result is None:
            self.respond(HTTPStatus.NOT_FOUND)
        else:
            self.respond(HTTPStatus.OK, json.dumps(result), "application/json")

    def submit_decision(self, *, preview):
        try:
            form = parse_qs(self.body("application/x-www-form-urlencoded"),
                            keep_blank_values=True, strict_parsing=True)
            tokens = form.get("token", [])
            if len(tokens) != 1 or not TOKEN.fullmatch(tokens[0]):
                raise ValueError
            decisions = self.server.pairing.decisions
            if preview and set(form) == {"token"}:
                result = decisions.preview(tokens[0])
                if result is not None:
                    self.respond(HTTPStatus.OK, json.dumps(result), "application/json")
                    return
            if not preview and set(form) == {"token", "choice"}:
                outcome = {("approve",): "approved", ("deny",): "denied"}.get(tuple(form["choice"]))
                if outcome and decisions.decide(tokens[0], outcome):
                    self.page(HTTPStatus.OK, "Request " + outcome)
                    return
        except ValueError:
            pass
        except sqlite3.Error:
            self.page(HTTPStatus.SERVICE_UNAVAILABLE, "Could not confirm your decision. Try again.")
            return
        self.page(HTTPStatus.FORBIDDEN, "This request is no longer available.")


class PairingServer(HTTPServer):
    def __init__(self, port, pairing, public_origin=None):
        super().__init__(("127.0.0.1", port), Handler)
        self.origin = public_origin or f"http://127.0.0.1:{self.server_port}"
        self.authority = urlsplit(self.origin).netloc
        self.pairing = pairing
        self.owner_key = pairing.owner_key.encode("ascii")
        self.advance_at = 0

    def service_actions(self):
        now = time.monotonic()
        if now >= self.advance_at:
            self.advance_at = now + 30
            try:
                self.pairing.decisions.advance()
            except (OSError, sqlite3.Error):
                pass  # Retry the durable outbox without logging private records.

    def handle_error(self, _request, _client_address):
        # Untrusted input and private record details stay out of service logs.
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--public-origin", help="HTTPS origin supplied by a trusted reverse proxy")
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("Port must be between 0 and 65535.")
    if args.public_origin is not None:
        try:
            origin = urlsplit(args.public_origin)
            valid = (origin.scheme == "https" and origin.hostname and origin.username is None
                     and origin.port != 0 and args.public_origin == f"https://{origin.netloc}")
        except ValueError:
            valid = False
        if not valid:
            parser.error("Public origin must be an HTTPS origin without credentials or a path.")
    os.umask(0o077)
    try:
        with PairingServer(args.port, Pairing(args.state_dir), args.public_origin) as server:
            print(f"Pairing service listening at {server.origin}", flush=True)
            server.serve_forever()
    except (OSError, ValueError, sqlite3.Error):
        print("Could not start the pairing service.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
