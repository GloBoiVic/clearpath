"""Opt-in live DNS and HTTPS HEAD probes; no system/browser settings changed.

No adult site is queried upstream or contacted over HTTP. Names of allowed sites
and forced-safe endpoints are disclosed to the explicitly selected DNS provider.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from dnslib import DNSRecord, QTYPE, RCODE

# Make `python scripts/live_smoke.py` work without an editable installation.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from clearpath.dns import Resolver, Upstream, serve
from clearpath.policy import PolicyStore


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--upstream-port", type=int, default=53)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    resolver = Resolver(PolicyStore(root / "policy.example.json"), Upstream(args.upstream, args.upstream_port))
    results = []
    with serve(resolver) as port:
        for host, kind, tcp in [("adult.example", "A", False), ("pornhub.com", "AAAA", True), ("www.google.com", "A", False), ("www.google.com", "AAAA", False), ("www.bing.com", "A", False), ("duckduckgo.com", "A", False), ("github.com", "A", False), ("registry.npmjs.org", "A", False), ("pypi.org", "A", True), ("registry-1.docker.io", "AAAA", False)]:
            query = DNSRecord.question(host, kind)
            answer = DNSRecord.parse(query.send("127.0.0.1", port, tcp=tcp, timeout=6))
            expected = RCODE.NXDOMAIN if host in ("adult.example", "pornhub.com") else RCODE.NOERROR
            passed = answer.header.rcode == expected
            if expected == RCODE.NXDOMAIN:
                passed = passed and not answer.rr
            else:
                passed = passed and any(rr.rtype == getattr(QTYPE, kind) for rr in answer.rr)
                safe_target = resolver.store.snapshot().safesearch.get(host)
                if safe_target:
                    passed = passed and any(rr.rtype == QTYPE.CNAME and str(rr.rdata) == safe_target + "." for rr in answer.rr)
            results.append({"host": host, "type": kind, "tcp": tcp,
                            "rcode": RCODE[answer.header.rcode],
                            "records": [{"type": QTYPE[rr.rtype], "value": str(rr.rdata)} for rr in answer.rr],
                            "pass": passed})
        # Per-process DNS overrides only; normal certificate validation stays enabled.
        for host, path in [("www.google.com", "/safesearch"), ("github.com", "/"), ("registry.npmjs.org", "/"), ("pypi.org", "/simple/")]:
            query = DNSRecord.question(host)
            answer = DNSRecord.parse(query.send("127.0.0.1", port, timeout=6))
            addresses = [str(rr.rdata) for rr in answer.rr if rr.rtype == QTYPE.A]
            if not addresses:
                results.append({"host": host, "probe": "HTTPS_HEAD", "pass": False, "reason": "no IPv4 answer"})
                continue
            completed = subprocess.run(["curl", "--silent", "--show-error", "--head", "--noproxy", "*", "--max-time", "15", "--resolve", f"{host}:443:{addresses[0]}", "--output", "/dev/null", "--write-out", "%{http_code} %{ssl_verify_result}", f"https://{host}{path}"], capture_output=True, text=True)
            results.append({"host": host, "probe": "HTTPS_HEAD", "http_and_tls": completed.stdout,
                            "pass": completed.returncode == 0 and completed.stdout.endswith(" 0") and not completed.stdout.startswith("000"),
                            "error": completed.stderr.strip()})
    print(json.dumps(results, indent=2))
    return 0 if all(item["pass"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
