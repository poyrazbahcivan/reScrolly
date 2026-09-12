import SwiftUI

/// The grocery list as a checklist grouped by aisle, with progress on top.
/// Sharing lives in the toolbar; the PDF is the paper-style list below.
struct ShopView: View {
    @EnvironmentObject var state: AppState
    @State private var pdfURL: URL?

    var body: some View {
        Screen {
            if let plan = state.plan {
                let buy = plan.shopping.filter { $0.section != "Check your pantry" }
                let done = buy.filter { state.checked.contains($0.id) }.count
                List {
                    Section {
                        ShopHeader(plan: plan, done: done, total: buy.count)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    ForEach(sections(plan), id: \.self) { sec in
                        Section {
                            ForEach(plan.shopping.filter { $0.section == sec }) { item in
                                ShopRow(item: item, checked: state.checked.contains(item.id)) {
                                    withAnimation(.snappy) { state.toggleChecked(item.id) }
                                }
                            }
                        } header: {
                            Label(sec, systemImage: Self.icon(sec))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.ink2)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .task(id: "\(plan.totalCost)-\(state.units.rawValue)") {
                    pdfURL = PaperList.renderPDF(plan: plan, servings: state.profile.servings)
                }
            }
        }
        .navigationTitle("Groceries")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url = pdfURL {
                        ShareLink(item: url) { Label("Share as PDF", systemImage: "doc.richtext") }
                    }
                    if let plan = state.plan {
                        Button { UIPasteboard.general.string = PaperList.plainText(plan: plan, servings: state.profile.servings) } label: {
                            Label("Copy as text", systemImage: "doc.on.doc")
                        }
                    }
                    if !state.checked.isEmpty {
                        Button(role: .destructive) { for id in state.checked { state.toggleChecked(id) } } label: {
                            Label("Clear checkmarks", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(state.plan == nil)
            }
        }
    }

    private func sections(_ plan: Plan) -> [String] {
        var seen: [String] = []
        for i in plan.shopping where !seen.contains(i.section) { seen.append(i.section) }
        return seen
    }

    static func icon(_ section: String) -> String {
        switch section {
        case "Produce": return "carrot"
        case "Meat": return "fork.knife"
        case "Seafood": return "fish"
        case "Dairy & Eggs": return "cup.and.saucer"
        case "Bakery": return "birthday.cake"
        case "Frozen": return "snowflake"
        case "Pantry": return "shippingbox"
        case "Check your pantry": return "checklist"
        default: return "bag"
        }
    }
}

struct ShopHeader: View {
    let plan: Plan
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 16) {
            RingGauge(progress: total == 0 ? 0 : Double(done) / Double(total), lineWidth: 8) {
                VStack(spacing: 0) {
                    Text("\(done)").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                    Text("of \(total)").font(.caption2).foregroundStyle(Theme.ink3)
                }
            }
            .frame(width: 78, height: 78)
            VStack(alignment: .leading, spacing: 4) {
                Text(Fmt.money(plan.totalCost)).font(.system(size: 28, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                Text("\(total) items, one trip · \(Fmt.money0(plan.request.budget)) budget").font(.subheadline).foregroundStyle(Theme.ink2)
                if total > 0 && done == total {
                    Label("Everything's in the cart", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .cardStyle(radius: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(done) of \(total) items checked. Total \(Fmt.money(plan.totalCost)).")
    }
}

struct ShopRow: View {
    let item: ShopItem
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(checked ? Theme.accent : Theme.ink3)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundStyle(checked ? Theme.ink3 : Theme.ink).strikethrough(checked, color: Theme.ink3)
                    Text(detail).font(.caption).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 8)
                Text(item.cost > 0 ? Fmt.money(item.cost) : "have").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: checked)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private var detail: String {
        if item.section == "Check your pantry" { return "needs \(Fmt.shopQty(item.qtyNeeded, item.unit))" }
        return PaperList.packs(item) + (item.perishable ? " · perishable" : "")
    }
}

/// The grocery list made to look like the paper one. Used for the PDF.
struct PaperList: View {
    let plan: Plan
    let servings: Int
    var checked: Set<String> = []
    var onToggle: ((String) -> Void)? = nil
    var forPrint = false

    private static let paper = Color(red: 0.995, green: 0.985, blue: 0.955)
    private static let rule = Color(red: 0.87, green: 0.84, blue: 0.78)

    private var sections: [String] {
        var seen: [String] = []
        for i in plan.shopping where !seen.contains(i.section) { seen.append(i.section) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Groceries").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(weekLabel).font(.subheadline).foregroundStyle(Theme.ink2)
                }
                Text("\(plan.distinctIngredients) items · one trip" + (servings > 1 ? " · for \(servings) people" : "")).font(.subheadline).foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 12)
            Rectangle().fill(Self.rule).frame(height: 1).padding(.horizontal, 22)

            ForEach(sections, id: \.self) { sec in
                Text(sec.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)
                ForEach(plan.shopping.filter { $0.section == sec }) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 3).stroke(Theme.ink2, lineWidth: 1.2).frame(width: 16, height: 16)
                            if checked.contains(item.id) { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
                        }
                        .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.system(size: 16)).foregroundStyle(Theme.ink)
                            Text(detail(item)).font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        }
                        Spacer()
                        Text(item.cost > 0 ? Fmt.money(item.cost) : "have").font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.ink2)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .overlay(alignment: .bottom) { Rectangle().fill(Self.rule.opacity(0.7)).frame(height: 0.8).padding(.horizontal, 22) }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Total").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(Fmt.money(plan.totalCost)).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 22).padding(.top, 16)
            Text("of \(Fmt.money0(plan.request.budget)) budget · est. waste \(Fmt.money(plan.wastePlan))").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 22).padding(.top, 2).padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.paper, in: RoundedRectangle(cornerRadius: forPrint ? 0 : 6, style: .continuous))
    }

    private var weekLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "\(f.string(from: PlanClock.date(0))) – \(f.string(from: PlanClock.date(6)))"
    }

    private func detail(_ i: ShopItem) -> String {
        if i.section == "Check your pantry" { return "needs \(Fmt.shopQty(i.qtyNeeded, i.unit))" }
        return Self.packs(i) + " · uses \(Fmt.shopQty(i.qtyNeeded, i.unit))" + (i.perishable ? " · perishable" : "")
    }

    /// How much to pick up, in words a shopper uses: "2 packs of 5", "1 loaf, 20 slices", "2 × 1.1 lb".
    static func packs(_ i: ShopItem) -> String {
        let n = i.packs
        switch i.unit {
        case "ea": return i.packQty == 1 ? "\(n)" : "\(n) \(n == 1 ? "pack" : "packs") of \(Int(i.packQty))"
        case "slice": return "\(n) \(n == 1 ? "loaf" : "loaves"), \(Int(i.packQty)) slices each"
        case "bunch": let total = Int(Double(n) * i.packQty); return "\(total) \(total == 1 ? "bunch" : "bunches")"
        default: return n == 1 ? Fmt.shopQty(i.packQty, i.unit) : "\(n) × \(Fmt.shopQty(i.packQty, i.unit))"
        }
    }

    static func plainText(plan: Plan, servings: Int) -> String {
        var out = "Groceries" + (servings > 1 ? " (for \(servings))" : "") + "\n"
        var seen: [String] = []
        for i in plan.shopping where !seen.contains(i.section) { seen.append(i.section) }
        for sec in seen {
            out += "\n\(sec)\n"
            for i in plan.shopping where i.section == sec {
                out += "  [ ] \(i.name)  \(packs(i))" + (i.cost > 0 ? "  \(Fmt.money(i.cost))" : "") + "\n"
            }
        }
        out += "\nTotal \(Fmt.money(plan.totalCost))\n"
        return out
    }

    @MainActor
    static func renderPDF(plan: Plan, servings: Int) -> URL? {
        let view = PaperList(plan: plan, servings: servings, forPrint: true).frame(width: 560)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heisoj-groceries.pdf")
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        return url
    }
}
