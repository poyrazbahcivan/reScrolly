import SwiftUI

/// The grocery list, made to feel like the paper one. Cream sheet, ruled rows,
/// square checkboxes, quantities on the right, total at the bottom.
/// Shares as a PDF that looks the same.
struct ShopView: View {
    @EnvironmentObject var state: AppState
    @State private var pdfURL: URL?

    var body: some View {
        Screen {
            if let plan = state.plan {
                ScrollView {
                    VStack(spacing: 16) {
                        PaperList(plan: plan, servings: state.profile.servings, checked: state.checked, onToggle: { state.toggleChecked($0) })
                        HStack(spacing: 10) {
                            if let url = pdfURL {
                                ShareLink(item: url) {
                                    HStack(spacing: 8) { Image(systemName: "square.and.arrow.up"); Text("Share as PDF").font(.body.weight(.medium)) }
                                        .frame(maxWidth: .infinity).frame(height: 52).foregroundStyle(Theme.ink)
                                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
                                }
                            } else {
                                SecondaryButton(title: "Share as PDF", systemImage: "square.and.arrow.up") { pdfURL = PaperList.renderPDF(plan: plan, servings: state.profile.servings) }
                            }
                            SecondaryButton(title: "Copy as text", systemImage: "doc.on.doc") { UIPasteboard.general.string = PaperList.plainText(plan: plan, servings: state.profile.servings) }
                        }
                        if !state.checked.isEmpty {
                            TextButton(title: "Clear checkmarks") { for id in state.checked { state.toggleChecked(id) } }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Shop")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: state.plan?.totalCost) { _, _ in pdfURL = nil }
    }
}

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
            // header
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
                    Button { onToggle?(item.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 3).stroke(Theme.ink2, lineWidth: 1.2).frame(width: 16, height: 16)
                                if checked.contains(item.id) { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
                            }
                            .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 16)).foregroundStyle(checked.contains(item.id) ? Theme.ink3 : Theme.ink)
                                    .strikethrough(checked.contains(item.id), color: Theme.ink3)
                                Text(detail(item)).font(.system(size: 12)).foregroundStyle(Theme.ink3)
                            }
                            Spacer()
                            Text(item.cost > 0 ? Fmt.money(item.cost) : "have").font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.ink2)
                        }
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .overlay(alignment: .bottom) { Rectangle().fill(Self.rule.opacity(0.7)).frame(height: 0.8).padding(.horizontal, 22) }
                    }
                    .buttonStyle(.plain)
                    .disabled(onToggle == nil)
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
        .overlay(RoundedRectangle(cornerRadius: forPrint ? 0 : 6, style: .continuous).stroke(Self.rule, lineWidth: forPrint ? 0 : 1))
        .shadow(color: forPrint ? .clear : .black.opacity(0.05), radius: 8, y: 3)
    }

    private var weekLabel: String {
        let start = UserDefaults.standard.object(forKey: "plan_started") as? Date ?? Date()
        let f = DateFormatter(); f.dateFormat = "MMM d"
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private func detail(_ i: ShopItem) -> String {
        if i.section == "Check your pantry" { return "needs \(Fmt.qty(i.qtyNeeded, i.unit))" }
        return "\(i.packs) \(i.packs == 1 ? "pack" : "packs") · \(Fmt.qty(i.qtyNeeded, i.unit))" + (i.perishable ? " · perishable" : "")
    }

    // MARK: export

    static func plainText(plan: Plan, servings: Int) -> String {
        var out = "Groceries" + (servings > 1 ? " (for \(servings))" : "") + "\n"
        var seen: [String] = []
        for i in plan.shopping where !seen.contains(i.section) { seen.append(i.section) }
        for sec in seen {
            out += "\n\(sec)\n"
            for i in plan.shopping where i.section == sec {
                out += "  [ ] \(i.name)  \(i.packs) x \(Fmt.qty(i.packQty, i.unit))" + (i.cost > 0 ? "  \(Fmt.money(i.cost))" : "") + "\n"
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
