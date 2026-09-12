import SwiftUI

/// The recipe library as a grid. Filters wrap onto new lines instead of scrolling sideways.
/// Long-press a card to pin or delete it.
struct RecipesView: View {
    @EnvironmentObject var state: AppState
    @State private var showImport = false
    @State private var query = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", yours = "Yours", pinned = "Pinned", quick = "Quick", breakfast = "Breakfast", vegetarian = "Vegetarian"
        var id: String { rawValue }
    }

    struct Item: Identifiable {
        let draft: RecipeDraft
        let custom: [CustomIngredient]
        let mine: Bool
        var id: String { draft.id }
    }

    private var items: [Item] {
        let mine = state.recipes.map { Item(draft: $0.recipe, custom: $0.customIngredients, mine: true) }
        let catalog = (state.catalog.recipes ?? []).filter { $0.meals > 0 }.sorted { $0.name < $1.name }.map { r in
            Item(draft: RecipeDraft(id: r.id, name: r.name, meals: r.meals, activeMinutes: r.activeMinutes, totalMinutes: r.totalMinutes, keepsDays: 3,
                                    ingredients: r.ingredients, steps: r.steps, equipment: [], tags: r.tags, moods: r.moods, source: "catalog", sourceRef: nil),
                 custom: [], mine: false)
        }
        return (mine + catalog).filter { matchesQuery($0) && passes($0) }
    }

    private func matchesQuery(_ item: Item) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || item.draft.name.localizedCaseInsensitiveContains(q) || item.draft.ingredients.contains { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func passes(_ item: Item) -> Bool {
        let d = item.draft
        let moods = d.moods ?? []
        switch filter {
        case .all: return true
        case .yours: return item.mine
        case .pinned: return state.pinned.contains(d.id)
        case .quick: return moods.contains("quick") || d.totalMinutes <= 20
        case .breakfast: return moods.contains("breakfast")
        case .vegetarian: return !d.tags.contains { ["meat", "poultry", "beef", "fish"].contains($0) }
        }
    }

    var body: some View {
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AddRecipeCard { showImport = true }
                    FlowLayout(spacing: 8) {
                        ForEach(Filter.allCases) { f in
                            Chip(title: f.rawValue, selected: filter == f) { withAnimation(.snappy) { filter = f } }
                        }
                    }
                    if !state.pinned.isEmpty { pinnedBanner }
                    let shown = items
                    if shown.isEmpty {
                        ContentUnavailableView(filter == .yours ? "No recipes of yours yet" : "Nothing matches",
                                               systemImage: filter == .yours ? "book" : "magnifyingglass",
                                               description: Text(filter == .yours ? "Share a reel or take a photo to add one." : "Try another filter or search."))
                            .padding(.top, 24)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(shown) { item in
                                NavigationLink { RecipeLibraryDetail(recipe: item.draft, custom: item.custom, mine: item.mine) } label: {
                                    RecipeTile(recipe: item.draft, mine: item.mine, pinned: state.pinned.contains(item.id))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { state.setPinned(item.id, !state.pinned.contains(item.id)) } label: {
                                        Label(state.pinned.contains(item.id) ? "Unpin" : "Pin to this week", systemImage: "pin")
                                    }
                                    if item.mine {
                                        Button(role: .destructive) { Task { await state.deleteRecipe(item.id) } } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle("Recipes")
        .searchable(text: $query, prompt: "Search recipes or ingredients")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImport = true } label: { Label("Add a recipe", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showImport) { RecipeImportView() }
        .refreshable { await state.loadRecipes() }
    }

    private var pinnedBanner: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: "pin.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text("\(state.pinned.count) pinned for this week").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("Replan to build the week around them.").font(.caption).foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 4)
            Button("Replan") { Task { await state.replan() } }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
        }
        .padding(12)
        .cardStyle()
    }
}

struct AddRecipeCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a recipe").font(.headline).foregroundStyle(Color.white)
                    Text("Share a reel, take a photo, or type it").font(.subheadline).foregroundStyle(Color.white.opacity(0.85))
                }
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    Image(systemName: "link")
                    Image(systemName: "camera")
                    Image(systemName: "text.cursor")
                }
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.85))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct RecipeTile: View {
    let recipe: RecipeDraft
    let mine: Bool
    let pinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecipeBanner(id: recipe.id, name: recipe.name, tags: recipe.tags, moods: recipe.moods ?? [], height: 96)
                .overlay(alignment: .topTrailing) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.white)
                            .padding(6).background(Theme.accent, in: Circle()).padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if mine {
                        Text("Yours").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.surface, in: Capsule()).padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2, reservesSpace: true)
                Text("\(recipe.meals) meals · \(Fmt.minutes(recipe.totalMinutes))").font(.caption).foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .cardStyle(radius: 18)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct RecipeLibraryDetail: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let recipe: RecipeDraft
    let custom: [CustomIngredient]
    let mine: Bool
    @State private var part: Part = .ingredients

    enum Part: String, CaseIterable, Identifiable {
        case ingredients = "Ingredients", steps = "Steps"
        var id: String { rawValue }
    }

    var body: some View {
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RecipeBanner(id: recipe.id, name: recipe.name, tags: recipe.tags, moods: recipe.moods ?? [], height: 150)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(recipe.name).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
                        FlowLayout(spacing: 6) {
                            Pill(text: "\(recipe.meals) meals", systemImage: "fork.knife")
                            Pill(text: "\(Fmt.minutes(recipe.activeMinutes)) hands on", systemImage: "hand.raised")
                            Pill(text: "\(Fmt.minutes(recipe.totalMinutes)) total", systemImage: "clock")
                            ForEach(recipe.tags, id: \.self) { t in
                                Pill(text: Labels.allergens.first { $0.0 == t }?.1 ?? t.humanized)
                            }
                        }
                    }
                    Toggle(isOn: Binding(get: { state.pinned.contains(recipe.id) }, set: { state.setPinned(recipe.id, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pin to this week").foregroundStyle(Theme.ink)
                            Text("The next plan is built around it.").font(.caption).foregroundStyle(Theme.ink2)
                        }
                    }
                    .tint(Theme.accent)
                    .padding(14)
                    .cardStyle()
                    Picker("Show", selection: $part) {
                        ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch part {
                    case .ingredients: IngredientList(items: recipe.ingredients)
                    case .steps: StepList(steps: recipe.steps)
                    }
                    if !custom.isEmpty {
                        InlineNotice(text: "Estimated prices for: " + custom.map { "\($0.name) \(Fmt.money($0.packPrice))" }.joined(separator: ", ") + ".")
                    }
                    if mine, let ref = recipe.sourceRef, !ref.isEmpty, let url = URL(string: ref) {
                        Link(destination: url) { Label("Open the original", systemImage: "arrow.up.right.square").font(.subheadline) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mine {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { Task { await state.deleteRecipe(recipe.id); dismiss() } } label: {
                            Label("Delete recipe", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }
}

/// Ingredients with amounts in the chosen units. `checkable` for ticking things off while cooking.
struct IngredientList: View {
    let items: [QtyItem]
    var checkable = false
    @State private var checked: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, i in
                if checkable {
                    Button { toggle(i.id) } label: { row(i) }.buttonStyle(.plain)
                } else {
                    row(i)
                }
                if idx < items.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .cardStyle()
        .sensoryFeedback(.selection, trigger: checked)
    }

    private func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    private func row(_ i: QtyItem) -> some View {
        let done = checked.contains(i.id)
        return HStack(spacing: 12) {
            if checkable {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Theme.accent : Theme.ink3)
            }
            Text(i.name).foregroundStyle(done ? Theme.ink3 : Theme.ink).strikethrough(done, color: Theme.ink3)
            if i.matched == false {
                Text("new").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 8)
            Text(Fmt.qty(i.qty, i.unit)).foregroundStyle(Theme.ink2).monospacedDigit()
        }
        .font(.subheadline)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct StepList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(Theme.accentSoft, in: Circle())
                    Text(Fmt.text(s)).font(.subheadline).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
