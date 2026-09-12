import SwiftUI

/// The plan starts the day it was made. Day 0 is shopping and the first cook.
enum PlanClock {
    static var start: Date { Calendar.current.startOfDay(for: UserDefaults.standard.object(forKey: "plan_started") as? Date ?? Date()) }
    static var todayIndex: Int {
        let d = Calendar.current.dateComponents([.day], from: start, to: Calendar.current.startOfDay(for: Date())).day ?? 0
        return min(max(d, 0), 6)
    }
    static func date(_ day: Int) -> Date { Calendar.current.date(byAdding: .day, value: day, to: start) ?? start }
}

/// Today at a glance. The week is a strip of days: tap one to look at it, tap a meal to open the recipe.
struct TodayView: View {
    @EnvironmentObject var state: AppState
    @State private var selected: Int?

    var body: some View {
        Screen {
            if let plan = state.plan {
                let today = PlanClock.todayIndex
                let day = selected ?? today
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dateLine(plan, day: day)).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Theme.accent)
                            Text(greeting(day: day, today: today)).font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.ink)
                        }
                        DayStrip(plan: plan, selected: day, today: today) { d in
                            withAnimation(.snappy) { selected = d == today ? nil : d }
                        }
                        DayContent(plan: plan, day: day)
                        if state.usedFallback {
                            InlineNotice(text: "This is a sample week. Connect to the server in You → Server to plan your own.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dateLine(_ plan: Plan, day: Int) -> String {
        let label = plan.meals.first { $0.day == day }?.label ?? ""
        return "\(label.uppercased()) · \(PlanClock.date(day).formatted(.dateTime.month(.abbreviated).day()).uppercased())"
    }

    private func greeting(day: Int, today: Int) -> String {
        if day != today { return day < today ? "Earlier this week" : "Coming up" }
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        return state.profile.name.isEmpty ? part : "\(part), \(state.profile.name)"
    }
}

/// Seven days in a row that always fits the screen. A flame marks cook days.
struct DayStrip: View {
    let plan: Plan
    let selected: Int
    let today: Int
    let onSelect: (Int) -> Void

    private var days: [Int] { Array(Set(plan.meals.map(\.day))).sorted() }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { d in
                let isSelected = d == selected
                let cooks = plan.sessionDays.contains(d)
                let label = plan.meals.first { $0.day == d }?.label ?? ""
                Button { onSelect(d) } label: {
                    VStack(spacing: 5) {
                        Text(String(label.prefix(1)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Theme.ink3)
                        Text(PlanClock.date(d).formatted(.dateTime.day()))
                            .font(.callout.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(isSelected ? Color.white : (d == today ? Theme.accent : Theme.ink))
                        Image(systemName: "flame.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(isSelected ? Color.white : Theme.accent)
                            .opacity(cooks ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(isSelected ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isSelected ? Color.clear : Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label + (cooks ? ", cook day" : "") + (d == today ? ", today" : ""))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// One day: whether you cook, the meals, and what's waiting in the fridge.
struct DayContent: View {
    let plan: Plan
    let day: Int

    var body: some View {
        let meals = plan.meals.filter { $0.day == day }
        VStack(alignment: .leading, spacing: 22) {
            if let s = plan.sessions.first(where: { $0.day == day }) {
                NavigationLink { SessionView(session: s, plan: plan) } label: { CookDayCard(plan: plan, session: s) }
                    .buttonStyle(.plain)
            } else {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "refrigerator", tint: Theme.ink2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No cooking today").font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                        Text("Everything comes from the fridge. Just reheat.").font(.subheadline).foregroundStyle(Theme.ink2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .cardStyle()
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Meals", detail: "\(meals.filter { $0.recipeId != nil }.count) planned")
                ForEach(meals) { m in MealRow(plan: plan, meal: m) }
            }
            FridgeGrid(plan: plan, day: day)
        }
    }
}

struct CookDayCard: View {
    let plan: Plan
    let session: Session

    var body: some View {
        let recipes = session.recipeIds.compactMap { plan.recipe($0) }
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Cook day", systemImage: "flame.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.white.opacity(0.9))
                Text("\(recipes.count) \(recipes.count == 1 ? "recipe" : "recipes") · \(Fmt.minutes(session.activeMinutes)) hands on")
                    .font(.title3.weight(.semibold)).foregroundStyle(Color.white)
                HStack(spacing: -8) {
                    ForEach(recipes.prefix(6)) { r in
                        RecipeThumb(id: r.id, name: r.name, tags: r.tags ?? [], moods: r.moods ?? [], size: 34, outlined: true)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(Color.white.opacity(0.8))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the cooking order")
    }
}

struct MealRow: View {
    let plan: Plan
    let meal: Meal

    private var icon: String { meal.slot == "breakfast" ? "sunrise" : (meal.slot == "lunch" ? "sun.max" : "moon.stars") }

    var body: some View {
        if let r = plan.recipe(meal.recipeId), !meal.isSkipped {
            NavigationLink { RecipeView(recipe: r, plan: plan) } label: { row(title: r.name, detail: detail(r), recipe: r) }
                .buttonStyle(.plain)
        } else {
            row(title: meal.isSkipped ? "Out" : "Nothing planned",
                detail: meal.isSkipped ? (meal.reason ?? "On your calendar") : "Not covered with this week's limits", recipe: nil)
        }
    }

    private func detail(_ r: PlanRecipe) -> String {
        guard let s = plan.sessions.first(where: { $0.index == r.session }) else { return "" }
        return s.day == meal.day ? "Cook today" : "From \(s.label)'s cook"
    }

    private func row(title: String, detail: String, recipe: PlanRecipe?) -> some View {
        HStack(spacing: 14) {
            if let r = recipe {
                RecipeThumb(id: r.id, name: r.name, tags: r.tags ?? [], moods: r.moods ?? [], size: 52)
            } else {
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.line.opacity(0.5))
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: meal.isSkipped ? "calendar" : "minus").foregroundStyle(Theme.ink3))
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(meal.slot.titled, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                Text(title).font(.body.weight(.semibold)).foregroundStyle(recipe == nil ? Theme.ink3 : Theme.ink).lineLimit(2)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Theme.ink2) }
            }
            Spacer(minLength: 8)
            if recipe != nil { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .contentShape(Rectangle())
    }
}

/// What earlier cooks left in the fridge and how many days each has left, as rings.
struct FridgeGrid: View {
    let plan: Plan
    let day: Int

    private struct Item: Identifiable {
        let recipe: PlanRecipe
        let component: QtyItem
        let cookDay: Int
        var id: String { "\(recipe.id)-\(component.id)" }
    }

    var body: some View {
        let items: [Item] = plan.recipes.flatMap { r -> [Item] in
            guard let cook = plan.sessions.first(where: { $0.index == r.session })?.day, cook <= day else { return [] }
            return r.produces.map { Item(recipe: r, component: $0, cookDay: cook) }
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "In the fridge", detail: "cooked once, eaten later")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(items) { item in
                        let keeps = max(1, item.recipe.keepsDays)
                        let left = max(0, item.cookDay + item.recipe.keepsDays - day)
                        HStack(spacing: 12) {
                            RingGauge(progress: Double(left) / Double(keeps), tint: left <= 1 ? Theme.warn : Theme.accent, lineWidth: 5) {
                                Text("\(left)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                            }
                            .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.component.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(2)
                                Text(left == 1 ? "1 day left" : "\(left) days left").font(.caption).foregroundStyle(Theme.ink2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// A single day, opened from the week.
struct DayDetailView: View {
    let plan: Plan
    let day: Int

    var body: some View {
        Screen {
            ScrollView {
                DayContent(plan: plan, day: day)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .navigationTitle(plan.meals.first { $0.day == day }?.label ?? "Day")
        .navigationBarTitleDisplayMode(.inline)
    }
}
