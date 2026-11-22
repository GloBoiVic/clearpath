// vm-typepw: type one line from stdin into the focused field in the guest. The text is never an argument.
// Usage: printf '%s' "$LAB_PASSWORD" | vm-typepw [--return] [--dry-run]
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var pressReturn = false
var dryRun = false
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--return": pressReturn = true
    case "--dry-run": dryRun = true
    default: fail("vm-typepw takes no text argument. Pipe the lab password on stdin.")
    }
}
guard isatty(0) == 0 else { fail("stdin must be a pipe, not a terminal") }
guard let line = readLine(strippingNewline: true), !line.isEmpty else { fail("stdin was empty") }
if dryRun {
    // Never print the text itself.
    print("would type \(line.count) characters\(pressReturn ? " and press return" : "")")
    exit(0)
}

func key(_ code: CGKeyCode, text: [UniChar]? = nil) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("Could not create a key event") }
        if let text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
        event.post(tap: .cghidEventTap)
    }
    usleep(20_000)
}
for character in line { key(0, text: Array(String(character).utf16)) }
if pressReturn { key(36) }
