"""Compile two reviewed upstream helpers only; no daemon, installer, or network changes.

Usage: .venv/bin/python scripts/audit_upstream.py /path/to/audited/repository
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from dnslib import DNSRecord, EDNS0, QTYPE


EXPECTED = "7bf0c4718941a716f8be68a79736a9c4f8543a3a"
repo = Path(sys.argv[1]).resolve()
commit = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
if commit != EXPECTED:
    raise SystemExit("Audit harness requires the documented commit")
query = DNSRecord.question("www.google.com", "AAAA")
query.header.ad = 1
query.add_ar(EDNS0(flags="do", udp_len=1232))
swift = '''import Foundation
let packet: [UInt8] = PACKET
let safe = DNSMessage.aRecordResponse(for: packet, address: (192, 0, 2, 1))
let blocked = DNSMessage.nxdomainResponse(for: packet)
print(safe.map { String(format: "%02x", $0) }.joined())
print(blocked.map { String(format: "%02x", $0) }.joined())
let trie = DomainTrie()
trie.insert("adult.example")
print(trie.isBlocked("sub.adult.example"), trie.isBlocked("notadult.example"))
'''.replace("PACKET", str(list(query.pack())))
with tempfile.TemporaryDirectory(prefix="clearpath-upstream-") as tmp:
    root = Path(tmp)
    (root / "main.swift").write_text(swift)
    sources = repo / "macos/Sources/dfdaemon"
    subprocess.run(["swiftc", "-module-cache-path", str(root / "cache"), str(sources / "DNSMessage.swift"), str(sources / "DomainTrie.swift"), str(root / "main.swift"), "-o", str(root / "probe")], check=True)
    lines = subprocess.check_output([str(root / "probe")], text=True).splitlines()
safe, blocked = (DNSRecord.parse(bytes.fromhex(line)) for line in lines[:2])
results = {
    "commit": commit,
    "AAAA_query_answer_type": QTYPE[safe.rr[0].rtype],
    "rewrite_preserves_unearned_AD_bit": bool(safe.header.ad),
    "safe_reply_has_uncounted_trailing_bytes": len(bytes.fromhex(lines[0])) > len(safe.pack()),
    "blocked_reply_has_uncounted_trailing_bytes": len(bytes.fromhex(lines[1])) > len(blocked.pack()),
    "trie_subdomain_and_near_miss": lines[2],
}
print(json.dumps(results, indent=2))
assert results["AAAA_query_answer_type"] == "A"
assert results["rewrite_preserves_unearned_AD_bit"]
assert results["safe_reply_has_uncounted_trailing_bytes"]
assert results["blocked_reply_has_uncounted_trailing_bytes"]
assert lines[2] == "true false"
