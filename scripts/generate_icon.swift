import AppKit
import Foundation

// Original vector artwork, rendered to Apple's required opaque 1024 px icon.
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.085, green: 0.065, blue: 0.09, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
let fruit = NSBezierPath(roundedRect: NSRect(x: 142, y: 132, width: 740, height: 690), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(calibratedRed: 1, green: 0.32, blue: 0.30, alpha: 1), ending: NSColor(calibratedRed: 0.83, green: 0.08, blue: 0.25, alpha: 1))!.draw(in: fruit, angle: -65)
let leaf = NSBezierPath()
leaf.move(to: NSPoint(x: 505, y: 818))
leaf.curve(to: NSPoint(x: 736, y: 941), controlPoint1: NSPoint(x: 530, y: 932), controlPoint2: NSPoint(x: 656, y: 948))
leaf.curve(to: NSPoint(x: 505, y: 818), controlPoint1: NSPoint(x: 711, y: 837), controlPoint2: NSPoint(x: 600, y: 817))
NSColor(calibratedRed: 1, green: 0.77, blue: 0.66, alpha: 1).setFill()
leaf.fill()
let play = NSBezierPath()
play.move(to: NSPoint(x: 420, y: 322))
play.line(to: NSPoint(x: 420, y: 648))
play.curve(to: NSPoint(x: 452, y: 666), controlPoint1: NSPoint(x: 420, y: 669), controlPoint2: NSPoint(x: 435, y: 676))
play.line(to: NSPoint(x: 696, y: 506))
play.curve(to: NSPoint(x: 696, y: 472), controlPoint1: NSPoint(x: 716, y: 493), controlPoint2: NSPoint(x: 716, y: 485))
play.line(to: NSPoint(x: 452, y: 306))
play.curve(to: NSPoint(x: 420, y: 322), controlPoint1: NSPoint(x: 435, y: 294), controlPoint2: NSPoint(x: 420, y: 302))
NSColor.white.setFill()
play.fill()
image.unlockFocus()
let output = URL(fileURLWithPath: "iOS/Hongguo/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let opaqueContext = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
opaqueContext.draw(image.cgImage(forProposedRect: nil, context: nil, hints: nil)!,
                   in: CGRect(origin: .zero, size: size))
let bitmap = NSBitmapImageRep(cgImage: opaqueContext.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("AppIcon.png"))
let manifest = """
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try Data(manifest.utf8).write(to: output.appendingPathComponent("Contents.json"))
print("Generated original iOS app icon")
