import SwiftUI

struct TodayView: View {
    @EnvironmentObject var state: AppState

    private var todayIndex: Int {
        // Plan day 0 is the shopping/first cook day. We show the week in order from the day the plan was made.
        let stored = UserDefaults.standard.object(forKey: "plan_started") as? Date ?? Date()
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: stored), to: Calendar.current.startOfDay(for: Date())).day ?? 0
        return min(max(days, 0), 6)
    }

    var body: some View {
        Screen {
            if let plan = state.plan {
                let day = todayIndex
                let meals = plan.meals.filter { $0.day == day }
                let session = plan.sessions.first { $0.day == day }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.profile.name.isEmpty ? "Today" : "Hi \(state.profile.name)").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(dayLine(day: day, cooks: session != nil)).foregroundStyle(Theme.ink2)
                        }

                        if let s = session {
                            NavigationLink { SessionView(session: s, plan: plan) } label: {
                                Card {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Cook day").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                                            Text(s.recipeIds.compactMap { plan.recipe($0)?.name }.joined(separator: ", ")).font(.body).foregroundStyle(Theme.ink)
                                            Text("\(Fmt.minutes(s.activeMinutes)) hands on").font(.subheadline).foregroundStyle(Theme.ink2)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(Theme.ink3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        SectionTitle(text: "Meals")
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(meals) { m in
                                    HStack {
                                        Text(m.slot.titled).font(.subheadline).foregroundStyle(Theme.ink2).frame(width: 84, alignment: .leading)
                                        if m.isSkipped {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text("Out").foregroundStyle(Theme.ink3)
                                                Text(m.reason ?? "On your calendar").font(.caption).foregroundStyle(Theme.ink3)
                                            }
                                        } else {
                                            Text(plan.recipe(m.recipeId)?.name ?? "Nothing planned").foregroundStyle(m.recipeId == nil ? Theme.ink3 : Theme.ink)
                                        }
                                        Spacer()
                                        if let r = plan.recipe(m.recipeId), let sess = plan.sessions.first(where: { $0.index == r.session }), sess.day != day {
                                            Text("from \(sess.label.prefix(3))").font(.caption).foregroundStyle(Theme.ink3)
                                        }
                                    }
                                    .padding(16)
                                    if m.id != meals.last?.id { Divider().padding(.leading, 16) }
                                }
                            }
                        }

                        SectionTitle(text: "In the fridge")
                        FridgeView(plan: plan, day: day)

                        if state.usedFallback {
                            InlineNotice(text: "This is a sample week. Connect to the server in Profile to plan your own.")
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dayLine(day: Int, cooks: Bool) -> String {
        let name = state.plan?.meals.first { $0.day == day }?.label ?? ""
        return cooks ? "\(name). You cook today." : "\(name). Nothing to cook, just reheat."
    }
}

/// Components made so far and how long they keep. Derived from the plan, not tracked.
struct FridgeView: View {
    let plan: Plan
    let day: Int
    var body: some View {
        let made = plan.recipes.filter { r in (plan.sessions.first { $0.index == r.session }?.day ?? 99) <= day && !r.produces.isEmpty }
        Card(padding: 0) {
            if made.isEmpty {
                Text("Nothing cooked yet.").foregroundStyle(Theme.ink3).padding(16)
            } else {
                VStack(spacing: 0) {
                    ForEach(made) { r in
                        let cookDay = plan.sessions.first { $0.index == r.session }?.day ?? 0
                        ForEach(r.produces) { p in
                            HStack {
                                Text(p.name).foregroundStyle(Theme.ink)
                                Spacer()
                                Text("good \(max(0, cookDay + r.keepsDays - day)) more days").font(.caption).foregroundStyle(Theme.ink2)
                            }
                            .padding(16)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }
}
