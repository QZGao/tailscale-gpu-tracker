import AppKit
import CoreText

struct StatusEntry {
    let initial: String
    let value: String
}

@MainActor
final class StatusLabelView: NSView {
    var entries: [StatusEntry] = [] { didSet { needsDisplay = true } }
    var isMenuOpen = false { didSet { needsDisplay = true } }
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    var requiredWidth: CGFloat {
        guard !entries.isEmpty else { return 43 }
        return 12 + entries.reduce(CGFloat(0)) { $0 + 18 + 5 + width($1.value) } + CGFloat(entries.count - 1) * 14
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let color = isMenuOpen ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        guard !entries.isEmpty else {
            drawText("GPU", x: 6, centerY: bounds.midY, font: font, color: color)
            return
        }
        var x: CGFloat = 6
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                drawText("·", x: x + 5, centerY: bounds.midY, font: font, color: color)
                x += 14
            }
            let rect = NSRect(x: x, y: bounds.midY - 8, width: 18, height: 16)
            color.withAlphaComponent(0.65).setStroke()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            path.stroke()
            let initialFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
            let initialWidth = (entry.initial as NSString).size(withAttributes: [.font: initialFont]).width
            drawText(entry.initial, x: x + (18 - initialWidth) / 2, centerY: bounds.midY, font: initialFont, color: color)
            x += 23
            drawText(entry.value, x: x, centerY: bounds.midY, font: font, color: color)
            x += width(entry.value)
        }
    }

    private func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func drawText(_ text: String, x: CGFloat, centerY: CGFloat, font: NSFont, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: font, .foregroundColor: color]) as CFAttributedString)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = .zero
        let ink = CTLineGetImageBounds(line, context)
        let scale = window?.backingScaleFactor ?? 2
        context.textPosition = CGPoint(x: (x * scale).rounded() / scale,
                                       y: ((centerY - ink.midY) * scale).rounded() / scale)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
