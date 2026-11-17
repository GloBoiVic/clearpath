"""Small loopback DNS experiment, deliberately not a production resolver."""
import argparse
import contextlib
import ipaddress
import secrets
import signal
import socket
import socketserver
import struct
import threading

from dnslib import CNAME, DNSHeader, DNSRecord, QTYPE, RCODE, RR
from dnslib.dns import DNSError

from .policy import PolicyStore


def reply(query, code=RCODE.NOERROR):
    # Build fresh flags and sections; never assert DNSSEC authenticity for rewrites.
    return DNSRecord(DNSHeader(id=query.header.id, qr=1, ra=1,
                              rd=query.header.rd, rcode=code), q=query.q)


def read_exact(sock, size):
    parts = bytearray()
    while len(parts) < size:
        part = sock.recv(size - len(parts))
        if not part:
            raise OSError("short TCP frame")
        parts.extend(part)
    return bytes(parts)


class Upstream:
    def __init__(self, address, port=53, timeout=2):
        ip = ipaddress.ip_address(address)  # explicit IP; no recursive OS DNS call
        self.family = socket.AF_INET6 if ip.version == 6 else socket.AF_INET
        if not 1 <= port <= 65535:
            raise ValueError("invalid upstream port")
        self.endpoint = (str(ip), port)
        self.timeout = timeout

    def exchange(self, request, tcp=False):
        # A fresh randomized transaction ID for each upstream transaction.
        outgoing = DNSRecord.parse(request.pack())
        outgoing.header.id = secrets.randbits(16)
        packet = outgoing.pack()
        with socket.socket(self.family, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as sock:
            sock.settimeout(self.timeout)
            sock.connect(self.endpoint)  # UDP only accepts packets from this peer
            if tcp:
                sock.sendall(struct.pack("!H", len(packet)) + packet)
                response = DNSRecord.parse(read_exact(sock, struct.unpack("!H", read_exact(sock, 2))[0]))
            else:
                sock.send(packet)
                response = DNSRecord.parse(sock.recv(65535))
        if (not response.header.qr or response.header.id != outgoing.header.id
                or response.header.opcode != outgoing.header.opcode
                or len(response.questions) != 1 or response.q != outgoing.q):
            raise ValueError("mismatched upstream response")
        if response.header.tc:
            if tcp:
                raise ValueError("truncated TCP response")
            return self.exchange(request, tcp=True)
        response.header.id = request.header.id
        return response


class Resolver:
    def __init__(self, store, upstream):
        self.store = store
        self.upstream = upstream

    def resolve(self, query, tcp=False):
        if query.header.qr or query.header.opcode or len(query.questions) != 1:
            return DNSRecord(DNSHeader(id=query.header.id, qr=1, rcode=RCODE.FORMERR))
        if query.q.qclass != 1:
            return reply(query, RCODE.REFUSED)
        policy = self.store.snapshot()  # exactly one generation per query
        try:
            name = str(query.q.qname).rstrip(".").lower()
            # DNS-SD/localhost/single-label names are forwarded without hostname-rule parsing.
            try:
                action, target = policy.decide(name)
            except ValueError:
                action, target = "allow", None
            if action == "block":
                return reply(query, RCODE.NXDOMAIN)
            if action == "safe":
                out = reply(query)
                # Suppress HTTPS/SVCB address hints and other alternate routing records.
                if query.q.qtype not in (QTYPE.A, QTYPE.AAAA, QTYPE.CNAME):
                    return out
                out.add_answer(RR(query.q.qname, QTYPE.CNAME, ttl=60, rdata=CNAME(target)))
                if query.q.qtype == QTYPE.CNAME:
                    return out
                safe_query = DNSRecord.question(target, QTYPE[query.q.qtype])
                safe_response = self.upstream.exchange(safe_query, tcp=tcp)
                if safe_response.header.rcode != RCODE.NOERROR:
                    return reply(query, RCODE.SERVFAIL)
                # Only copy records on the target's CNAME chain; no unrelated address hints.
                relevant = {target + "."}
                for _ in range(16):
                    before = len(relevant)
                    for rr in safe_response.rr:
                        if str(rr.rname).lower() in relevant and rr.rtype == QTYPE.CNAME:
                            relevant.add(str(rr.rdata).lower())
                    if len(relevant) == before:
                        break
                for rr in safe_response.rr:
                    if str(rr.rname).lower() in relevant and rr.rtype in (query.q.qtype, QTYPE.CNAME):
                        out.add_answer(rr)
                return out
            response = self.upstream.exchange(query, tcp=tcp)
            # Known-blocked aliases cannot smuggle an allowed name onto a blocked destination.
            for rr in response.rr:
                if rr.rtype == QTYPE.CNAME:
                    try:
                        alias_action, _ = policy.decide(str(rr.rdata))
                    except ValueError:
                        continue
                    if alias_action == "block":
                        return reply(query, RCODE.NXDOMAIN)
                    if alias_action == "safe":
                        return reply(query, RCODE.SERVFAIL)  # don't forward unsafe cached IPs
            return response
        except (OSError, ValueError, DNSError):
            return reply(query, RCODE.SERVFAIL)  # never retry the unfiltered search hostname

    def handle(self, packet, tcp=False):
        try:
            query = DNSRecord.parse(packet)
        except (DNSError, ValueError):
            txid = int.from_bytes(packet[:2], "big") if len(packet) >= 2 else 0
            return DNSRecord(DNSHeader(id=txid, qr=1, rcode=RCODE.FORMERR)).pack()
        response = self.resolve(query, tcp)
        packed = response.pack()
        limit = 512
        for rr in query.ar:
            if rr.rtype == QTYPE.OPT:
                limit = max(512, min(rr.rclass, 1232))
        if not tcp and len(packed) > limit:
            response = reply(query)
            response.header.tc = 1
            return response.pack()
        return packed


class BoundedThreads(socketserver.ThreadingMixIn):
    daemon_threads = True
    allow_reuse_address = True

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        pass  # no client addresses, query names or tracebacks in logs


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        sock.sendto(self.server.resolver.handle(packet), self.client_address)


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        # One message per connection is enough for this experiment.
        size = struct.unpack("!H", read_exact(self.request, 2))[0]
        packet = read_exact(self.request, size)
        answer = self.server.resolver.handle(packet, tcp=True)
        self.request.sendall(struct.pack("!H", len(answer)) + answer)


class UDPServer(BoundedThreads, socketserver.UDPServer):
    max_packet_size = 65535


class TCPServer(BoundedThreads, socketserver.TCPServer):
    pass


@contextlib.contextmanager
def serve(resolver, port=0, address="127.0.0.1"):
    if address not in ("127.0.0.1", "::1") or (port != 0 and not 1024 <= port <= 65535):
        raise ValueError("prototype requires loopback and an unprivileged port")
    family = socket.AF_INET6 if address == "::1" else socket.AF_INET
    udp_cls = type("LocalUDP", (UDPServer,), {"address_family": family})
    tcp_cls = type("LocalTCP", (TCPServer,), {"address_family": family})
    slots = threading.BoundedSemaphore(32)
    with udp_cls((address, port), UDPHandler) as udp:
        actual_port = udp.server_address[1]
        with tcp_cls((address, actual_port), TCPHandler) as tcp:
            threads = []
            for server in (udp, tcp):
                server.slots = slots
                server.resolver = resolver
                thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
                thread.start()
                threads.append(thread)
            try:
                yield actual_port
            finally:
                for server in (udp, tcp):
                    server.shutdown()
                for thread in threads:
                    thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", default="policy.example.json")
    parser.add_argument("--upstream", required=True, help="explicit DNS server IP; never auto-changes macOS DNS")
    parser.add_argument("--upstream-port", type=int, default=53)
    parser.add_argument("--port", type=int, default=1053)
    parser.add_argument("--listen", choices=("127.0.0.1", "::1"), default="127.0.0.1")
    args = parser.parse_args()
    store = PolicyStore(args.policy)
    resolver = Resolver(store, Upstream(args.upstream, args.upstream_port))
    if ipaddress.ip_address(args.upstream).is_loopback and args.upstream_port == args.port:
        parser.error("upstream must not point back to this listener")
    stop = threading.Event()
    reload_requested = threading.Event()

    def reload_policy(*_):
        try:
            store.reload()
            print("Policy reloaded", flush=True)
        except (OSError, ValueError):
            print("Reload rejected; previous policy retained", flush=True)

    signal.signal(signal.SIGHUP, lambda *_: reload_requested.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    with serve(resolver, args.port, args.listen) as port:
        print(f"Isolated DNS on {args.listen}:{port}; policy SHA256 {store.snapshot().digest}", flush=True)
        while not stop.wait(0.1):
            if reload_requested.is_set():
                reload_requested.clear()
                reload_policy()


if __name__ == "__main__":
    main()
