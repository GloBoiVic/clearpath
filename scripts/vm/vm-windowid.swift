// vm-windowid: print the front-most window of an app as "ID X Y WIDTH HEIGHT" (points), for screencapture -l.
// Usage: vm-windowid APP [TITLE-SUBSTRING]   Exits 1 when no window matches.
import CoreGraphics
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard (1...2).contains(arguments.count) else {
    FileHandle.standardError.write(Data("Usage: vm-windowid APP [TITLE-SUBSTRING]\n".utf8))
    exit(2)
}
let app = arguments[0].lowercased()
let title = arguments.count == 2 ? arguments[1].lowercased() : nil

// Front to back. Layer 0 is ordinary windows; menu bar items and banners sit on other layers.
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list {
    guard (window[kCGWindowOwnerName as String] as? String)?.lowercased() == app,
          window[kCGWindowLayer as String] as? Int == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double] else { continue }
    if let title, !((window[kCGWindowName as String] as? String)?.lowercased().contains(title) ?? false) { continue }
    print(id, Int(bounds["X"] ?? 0), Int(bounds["Y"] ?? 0), Int(bounds["Width"] ?? 0), Int(bounds["Height"] ?? 0))
    exit(0)
}
FileHandle.standardError.write(Data("No on-screen window for \(arguments[0])\n".utf8))
exit(1)
