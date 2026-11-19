// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Components/Theme.swift
// Description: SP Drive design system v2 — the one token set shared with the web (CSS variables) and iOS: colour roles (light, dark, increased contrast), an editorial type scale, spacing, radii, elevation, and a motion vocabulary that honours Reduce Motion. The table in docs/next/DESIGN-SYSTEM-V2.md is the contract; names here match it.
import AppKit
import SwiftUI

enum SPDTheme {
    // MARK: Colour roles
    /// A colour with its four variants. Hex values are sRGB; `a` is the alpha.
    struct Role: Sendable {
        let light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32
        let la: Double, da: Double
        init(_ light: UInt32, _ dark: UInt32, hc lightHC: UInt32? = nil, _ darkHC: UInt32? = nil, alpha la: Double = 1, _ da: Double? = nil) {
            self.light = light; self.dark = dark; self.lightHC = lightHC ?? light; self.darkHC = darkHC ?? dark; self.la = la; self.da = da ?? la
        }
        var nsColor: NSColor {
            NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) ?? .aqua
                switch match {
                case .darkAqua: return Role.ns(dark, da)
                case .accessibilityHighContrastAqua: return Role.ns(lightHC, min(1, la * 1.6))
                case .accessibilityHighContrastDarkAqua: return Role.ns(darkHC, min(1, da * 1.6))
                default: return Role.ns(light, la)
                }
            }
        }
        var color: SwiftUI.Color { SwiftUI.Color(nsColor: nsColor) }
        static func ns(_ hex: UInt32, _ a: Double) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
    }
    enum Palette {
        /// Identity. Violet is the accent of every control; indigo is its companion in the mark only.
        static let brand = Role(0x6D3DF2, 0x9882FF, hc: 0x4F22C9, 0xB7A8FF)
        static let brandIndigo = Role(0x4A55E0, 0x8E97FF, hc: 0x2F39B8, 0xAEB5FF)
        /// Quiet wash of the brand: selection, hovered rows, valid drop targets.
        static let brandWash = Role(0x6D3DF2, 0x9882FF, hc: 0x4F22C9, 0xB7A8FF, alpha: 0.10, 0.18)
        static let selection = Role(0x6D3DF2, 0x9882FF, hc: 0x4F22C9, 0xB7A8FF, alpha: 0.16, 0.30)
        // Surfaces, from the back of the window forward.
        static let canvas = Role(0xFFFFFF, 0x1B1B1F, hc: 0xFFFFFF, 0x000000)
        static let surface = Role(0xF6F6F9, 0x232328, hc: 0xF2F2F6, 0x101013)
        static let surfaceRaised = Role(0xFFFFFF, 0x2B2B31, hc: 0xFFFFFF, 0x1A1A1E)
        static let sunken = Role(0xEEEEF3, 0x161619, hc: 0xE6E6EC, 0x000000)
        static let hairline = Role(0x000000, 0xFFFFFF, alpha: 0.10, 0.12)
        // Text.
        static let textPrimary = Role(0x16161A, 0xF2F2F5, hc: 0x000000, 0xFFFFFF)
        static let textSecondary = Role(0x5C5C66, 0xA6A6B0, hc: 0x33333A, 0xD4D4DC)
        static let textTertiary = Role(0x8A8A94, 0x7C7C86, hc: 0x55555E, 0xB0B0BA)
        static let onBrand = Role(0xFFFFFF, 0x14102B, hc: 0xFFFFFF, 0x000000)
        // Status. Never the only carrier of meaning: always paired with a symbol or a word.
        static let positive = Role(0x1E8E5A, 0x4CC38A, hc: 0x116B41, 0x7BE0AE)
        static let warning = Role(0xB76E00, 0xF0B454, hc: 0x8A5200, 0xFFD084)
        static let critical = Role(0xC8322B, 0xFF6B63, hc: 0x9E1C16, 0xFF9A94)
    }
    static let brand = Palette.brand.color
    static let brandIndigo = Palette.brandIndigo.color
    static let brandWash = Palette.brandWash.color
    static let selection = Palette.selection.color
    static let canvas = Palette.canvas.color
    static let surface = Palette.surface.color
    static let surfaceRaised = Palette.surfaceRaised.color
    static let sunken = Palette.sunken.color
    static let hairline = Palette.hairline.color
    static let textPrimary = Palette.textPrimary.color
    static let textSecondary = Palette.textSecondary.color
    static let textTertiary = Palette.textTertiary.color
    static let onBrand = Palette.onBrand.color
    static let positive = Palette.positive.color
    static let warning = Palette.warning.color
    static let critical = Palette.critical.color

    // MARK: Type scale (editorial: a serif for titles that name a place or a moment, the system sans for everything you operate)
    enum Typo {
        /// Empty states, sign-in, sheet heroes.
        static let display = Font.system(size: 28, weight: .semibold, design: .serif)
        /// Sheet and section titles.
        static let title = Font.system(size: 20, weight: .semibold, design: .serif)
        /// Card titles, inspector name.
        static let headline = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyStrong = Font.system(size: 13, weight: .medium)
        static let callout = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        /// Small capitals above groups ("SUR CE MAC"): 10 pt medium, tracked +0.6.
        static let eyebrow = Font.system(size: 10, weight: .semibold)
        static let eyebrowTracking: CGFloat = 0.6
        static let mono = Font.system(size: 11, design: .monospaced)
        /// Large figures of dashboards (storage, speeds): tabular digits.
        static let figure = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    }

    // MARK: Spacing (4-pt grid), radii, sizes
    enum Space { static let xxs: CGFloat = 2, xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32, xxxl: CGFloat = 48 }
    enum Radius { static let xs: CGFloat = 4, sm: CGFloat = 6, md: CGFloat = 10, lg: CGFloat = 14, xl: CGFloat = 20 }
    enum Size { static let gridCell: CGFloat = 148, gridThumb: CGFloat = 116, rowIcon: CGFloat = 20, palette: CGFloat = 620 }

    // MARK: Elevation
    struct Elevation: Sendable { let radius: CGFloat, y: CGFloat, opacity: Double
        /// Flat: a hairline only.
        static let e0 = Elevation(radius: 0, y: 0, opacity: 0)
        /// Cards resting on the canvas.
        static let e1 = Elevation(radius: 3, y: 1, opacity: 0.07)
        /// Floating panels: command palette, drop zone, popovers.
        static let e2 = Elevation(radius: 24, y: 8, opacity: 0.16)
        /// Things in the hand: dragged items, the Quick Look lift.
        static let e3 = Elevation(radius: 40, y: 16, opacity: 0.24)
    }

    // MARK: Motion
    /// A named motion: what plays normally, and what plays when the person asked for reduced motion (a short fade, or nothing).
    struct Motion: Sendable {
        let name: String
        let duration: Double
        let full: Animation
        let reduced: Animation?
        func resolved(reduceMotion: Bool) -> Animation? { reduceMotion ? reduced : full }
        /// For imperative code outside a view (AppKit panels): reads the system setting directly.
        var current: Animation? { resolved(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }

        enum Duration { static let instant = 0.10, quick = 0.18, standard = 0.28, slow = 0.45 }
        enum Curve {
            /// Things that move from one resting place to another.
            static func standard(_ d: Double) -> Animation { .timingCurve(0.2, 0, 0, 1, duration: d) }
            /// Things arriving: fast start, long settle.
            static func enter(_ d: Double) -> Animation { .timingCurve(0.05, 0.7, 0.1, 1, duration: d) }
            /// Things leaving: no settle.
            static func exit(_ d: Double) -> Animation { .timingCurve(0.3, 0, 0.8, 0.15, duration: d) }
            static let springSnappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
            static let springGentle = Animation.spring(response: 0.45, dampingFraction: 0.82)
        }
        private static let fade = Animation.easeOut(duration: Duration.instant)
        /// Selection and pressed states.
        static let select = Motion(name: "select", duration: Duration.instant, full: Curve.standard(Duration.instant), reduced: nil)
        /// Hover washes, badges appearing.
        static let hover = Motion(name: "hover", duration: Duration.quick, full: Curve.standard(Duration.quick), reduced: nil)
        /// Going into or out of a folder, changing section.
        static let navigate = Motion(name: "navigate", duration: Duration.standard, full: Curve.enter(Duration.standard), reduced: fade)
        /// Panels that slide or grow into view: inspector, command palette, banners.
        static let reveal = Motion(name: "reveal", duration: Duration.standard, full: Curve.springGentle, reduced: fade)
        static let dismiss = Motion(name: "dismiss", duration: Duration.quick, full: Curve.exit(Duration.quick), reduced: fade)
        /// A valid drop target answering the drag.
        static let drop = Motion(name: "drop", duration: Duration.standard, full: Curve.springSnappy, reduced: nil)
        /// Progress bars and figures that follow live data.
        static let progress = Motion(name: "progress", duration: 0.20, full: .linear(duration: 0.20), reduced: .linear(duration: 0.20))
        /// Slow, ambient: the breathing of the sync mark. Removed entirely under Reduce Motion.
        static let ambient = Motion(name: "ambient", duration: Duration.slow * 3, full: .easeInOut(duration: Duration.slow * 3).repeatForever(autoreverses: true), reduced: nil)
        static let all = [select, hover, navigate, reveal, dismiss, drop, progress, ambient]
    }
}

// MARK: Modifiers
private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let motion: SPDTheme.Motion
    let value: V
    func body(content: Content) -> some View { content.animation(motion.resolved(reduceMotion: reduce), value: value) }
}
private struct ElevationModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let e: SPDTheme.Elevation
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(e.opacity * (scheme == .dark ? 1.7 : 1)), radius: e.radius, y: e.y)
    }
}
extension View {
    /// Animates changes of `value` with a named motion, or its reduced form when Reduce Motion is on.
    func spdMotion<V: Equatable>(_ motion: SPDTheme.Motion, value: V) -> some View { modifier(MotionModifier(motion: motion, value: value)) }
    func spdElevation(_ e: SPDTheme.Elevation) -> some View { modifier(ElevationModifier(e: e)) }
    /// A calm card: raised surface, hairline, resting elevation.
    func spdCard(padding: CGFloat = SPDTheme.Space.lg, radius: CGFloat = SPDTheme.Radius.lg) -> some View {
        self.padding(padding)
            .background(SPDTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(SPDTheme.hairline))
            .spdElevation(.e1)
    }
    func spdEyebrow() -> some View { self.font(SPDTheme.Typo.eyebrow).tracking(SPDTheme.Typo.eyebrowTracking).textCase(.uppercase).foregroundStyle(SPDTheme.textTertiary) }
}
/// `withAnimation` with a named motion.
@MainActor func spdAnimate(_ motion: SPDTheme.Motion, _ body: () -> Void) {
    if let a = motion.current { withAnimation(a, body) } else { body() }
}

/// A small status pill: a symbol and a word, tinted (never colour alone).
struct SPDPill: View {
    let text: String
    var symbol: String?
    var tint: Color = SPDTheme.textSecondary
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(SPDTheme.Typo.caption.weight(.medium))
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(tint).background(tint.opacity(0.13), in: Capsule())
    }
}

/// An empty state that says where you are, why it is empty, and what to do next.
struct SPDEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    /// Width of the text column (a fixed width: a text that sizes itself from its container inside the split view's detail made AppKit loop on constraints).
    var width: CGFloat = 420
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: SPDTheme.Space.md) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(SPDTheme.brand).symbolRenderingMode(.hierarchical)
                .frame(width: 72, height: 72).background(SPDTheme.brandWash, in: Circle()).accessibilityHidden(true)
            Text(title).font(width < 300 ? SPDTheme.Typo.title : SPDTheme.Typo.display).foregroundStyle(SPDTheme.textPrimary).multilineTextAlignment(.center).lineLimit(2).frame(width: width)
            Text(message).font(SPDTheme.Typo.body).foregroundStyle(SPDTheme.textSecondary).multilineTextAlignment(.center).lineLimit(6).frame(width: width)
            HStack(spacing: SPDTheme.Space.sm) { actions() }.padding(.top, SPDTheme.Space.xs)
        }
        .padding(width < 300 ? SPDTheme.Space.md : SPDTheme.Space.xxl).frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
extension SPDEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String, width: CGFloat = 420) { self.init(symbol: symbol, title: title, message: message, width: width) { EmptyView() } }
}
