"""Explicit live native-core probes, not system-wide interception or browser tests."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from dnslib import DNSRecord, QTYPE

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    results = []
    cases = [("adult.example",1,False),("pornhub.com",28,True),("blocked.example",65,False),
             ("www.google.com",1,False),("www.google.com",28,False),("www.google.com",65,False),
             ("www.bing.com",1,True),("duckduckgo.com",1,False),
             ("github.com",1,False),("registry.npmjs.org",1,False),("pypi.org",1,True),("registry-1.docker.io",28,False)]
    policy = json.loads((ROOT / "policy.example.json").read_text())
    for host,kind,tcp in cases:
        command = [args.binary,"probe",str(ROOT / "policy.example.json"),host,str(kind),args.upstream,"53"]
        if tcp:
            command.append("--tcp")
        completed = subprocess.run(command, capture_output=True, text=True, timeout=15)
        if completed.returncode:
            results.append({"host": host, "type": kind, "pass": False, "error": "native probe process failed"})
            continue
        raw = json.loads(completed.stdout)
        response = DNSRecord.parse(bytes.fromhex(raw["packetHex"]))
        blocked = host in ("adult.example","pornhub.com","blocked.example")
        passed = response.header.rcode == (3 if blocked else 0)
        if blocked or kind == 65:
            passed &= not response.rr
        else:
            passed &= any(rr.rtype == kind for rr in response.rr)
            target = policy["safesearch"].get(host)
            if target:
                passed &= any(rr.rtype == QTYPE.CNAME and str(rr.rdata) == target + "." for rr in response.rr)
        results.append({"host": host, "type": kind, "tcp": tcp, "rcode": response.header.rcode,
                        "records": [{"type": QTYPE[rr.rtype], "value": str(rr.rdata)} for rr in response.rr], "pass": bool(passed)})
    # Ordinary developer HTTPS uses only the returned address in this curl process.
    for host,path in (("www.google.com","/safesearch"),("github.com","/"),("registry.npmjs.org","/"),("pypi.org","/simple/")):
        address = next((rr["value"] for row in results if row["host"] == host and row["type"] == 1 for rr in row.get("records",[]) if rr["type"] == "A"),None)
        if address is None:
            results.append({"host":host,"probe":"HTTPS_HEAD","pass":False}); continue
        completed = subprocess.run(["curl","--silent","--show-error","--head","--noproxy","*","--max-time","15", "--resolve",f"{host}:443:{address}","--output","/dev/null","--write-out","%{http_code} %{ssl_verify_result}",f"https://{host}{path}"],capture_output=True,text=True)
        results.append({"host":host,"probe":"HTTPS_HEAD","http_tls":completed.stdout,
                        "pass":completed.returncode==0 and completed.stdout=="200 0"})
    github_address = next((rr["value"] for row in results if row.get("host") == "github.com" and row.get("type") == 1 for rr in row.get("records",[]) if rr["type"] == "A"),None)
    if github_address:
        completed = subprocess.run(["git","-c",f"http.curloptResolve=github.com:443:{github_address}","-c","credential.helper=", "ls-remote","https://github.com/GloBoiVic/clearpath.git","HEAD"],capture_output=True,text=True,timeout=20)
        results.append({"probe":"GIT_LS_REMOTE","pass":completed.returncode==0 and completed.stdout.strip().endswith("HEAD")})
    report = {"system_configuration_changed":False,"native_extension_activated":False,"results":results}
    Path(args.output).write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({"passed":sum(row["pass"] for row in results),"total":len(results),"extension_activated":False}))
    return 0 if all(row["pass"] for row in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
