import Foundation

// All wire types mirror the API. Decoded with .convertFromSnakeCase.

// MARK: - Profile (the quiz answers)

struct UserProfile: Codable, Equatable {
    var name: String = ""
    var goals: [String] = []
    var servings: Int = 1
    var dietStyle: String = "everything"      // everything | vegetarian | pescatarian | vegan
    var avoid: [String] = []                   // allergen tags: dairy, eggs, gluten, nuts, soy, fish, beef, poultry
    var wontEat: [String] = []                 // specific ingredient ids, hard limits
    var mustHave: [String] = []                // specific ingredient ids the week should include
    var likes: [String] = []                   // mood tags: quick, comfort, spicy, ...
    var cookingLevel: String = "some"          // beginner | some | confident
    var equipment: [String] = ["stove", "pan", "pot", "microwave"]
    var budget: Double = 40
    var cookSessions: Int = 2
    var mealsPerDay: Int = 2
    var shopWeekday: Int = 0                   // 0 = Sunday
    var useCalendar: Bool = false
    var notifications: Bool = false
    var onlyMyRecipes: Bool = false
    var onboardingComplete: Bool = false

    var excludeTags: [String] {
        var tags = Set(avoid)
        switch dietStyle {
        case "vegetarian": tags.formUnion(["meat", "poultry", "beef", "fish"])
        case "pescatarian": tags.formUnion(["meat", "poultry", "beef"])
        case "vegan": tags.formUnion(["meat", "poultry", "beef", "fish", "dairy", "eggs"])
        default: break
        }
        return Array(tags).sorted()
    }

    var maxActiveMinutes: Int { cookingLevel == "beginner" ? 60 : (cookingLevel == "confident" ? 120 : 90) }

    var dietLabel: String {
        switch dietStyle {
        case "vegetarian": return "Vegetarian"
        case "pescatarian": return "Pescatarian"
        case "vegan": return "Vegan"
        default: return "Eats everything"
        }
    }
    var levelLabel: String {
        switch cookingLevel {
        case "beginner": return "Beginner"
        case "confident": return "Confident"
        default: return "Getting there"
        }
    }
}

// MARK: - Auth

struct AuthUser: Codable, Equatable { var id: String; var email: String; var name: String }
struct AuthResponse: Codable { var token: String; var user: AuthUser }
struct RegisterBody: Codable { var email: String; var password: String; var name: String; var deviceId: String? }
struct LoginBody: Codable { var email: String; var password: String; var deviceId: String? }
struct WhoAmI: Codable {
    var kind: String
    var id: String
    var email: String?
    var name: String?
}

// MARK: - Plan request

struct SkipSlot: Codable, Equatable, Hashable {
    var day: Int
    var slot: String
    var reason: String
}

struct PlanRequest: Codable, Equatable {
    var budget: Double = 40
    var cookSessions: Int = 2
    var days: Int = 7
    var mealsPerDay: Int = 2
    var excludeTags: [String] = ["fish"]
    var excludeIngredients: [String] = []
    var equipment: [String] = ["stove", "oven", "pan", "pot", "sheet_pan", "microwave"]
    var maxActiveMinutesPerSession: Int = 90
    var assumeStaples: Bool = true
    var servings: Int = 1
    var startWeekday: Int = 0
    var skipSlots: [SkipSlot] = []
    var mustHave: [String] = []
    var likes: [String] = []
    var pinnedRecipeIds: [String] = []
    var onlyMyRecipes: Bool = false
}

// MARK: - Plan

struct Plan: Codable {
    var request: PlanRequest
    var mealsRequired: Int
    var mealsPlanned: Int
    var mealsUnfilled: Int
    var mealsSkipped: Int?
    var budgetToCoverAll: Double?
    var sessionsToCoverAll: Int?
    var totalCost: Double
    var distinctIngredients: Int
    var wastePlan: Double
    var wasteBaseline: Double
    var sessions: [Session]
    var recipes: [PlanRecipe]
    var meals: [Meal]
    var shopping: [ShopItem]
    var perishables: [Perishable]
    var graph: Graph
    var explanations: [String]
    var warnings: [String]
    var solveMs: Double?

    func recipe(_ id: String?) -> PlanRecipe? { recipes.first { $0.id == id } }
    var sessionDays: Set<Int> { Set(sessions.map(\.day)) }
}

struct Session: Codable, Identifiable {
    var index: Int; var day: Int; var label: String; var recipeIds: [String]; var activeMinutes: Int; var totalMinutes: Int
    var id: Int { index }
}

struct QtyItem: Codable, Hashable, Identifiable {
    var id: String; var name: String; var qty: Double; var unit: String
    var matched: Bool?
}

struct PlanRecipe: Codable, Identifiable {
    var id: String
    var name: String
    var meals: Int
    var session: Int
    var activeMinutes: Int
    var totalMinutes: Int
    var keepsDays: Int
    var ingredients: [QtyItem]
    var consumes: [QtyItem]
    var produces: [QtyItem]
    var equipment: [String]
    var techniques: [String]
    var steps: [String]
    var source: String?
    var moods: [String]?
    var pinned: Bool?
    var isMine: Bool { (source ?? "catalog") != "catalog" }
}

struct Meal: Codable, Identifiable {
    var day: Int; var label: String; var slot: String; var recipeId: String?; var fromSession: Int?
    var skipped: Bool?; var reason: String?
    var id: String { "\(day)-\(slot)" }
    var isSkipped: Bool { skipped ?? false }
}

struct ShopItem: Codable, Identifiable {
    var id: String; var name: String; var section: String; var qtyNeeded: Double; var unit: String
    var packs: Int; var packQty: Double; var packPrice: Double; var cost: Double; var perishable: Bool; var staple: Bool
}

struct Perishable: Codable, Identifiable { var id: String; var name: String; var shelfLifeDays: Int; var lastUsedDay: Int; var ok: Bool }
struct Graph: Codable { var nodes: [GNode]; var edges: [GEdge] }
struct GNode: Codable, Identifiable { var id: String; var kind: String; var label: String; var session: Int?; var meals: Int? }
struct GEdge: Codable, Hashable { var from: String; var to: String; var label: String }

// MARK: - Catalog

struct CatalogIngredient: Codable, Identifiable, Hashable { var id: String; var name: String; var section: String }

struct CatalogRecipe: Codable, Identifiable {
    var id: String; var name: String; var meals: Int; var activeMinutes: Int; var totalMinutes: Int
    var ingredients: [QtyItem]; var steps: [String]; var tags: [String]; var moods: [String]?
}

struct CatalogInfo: Codable {
    var tags: [String]
    var equipment: [String]
    var moods: [String]?
    var ingredients: [CatalogIngredient]?
    var recipes: [CatalogRecipe]?
}

// MARK: - Recipes (the user's library)

struct RecipeDraft: Codable, Identifiable {
    var id: String
    var name: String
    var meals: Int
    var activeMinutes: Int
    var totalMinutes: Int
    var keepsDays: Int
    var ingredients: [QtyItem]
    var steps: [String]
    var equipment: [String]
    var tags: [String]
    var moods: [String]?
    var source: String
    var sourceRef: String?
}

struct CustomIngredient: Codable, Identifiable {
    var id: String; var name: String; var unit: String; var packQty: Double; var packPrice: Double
    var shelfLifeDays: Int; var perishable: Bool; var section: String; var tags: [String]; var staple: Bool
}

struct ImportResult: Codable {
    var recipe: RecipeDraft
    var customIngredients: [CustomIngredient]
    var warning: String?
}

/// "Makes 3 meals" instead of 2 scales the recipe. Every quantity scales exactly. Hands-on time grows
/// more slowly than the batch (chopping twice as much isn't twice the work), and oven or simmer time barely moves.
enum RecipeScale {
    static func qty(_ q: Double, unit: String, _ f: Double) -> Double {
        let v = q * f
        return ["ea", "slice", "bunch"].contains(unit) ? max(0.5, (v * 2).rounded() / 2) : max(0.1, (v * 10).rounded() / 10)
    }
    static func active(_ minutes: Int, _ f: Double) -> Int { max(1, Int((Double(minutes) * (0.5 + 0.5 * f)).rounded())) }
    static func total(active a: Int, total t: Int, _ f: Double) -> Int {
        active(a, f) + Int((Double(max(0, t - a)) * (0.85 + 0.15 * f)).rounded())
    }
}

/// What adding an imported recipe does to the week, from the planner run with and without it.
struct RecipeFit: Codable {
    struct Week: Codable { var totalCost: Double; var mealsPlanned: Int; var mealsRequired: Int; var distinctIngredients: Int; var wastePlan: Double }
    struct Item: Codable, Hashable { var name: String; var cost: Double }
    var included: Bool
    var reason: String?
    var before: Week
    var after: Week
    var costDelta: Double
    var reused: [String]
    var newItems: [Item]
    var replaced: [String]
}

struct UserRecipe: Codable, Identifiable {
    var id: String
    var createdAt: String
    var recipe: RecipeDraft
    var customIngredients: [CustomIngredient]
}

struct SavedPlanSummary: Codable, Identifiable {
    var id: String; var name: String; var createdAt: String; var totalCost: Double; var mealsPlanned: Int; var mealsRequired: Int
}
struct SavedPlan: Codable { var id: String; var name: String; var createdAt: String; var plan: Plan }

enum JSON {
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()
}

enum Labels {
    static let likes: [(String, String)] = [
        ("quick", "Quick"), ("comfort", "Comfort food"), ("spicy", "Spicy"), ("light", "Light"),
        ("high_protein", "High protein"), ("high_fiber", "High fiber"), ("one_pot", "One pot"), ("batch", "Batch cooking"), ("breakfast", "Real breakfasts"),
    ]
    static let allergens: [(String, String)] = [
        ("dairy", "Dairy"), ("eggs", "Eggs"), ("gluten", "Gluten"), ("nuts", "Nuts"), ("soy", "Soy"), ("fish", "Fish"), ("beef", "Beef"), ("poultry", "Chicken"),
    ]
    static let equipment: [String: String] = [
        "stove": "Stovetop", "oven": "Oven", "pan": "Frying pan", "pot": "Large pot", "sheet_pan": "Sheet pan", "microwave": "Microwave", "blender": "Blender",
    ]
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static func like(_ id: String) -> String { likes.first { $0.0 == id }?.1 ?? id.humanized }
}
