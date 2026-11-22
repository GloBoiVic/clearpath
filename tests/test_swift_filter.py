"""Live tests of the Swift filter process (`native/`, product clearpath-filter).

Each test runs the real binary from a disposable temp folder, bound to loopback on a
free high port, forwarding only to a loopback fixture upstream. Nothing here changes
the Mac's DNS settings or sends a name to an external DNS server.
"""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import unittest

from dnslib import RCODE, QTYPE, RD, RR, DNSRecord

from clearpath.dns import reply, serve
from test_filter import Fixture


ROOT = Path(__file__).resolve().parents[1]
SCRATCH = ROOT / "artifacts" / "native-build"
BLOCKED = ("adult.example", "sub.adult.example", "blocked.example", "sub.blocked.example")
RECORD_TYPES = ("A", "AAAA", "HTTPS", "SVCB")


def build_filter():
    """Build the current source so the test never runs a stale binary."""
    swift = shutil.which("swift")
    if swift is None:
        raise RuntimeError("swift is required: the Swift filter is part of the shipped product")
    common = [swift, "build", "--package-path", str(ROOT / "native"), "--scratch-path", str(SCRATCH), "--product", "clearpath-filter"]
    built = subprocess.run(common, capture_output=True, text=True)
    if built.returncode != 0:
        raise RuntimeError("swift build failed:\n" + built.stdout[-4000:] + built.stderr[-4000:])
    path = subprocess.run(common + ["--show-bin-path"], capture_output=True, text=True, check=True).stdout.strip()
    return Path(path) / "clearpath-filter"


class LiveFixture(Fixture):
    """The harness fixture plus HTTPS answers and deliberately broken upstream replies."""
    def handle(self, packet, tcp=False):
        query = DNSRecord.parse(packet)
        name = str(query.q.qname)
        if name == "malformed.example.":
            self.calls.append((name, query.q.qtype, tcp))
            return packet[:2] + b"\x81\x80\x00\x01\x00\x01garbage"
        if name == "wrong-id.example.":
            out = DNSRecord.parse(super().handle(packet, tcp))
            out.header.id ^= 1
            return out.pack()
        if name == "wrong-question.example.":
            self.calls.append((name, query.q.qtype, tcp))
            other = DNSRecord.question("other.example", QTYPE[query.q.qtype])
            other.header.id = query.header.id
            return reply(other).pack()
        if query.q.qtype in (QTYPE.HTTPS, QTYPE.SVCB):
            self.calls.append((name, query.q.qtype, tcp))
            out = reply(query)
            out.add_answer(RR(name, query.q.qtype, rdata=RD(b"\x00\x01\x00")))  # priority 1, target "."
            return out.pack()
        return super().handle(packet, tcp)


class SwiftFilterProcess(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = build_filter()

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.policy = self.tmp / "policy.json"
        self.policy_data = json.loads((ROOT / "policy.example.json").read_text())
        self.policy.write_text(json.dumps(self.policy_data))
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.fixture = LiveFixture()
        self.upstream_port = self.stack.enter_context(serve(self.fixture))

    def launch(self, *extra, upstream="127.0.0.1", upstream_port=None, listen="127.0.0.1"):
        args = [str(self.binary), "--policy", str(self.policy), "--upstream", upstream,
                "--upstream-port", str(upstream_port or self.upstream_port), "--listen", listen, "--port", "0", *extra]
        proc = subprocess.Popen(args, cwd=self.tmp, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        line = self.startup = proc.stdout.readline()
        self.assertTrue(line.startswith("Clearpath filter on "), line + proc.stderr.read() if proc.poll() is not None else line)
        return proc, int(line.split(";")[0].rsplit(":", 1)[1])

    def ask(self, port, name, qtype="A", tcp=False, address="127.0.0.1"):
        query = DNSRecord.question(name, qtype)
        response = DNSRecord.parse(query.send(address, port, tcp=tcp, timeout=3, ipv6=":" in address))
        self.assertEqual(response.header.id, query.header.id)
        self.assertEqual(str(response.q.qname).rstrip("."), name)
        return response

    def stop(self, proc):
        proc.send_signal(signal.SIGTERM)
        stdout, stderr = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0, stderr)
        return stdout + stderr

    def test_blocked_apex_and_subdomains_are_nxdomain_without_reaching_upstream(self):
        proc, port = self.launch()
        for tcp in (False, True):
            for name in BLOCKED:
                for kind in RECORD_TYPES:
                    response = self.ask(port, name, kind, tcp)
                    self.assertEqual(response.header.rcode, RCODE.NXDOMAIN, (name, kind, tcp))
                    self.assertEqual(response.rr, [])
        self.assertEqual(self.fixture.calls, [])
        output = self.stop(proc)
        for name in BLOCKED:
            self.assertNotIn(name, output)

    def test_search_engines_get_forced_safe_answers(self):
        proc, port = self.launch()
        for host, target in self.policy_data["safesearch"].items():
            for tcp in (False, True):
                for kind, address in (("A", "192.0.2.42"), ("AAAA", "2001:db8::1")):
                    response = self.ask(port, host, kind, tcp)
                    self.assertEqual(response.header.rcode, RCODE.NOERROR, (host, kind, tcp))
                    self.assertEqual(response.rr[0].rtype, QTYPE.CNAME)
                    self.assertEqual(str(response.rr[0].rdata).rstrip("."), target)
                    self.assertEqual(response.rr[-1].rtype, getattr(QTYPE, kind))
                    self.assertEqual(str(response.rr[-1].rdata), address)
                    self.assertEqual(response.header.ad, 0)
                for kind in ("HTTPS", "SVCB"):
                    response = self.ask(port, host, kind, tcp)
                    self.assertEqual((response.header.rcode, response.rr), (RCODE.NOERROR, []), (host, kind))
        asked = {name.rstrip(".") for name, _, _ in self.fixture.calls}
        self.assertTrue(asked.isdisjoint(self.policy_data["safesearch"]), asked)
        self.assertTrue({"forcesafesearch.google.com", "strict.bing.com", "safe.duckduckgo.com"} <= asked)
        self.stop(proc)

    def test_allowed_names_are_forwarded_for_a_aaaa_and_https(self):
        proc, port = self.launch()
        for tcp in (False, True):
            for kind, rtype in (("A", QTYPE.A), ("AAAA", QTYPE.AAAA), ("HTTPS", QTYPE.HTTPS), ("SVCB", QTYPE.SVCB)):
                for name in ("github.com", "registry.npmjs.org", "accounts.google.com"):
                    response = self.ask(port, name, kind, tcp)
                    self.assertEqual(response.header.rcode, RCODE.NOERROR, (name, kind, tcp))
                    self.assertEqual([rr.rtype for rr in response.rr], [rtype])
        self.stop(proc)

    def test_cname_to_blocked_or_search_name_is_not_returned(self):
        proc, port = self.launch()
        for tcp in (False, True):
            self.assertEqual(self.ask(port, "alias.example", tcp=tcp).header.rcode, RCODE.NXDOMAIN)
            self.assertEqual(self.ask(port, "search-alias.example", tcp=tcp).header.rcode, RCODE.SERVFAIL)
        self.stop(proc)

    def test_unavailable_safe_target_fails_closed(self):
        self.fixture.safe_fail = True
        proc, port = self.launch()
        for tcp in (False, True):
            for kind in ("A", "AAAA"):
                response = self.ask(port, "www.google.com", kind, tcp)
                self.assertEqual((response.header.rcode, response.rr), (RCODE.SERVFAIL, []))
        self.stop(proc)

    def test_silent_upstream_fails_closed_for_search_and_allowed_names(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as silent:
            silent.bind(("127.0.0.1", 0))
            proc, port = self.launch("--timeout", "0.2", upstream_port=silent.getsockname()[1])
            for name in ("www.google.com", "github.com"):
                for tcp in (False, True):
                    response = self.ask(port, name, "A", tcp)
                    self.assertEqual((response.header.rcode, response.rr), (RCODE.SERVFAIL, []), (name, tcp))
            self.stop(proc)

    def test_malformed_or_mismatched_upstream_replies_are_servfail(self):
        proc, port = self.launch()
        for name in ("malformed.example", "wrong-id.example", "wrong-question.example"):
            for tcp in (False, True):
                response = self.ask(port, name, "A", tcp)
                self.assertEqual((response.header.rcode, response.rr), (RCODE.SERVFAIL, []), (name, tcp))
        self.stop(proc)

    def test_malformed_client_queries_get_formerr_and_service_continues(self):
        proc, port = self.launch()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(3)
            for packet in (b"\x12\x34" + b"\x00" * 10, b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\xc0\x0c"):
                sock.sendto(packet, ("127.0.0.1", port))
                answer = sock.recv(65535)
                self.assertEqual(answer[:2], b"\x12\x34")
                self.assertEqual(answer[3] & 0x0F, RCODE.FORMERR)
        with socket.create_connection(("127.0.0.1", port), timeout=3) as conn:
            conn.sendall(struct.pack("!H", 3) + b"bad")  # frame shorter than a DNS header
            self.assertEqual(conn.recv(10), b"")  # connection closed, nothing answered
        self.assertEqual(self.ask(port, "adult.example", tcp=True).header.rcode, RCODE.NXDOMAIN)
        self.assertEqual(self.fixture.calls, [])
        self.stop(proc)

    def test_tcp_pipelined_queries_answered_in_order(self):
        proc, port = self.launch()
        queries = [DNSRecord.question(name) for name in ("adult.example", "github.com", "www.google.com")]
        with socket.create_connection(("127.0.0.1", port), timeout=3) as conn:
            conn.sendall(b"".join(struct.pack("!H", len(q.pack())) + q.pack() for q in queries))
            stream = conn.makefile("rb")
            for query, rcode in zip(queries, (RCODE.NXDOMAIN, RCODE.NOERROR, RCODE.NOERROR)):
                size = struct.unpack("!H", stream.read(2))[0]
                response = DNSRecord.parse(stream.read(size))
                self.assertEqual((response.header.id, response.header.rcode), (query.header.id, rcode))
        self.stop(proc)

    def test_ipv6_loopback_listener(self):
        with serve(self.fixture, address="::1") as upstream_port:
            proc, port = self.launch(upstream="::1", upstream_port=upstream_port, listen="::1")
            for tcp in (False, True):
                self.assertEqual(self.ask(port, "adult.example", tcp=tcp, address="::1").header.rcode, RCODE.NXDOMAIN)
                response = self.ask(port, "www.bing.com", "AAAA", tcp=tcp, address="::1")
                self.assertEqual(str(response.rr[0].rdata).rstrip("."), "strict.bing.com")
                self.assertEqual(response.rr[-1].rtype, QTYPE.AAAA)
            self.stop(proc)

    def test_listener_only_on_loopback_and_unprivileged_ports(self):
        base = [str(self.binary), "--policy", str(self.policy), "--upstream", "127.0.0.1", "--upstream-port", str(self.upstream_port)]
        refused = (
            ["--listen", "0.0.0.0", "--port", "0"],
            ["--listen", "::", "--port", "0"],
            ["--listen", "192.0.2.1", "--port", "0"],
            ["--port", "53"],
            ["--port", "1023"],
        )
        for extra in refused:
            result = subprocess.run(base + extra, cwd=self.tmp, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, (extra, result.stderr))
            self.assertEqual(result.stdout, "")

    def test_bad_upstream_or_policy_refuses_to_start(self):
        cases = (
            (["--upstream", "resolver.example"], 2),            # hostname would need OS resolution
            (["--upstream", "127.0.0.1", "--upstream-port", "0"], 2),
            (["--upstream", "127.0.0.1", "--upstream-port", "1053", "--port", "1053"], 2),  # loop to itself
        )
        for extra, code in cases:
            result = subprocess.run([str(self.binary), "--policy", str(self.policy), *extra], cwd=self.tmp, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, code, (extra, result.stderr))
        for bad in ("not json", json.dumps({"adult": ["*.bad"], "custom": [], "allow": [], "safesearch": {}})):
            self.policy.write_text(bad)
            result = subprocess.run([str(self.binary), "--policy", str(self.policy), "--upstream", "127.0.0.1", "--port", "0"],
                                    cwd=self.tmp, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("Policy rejected", result.stderr)
            self.assertEqual(result.stdout, "")
        missing = subprocess.run([str(self.binary), "--policy", str(self.tmp / "absent.json"), "--upstream", "127.0.0.1", "--port", "0"],
                                 cwd=self.tmp, capture_output=True, text=True, timeout=5)
        self.assertEqual(missing.returncode, 1)

    def test_startup_reports_policy_digest_and_logs_no_names(self):
        proc, port = self.launch()
        self.assertIn("policy SHA256 " + hashlib.sha256(self.policy.read_bytes()).hexdigest(), self.startup)
        for name in ("github.com", "www.google.com", "adult.example"):
            self.ask(port, name)
        output = self.stop(proc)
        self.assertEqual(os.listdir(self.tmp), ["policy.json"])  # the process writes nothing
        for name in ("github.com", "google", "adult"):
            self.assertNotIn(name, output)


if __name__ == "__main__":
    unittest.main()
