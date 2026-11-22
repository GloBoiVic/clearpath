// vm-click: click, or double-click, at a screen point in the guest.
// Usage: vm-click [--double] [--dry-run] X Y   (points, not pixels)
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var double = false
var dryRun = false
var numbers: [Double] = []
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--double": double = true
    case "--dry-run": dryRun = true
    default:
        guard let value = Double(argument), value >= 0 else { fail("Usage: vm-click [--double] [--dry-run] X Y") }
        numbers.append(value)
    }
}
guard numbers.count == 2 else { fail("Usage: vm-click [--double] [--dry-run] X Y") }
let point = CGPoint(x: numbers[0], y: numbers[1])

func post(_ type: CGEventType, clickState: Int64) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
        fail("Could not create a mouse event")
    }
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    event.post(tap: .cghidEventTap)
}

if dryRun {
    print("move to \(point.x) \(point.y), \(double ? "double-click" : "click")")
    exit(0)
}
// System Settings sheets ignore a click that arrives without a prior move and a short pause.
post(.mouseMoved, clickState: 0)
usleep(200_000)
for state: Int64 in double ? [1, 2] : [1] {
    post(.leftMouseDown, clickState: state)
    post(.leftMouseUp, clickState: state)
    usleep(50_000)
}
