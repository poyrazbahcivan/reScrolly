import SwiftUI

// Light, warm, quiet. One accent. System type. Native controls where they exist.

enum Theme {
    static let background = Color(red: 0.973, green: 0.969, blue: 0.957)   // warm paper
    static let surface = Color.white
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let ink2 = Color(red: 0.42, green: 0.42, blue: 0.45)
    static let ink3 = Color(red: 0.62, green: 0.62, blue: 0.65)
    static let line = Color(red: 0.905, green: 0.898, blue: 0.878)
    static let accent = Color(red: 0.17, green: 0.42, blue: 0.29)
    static let accentSoft = Color(red: 0.91, green: 0.95, blue: 0.93)
    static let warn = Color(red: 0.71, green: 0.35, blue: 0.09)
    static let warnSoft = Color(red: 0.99, green: 0.95, blue: 0.90)
    static let radius: CGFloat = 14
}

enum UnitSystem: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var title: String { self == .metric ? "Metric" : "Imperial" }
    var subtitle: String { self == .metric ? "Grams, kilograms, millilitres, °C" : "Ounces, pounds, cups, spoons, °F" }
    var icon: String { self == .metric ? "scalemass" : "ruler" }
}

enum Fmt {
    /// The user's choice from You → Units, else what the phone's region uses.
    static var units: UnitSystem {
        if let raw = UserDefaults.standard.string(forKey: "units"), let u = UnitSystem(rawValue: raw) { return u }
        return Locale.current.measurementSystem == .us ? .imperial : .metric
    }

    static func money(_ v: Double) -> String { String(format: "$%.2f", v) }
    static func money0(_ v: Double) -> String { String(format: "$%.0f", v) }
    static func minutes(_ m: Int) -> String { m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min" }

    /// An amount to cook with: g and kg, or oz, lb, spoons, and cups.
    static func qty(_ v: Double, _ unit: String) -> String { amount(v, unit, shopping: false) }
    /// An amount to buy: liquids in fluid ounces rather than cups.
    static func shopQty(_ v: Double, _ unit: String) -> String { amount(v, unit, shopping: true) }

    private static func amount(_ v: Double, _ unit: String, shopping: Bool) -> String {
        let imperial = units == .imperial
        switch unit {
        case "g": return imperial ? ounces(v) : metric(v, "g", "kg")
        case "ml": return imperial ? (shopping ? fluidOunces(v) : spoonsAndCups(v)) : metric(v, "ml", "L")
        case "ea": return number(v)
        case "slice": return "\(number(v)) \(v == 1 ? "slice" : "slices")"
        case "bunch": return "\(number(v)) \(v == 1 ? "bunch" : "bunches")"
        default: return "\(number(v)) \(unit)"
        }
    }

    private static func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private static func metric(_ v: Double, _ small: String, _ big: String) -> String {
        if v >= 1000 { return "\(number((v / 100).rounded() / 10)) \(big)" }
        return v < 10 ? "\(number((v * 10).rounded() / 10)) \(small)" : "\(Int(v.rounded())) \(small)"
    }

    private static func ounces(_ g: Double) -> String {
        let oz = g / 28.3495
        if oz >= 16 { return "\(number((oz / 16 * 10).rounded() / 10)) lb" }
        if oz >= 4 { return "\(Int(oz.rounded())) oz" }
        if g < 1.5 { return "a pinch" }
        return "\(fraction(oz, steps: 8)) oz"
    }

    private static func spoonsAndCups(_ ml: Double) -> String {
        if ml < 1.2 { return "a pinch" }
        if ml < 14 { return "\(fraction(ml / 4.929, steps: 4)) tsp" }
        if ml < 59 { return "\(fraction(ml / 14.787, steps: 2)) tbsp" }
        let cups = ml / 236.6
        return "\(fraction(cups, steps: 4)) \(cups > 1.125 ? "cups" : "cup")"
    }

    private static func fluidOunces(_ ml: Double) -> String {
        let oz = ml / 29.574
        return oz < 2 ? spoonsAndCups(ml) : "\(Int(oz.rounded())) fl oz"
    }

    /// 2.25 → "2¼", rounded to the nearest 1/steps and never zero.
    private static func fraction(_ x: Double, steps: Int) -> String {
        let n = max(1, Int((x * Double(steps)).rounded()))
        let whole = n / steps, rest = n % steps
        let glyphs: [Int: [Int: String]] = [2: [1: "½"], 4: [1: "¼", 2: "½", 3: "¾"], 8: [1: "⅛", 2: "¼", 3: "⅜", 4: "½", 5: "⅝", 6: "¾", 7: "⅞"]]
        let part = rest == 0 ? "" : (glyphs[steps]?[rest] ?? "")
        return whole == 0 ? part : "\(whole)\(part)"
    }

    /// Oven temperatures inside recipe text, in the chosen system: "Heat the oven to 425°F" ↔ "220°C".
    static func text(_ s: String) -> String {
        let pattern = #"(\d{2,3})\s?°\s?([CF])\b|(\d{2,3})\s?([CF])(?=\s?(?:[Ff]an|\.|,|;|\)|\s|$))"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let target = units == .imperial ? "F" : "C"
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let numberRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 3)
            let unitRange = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 4)
            guard let nr = Range(numberRange, in: s), let ur = Range(unitRange, in: s), let whole = Range(m.range, in: out),
                  let value = Double(s[nr]), (90...550).contains(value) else { continue }
            let from = String(s[ur])
            let converted = from == target ? value : (target == "C" ? (value - 32) * 5 / 9 : value * 9 / 5 + 32)
            out.replaceSubrange(whole, with: "\(Int((converted / 5).rounded() * 5))°\(target)")
        }
        return out
    }
}

extension String {
    var titled: String { prefix(1).uppercased() + dropFirst() }
    var humanized: String { replacingOccurrences(of: "_", with: " ").titled }
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct Screen<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            // Full width and pinned leading. A page narrower than the screen is otherwise centred,
            // and jumps sideways whenever its content changes width.
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var isLoading = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).font(.body.weight(.semibold)).opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().tint(.white) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.white)
            .background(enabled ? Theme.accent : Theme.ink3, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .disabled(!enabled || isLoading)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let s = systemImage { Image(systemName: s) }
                Text(title).font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(Theme.ink)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
        }
    }
}

struct TextButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink2)
    }
}

// MARK: - Selection

struct ChoiceCard: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let s = systemImage {
                    Image(systemName: s)
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(selected ? Theme.accent : Theme.ink2)
                        .background(selected ? Theme.accentSoft : Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                    if let sub = subtitle { Text(sub).font(.subheadline).foregroundStyle(Theme.ink2) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.line)
                    .font(.title3)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .foregroundStyle(selected ? Theme.accent : Theme.ink)
                .background(selected ? Theme.accentSoft : Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(selected ? Theme.accent : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Text

struct StepHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            if let s = subtitle { Text(s).font(.body).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.headline).foregroundStyle(Theme.ink) }
}

struct TrustNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock").font(.caption).foregroundStyle(Theme.ink3).padding(.top, 2)
            Text(text).font(.caption).foregroundStyle(Theme.ink3)
        }
    }
}

struct ProgressBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(Theme.accent).frame(width: max(8, g.size.width * progress))
            }
        }
        .frame(height: 4)
        .animation(.easeInOut(duration: 0.3), value: progress)
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View { Text(text).font(.caption.weight(.medium)).foregroundStyle(Theme.ink2).textCase(.uppercase) }
}

struct InputField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType? = nil
    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) }
            else { TextField(placeholder, text: $text) }
        }
        .keyboardType(keyboard)
        .textContentType(contentType)
        .textInputAutocapitalization(keyboard == .emailAddress || keyboard == .URL ? .never : .words)
        .autocorrectionDisabled(keyboard == .emailAddress || keyboard == .URL || secure)
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct InlineNotice: View {
    let text: String
    var tone: Tone = .info
    enum Tone { case info, warn }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .warn ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(tone == .warn ? Theme.warn : Theme.ink2)
            Text(text).font(.footnote).foregroundStyle(tone == .warn ? Theme.warn : Theme.ink2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .warn ? Theme.warnSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct RowLink<Destination: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                if let s = systemImage { Image(systemName: s).frame(width: 24).foregroundStyle(Theme.ink2) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.ink)
                    if let sub = subtitle { Text(sub).font(.subheadline).foregroundStyle(Theme.ink2).lineLimit(1) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Graphics

/// Muted colours and a symbol for each dish, picked from its id and what's in it, so a dish looks the same everywhere.
enum RecipeArt {
    static let palette: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 0.42), Color(red: 0.76, green: 0.45, blue: 0.33), Color(red: 0.78, green: 0.58, blue: 0.22),
        Color(red: 0.50, green: 0.39, blue: 0.56), Color(red: 0.34, green: 0.47, blue: 0.62), Color(red: 0.50, green: 0.53, blue: 0.28),
        Color(red: 0.74, green: 0.42, blue: 0.48),
    ]

    static func tint(_ id: String) -> Color {
        palette[id.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count]
    }

    static func symbol(name: String, tags: [String], moods: [String]) -> String {
        let n = name.lowercased()
        if moods.contains("breakfast") { return "sunrise" }
        if n.contains("soup") || n.contains("stock") || n.contains("dal") || n.contains("curry") { return "mug" }
        if tags.contains("fish") { return "fish" }
        if tags.contains("poultry") { return "bird" }
        if tags.contains("beef") || tags.contains("meat") { return "flame" }
        if n.contains("salad") || n.contains("veg") || n.contains("broccoli") { return "leaf" }
        if n.contains("rice") || n.contains("bowl") || n.contains("noodle") { return "takeoutbag.and.cup.and.straw" }
        if n.contains("pot of") || n.contains("sauce") || n.contains("batch") { return "frying.pan" }
        return "fork.knife"
    }
}

/// A square of colour with the dish's symbol. `outlined` for thumbnails that overlap.
struct RecipeThumb: View {
    let id: String
    let name: String
    var tags: [String] = []
    var moods: [String] = []
    var size: CGFloat = 44
    var outlined = false

    var body: some View {
        let tint = RecipeArt.tint(id)
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(Theme.surface)
            shape.fill(tint.opacity(0.18))
            Image(systemName: RecipeArt.symbol(name: name, tags: tags, moods: moods))
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .overlay { if outlined { shape.stroke(Theme.surface, lineWidth: 2) } }
        .accessibilityHidden(true)
    }
}

/// The full-width version, for cards and headers.
struct RecipeBanner: View {
    let id: String
    let name: String
    var tags: [String] = []
    var moods: [String] = []
    var height: CGFloat = 96

    var body: some View {
        let tint = RecipeArt.tint(id)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(
                Image(systemName: RecipeArt.symbol(name: name, tags: tags, moods: moods))
                    .font(.system(size: height * 0.36, weight: .medium))
                    .foregroundStyle(tint)
            )
            .accessibilityHidden(true)
    }
}

struct IconBadge: View {
    let systemImage: String
    var tint: Color = Theme.accent
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct Pill: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let s = systemImage { Image(systemName: s) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.ink2)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
}

struct RingGauge<Label: View>: View {
    let progress: Double
    var tint: Color = Theme.accent
    var lineWidth: CGFloat = 8
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label()
        }
        .animation(.snappy, value: progress)
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
            Spacer()
            if let d = detail { Text(d).font(.subheadline).foregroundStyle(Theme.ink3) }
        }
    }
}

/// The label for a row that opens another page.
struct NavRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                if let s = subtitle { Text(s).font(.subheadline).foregroundStyle(Theme.ink2).lineLimit(2) }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .contentShape(Rectangle())
    }
}

extension View {
    /// White card with a hairline border, the shape every surface in the app uses.
    func cardStyle(radius: CGFloat = Theme.radius) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}
