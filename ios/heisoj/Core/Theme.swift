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

enum Fmt {
    static func money(_ v: Double) -> String { String(format: "$%.2f", v) }
    static func money0(_ v: Double) -> String { String(format: "$%.0f", v) }
    static func qty(_ v: Double, _ unit: String) -> String {
        let n = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        return "\(n) \(unit)"
    }
    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }
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
