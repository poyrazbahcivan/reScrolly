import SwiftUI

/// One bar per perishable. Grey is how long it lasts from shopping day.
/// The dot is the last day the plan uses it. Green when the dot is inside the bar.
struct RotTimelineView: View {
    let plan: Plan
    private let horizon = 7
    private let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer().frame(width: 96)
                HStack(spacing: 0) {
                    ForEach(0..<horizon, id: \.self) { d in
                        Text(dayLabels[d]).font(.caption2).foregroundStyle(Theme.ink3).frame(maxWidth: .infinity)
                    }
                }
            }
            ForEach(plan.perishables) { p in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.caption).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(p.shelfLifeDays >= 14 ? "keeps 2+ wk" : "keeps \(p.shelfLifeDays) d").font(.caption2).foregroundStyle(Theme.ink3)
                    }
                    .frame(width: 88, alignment: .leading)
                    GeometryReader { geo in
                        let unit = geo.size.width / CGFloat(horizon)
                        let fill = CGFloat(min(p.shelfLifeDays + 1, horizon)) * unit
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line.opacity(0.5)).frame(height: 8)
                            Capsule().fill(Theme.line).frame(width: fill, height: 8)
                            Circle().fill(p.ok ? Theme.accent : Theme.warn).frame(width: 10, height: 10)
                                .offset(x: CGFloat(min(p.lastUsedDay, horizon - 1)) * unit + unit / 2 - 5)
                        }
                        .frame(height: 10)
                    }
                    .frame(height: 10)
                }
            }
            HStack(spacing: 14) {
                HStack(spacing: 5) { Circle().fill(Theme.accent).frame(width: 8, height: 8); Text("used in time").font(.caption2).foregroundStyle(Theme.ink3) }
                HStack(spacing: 5) { Circle().fill(Theme.warn).frame(width: 8, height: 8); Text("would spoil").font(.caption2).foregroundStyle(Theme.ink3) }
            }
            .padding(.top, 4)
        }
    }
}
