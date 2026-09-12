import SwiftUI

/// Three layers: ingredients, recipes grouped by cook session, days eaten.
/// Tap a recipe to see everything it touches. Monochrome by default, accent on selection.
struct FlowGraphView: View {
    let plan: Plan
    @State private var selected: String?

    private let rowH: CGFloat = 24
    private let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var ingredients: [GNode] { plan.graph.nodes.filter { $0.kind == "ingredient" }.sorted { $0.label < $1.label } }
    private var recipeRows: [(node: GNode?, header: String?)] {
        var rows: [(GNode?, String?)] = []
        for s in plan.sessions {
            rows.append((nil, s.label))
            for rid in s.recipeIds {
                if let n = plan.graph.nodes.first(where: { $0.id == "rec:\(rid)" }) { rows.append((n, nil)) }
            }
        }
        return rows
    }
    private var days: [Int] { Array(Set(plan.meals.map(\.day))).sorted() }
    private var height: CGFloat { CGFloat(max(ingredients.count, recipeRows.count, days.count)) * rowH + 32 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { ctx, size in
                let colX: [CGFloat] = [12, size.width * 0.50, size.width - 12]
                var pos: [String: CGPoint] = [:]
                for (i, n) in ingredients.enumerated() { pos[n.id] = CGPoint(x: colX[0], y: 16 + CGFloat(i) * rowH) }
                for (i, row) in recipeRows.enumerated() {
                    let y = 16 + CGFloat(i) * rowH
                    if let n = row.node { pos[n.id] = CGPoint(x: colX[1], y: y) }
                    else if let h = row.header {
                        ctx.draw(Text(h.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3), at: CGPoint(x: colX[1], y: y), anchor: .leading)
                    }
                }
                for (i, d) in days.enumerated() { pos["day:\(d)"] = CGPoint(x: colX[2], y: 16 + CGFloat(i) * rowH) }

                func on(_ id: String) -> Bool { selected == nil || selected == id }
                let dim = Color.gray.opacity(0.10)
                let base = Color.gray.opacity(0.35)

                for e in plan.graph.edges where e.from.hasPrefix("ing:") {
                    guard let a = pos[e.from], let b = pos[e.to] else { continue }
                    let active = on(e.to)
                    curve(ctx, CGPoint(x: a.x + w(e.from) + 4, y: a.y), CGPoint(x: b.x - 6, y: b.y), active ? (selected == nil ? base : Theme.accent) : dim)
                }
                for e in plan.graph.edges where e.from.hasPrefix("rec:") {
                    guard let a = pos[e.from], let b = pos[e.to] else { continue }
                    let active = on(e.from) || on(e.to)
                    var p = Path()
                    let x0 = a.x + w(e.from) + 6, x1 = b.x + w(e.to) + 6, bulge = max(x0, x1) + 18
                    p.move(to: CGPoint(x: x0, y: a.y))
                    p.addCurve(to: CGPoint(x: x1, y: b.y), control1: CGPoint(x: bulge, y: a.y), control2: CGPoint(x: bulge, y: b.y))
                    ctx.stroke(p, with: .color(active ? (selected == nil ? Theme.accent.opacity(0.7) : Theme.accent) : dim), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }
                for m in plan.meals {
                    guard let rid = m.recipeId, let a = pos["rec:\(rid)"], let b = pos["day:\(m.day)"] else { continue }
                    let active = on("rec:\(rid)")
                    curve(ctx, CGPoint(x: a.x + w("rec:\(rid)") + 4, y: a.y), CGPoint(x: b.x - 30, y: b.y), active ? (selected == nil ? base : Theme.accent) : dim)
                }
                for n in ingredients {
                    guard let p = pos[n.id] else { continue }
                    ctx.draw(Text(n.label).font(.system(size: 11)).foregroundStyle(selected == nil ? Theme.ink : Theme.ink3), at: p, anchor: .leading)
                }
                for row in recipeRows {
                    guard let n = row.node, let p = pos[n.id] else { continue }
                    let isSel = selected == n.id
                    ctx.draw(Text(n.label).font(.system(size: 11, weight: isSel ? .semibold : .regular)).foregroundStyle(isSel ? Theme.accent : (selected == nil ? Theme.ink : Theme.ink3)), at: p, anchor: .leading)
                }
                for d in days {
                    guard let p = pos["day:\(d)"] else { continue }
                    ctx.draw(Text(dayLabels[d % 7]).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2), at: p, anchor: .trailing)
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                let idx = Int((g.location.y - 16 + rowH / 2) / rowH)
                if idx >= 0, idx < recipeRows.count, let n = recipeRows[idx].node, abs(g.location.x - g.startLocation.x) < 8 {
                    selected = (selected == n.id) ? nil : n.id
                } else { selected = nil }
            })
            HStack(spacing: 14) {
                Legend(color: .gray.opacity(0.5), label: "ingredient", dashed: false)
                Legend(color: Theme.accent.opacity(0.7), label: "cooked, used later", dashed: true)
                Spacer()
                Text(selected == nil ? "Tap a recipe" : "Tap again to clear").font(.caption2).foregroundStyle(Theme.ink3)
            }
        }
    }

    private func w(_ id: String) -> CGFloat { CGFloat((plan.graph.nodes.first { $0.id == id }?.label ?? "").count) * 5.6 }

    private func curve(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint, _ color: Color) {
        var p = Path()
        p.move(to: a)
        let mid = (a.x + b.x) / 2
        p.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
        ctx.stroke(p, with: .color(color), lineWidth: 1)
    }
}

private struct Legend: View {
    let color: Color
    let label: String
    let dashed: Bool
    var body: some View {
        HStack(spacing: 5) {
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 18, y: 0)) }
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, dash: dashed ? [3, 3] : []))
                .frame(width: 18, height: 1)
            Text(label).font(.caption2).foregroundStyle(Theme.ink3)
        }
    }
}
