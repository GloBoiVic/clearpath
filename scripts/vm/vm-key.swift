// vm-key: press one key, with optional modifiers, in the guest.
// Usage: vm-key [--dry-run] [cmd+][shift+][option+][ctrl+]KEY   e.g. vm-key cmd+shift+4, vm-key return
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let codes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
]
let modifiers: [String: CGEventFlags] = [
    "cmd": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "ctrl": .maskControl,
]

var dryRun = false
var combo: String?
for argument in CommandLine.arguments.dropFirst() {
    if argument == "--dry-run" { dryRun = true } else if combo == nil { combo = argument.lowercased() } else { combo = "" }
}
guard let combo, !combo.isEmpty else { fail("Usage: vm-key [--dry-run] [cmd+][shift+][option+][ctrl+]KEY") }
var parts = combo.components(separatedBy: "+")
let name = parts.removeLast()
guard let code = codes[name] else { fail("Unknown key '\(name)'. Known: \(codes.keys.sorted().joined(separator: " "))") }
var flags = CGEventFlags()
for part in parts {
    guard let flag = modifiers[part] else { fail("Unknown modifier '\(part)'. Known: cmd shift option ctrl") }
    flags.insert(flag)
}
if dryRun {
    print("key \(name) code \(code) modifiers \(parts.joined(separator: "+"))")
    exit(0)
}
for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("Could not create a key event") }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(50_000)
}
