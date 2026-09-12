import SwiftUI

struct PlanView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Screen {
            if let plan = state.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SummaryCard(plan: plan)
                        if state.usedFallback {
                            InlineNotice(text: "Sample week. Connect to the server in Profile to plan your own.")
                        }
                        SectionTitle(text: "The week")
                        WeekGrid(plan: plan)
                        SectionTitle(text: "Cook sessions")
                        SessionsSummary(plan: plan)
                        VStack(alignment: .leading, spacing: 2) {
                            SectionTitle(text: "How it chains")
                            Text("What you cook first becomes what you eat later. Tap a recipe.").font(.subheadline).foregroundStyle(Theme.ink2)
                        }
                        Card { FlowGraphView(plan: plan) }
                        VStack(alignment: .leading, spacing: 2) {
                            SectionTitle(text: "Nothing rots")
                            Text("Every perishable is used inside its window.").font(.subheadline).foregroundStyle(Theme.ink2)
                        }
                        Card { RotTimelineView(plan: plan) }
                        SectionTitle(text: "Why this plan")
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(plan.explanations, id: \.self) { line in
                                    HStack(alignment: .top, spacing: 10) {
                                        Circle().fill(Theme.accent).frame(width: 6, height: 6).padding(.top, 7)
                                        Text(line).font(.subheadline).foregroundStyle(Theme.ink)
                                    }
                                }
                                ForEach(plan.warnings, id: \.self) { w in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warn).font(.subheadline)
                                        Text(w).font(.subheadline).foregroundStyle(Theme.ink)
                                    }
                                }
                                if let ms = plan.solveMs {
                                    Text("Solved in \(Int(ms)) ms. No language model in the loop.").font(.caption).foregroundStyle(Theme.ink3).padding(.top, 4)
                                }
                            }
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
                Button("Replan") { Task { await state.replan() } }
            }
        }
    }
}

struct SummaryCard: View {
    let plan: Plan
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.money(plan.totalCost)).font(.system(size: 36, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                    Text("of \(Fmt.money0(plan.request.budget))").foregroundStyle(Theme.ink2)
                    Spacer()
                }
                Divider()
                HStack(spacing: 0) {
                    Stat(value: "\(plan.mealsPlanned) of \(plan.mealsRequired)", label: (plan.mealsSkipped ?? 0) > 0 ? "meals, \(plan.mealsSkipped!) out" : "meals")
                    Stat(value: "\(plan.sessions.count)", label: plan.sessions.count == 1 ? "cook" : "cooks")
                    Stat(value: "\(plan.distinctIngredients)", label: "ingredients")
                    Stat(value: Fmt.money(plan.wastePlan), label: "est. waste")
                }
                if plan.mealsUnfilled > 0 {
                    Divider()
                    if let b = plan.budgetToCoverAll {
                        Text("Covering all \(plan.mealsRequired) meals would cost \(Fmt.money(b)).").font(.subheadline).foregroundStyle(Theme.ink)
                    } else if let s = plan.sessionsToCoverAll {
                        Text("Cooking \(s) times instead would cover every meal.").font(.subheadline).foregroundStyle(Theme.ink)
                    } else {
                        Text("\(plan.mealsUnfilled) meals aren't covered with these limits.").font(.subheadline).foregroundStyle(Theme.ink)
                    }
                }
                Divider()
                Text("Buying each recipe's ingredients separately would waste about \(Fmt.money(plan.wasteBaseline)) in unused perishables. This plan wastes about \(Fmt.money(plan.wastePlan)).")
                    .font(.footnote).foregroundStyle(Theme.ink2)
            }
        }
    }
}

struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(Theme.ink)
            Text(label).font(.caption).foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WeekGrid: View {
    let plan: Plan
    private var days: [Int] { Array(Set(plan.meals.map(\.day))).sorted() }

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let dayMeals = plan.meals.filter { $0.day == day }
                    let cooks = plan.sessionDays.contains(day)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(dayMeals.first?.label.prefix(3) ?? "")).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            if cooks { Text("cook").font(.caption2.weight(.medium)).foregroundStyle(Theme.accent) }
                        }
                        .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(dayMeals) { m in
                                HStack {
                                    Text(m.slot.titled).font(.caption).foregroundStyle(Theme.ink2).frame(width: 64, alignment: .leading)
                                    if m.isSkipped {
                                        Text("Out · \(m.reason ?? "calendar")").font(.subheadline).foregroundStyle(Theme.ink3).lineLimit(1)
                                    } else {
                                        Text(plan.recipe(m.recipeId)?.name ?? "—").font(.subheadline).foregroundStyle(m.recipeId == nil ? Theme.ink3 : Theme.ink)
                                    }
                                    if let r = plan.recipe(m.recipeId), r.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.accent) }
                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding(16)
                    if day != days.last { Divider().padding(.leading, 16) }
                }
            }
        }
    }
}

struct SessionsSummary: View {
    let plan: Plan
    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(plan.sessions) { s in
                    NavigationLink { SessionView(session: s, plan: plan) } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                Text("\(Fmt.minutes(s.activeMinutes)) hands on").font(.caption).foregroundStyle(Theme.ink2)
                            }
                            .frame(width: 110, alignment: .leading)
                            Text(s.recipeIds.compactMap { plan.recipe($0)?.name }.joined(separator: ", ")).font(.subheadline).foregroundStyle(Theme.ink)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                        }
                        .padding(16)
                    }
                    .buttonStyle(.plain)
                    if s.id != plan.sessions.last?.id { Divider().padding(.leading, 16) }
                }
            }
        }
    }
}
