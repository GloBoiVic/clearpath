// vm-ocr: read a screenshot on the host and print each text line with its centre point, to find click targets.
// Usage: vm-ocr [--scale N] [--find TEXT] IMAGE.png
// Output: "X<TAB>Y<TAB>text", top to bottom. X and Y are image pixels divided by N (default 2, the guest's scale),
// so for a window capture they are points inside the window. Add the origin from vm-windowid for screen points.
// With --find, prints only lines containing TEXT (ignoring case) and exits 1 when none match.
import Foundation
import ImageIO
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
let usage = "Usage: vm-ocr [--scale N] [--find TEXT] IMAGE.png"

var scale = 2.0
var find: String?
var path: String?
var rest = CommandLine.arguments.dropFirst()
while let argument = rest.popFirst() {
    switch argument {
    case "--scale":
        guard let value = rest.popFirst().flatMap({ Double($0) }), value > 0 else { fail(usage) }
        scale = value
    case "--find":
        guard let value = rest.popFirst() else { fail(usage) }
        find = value.lowercased()
    default:
        guard path == nil else { fail(usage) }
        path = argument
    }
}
guard let path else { fail(usage) }
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Could not read \(path) as an image") }

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { fail("OCR failed: \(error)") }

let width = Double(image.width)
let height = Double(image.height)
var lines: [(x: Double, y: Double, text: String)] = []
for observation in request.results ?? [] {
    guard let text = observation.topCandidates(1).first?.string else { continue }
    // Vision boxes are normalized with the origin at the bottom left.
    let box = observation.boundingBox
    lines.append((box.midX * width / scale, (1 - box.midY) * height / scale, text))
}
lines.sort { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
var matched = false
for line in lines where find == nil || line.text.lowercased().contains(find!) {
    matched = true
    print("\(Int(line.x.rounded()))\t\(Int(line.y.rounded()))\t\(line.text)")
}
exit(find == nil || matched ? 0 : 1)
