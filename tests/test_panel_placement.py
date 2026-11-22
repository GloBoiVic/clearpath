"""Checks where the menu-bar panel opens, by compiling app/PanelPlacement.swift with a small driver."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

# Screen visible frame 1512 x 945 under a 37 pt menu bar; panel 320 x 360; icon 24 x 37 in the bar.
DRIVER = """
import CoreGraphics
let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
let panel = CGSize(width: 320, height: 360)
func at(_ x: CGFloat) -> CGPoint {
    panelOrigin(icon: CGRect(x: x, y: 945, width: 24, height: 37), panel: panel, screen: screen)
}
for x in [900, 1300, 1490] as [CGFloat] { let p = at(x); print(Int(p.x), Int(p.y)) }
let side = panelOrigin(icon: CGRect(x: 1700, y: 945, width: 24, height: 37), panel: panel,
                       screen: CGRect(x: 1512, y: 0, width: 1512, height: 945))
print(Int(side.x), Int(side.y))
"""


class PanelPlacementTests(unittest.TestCase):
    def setUp(self):
        swiftc = shutil.which("swiftc")
        if swiftc is None:
            raise RuntimeError("swiftc is required: the menu-bar app is part of the shipped product")
        self.work = Path(tempfile.mkdtemp(prefix="clearpath-placement-"))
        self.addCleanup(shutil.rmtree, self.work, ignore_errors=True)
        (self.work / "main.swift").write_text(DRIVER)
        binary = self.work / "placement"
        subprocess.run(
            [swiftc, "-module-cache-path", str(self.work / "cache"),
             str(ROOT / "app" / "PanelPlacement.swift"), str(self.work / "main.swift"), "-o", str(binary)],
            check=True, capture_output=True, timeout=300,
        )
        out = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30).stdout
        self.rows = [tuple(int(n) for n in line.split()) for line in out.splitlines()]

    def test_panel_hangs_below_the_menu_bar_and_extends_right_from_the_icon(self):
        self.assertEqual(self.rows[0], (900, 945 - 360))

    def test_panel_flips_left_when_the_icon_is_near_the_right_edge(self):
        # 1300 + 320 would pass 1512, so the panel's right edge meets the icon's right edge (1324).
        self.assertEqual(self.rows[1], (1324 - 320, 585))

    def test_panel_stays_on_screen_at_the_very_edge(self):
        x, _ = self.rows[2]
        self.assertLessEqual(x + 320, 1512)
        self.assertGreaterEqual(x, 0)

    def test_panel_follows_the_icon_onto_a_second_screen(self):
        self.assertEqual(self.rows[3], (1700, 585))


if __name__ == "__main__":
    unittest.main()
