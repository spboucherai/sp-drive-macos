// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Scripts/measure-launch.swift
// Description: Measures the cold launch of the development variant: time from process start to its first window on screen (polled every 5 ms through the window server; nothing is captured). The app is stopped after each run.
// Usage: swift Scripts/measure-launch.swift [runs]        (only ever starts and stops "SP Drive Dev")
import CoreGraphics
import Foundation

let bin = NSString(string: "~/Library/Developer/SPDrive/DerivedData/Build/Products/Debug/SP Drive Dev.app/Contents/MacOS/SP Drive Dev").expandingTildeInPath
let runs = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 3 : 3
var results: [Double] = []
for _ in 0..<runs {
    let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = ["-ApplePersistenceIgnoreState", "YES"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    let start = DispatchTime.now()
    try p.run()
    var shown: Double?
    while shown == nil, DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds < 15_000_000_000 {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if list.contains(where: { ($0["kCGWindowOwnerPID"] as? Int32) == p.processIdentifier && ($0["kCGWindowLayer"] as? Int) == 0 && (($0["kCGWindowBounds"] as? [String: Any])?["Width"] as? Double ?? 0) > 300 }) {
            shown = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        } else { usleep(5000) }
    }
    p.terminate(); p.waitUntilExit()
    if let shown { results.append(shown); print(String(format: "first window after %.0f ms", shown)) } else { print("no window within 15 s") }
    sleep(1)
}
if !results.isEmpty { print(String(format: "median %.0f ms over %d runs", results.sorted()[results.count / 2], results.count)) }
