// Draws the app icon (a portrait screen showing a page of text) at 1024×1024 and writes it to the
// path given. scripts/make-icons.sh turns it into the iPad asset and the Mac .icns.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Background: deep blue to indigo.
let colors = [NSColor(red: 0.10, green: 0.16, blue: 0.36, alpha: 1).cgColor,
              NSColor(red: 0.24, green: 0.18, blue: 0.52, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// The screen: a portrait rounded rectangle with a bezel.
let screen = CGRect(x: 302, y: 162, width: 420, height: 700)
ctx.setFillColor(NSColor(white: 0.07, alpha: 1).cgColor)
ctx.addPath(CGPath(roundedRect: screen.insetBy(dx: -26, dy: -26), cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.fillPath()
ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.fillPath()

// A page of text: a heading bar and lines of varying length.
ctx.setFillColor(NSColor(red: 0.24, green: 0.30, blue: 0.62, alpha: 1).cgColor)
ctx.addPath(CGPath(roundedRect: CGRect(x: 350, y: 760, width: 240, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
ctx.fillPath()
ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
let widths: [CGFloat] = [324, 300, 318, 250, 324, 286, 310, 200, 324, 296, 180]
for (i, w) in widths.enumerated() {
    let y = 700 - CGFloat(i) * 46
    ctx.addPath(CGPath(roundedRect: CGRect(x: 350, y: y, width: w, height: 20), cornerWidth: 10, cornerHeight: 10, transform: nil))
}
ctx.fillPath()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
