// Prints the CGWindowID of the largest on-screen window owned by the named app,
// for `screencapture -l`. Usage: windowid <owner name>
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? ""
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

var best: (id: Int, area: Double)?
for window in windows {
    guard window[kCGWindowOwnerName as String] as? String == owner,
          window[kCGWindowLayer as String] as? Int == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let width = bounds["Width"], let height = bounds["Height"] else { continue }
    if width * height > (best?.area ?? 0) { best = (id, width * height) }
}

if let best {
    print(best.id)
} else {
    FileHandle.standardError.write(Data("No window found for \(owner)\n".utf8))
    exit(1)
}
