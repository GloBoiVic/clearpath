"""Tests of the disposable-VM helpers in scripts/vm.

The guest helpers are run only with --dry-run or with bad input, so no test posts a
mouse or key event to this Mac. The OCR helper runs on an image the test draws in a
temp folder. The DNS fixture runs on loopback high ports with a fixed loopback target.
Nothing here starts a VM or touches DNS, profiles or credentials.
"""
import os
from pathlib import Path
import platform
import pty
import socket
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "artifacts" / "vm-tools"
CACHE = ROOT / "artifacts" / "swift-module-cache"

DRAWING = """
import AppKit
let w = 800, h = 400
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
("Clearpath Settings" as NSString).draw(at: NSPoint(x: 100, y: 300), withAttributes: attributes)
("Install" as NSString).draw(at: NSPoint(x: 100, y: 100), withAttributes: attributes)
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
CGImageDestinationFinalize(destination)
"""


def run(tool, *args, stdin=None):
    return subprocess.run([str(TOOLS / tool), *args], input=stdin, capture_output=True, text=True, timeout=60)


class VMHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        env = dict(os.environ, VM_ARCH=platform.machine())
        built = subprocess.run([str(ROOT / "scripts" / "vm" / "build.sh")], env=env, capture_output=True, text=True)
        if built.returncode != 0:
            raise RuntimeError("scripts/vm/build.sh failed:\n" + built.stdout[-4000:] + built.stderr[-4000:])

    def test_click_and_double_click_report_the_point_without_posting_events(self):
        self.assertEqual(run("vm-click", "--dry-run", "512", "384").stdout, "move to 512.0 384.0, click\n")
        self.assertEqual(run("vm-click", "--dry-run", "--double", "10", "20").stdout, "move to 10.0 20.0, double-click\n")

    def test_click_refuses_a_missing_or_negative_point(self):
        for args in (["--dry-run"], ["--dry-run", "5"], ["--dry-run", "-5", "5"], ["--dry-run", "a", "b"], ["--bogus", "1", "2"]):
            result = run("vm-click", *args)
            self.assertEqual(result.returncode, 2, args)
            self.assertEqual(result.stdout, "")

    def test_key_press_maps_names_and_modifiers(self):
        self.assertEqual(run("vm-key", "--dry-run", "cmd+shift+4").stdout, "key 4 code 21 modifiers cmd+shift\n")
        self.assertEqual(run("vm-key", "--dry-run", "return").stdout, "key return code 36 modifiers \n")

    def test_key_press_refuses_unknown_keys_and_modifiers(self):
        for combo in ("hyper+a", "cmd+banana", ""):
            self.assertEqual(run("vm-key", "--dry-run", combo).returncode, 2, combo)

    def test_typed_text_comes_only_from_stdin_and_is_never_printed(self):
        result = run("vm-typepw", "--dry-run", "--return", stdin="lab-secret-123\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "would type 14 characters and press return\n")
        self.assertNotIn("lab-secret", result.stdout + result.stderr)

    def test_typed_text_refuses_an_argument_empty_stdin_and_a_terminal(self):
        result = run("vm-typepw", "--dry-run", "lab-secret-123", stdin="x\n")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("lab-secret", result.stdout + result.stderr)
        self.assertEqual(run("vm-typepw", "--dry-run", stdin="").returncode, 2)
        self.assertEqual(run("vm-typepw", "--dry-run", stdin="\n").returncode, 2)
        master, slave = pty.openpty()
        try:
            terminal = subprocess.run([str(TOOLS / "vm-typepw"), "--dry-run"], stdin=slave, capture_output=True, text=True, timeout=60)
        finally:
            os.close(master)
            os.close(slave)
        self.assertEqual(terminal.returncode, 2)
        self.assertIn("pipe", terminal.stderr)

    def test_window_lookup_fails_clearly_when_the_app_has_no_window(self):
        result = run("vm-windowid", "Clearpath No Such App")
        self.assertEqual(result.returncode, 1)
        self.assertIn("No on-screen window", result.stderr)
        self.assertEqual(run("vm-windowid").returncode, 2)

    def test_ocr_prints_the_centre_of_each_line_and_can_find_one(self):
        with tempfile.TemporaryDirectory() as folder:
            script, image = Path(folder) / "draw.swift", Path(folder) / "shot.png"
            script.write_text(DRAWING)
            drawn = subprocess.run(["swiftc", "-module-cache-path", str(CACHE), str(script), "-o", str(Path(folder) / "draw")],
                                   capture_output=True, text=True)
            self.assertEqual(drawn.returncode, 0, drawn.stderr[-2000:])
            subprocess.run([str(Path(folder) / "draw"), str(image)], check=True, timeout=60)

            full = run("vm-ocr", "--scale", "1", str(image))
            self.assertEqual(full.returncode, 0, full.stderr)
            rows = [line.split("\t") for line in full.stdout.splitlines()]
            self.assertEqual([row[2] for row in rows], ["Clearpath Settings", "Install"])  # top to bottom

            found = run("vm-ocr", "--scale", "1", "--find", "INSTALL", str(image))
            self.assertEqual(found.returncode, 0)
            x, y, text = found.stdout.strip().split("\t")
            self.assertEqual(text, "Install")
            self.assertTrue(100 < int(x) < 300 and abs(int(y) - 270) < 30, (x, y))  # drawn 100 points from the bottom edge

            halved = run("vm-ocr", "--scale", "2", "--find", "install", str(image)).stdout.split("\t")
            self.assertLessEqual(abs(int(halved[0]) - int(x) / 2), 1)
            self.assertLessEqual(abs(int(halved[1]) - int(y) / 2), 1)

            self.assertEqual(run("vm-ocr", "--find", "no such words", str(image)).returncode, 1)
            self.assertEqual(run("vm-ocr", str(Path(folder) / "missing.png")).returncode, 2)

    def test_dns_fixture_answers_and_the_vpn_stand_in_answers_its_suffix_and_forwards_the_rest(self):
        from dnslib import DNSRecord

        def start(*args):
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            proc = subprocess.Popen([str(TOOLS / "vm-dns-fixture"), args[0], "127.0.0.1", str(port), *args[1:]],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.addCleanup(proc.wait, 5)
            self.addCleanup(proc.kill)
            self.assertIn("fixture on 127.0.0.1", proc.stdout.readline())
            return proc, port

        def ask(port, name, qtype="A"):
            response = DNSRecord.parse(DNSRecord.question(name, qtype).send("127.0.0.1", port, timeout=3))
            return response.header.rcode, [str(rr.rdata) for rr in response.rr]

        router, router_port = start("answer")
        vpn, vpn_port = start("vpn", "tailnet.example", "127.0.0.1", str(router_port))
        self.assertEqual(ask(router_port, "allowed.example"), (0, ["192.0.2.42"]))
        self.assertEqual(ask(router_port, "allowed.example", "AAAA"), (0, []))
        self.assertEqual(ask(vpn_port, "host.tailnet.example"), (0, ["100.64.0.7"]))
        self.assertEqual(ask(vpn_port, "other.example"), (0, ["192.0.2.42"]))
        self.assertEqual(vpn.stdout.readline().strip(), "vpn host.tailnet.example 1")
        self.assertEqual(vpn.stdout.readline().strip(), "vpn other.example 1 via 127.0.0.1")
        self.assertEqual(run("vm-dns-fixture", "vpn", "127.0.0.1", "53").returncode, 2)


if __name__ == "__main__":
    unittest.main()
