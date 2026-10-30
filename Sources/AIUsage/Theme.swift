import AIUsageCore
import AppKit
import SwiftUI

/// Colours follow coding-usage-bar: green when fine/learning, amber when under-using,
/// coral when too fast or at the limit, grey for errors.
enum Theme {
    static func hex(_ hex: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// A colour that resolves per appearance (light, dark).
    static func dynamic(_ light: String, _ dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light)
        }
    }

    static let ok = dynamic("248A3D", "30D158")
    static let warning = dynamic("FF9F0A", "FFD60A")
    static let alert = dynamic("D97757", "E8956E")
    static let muted = dynamic("6B7280", "A1A1AA")

    static func color(for state: BurnState?) -> NSColor {
        switch state {
        case .underBurn: return warning
        case .overBurn, .limitRisk, .depleted: return alert
        case .unavailable, .none: return muted
        case .learning, .onTrack, .balance: return ok
        }
    }

    static func isDark(_ appearance: NSAppearance?) -> Bool {
        (appearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Draws a provider mark (rounded square + monogram) into `rect` in the current context.
    static func drawMark(_ provider: ProviderKind, in rect: NSRect, badge: Int? = nil) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.24, yRadius: rect.height * 0.24)
        hex(provider.markColorHex).setFill()
        path.fill()
        let font = NSFont.systemFont(ofSize: rect.height * 0.62, weight: .heavy)
        let text = NSAttributedString(string: provider.monogram, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        if let badge {
            // Small index so several accounts of one provider stay distinguishable.
            let bFont = NSFont.monospacedDigitSystemFont(ofSize: rect.height * 0.42, weight: .bold)
            let b = NSAttributedString(string: "\(badge)", attributes: [.font: bFont, .foregroundColor: NSColor.white])
            let bs = b.size()
            let d = max(bs.width, bs.height) + 1
            let circle = NSRect(x: rect.maxX - d * 0.75, y: rect.minY - d * 0.25, width: d, height: d)
            NSColor.black.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: circle).fill()
            b.draw(at: NSPoint(x: circle.midX - bs.width / 2, y: circle.midY - bs.height / 2))
        }
    }
}

struct ProviderMark: View {
    let provider: ProviderKind
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Color(nsColor: Theme.hex(provider.markColorHex)))
            .frame(width: size, height: size)
            .overlay(Text(provider.monogram).font(.system(size: size * 0.62, weight: .heavy)).foregroundStyle(.white))
    }
}
