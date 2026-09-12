import SwiftUI

/// The recipe library. The user's own recipes first, then the catalog.
/// Pinned recipes are forced into the next week's plan.
struct RecipesView: View {
    @EnvironmentObject var state: AppState
    @State private var showImport = false
    @State private var query = ""

    private var mine: [UserRecipe] { state.recipes.filter { query.isEmpty || $0.recipe.name.localizedCaseInsensitiveContains(query) } }
    private var catalog: [CatalogRecipe] { (state.catalog.recipes ?? []).filter { $0.meals > 0 && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }.sorted { $0.name < $1.name } }

    var body: some View {
        List {
            if !state.pinned.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "pin.fill").foregroundStyle(Theme.accent)
                        Text("\(state.pinned.count) pinned for this week").foregroundStyle(Theme.ink)
                        Spacer()
                        Button("Replan") { Task { await state.replan() } }.font(.subheadline.weight(.medium))
                    }
                }
            }
            Section {
                Button { showImport = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add a recipe").foregroundStyle(Theme.ink)
                            Text("Paste a link, take a photo, or type it").font(.caption).foregroundStyle(Theme.ink2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("My recipes") {
                if mine.isEmpty {
                    Text(state.serverReachable ? "Nothing yet. Add one and it'll be planned into your week." : "Connect to the server to see your recipes.")
                        .font(.subheadline).foregroundStyle(Theme.ink3)
                }
                ForEach(mine) { r in
                    NavigationLink { RecipeLibraryDetail(recipe: r.recipe, custom: r.customIngredients, mine: true) } label: { RecipeRow(name: r.recipe.name, meals: r.recipe.meals, minutes: r.recipe.totalMinutes, source: r.recipe.source, pinned: state.pinned.contains(r.id)) }
                }
                .onDelete { idx in Task { for i in idx { await state.deleteRecipe(mine[i].id) } } }
            }
            Section("From the catalog") {
                ForEach(catalog) { r in
                    NavigationLink {
                        RecipeLibraryDetail(recipe: RecipeDraft(id: r.id, name: r.name, meals: r.meals, activeMinutes: r.activeMinutes, totalMinutes: r.totalMinutes, keepsDays: 3, ingredients: r.ingredients, steps: r.steps, equipment: [], tags: r.tags, moods: r.moods, source: "catalog", sourceRef: nil), custom: [], mine: false)
                    } label: { RecipeRow(name: r.name, meals: r.meals, minutes: r.totalMinutes, source: "catalog", pinned: state.pinned.contains(r.id)) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .searchable(text: $query, prompt: "Search recipes")
        .navigationTitle("Recipes")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showImport = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showImport) { RecipeImportView() }
        .refreshable { await state.loadRecipes() }
    }
}

struct RecipeRow: View {
    let name: String; let meals: Int; let minutes: Int; let source: String; let pinned: Bool
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).foregroundStyle(Theme.ink)
                Text("\(meals) meals · \(Fmt.minutes(minutes))" + (source == "url" ? " · from a link" : (source == "ocr" || source == "image") ? " · from a photo" : source == "text" ? " · typed" : ""))
                    .font(.caption).foregroundStyle(Theme.ink2)
            }
            Spacer()
            if pinned { Image(systemName: "pin.fill").foregroundStyle(Theme.accent).font(.caption) }
        }
        .padding(.vertical, 2)
    }
}

struct RecipeLibraryDetail: View {
    @EnvironmentObject var state: AppState
    let recipe: RecipeDraft
    let custom: [CustomIngredient]
    let mine: Bool

    var body: some View {
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        Toggle(isOn: Binding(get: { state.pinned.contains(recipe.id) }, set: { state.setPinned(recipe.id, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pin to this week").foregroundStyle(Theme.ink)
                                Text("Forces it into the next plan. Replan from the Recipes tab.").font(.caption).foregroundStyle(Theme.ink2)
                            }
                        }
                        .tint(Theme.accent)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(recipe.meals) meals · \(Fmt.minutes(recipe.activeMinutes)) hands on · \(Fmt.minutes(recipe.totalMinutes)) total").font(.subheadline).foregroundStyle(Theme.ink2)
                            if !recipe.tags.isEmpty { Text("Contains " + recipe.tags.map { tag in Labels.allergens.first { $0.0 == tag }?.1.lowercased() ?? tag }.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.ink3) }
                            Divider()
                            ForEach(recipe.ingredients) { i in
                                HStack {
                                    Text(i.name).foregroundStyle(Theme.ink)
                                    if i.matched == false { Text("new").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent) }
                                    Spacer()
                                    Text(Fmt.qty(i.qty, i.unit)).foregroundStyle(Theme.ink2).monospacedDigit()
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                    if !recipe.steps.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { i, s in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("\(i + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink3).frame(width: 18)
                                        Text(s).font(.subheadline).foregroundStyle(Theme.ink)
                                    }
                                }
                            }
                        }
                    }
                    if !custom.isEmpty {
                        InlineNotice(text: "Estimated prices for: " + custom.map { "\($0.name) \(Fmt.money($0.packPrice))" }.joined(separator: ", ") + ". Edit them on the server catalog if they're off.")
                    }
                    if mine, let ref = recipe.sourceRef, !ref.isEmpty, let url = URL(string: ref) {
                        Link(destination: url) { Label("Open the original", systemImage: "link").font(.subheadline) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
