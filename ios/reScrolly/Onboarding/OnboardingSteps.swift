import SwiftUI

struct NameStep: View {
    @Binding var profile: UserProfile
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InputField(placeholder: "Your name", text: $profile.name, contentType: .givenName).focused($focused).onAppear { focused = true }
            TrustNote(text: "Only used to greet you. Never shown to anyone else.")
        }
    }
}

struct GoalsStep: View {
    @Binding var profile: UserProfile
    private let goals: [(String, String, String, String)] = [
        ("save", "Spend less on food", "Stay under a weekly number", "dollarsign.circle"),
        ("waste", "Stop throwing food away", "Use everything you buy", "leaf"),
        ("health", "Eat better than I do now", "Real meals instead of snacks", "heart"),
        ("learn", "Learn to actually cook", "Few techniques, repeated until they stick", "book"),
    ]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(goals, id: \.0) { g in
                ChoiceCard(title: g.1, subtitle: g.2, systemImage: g.3, selected: profile.goals.contains(g.0)) {
                    if profile.goals.contains(g.0) { profile.goals.removeAll { $0 == g.0 } } else { profile.goals.append(g.0) }
                }
            }
        }
    }
}

struct ServingsStep: View {
    @Binding var profile: UserProfile
    var body: some View {
        VStack(spacing: 10) {
            ChoiceCard(title: "Just me", systemImage: "person", selected: profile.servings == 1) { profile.servings = 1 }
            ChoiceCard(title: "Two of us", systemImage: "person.2", selected: profile.servings == 2) { profile.servings = 2 }
            ChoiceCard(title: "Three", systemImage: "person.3", selected: profile.servings == 3) { profile.servings = 3 }
            ChoiceCard(title: "Four", systemImage: "person.3.fill", selected: profile.servings == 4) { profile.servings = 4 }
            Card {
                Stepper("More: \(profile.servings) people", value: $profile.servings, in: 1...8).font(.body)
            }
        }
    }
}

struct DietStep: View {
    @Binding var profile: UserProfile
    var body: some View {
        VStack(spacing: 10) {
            ChoiceCard(title: "I eat everything", systemImage: "fork.knife", selected: profile.dietStyle == "everything") { profile.dietStyle = "everything" }
            ChoiceCard(title: "Vegetarian", subtitle: "No meat or fish", systemImage: "carrot", selected: profile.dietStyle == "vegetarian") { profile.dietStyle = "vegetarian" }
            ChoiceCard(title: "Pescatarian", subtitle: "Fish, no meat", systemImage: "fish", selected: profile.dietStyle == "pescatarian") { profile.dietStyle = "pescatarian" }
            ChoiceCard(title: "Vegan", subtitle: "No animal products", systemImage: "leaf", selected: profile.dietStyle == "vegan") { profile.dietStyle = "vegan" }
        }
    }
}

struct AvoidStep: View {
    @Binding var profile: UserProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowLayout(spacing: 8) {
                ForEach(Labels.allergens, id: \.0) { o in
                    Chip(title: o.1, selected: profile.avoid.contains(o.0)) {
                        if profile.avoid.contains(o.0) { profile.avoid.removeAll { $0 == o.0 } } else { profile.avoid.append(o.0) }
                    }
                }
            }
            InlineNotice(text: "Anything selected here is excluded outright. A recipe containing it is never planned, even if it would be cheaper.")
        }
    }
}

/// Search-and-pick over the ingredient catalog. Used for both "won't eat" and "must have".
struct IngredientPickStep: View {
    @Binding var selection: [String]
    let catalog: CatalogInfo
    var exclude: [String] = []
    var prompt: String
    var tone: InlineNotice.Tone
    @State private var query = ""

    private var all: [CatalogIngredient] {
        catalog.ingredients ?? [
            CatalogIngredient(id: "cilantro", name: "Cilantro", section: "Produce"), CatalogIngredient(id: "onion", name: "Yellow onions", section: "Produce"),
            CatalogIngredient(id: "tofu", name: "Firm tofu", section: "Produce"), CatalogIngredient(id: "broccoli", name: "Broccoli", section: "Produce"),
            CatalogIngredient(id: "spinach", name: "Spinach", section: "Produce"), CatalogIngredient(id: "eggs", name: "Eggs", section: "Dairy & Eggs"),
        ]
    }
    private var matches: [CatalogIngredient] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = all.filter { !exclude.contains($0.id) }
        if q.isEmpty { return pool.filter { !$0.id.hasPrefix("custom_") }.sorted { $0.name < $1.name } }
        return pool.filter { $0.name.lowercased().contains(q) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !selection.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(selection, id: \.self) { id in
                        Chip(title: (all.first { $0.id == id }?.name ?? id.humanized) + "  ×", selected: true) { selection.removeAll { $0 == id } }
                    }
                }
            }
            InputField(placeholder: prompt, text: $query)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(matches.prefix(12)) { ing in
                        Button {
                            if selection.contains(ing.id) { selection.removeAll { $0 == ing.id } } else { selection.append(ing.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(ing.name).foregroundStyle(Theme.ink)
                                    Text(ing.section).font(.caption).foregroundStyle(Theme.ink3)
                                }
                                Spacer()
                                Image(systemName: selection.contains(ing.id) ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(selection.contains(ing.id) ? Theme.accent : Theme.ink3)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if ing.id != matches.prefix(12).last?.id { Divider().padding(.leading, 14) }
                    }
                    if matches.isEmpty { Text("Nothing matches. Add it as a recipe later and it joins the list.").font(.footnote).foregroundStyle(Theme.ink3).padding(14) }
                }
            }
            if tone == .warn {
                InlineNotice(text: "Hard limit. No recipe with these will ever be planned.", tone: .warn)
            } else {
                InlineNotice(text: "Soft preference. We'll include a recipe with each of these if it fits the budget, and say so on the plan.")
            }
        }
    }
}

struct LikesStep: View {
    @Binding var profile: UserProfile
    let catalog: CatalogInfo
    private var options: [(String, String)] {
        let ids = catalog.moods ?? Labels.likes.map(\.0)
        return ids.map { ($0, Labels.like($0)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowLayout(spacing: 8) {
                ForEach(options, id: \.0) { o in
                    Chip(title: o.1, selected: profile.likes.contains(o.0)) {
                        if profile.likes.contains(o.0) { profile.likes.removeAll { $0 == o.0 } } else { profile.likes.append(o.0) }
                    }
                }
            }
            InlineNotice(text: "Recipes that match get picked first when the numbers are close. Nothing here is a hard rule.")
        }
    }
}

struct SkillStep: View {
    @Binding var profile: UserProfile
    var body: some View {
        VStack(spacing: 10) {
            ChoiceCard(title: "Beginner", subtitle: "Shorter sessions, simpler recipes", systemImage: "1.circle", selected: profile.cookingLevel == "beginner") { profile.cookingLevel = "beginner" }
            ChoiceCard(title: "Getting there", subtitle: "Up to 90 minutes hands-on per session", systemImage: "2.circle", selected: profile.cookingLevel == "some") { profile.cookingLevel = "some" }
            ChoiceCard(title: "Confident", subtitle: "Longer sessions, more in parallel", systemImage: "3.circle", selected: profile.cookingLevel == "confident") { profile.cookingLevel = "confident" }
        }
    }
}

struct KitchenStep: View {
    @Binding var profile: UserProfile
    let options: [String]
    private let icons: [String: String] = ["stove": "flame", "oven": "oven", "pan": "frying.pan", "pot": "cooktop", "sheet_pan": "rectangle", "microwave": "microwave", "blender": "tornado"]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(options, id: \.self) { eq in
                ChoiceCard(title: Labels.equipment[eq] ?? eq.humanized, systemImage: icons[eq] ?? "square", selected: profile.equipment.contains(eq)) {
                    if profile.equipment.contains(eq) { profile.equipment.removeAll { $0 == eq } } else { profile.equipment.append(eq) }
                }
            }
            if profile.equipment.isEmpty { InlineNotice(text: "Pick at least one. A microwave alone still gets you a plan.", tone: .warn) }
        }
    }
}

struct BudgetStep: View {
    @Binding var profile: UserProfile
    private var perMeal: Double { profile.budget / Double(max(1, 7 * profile.mealsPerDay * profile.servings)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.money0(profile.budget)).font(.system(size: 44, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                        Text("per week").foregroundStyle(Theme.ink2)
                    }
                    Slider(value: $profile.budget, in: 20...300, step: 5)
                    HStack {
                        Text("$20").font(.caption).foregroundStyle(Theme.ink3)
                        Spacer()
                        Text("About \(Fmt.money(perMeal)) per person per meal").font(.caption).foregroundStyle(Theme.ink2)
                        Spacer()
                        Text("$300").font(.caption).foregroundStyle(Theme.ink3)
                    }
                }
            }
            InlineNotice(text: "Salt, oil, and spices are assumed to be in your pantry and aren't counted.")
        }
    }
}

struct FrequencyStep: View {
    @Binding var profile: UserProfile
    private let options: [(Int, String, String)] = [
        (1, "Once", "One big session. Everything else is reheating."),
        (2, "Twice", "Start of the week and midweek. The sweet spot for most people."),
        (3, "Three times", "Fresher meals, shorter sessions."),
        (4, "Four times", "Short sessions every other day."),
    ]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(options, id: \.0) { o in
                ChoiceCard(title: o.1, subtitle: o.2, systemImage: "\(o.0).circle", selected: profile.cookSessions == o.0) { profile.cookSessions = o.0 }
            }
        }
    }
}

struct MealsStep: View {
    @Binding var profile: UserProfile
    var body: some View {
        VStack(spacing: 10) {
            ChoiceCard(title: "One", subtitle: "Dinner only", systemImage: "moon", selected: profile.mealsPerDay == 1) { profile.mealsPerDay = 1 }
            ChoiceCard(title: "Two", subtitle: "Lunch and dinner", systemImage: "sun.max", selected: profile.mealsPerDay == 2) { profile.mealsPerDay = 2 }
            ChoiceCard(title: "Three", subtitle: "Breakfast, lunch, dinner", systemImage: "sunrise", selected: profile.mealsPerDay == 3) { profile.mealsPerDay = 3 }
        }
    }
}

struct ShopDayStep: View {
    @Binding var profile: UserProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { d in
                        Button { profile.shopWeekday = d } label: {
                            HStack {
                                Text(Labels.weekdays[d]).foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: profile.shopWeekday == d ? "checkmark.circle.fill" : "circle").foregroundStyle(profile.shopWeekday == d ? Theme.accent : Theme.line).font(.title3)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        if d < 6 { Divider().padding(.leading, 14) }
                    }
                }
            }
            Card {
                Toggle(isOn: $profile.notifications) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check in the evening before").foregroundStyle(Theme.ink)
                        Text("One notification a week: anything changed?").font(.caption).foregroundStyle(Theme.ink2)
                    }
                }
                .tint(Theme.accent)
            }
        }
    }
}

struct CalendarStep: View {
    @Binding var profile: UserProfile
    @EnvironmentObject var state: AppState
    @State private var asking = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar").font(.title3).foregroundStyle(Theme.accent).frame(width: 36, height: 36).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.calendar.authorized && profile.useCalendar ? "Calendar connected" : "Connect your calendar").foregroundStyle(Theme.ink)
                            Text("Read only. Events never leave the phone.").font(.caption).foregroundStyle(Theme.ink2)
                        }
                    }
                    if state.calendar.authorized && profile.useCalendar {
                        let c = state.calendar.lastConflicts
                        if c.isEmpty {
                            Text("Nothing on the calendar clashes with a meal this week.").font(.subheadline).foregroundStyle(Theme.ink2)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("We'll leave these open:").font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                                ForEach(c, id: \.self) { s in
                                    Text("\(Labels.weekdays[(Calendar.current.component(.weekday, from: Date()) - 1 + s.day) % 7]) \(s.slot): \(s.reason)")
                                        .font(.subheadline).foregroundStyle(Theme.ink2)
                                }
                            }
                        }
                        Button("Disconnect") { profile.useCalendar = false }.font(.subheadline).foregroundStyle(Theme.warn)
                    } else {
                        PrimaryButton(title: "Connect", isLoading: asking) {
                            asking = true
                            Task { _ = await state.connectCalendar(); asking = false }
                        }
                    }
                }
            }
            TrustNote(text: "We look at event titles and times for the next seven days, on the phone, to spot lunches and dinners. Nothing is uploaded.")
        }
    }
}
