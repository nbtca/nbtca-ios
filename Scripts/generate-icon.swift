import AppKit
// Run: swift Scripts/generate-icon.swift nbtca/Assets.xcassets/AppIcon.appiconset/AppIcon.png
let size = NSSize(width: 1024, height: 1024)
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let rect = NSRect(origin: .zero, size: size)
NSGradient(starting: NSColor(calibratedRed: 0.02, green: 0.49, blue: 0.96, alpha: 1), ending: NSColor(calibratedRed: 0.08, green: 0.23, blue: 0.62, alpha: 1))!.draw(in: rect, angle: -55)
let glow = NSBezierPath(ovalIn: NSRect(x: 55, y: 55, width: 914, height: 914))
NSColor.white.withAlphaComponent(0.06).setFill(); glow.fill()
let ring = NSBezierPath()
ring.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 292, startAngle: 61, endAngle: 119, clockwise: true)
ring.lineWidth = 58; ring.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.94).setStroke(); ring.stroke()
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 552, y: 835)); bolt.line(to: NSPoint(x: 365, y: 498)); bolt.line(to: NSPoint(x: 495, y: 498)); bolt.line(to: NSPoint(x: 462, y: 218)); bolt.line(to: NSPoint(x: 660, y: 563)); bolt.line(to: NSPoint(x: 533, y: 563)); bolt.close()
NSColor.white.setFill(); bolt.fill()
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
