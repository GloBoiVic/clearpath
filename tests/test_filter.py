import concurrent.futures
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

from dnslib import A, AAAA, CNAME, DNSHeader, DNSQuestion, DNSRecord, EDNS0, QTYPE, RCODE, RR, TXT

from clearpath.dns import Resolver, Upstream, read_exact, reply, serve
from clearpath.policy import Policy, PolicyStore, domain, replace_domain_list


ROOT = Path(__file__).resolve().parents[1]


class Fixture:
    """No external queries: documentation IPs, local packets, recorded calls only."""
    def __init__(self):
        self.calls = []
        self.safe_fail = False
        self.truncate = False

    def handle(self, packet, tcp=False):
        query = DNSRecord.parse(packet)
        self.calls.append((str(query.q.qname), query.q.qtype, tcp))
        out = reply(query)
        name = str(query.q.qname)
        if self.safe_fail and name == "forcesafesearch.google.com.":
            out.header.rcode = RCODE.SERVFAIL
        elif self.truncate and not tcp:
            out.header.tc = 1
        elif name == "alias.example.":
            out.add_answer(RR(name, QTYPE.CNAME, rdata=CNAME("adult.example")))
            out.add_answer(RR("adult.example", QTYPE.A, rdata=A("192.0.2.1")))
        elif name == "search-alias.example.":
            out.add_answer(RR(name, QTYPE.CNAME, rdata=CNAME("www.google.com")))
            out.add_answer(RR("www.google.com", QTYPE.A, rdata=A("192.0.2.2")))
        elif name == "large.example.":
            for _ in range(6):
                out.add_answer(RR(name, QTYPE.TXT, rdata=TXT("x" * 200)))
        elif name == "no-v6.example." and query.q.qtype == QTYPE.AAAA:
            pass
        elif query.q.qtype == QTYPE.AAAA:
            out.add_answer(RR(name, QTYPE.AAAA, rdata=AAAA("2001:db8::1")))
        elif query.q.qtype == QTYPE.TXT:
            out.add_answer(RR(name, QTYPE.TXT, rdata=TXT("fixture")))
        else:
            out.add_answer(RR(name, QTYPE.A, ttl=30, rdata=A("192.0.2.42")))
        return out.pack()


class PolicySetup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "policy.json"
        self.data = json.loads((ROOT / "policy.example.json").read_text())
        self.write()

    def write(self):
        candidate = self.path.with_suffix(".new")
        candidate.write_text(json.dumps(self.data))
        os.replace(candidate, self.path)

class PolicyTests(PolicySetup):
    def test_boundaries_case_and_idn(self):
        p = Policy.load(self.path)
        for host in ("adult.example", "sub.adult.example", "ADULT.Example."):
            self.assertEqual(p.decide(host)[0], "block")
        for host in ("notadult.example", "adult.example.evil.test", "github.com"):
            self.assertEqual(p.decide(host)[0], "allow")
        self.assertEqual(domain("BÜCHER.example."), "xn--bcher-kva.example")

    def test_reject_bad_rules(self):
        for value in ("*.example.com", "https://example.com", "com", "", "127.0.0.1", "a..com", "a.com..", " a.com", "a" * 64 + ".com"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                domain(value)

    def test_precedence_and_exception(self):
        self.data["allow"] = ["sub.adult.example"]
        self.data["custom"] += ["private.sub.adult.example", "www.google.com"]
        self.write()
        p = Policy.load(self.path)
        self.assertEqual(p.decide("sub.adult.example")[0], "allow")
        self.assertEqual(p.decide("private.sub.adult.example")[0], "block")
        self.assertEqual(p.decide("www.google.com")[0], "block")

    def test_reject_allow_overlap_with_safesearch(self):
        self.data["allow"] = ["google.com"]
        self.write()
        with self.assertRaises(ValueError):
            Policy.load(self.path)

    def test_reload_last_good_and_restart(self):
        store = PolicyStore(self.path)
        original = store.snapshot()
        self.path.write_text("broken")
        with self.assertRaises(ValueError):
            store.reload()
        self.assertIs(store.snapshot(), original)
        self.data["custom"].append("github.com")
        self.write()
        store.reload()
        self.assertEqual(store.snapshot().decide("github.com")[0], "block")
        self.assertEqual(PolicyStore(self.path).snapshot().digest, store.snapshot().digest)

    def test_reject_schema_duplicate_and_cycle(self):
        for raw in ('{}', '{"adult":[],"adult":[]}', '[]'):
            self.path.write_text(raw)
            with self.assertRaises(ValueError):
                Policy.load(self.path)
        self.data["safesearch"]["forcesafesearch.google.com"] = "www.google.com"
        self.write()
        with self.assertRaises(ValueError):
            Policy.load(self.path)

    def test_atomic_custom_list_import_and_failure(self):
        domains = self.path.with_suffix(".txt")
        domains.write_text("# custom list\n*.New.example\nnew.example\nBÜCHER.example\n")
        replace_domain_list(self.path, domains, "custom")
        p = Policy.load(self.path)
        self.assertEqual(p.custom, {"new.example", "xn--bcher-kva.example"})
        self.assertEqual(p.decide("sub.new.example")[0], "block")
        self.assertEqual(p.adult, frozenset(self.data["adult"]))
        original = self.path.read_bytes()
        for text in ("", "<html>bad download</html>", "0.0.0.0 adult.example"):
            domains.write_text(text)
            with self.assertRaises(ValueError):
                replace_domain_list(self.path, domains, "custom")
            self.assertEqual(self.path.read_bytes(), original)

    def test_adult_import(self):
        domains = self.path.with_suffix(".txt")
        domains.write_text("new-adult.example\n")
        replace_domain_list(self.path, domains, "adult")
        p = Policy.load(self.path)
        self.assertEqual(p.decide("new-adult.example")[0], "block")
        self.assertEqual(p.custom, frozenset(self.data["custom"]))


class NetworkTests(PolicySetup):
    def setUp(self):
        super().setUp()
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.fixture = Fixture()
        self.upstream_port = self.stack.enter_context(serve(self.fixture))
        self.store = PolicyStore(self.path)
        self.resolver = Resolver(self.store, Upstream("127.0.0.1", self.upstream_port, timeout=0.3))
        self.port = self.stack.enter_context(serve(self.resolver))

    def ask(self, name, qtype="A", tcp=False, query=None, port=None):
        query = query or DNSRecord.question(name, qtype)
        packet = query.send("127.0.0.1", port or self.port, tcp=tcp, timeout=2)
        response = DNSRecord.parse(packet)
        self.assertEqual(response.header.id, query.header.id)
        return response

    def test_block_all_record_types_udp_tcp(self):
        for host in ("adult.example", "sub.adult.example", "pornhub.com", "blocked.example"):
            for kind in ("A", "AAAA", "HTTPS", "SVCB", "TXT"):
                for tcp in (False, True):
                    with self.subTest(host=host, kind=kind, tcp=tcp):
                        self.assertEqual(self.ask(host, kind, tcp).header.rcode, RCODE.NXDOMAIN)
        self.assertEqual(self.fixture.calls, [])  # blocked domains never leave loopback filter

    def test_safesearch_all_mappings_ipv4_ipv6(self):
        for host, target in self.data["safesearch"].items():
            for kind in ("A", "AAAA"):
                for tcp in (False, True):
                    response = self.ask(host, kind, tcp)
                    self.assertEqual(response.header.rcode, 0)
                    self.assertEqual(str(response.rr[0].rdata), target + ".")
                    self.assertEqual(response.rr[1].rtype, getattr(QTYPE, kind))
                    self.assertFalse(response.header.ad)
        self.assertFalse(any(name in {h + "." for h in self.data["safesearch"]} for name, _, _ in self.fixture.calls))

    def test_safe_failure_does_not_forward_normal_search(self):
        self.fixture.safe_fail = True
        self.assertEqual(self.ask("www.google.com").header.rcode, RCODE.SERVFAIL)
        self.assertEqual([call[0] for call in self.fixture.calls], ["forcesafesearch.google.com."])

    def test_safe_no_ipv6_is_nodata_not_unsafe_fallback(self):
        self.data["safesearch"]["search.example"] = "no-v6.example"
        self.write()
        self.store.reload()
        response = self.ask("search.example", "AAAA")
        self.assertEqual(response.header.rcode, 0)
        self.assertEqual([rr.rtype for rr in response.rr], [QTYPE.CNAME])

    def test_suppress_safe_https_svcb_and_no_ad(self):
        for kind in ("HTTPS", "SVCB", "TXT"):
            query = DNSRecord.question("www.google.com", kind)
            query.header.ad = 1
            query.add_ar(EDNS0(flags="do", udp_len=1232))
            response = self.ask("", query=query)
            self.assertFalse(response.rr)
            self.assertFalse(response.ar)
            self.assertFalse(response.header.ad)
        self.assertFalse(self.fixture.calls)

    def test_cname_cloaking_blocked_and_safe_alias(self):
        self.assertEqual(self.ask("alias.example").header.rcode, RCODE.NXDOMAIN)
        self.assertEqual(self.ask("search-alias.example").header.rcode, RCODE.SERVFAIL)

    def test_developer_domain_forwarding(self):
        for host in ("github.com", "api.github.com", "registry.npmjs.org", "pypi.org", "registry-1.docker.io", "localhost", "db.internal", "_postgresql._tcp.dev.example"):
            for kind in ("A", "AAAA", "TXT"):
                response = self.ask(host, kind)
                self.assertEqual(response.header.rcode, 0)
                self.assertEqual(response.rr[0].rtype, getattr(QTYPE, kind))

    def test_edns_fresh_packets(self):
        for host in ("adult.example", "www.google.com"):
            query = DNSRecord.question(host)
            query.header.ad = 1
            query.add_ar(EDNS0(flags="do", udp_len=1232))
            response = self.ask("", query=query)
            self.assertEqual(response.header.ar, len(response.ar))
            self.assertFalse(response.header.ad)

    def test_upstream_truncation_retries_tcp(self):
        self.fixture.truncate = True
        self.assertEqual(self.ask("github.com").header.rcode, 0)
        self.assertEqual([x[2] for x in self.fixture.calls], [False, True])

    def test_large_answer_client_retries_tcp(self):
        response = self.ask("large.example", "TXT")
        self.assertTrue(response.header.tc)
        self.assertFalse(response.rr)
        response = self.ask("large.example", "TXT", tcp=True)
        self.assertEqual(len(response.rr), 6)
        self.assertFalse(response.header.tc)

    def test_timeout_returns_servfail(self):
        # A bound socket that intentionally never replies.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(("127.0.0.1", 0))
            resolver = Resolver(self.store, Upstream("127.0.0.1", sock.getsockname()[1], timeout=0.02))
            query = DNSRecord.question("www.google.com")
            self.assertEqual(DNSRecord.parse(resolver.handle(query.pack())).header.rcode, RCODE.SERVFAIL)

    def test_invalid_packets_and_multi_question(self):
        packets = [b"", b"\x12\x34", b"\x00" * 12, b"\x00" * 12 + b"\xc0\x0c"]
        query = DNSRecord.question("github.com")
        query.add_question(DNSQuestion("adult.example"))
        packets.append(query.pack())
        for packet in packets:
            self.assertEqual(DNSRecord.parse(self.resolver.handle(packet)).header.rcode, RCODE.FORMERR)

    def test_no_query_logging(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.ask("adult.example")
            self.ask("github.com")
        self.assertEqual(output.getvalue(), "")

    def test_alternate_dns_bypasses_filter(self):
        self.assertEqual(self.ask("adult.example").header.rcode, RCODE.NXDOMAIN)
        self.assertEqual(self.ask("adult.example", port=self.upstream_port).header.rcode, 0)

    def test_concurrent_requests(self):
        hosts = ["adult.example", "github.com", "www.google.com"] * 8
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            answers = list(pool.map(self.ask, hosts))
        self.assertEqual([a.header.rcode for a in answers], [3, 0, 0] * 8)

    def test_ipv6_listener_and_upstream(self):
        # Failing to bind IPv6 is reported as a failure, never silently skipped.
        with serve(self.fixture, address="::1") as port:
            resolver = Resolver(self.store, Upstream("::1", port))
            with serve(resolver, address="::1") as filter_port:
                with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sock:
                    sock.settimeout(2)
                    sock.connect(("::1", filter_port))
                    sock.send(DNSRecord.question("www.google.com", "AAAA").pack())
                    response = DNSRecord.parse(sock.recv(65535))
                self.assertEqual(response.rr[1].rtype, QTYPE.AAAA)

    def test_loopback_and_port_guards(self):
        for address, port in (("0.0.0.0", 1053), ("127.0.0.1", 53), ("::", 1053)):
            with self.assertRaises(ValueError), serve(self.resolver, port, address):
                pass

    def test_process_restart_and_sighup(self):
        def start():
            proc = subprocess.Popen([sys.executable, "-m", "clearpath.dns", "--policy", str(self.path), "--upstream", "127.0.0.1", "--upstream-port", str(self.upstream_port), "--port", "0"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.addCleanup(lambda: proc.poll() is None and proc.kill())
            line = proc.stdout.readline()
            self.assertTrue(line.startswith("Isolated DNS"), line)
            return proc, int(line.split(";")[0].rsplit(":", 1)[1])

        proc, port = start()
        try:
            self.assertEqual(self.ask("blocked.example", port=port).header.rcode, 3)
            self.data["custom"].append("github.com")
            self.write()
            proc.send_signal(signal.SIGHUP)
            self.assertEqual(proc.stdout.readline().strip(), "Policy reloaded")
            self.assertEqual(self.ask("github.com", port=port).header.rcode, 3)
            self.path.write_text("invalid")
            proc.send_signal(signal.SIGHUP)
            self.assertIn("previous policy retained", proc.stdout.readline())
            self.assertEqual(self.ask("github.com", port=port).header.rcode, 3)
        finally:
            proc.terminate()
            stdout, stderr = proc.communicate(timeout=4)
        self.assertEqual(proc.returncode, 0, stderr)
        self.assertNotIn("github.com", stdout + stderr)
        self.write()
        proc, port = start()
        try:
            self.assertEqual(self.ask("github.com", port=port).header.rcode, 3)
        finally:
            proc.terminate()
            proc.communicate(timeout=4)


class UpstreamValidationTests(unittest.TestCase):
    def test_mismatched_reply_rejected(self):
        class WrongFixture(Fixture):
            def handle(self, packet, tcp=False):
                out = DNSRecord.parse(super().handle(packet, tcp))
                out.header.id ^= 1
                return out.pack()
        with serve(WrongFixture()) as port:
            with self.assertRaises(ValueError):
                Upstream("127.0.0.1", port).exchange(DNSRecord.question("example.com"))

    def test_partial_tcp_frame(self):
        left, right = socket.socketpair()
        with left, right:
            right.sendall(b"a")
            right.shutdown(socket.SHUT_WR)
            with self.assertRaises(OSError):
                read_exact(left, 2)


if __name__ == "__main__":
    unittest.main()
