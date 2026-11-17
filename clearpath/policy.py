"""Validated, immutable policy snapshots. No browsing history or network I/O."""
import argparse
import hashlib
import ipaddress
import json
import os
import re
import threading
import tempfile
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType


def domain(value):
    if not isinstance(value, str) or value != value.strip():
        raise ValueError("expected a domain without surrounding whitespace")
    value = value.removesuffix(".").lower()
    try:
        value = value.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise ValueError("invalid IDN") from exc
    if len(value) > 253 or "." not in value:
        raise ValueError("expected a qualified domain")
    if any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x)
           for x in value.split(".")):
        raise ValueError("invalid domain label")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return value
    raise ValueError("IP literals are not domain rules")


def matches(name, rules):
    labels = name.split(".")
    return any(".".join(labels[i:]) in rules for i in range(len(labels)))


@dataclass(frozen=True)
class Policy:
    adult: frozenset
    custom: frozenset
    allow: frozenset
    safesearch: object
    digest: str

    @classmethod
    def load(cls, path):
        raw = Path(path).read_bytes()
        if len(raw) > 16 * 1024 * 1024:
            raise ValueError("policy exceeds prototype size limit")

        def unique(pairs):
            out = {}
            for key, value in pairs:
                if key in out:
                    raise ValueError("duplicate JSON key")
                out[key] = value
            return out

        data = json.loads(raw, object_pairs_hook=unique)
        if not isinstance(data, dict) or set(data) != {"adult", "custom", "allow", "safesearch"}:
            raise ValueError("expected adult, custom, allow and safesearch keys")
        lists = []
        for key in ("adult", "custom", "allow"):
            if not isinstance(data[key], list):
                raise ValueError("rule sets must be lists")
            lists.append(frozenset(domain(x) for x in data[key]))
        if not isinstance(data["safesearch"], dict):
            raise ValueError("safesearch must be a mapping")
        safe = {domain(k): domain(v) for k, v in data["safesearch"].items()}
        if len(safe) != len(data["safesearch"]) or set(safe) & set(safe.values()):
            raise ValueError("duplicate normalized hosts or recursive SafeSearch targets")
        # An override must never permit the ordinary version of a search hostname.
        if any(matches(host, lists[2]) for host in safe):
            raise ValueError("allow rule overlaps SafeSearch")
        return cls(*lists, MappingProxyType(safe), hashlib.sha256(raw).hexdigest())

    def decide(self, name):
        name = domain(name)
        # Explicit custom blocks win, even over exceptions and SafeSearch.
        if matches(name, self.custom):
            return "block", None
        if name in self.safesearch:
            return "safe", self.safesearch[name]
        if matches(name, self.allow):
            return "allow", None
        return ("block", None) if matches(name, self.adult) else ("allow", None)


class PolicyStore:
    def __init__(self, path):
        self.path = Path(path)
        self._lock = threading.Lock()
        self._policy = Policy.load(path)

    def snapshot(self):
        with self._lock:
            return self._policy

    def reload(self):
        candidate = Policy.load(self.path)  # failure leaves current policy intact
        with self._lock:
            self._policy = candidate
        return candidate.digest


def replace_domain_list(policy_path, list_path, category):
    """Validate an entire candidate then atomically replace one local policy file.

    Input is domain-only (not hosts/adblock format). This deliberately performs
    no downloading and does not signal any running process automatically.
    """
    if category not in ("adult", "custom"):
        raise ValueError("only adult or custom imports are supported")
    policy_path = Path(policy_path)
    Policy.load(policy_path)
    data = json.loads(policy_path.read_bytes())
    text = Path(list_path).read_text(encoding="utf-8")
    if len(text) > 16 * 1024 * 1024:
        raise ValueError("list exceeds prototype size limit")
    names = set()
    for line in text.splitlines():
        line = line.partition("#")[0].strip()
        if line:
            names.add(domain(line.removeprefix("*.")))
    if not names:
        raise ValueError("refusing empty import; edit JSON explicitly to clear a list")
    data[category] = sorted(names)
    candidate_path = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=policy_path.parent, prefix=".policy-", delete=False) as out:
            candidate_path = Path(out.name)
            json.dump(data, out, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        candidate = Policy.load(candidate_path)
        os.replace(candidate_path, policy_path)
        return candidate.digest
    finally:
        if candidate_path is not None:
            candidate_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description="Validate a local policy or atomically import a domain list")
    parser.add_argument("policy")
    parser.add_argument("--import-list")
    parser.add_argument("--category", choices=("adult", "custom"), default="custom")
    args = parser.parse_args()
    if args.import_list:
        digest = replace_domain_list(args.policy, args.import_list, args.category)
    else:
        digest = Policy.load(args.policy).digest
    print(f"Valid policy SHA256 {digest}")


if __name__ == "__main__":
    main()
