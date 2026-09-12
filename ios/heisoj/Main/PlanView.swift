import Charts
import SwiftUI

/// The week. A budget ring on top, then three short sections instead of one long page.
/// Anything deeper (cost charts, the chain graph, freshness, why) is its own page under Insights.
struct PlanView: View {
    @EnvironmentObject var state: AppState
    @State private var section: Section = .meals

    enum Section: String, CaseIterable, Identifiable {
        case meals = "Meals", cooking = "Cooking", insights = "Insights"
        var id: String { rawValue }
    }

    var body: some View {
        Screen {
            if let plan = state.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        WeekSummary(plan: plan)
                        if state.usedFallback {
                            InlineNotice(text: "Sample week. Connect to the server in You → Server to plan your own.")
                        }
                        Picker("Section", selection: $section) {
                            ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        switch section {
                        case .meals: WeekMeals(plan: plan)
                        case .cooking: WeekCooking(plan: plan)
                        case .insights: WeekInsights(plan: plan)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
        .navigationTitle("This week")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await state.replan() } } label: { Label("Replan", systemImage: "arrow.clockwise") }
            }
        }
    }
}

struct WeekSummary: View {
    let plan: Plan

    var body: some View {
        let budget = plan.request.budget
        let share = plan.totalCost / max(1, budget)
        Card {
            HStack(spacing: 18) {
                RingGauge(progress: share, tint: share > 1 ? Theme.warn : Theme.accent, lineWidth: 10) {
                    VStack(spacing: 0) {
                        Text(Fmt.money0(plan.totalCost)).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                        Text("of \(Fmt.money0(budget))").font(.caption).foregroundStyle(Theme.ink3)
                    }
                }
                .frame(width: 104, height: 104)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Fmt.money(plan.totalCost)) of a \(Fmt.money0(budget)) budget")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    MiniStat(value: "\(plan.mealsPlanned)/\(plan.mealsRequired)", label: "meals")
                    MiniStat(value: "\(plan.sessions.count)", label: plan.sessions.count == 1 ? "cook" : "cooks")
                    MiniStat(value: "\(plan.distinctIngredients)", label: "ingredients")
                    MiniStat(value: Fmt.money0(max(0, plan.wasteBaseline - plan.wastePlan)), label: "waste avoided")
                }
            }
        }
    }
}

struct MiniStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(Theme.ink)
            Text(label).font(.caption).foregroundStyle(Theme.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Meals

struct WeekMeals: View {
    let plan: Plan
    private var days: [Int] { Array(Set(plan.meals.map(\.day))).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if plan.mealsUnfilled > 0 { InlineNotice(text: uncovered, tone: .warn) }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(days, id: \.self) { d in
                        NavigationLink { DayDetailView(plan: plan, day: d) } label: { DayRow(plan: plan, day: d) }
                            .buttonStyle(.plain)
                        if d != days.last { Divider().padding(.leading, 68) }
                    }
                }
            }
        }
    }

    private var uncovered: String {
        if let b = plan.budgetToCoverAll { return "\(plan.mealsUnfilled) meals aren't covered. \(Fmt.money(b)) would cover all \(plan.mealsRequired)." }
        if let s = plan.sessionsToCoverAll { return "\(plan.mealsUnfilled) meals aren't covered. Cooking \(s) times would cover them." }
        return "\(plan.mealsUnfilled) meals aren't covered with these limits. More budget, time, or kitchen tools would help."
    }
}

struct DayRow: View {
    let plan: Plan
    let day: Int

    var body: some View {
        let meals = plan.meals.filter { $0.day == day }
        let label = meals.first?.label ?? ""
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(String(label.prefix(3)).uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Theme.ink3)
                Text(PlanClock.date(day).formatted(.dateTime.day())).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                Image(systemName: "flame.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                    .opacity(plan.sessionDays.contains(day) ? 1 : 0)
            }
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(meals) { m in
                    HStack(spacing: 8) {
                        if let r = plan.recipe(m.recipeId), !m.isSkipped {
                            RecipeThumb(id: r.id, name: r.name, tags: r.tags ?? [], moods: r.moods ?? [], size: 24)
                            Text(r.name).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1)
                        } else {
                            Image(systemName: m.isSkipped ? "calendar" : "minus.circle").font(.subheadline)
                                .foregroundStyle(Theme.ink3).frame(width: 24)
                            Text(m.isSkipped ? "Out · \(m.reason ?? "calendar")" : "Nothing planned")
                                .font(.subheadline).foregroundStyle(Theme.ink3).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
        }
        .padding(12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cooking

struct WeekCooking: View {
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hands-on minutes per cook").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Chart {
                        ForEach(plan.sessions) { s in
                            BarMark(x: .value("Day", s.label), y: .value("Minutes", s.activeMinutes))
                                .foregroundStyle(Theme.accent)
                                .cornerRadius(6)
                                .annotation(position: .top) {
                                    Text("\(s.activeMinutes)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.ink2)
                                }
                        }
                        RuleMark(y: .value("Your cap", plan.request.maxActiveMinutesPerSession))
                            .foregroundStyle(Theme.warn.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("your cap").font(.caption2).foregroundStyle(Theme.warn)
                            }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 150)
                }
            }
            ForEach(plan.sessions) { s in
                NavigationLink { SessionView(session: s, plan: plan) } label: { SessionCard(plan: plan, session: s) }
                    .buttonStyle(.plain)
            }
        }
    }
}

struct SessionCard: View {
    let plan: Plan
    let session: Session

    var body: some View {
        let recipes = session.recipeIds.compactMap { plan.recipe($0) }
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.label).font(.headline).foregroundStyle(Theme.ink)
                    Text("\(Fmt.minutes(session.activeMinutes)) hands on").font(.subheadline).foregroundStyle(Theme.ink2)
                }
                HStack(spacing: -6) {
                    ForEach(recipes.prefix(7)) { r in
                        RecipeThumb(id: r.id, name: r.name, tags: r.tags ?? [], moods: r.moods ?? [], size: 30, outlined: true)
                    }
                }
                Text(recipes.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(Theme.ink2).lineLimit(2)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .contentShape(Rectangle())
    }
}

// MARK: - Insights

struct WeekInsights: View {
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink { CostView(plan: plan) } label: {
                Card { CostDonut(plan: plan, compact: true) }
            }
            .buttonStyle(.plain)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink { ConsideredView(plan: plan) } label: {
                        NavRow(title: "What shaped your plan", subtitle: "Every answer you gave, and what it did", systemImage: "slider.horizontal.3")
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { CostView(plan: plan) } label: {
                        NavRow(title: "Where the money goes", subtitle: "\(Fmt.money(plan.totalCost)) by aisle and by item", systemImage: "chart.pie")
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { ChainView(plan: plan) } label: {
                        NavRow(title: "How it chains", subtitle: "What you cook first becomes what you eat later", systemImage: "arrow.triangle.branch")
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { FreshnessView(plan: plan) } label: {
                        NavRow(title: "Nothing rots", subtitle: "Every perishable, used inside its window", systemImage: "leaf")
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { NotesView(plan: plan) } label: {
                        NavRow(title: "Notes", subtitle: plan.warnings.isEmpty ? "How this week fits together" : "\(plan.warnings.count) to check",
                               systemImage: plan.warnings.isEmpty ? "text.alignleft" : "exclamationmark.circle",
                               tint: plan.warnings.isEmpty ? Theme.accent : Theme.warn)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AisleCost: Identifiable {
    let id: String
    let cost: Double
    let color: Color
}

extension Plan {
    var aisleCosts: [AisleCost] {
        var totals: [String: Double] = [:]
        for item in shopping where item.cost > 0 { totals[item.section, default: 0] += item.cost }
        return totals.sorted { $0.value > $1.value }.enumerated().map { pair in
            AisleCost(id: pair.element.key, cost: pair.element.value, color: RecipeArt.palette[pair.offset % RecipeArt.palette.count])
        }
    }
}

struct CostDonut: View {
    let plan: Plan
    var compact = false

    var body: some View {
        let aisles = plan.aisleCosts
        HStack(spacing: 18) {
            Chart(aisles) { a in
                SectorMark(angle: .value("Cost", a.cost), innerRadius: .ratio(0.64), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(a.color)
            }
            .chartBackground { _ in
                VStack(spacing: 0) {
                    Text(Fmt.money0(plan.totalCost)).font(.headline.monospacedDigit()).foregroundStyle(Theme.ink)
                    Text("total").font(.caption2).foregroundStyle(Theme.ink3)
                }
            }
            .frame(width: compact ? 112 : 170, height: compact ? 112 : 170)
            VStack(alignment: .leading, spacing: 7) {
                if compact { Text("Where the money goes").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink) }
                ForEach(aisles.prefix(compact ? 4 : 12)) { a in
                    HStack(spacing: 8) {
                        Circle().fill(a.color).frame(width: 8, height: 8)
                        Text(a.id).font(.caption).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.money(a.cost)).font(.caption.monospacedDigit()).foregroundStyle(Theme.ink2)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CostView: View {
    let plan: Plan

    var body: some View {
        let items = Array(plan.shopping.filter { $0.cost > 0 }.sorted { $0.cost > $1.cost }.prefix(8))
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card { CostDonut(plan: plan) }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Biggest items").font(.headline).foregroundStyle(Theme.ink)
                            Chart(items) { i in
                                BarMark(x: .value("Cost", i.cost), y: .value("Item", i.name))
                                    .foregroundStyle(Theme.accent)
                                    .cornerRadius(4)
                                    .annotation(position: .trailing) {
                                        Text(Fmt.money(i.cost)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.ink2)
                                    }
                            }
                            .chartXAxis(.hidden)
                            .frame(height: CGFloat(max(1, items.count)) * 32 + 8)
                        }
                    }
                    Card {
                        VStack(spacing: 10) {
                            line("Per meal", Fmt.money(plan.totalCost / Double(max(1, plan.mealsPlanned))))
                            line("Left in budget", Fmt.money(max(0, plan.request.budget - plan.totalCost)))
                            Divider()
                            line("Waste if you bought per recipe", Fmt.money(plan.wasteBaseline))
                            line("Waste with this plan", Fmt.money(plan.wastePlan))
                        }
                    }
                    Text("Salt, oil, and spices are assumed to be in your pantry and aren't counted.").font(.caption).foregroundStyle(Theme.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle("Where the money goes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.ink2)
            Spacer()
            Text(value).foregroundStyle(Theme.ink).monospacedDigit()
        }
        .font(.subheadline)
    }
}

/// Every onboarding answer next to what it did to this week, measured by the planner.
struct ConsideredView: View {
    @EnvironmentObject var state: AppState
    let plan: Plan

    var body: some View {
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Everything you told us, and what it did. Each line is measured on this week's plan.")
                        .font(.subheadline).foregroundStyle(Theme.ink2)
                    if let items = plan.considered, !items.isEmpty {
                        ForEach(items, id: \.self) { c in
                            let q = question(c.key)
                            HStack(alignment: .top, spacing: 12) {
                                IconBadge(systemImage: q.icon)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(q.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                        Spacer(minLength: 4)
                                        if !q.answer.isEmpty {
                                            Text(q.answer).font(.caption).foregroundStyle(Theme.ink3).lineLimit(2).multilineTextAlignment(.trailing)
                                        }
                                    }
                                    Text(c.effect).font(.subheadline).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle()
                            .accessibilityElement(children: .combine)
                        }
                        Text("Change any answer in You, and the week is rebuilt.").font(.caption).foregroundStyle(Theme.ink3)
                    } else {
                        InlineNotice(text: "Plan a week with the server to see how each answer shaped it.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle("What shaped your plan")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func question(_ key: String) -> (title: String, answer: String, icon: String) {
        let p = state.profile
        switch key {
        case "servings": return ("Feeding", p.servings == 1 ? "Just you" : "\(p.servings) people", "person.2")
        case "diet":
            let avoid = p.avoid.map { a in Labels.allergens.first { $0.0 == a }?.1 ?? a.humanized }
            return ("Diet and allergies", ([p.dietLabel] + avoid).joined(separator: ", "), "fork.knife")
        case "wont_eat": return ("Won't eat", names(p.wontEat), "xmark.circle")
        case "must_have": return ("Must have", "", "star")
        case "likes": return ("Likes", p.likes.map(Labels.like).joined(separator: ", "), "heart")
        case "skill": return ("Cooking level", p.levelLabel, "flame")
        case "kitchen": return ("Kitchen", "\(p.equipment.count) tools", "cooktop")
        case "budget": return ("Budget", "\(Fmt.money0(p.budget)) a week", "dollarsign.circle")
        case "sessions": return ("How often you cook", p.cookSessions == 1 ? "Once a week" : "\(p.cookSessions) times a week", "calendar")
        case "meals": return ("Meals a day", "\(p.mealsPerDay) a day", "sun.max")
        case "variety": return ("Variety", "Built in", "square.grid.2x2")
        case "goal_save": return ("Goal: spend less", "", "banknote")
        case "goal_waste": return ("Goal: stop wasting food", "", "leaf")
        case "goal_health": return ("Goal: eat better", "", "heart.text.square")
        case "goal_learn": return ("Goal: learn to cook", "", "graduationcap")
        case "calendar": return ("Calendar", "Connected", "calendar.badge.clock")
        case "pinned": return ("Pinned recipe", "", "pin")
        default: return (key.humanized, "", "circle")
        }
    }

    private func names(_ ids: [String]) -> String {
        ids.map { id in state.catalog.ingredients?.first { $0.id == id }?.name ?? id.humanized }.joined(separator: ", ")
    }
}

struct ChainView: View {
    let plan: Plan

    var body: some View {
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Ingredients on the left, recipes grouped by cook in the middle, days on the right. Dashed lines are food cooked once and eaten again later. Tap a recipe to trace it.")
                        .font(.subheadline).foregroundStyle(Theme.ink2)
                    Card { FlowGraphView(plan: plan) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle("How it chains")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FreshnessView: View {
    let plan: Plan

    var body: some View {
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Each bar is how long something lasts from shopping day. The dot is the last day the plan uses it. Green means it's used in time.")
                        .font(.subheadline).foregroundStyle(Theme.ink2)
                    Card { RotTimelineView(plan: plan) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle("Nothing rots")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NotesView: View {
    let plan: Plan

    var body: some View {
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.warnings, id: \.self) { w in InlineNotice(text: w, tone: .warn) }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(plan.explanations, id: \.self) { line in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle().fill(Theme.accent).frame(width: 6, height: 6).padding(.top, 7)
                                    Text(line).font(.subheadline).foregroundStyle(Theme.ink)
                                }
                            }
                            if let ms = plan.solveMs {
                                Text("Solved in \(Int(ms)) ms. No language model in the loop.").font(.caption).foregroundStyle(Theme.ink3)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
    }
}
