import Combine
import Foundation
import SwiftUI
#if canImport(Auth0)
import Auth0
import JWTDecode
#endif

enum Route: Equatable { case loading, welcome, onboarding, login, building, main }

@MainActor
final class AppState: ObservableObject {
    /// Auth0 API identifier. A name, not an address. Must match the Auth0 API and AUTH0_AUDIENCE.
    static let auth0Audience = "https://hs.poyraz.us"

    // routing
    @Published var route: Route = .loading
    @Published var pendingImportURL: String?

    // identity
    @Published var user: AuthUser?
    var isSignedIn: Bool { user != nil }

    // data
    @Published var profile = UserProfile()
    @Published var plan: Plan?
    @Published var planRaw: Data?
    @Published var usedFallback = false
    @Published var serverReachable = false
    @Published var catalog = CatalogInfo(tags: ["meat", "poultry", "beef", "fish", "dairy", "eggs", "gluten", "soy", "nuts"],
                                         equipment: ["stove", "oven", "pan", "pot", "sheet_pan", "microwave", "blender"],
                                         moods: nil, ingredients: nil, recipes: nil)
    @Published var recipes: [UserRecipe] = []
    @Published var pinned: Set<String> = []
    @Published var checked: Set<String> = []
    @Published var showSavePrompt = false
    /// Metric or imperial, everywhere. Stored on the phone; Fmt reads it.
    @Published var units: UnitSystem = Fmt.units {
        didSet { UserDefaults.standard.set(units.rawValue, forKey: "units") }
    }

    // ui
    @Published var isLoading = false
    @Published var errorMessage: String?

    let calendar = CalendarManager()

    #if canImport(Auth0)
    private let credentialsManager = CredentialsManager(authentication: Auth0.authentication())
    #endif

    private var bag = Set<AnyCancellable>()
    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var planFile: URL { docs.appendingPathComponent("plan.json") }
    private var profileFile: URL { docs.appendingPathComponent("profile.json") }
    private var userFile: URL { docs.appendingPathComponent("user.json") }

    init() {
        calendar.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    // MARK: lifecycle

    func bootstrap() async {
        restore()
        await restoreAuth0Session()
        calendar.checkAuthorization()
        if let s = UserDefaults.standard.array(forKey: "checked") as? [String] { checked = Set(s) }
        if let p = UserDefaults.standard.array(forKey: "pinned") as? [String] { pinned = Set(p) }
        route = profile.onboardingComplete ? (plan == nil ? .building : .main) : .welcome
        serverReachable = (try? await APIClient.shared.health()) ?? false
        if serverReachable, let c = try? await APIClient.shared.catalog() { catalog = c }
        if serverReachable, isSignedIn, let remote = try? await APIClient.shared.getProfile(), remote.onboardingComplete {
            profile = remote
            persistProfile()
        }
        await loadRecipes()
    }

    // MARK: onboarding

    func startOnboarding() { route = .onboarding }
    func openLogin() { route = .login }
    func backToWelcome() { route = .welcome }

    func finishOnboarding() async {
        profile.onboardingComplete = true
        persistProfile()
        if serverReachable { try? await APIClient.shared.putProfile(profile) }
        applyNotificationSetting()
        route = .building
    }

    /// Re-plan after anything changes: quiz answers, pinned recipes, calendar.
    func replan() async {
        persistProfile()
        if serverReachable { try? await APIClient.shared.putProfile(profile) }
        applyNotificationSetting()
        route = .building
    }

    // MARK: planning

    /// Every quiz answer lands here. Calendar conflicts are read fresh each time.
    func makeRequest() -> PlanRequest {
        let weekday = Calendar.current.component(.weekday, from: Date()) - 1
        let skips = profile.useCalendar ? calendar.conflicts(days: 7, mealsPerDay: profile.mealsPerDay) : []
        return PlanRequest(
            budget: profile.budget, cookSessions: profile.cookSessions, days: 7, mealsPerDay: profile.mealsPerDay,
            excludeTags: profile.excludeTags, excludeIngredients: profile.wontEat, equipment: profile.equipment,
            maxActiveMinutesPerSession: profile.maxActiveMinutes, assumeStaples: true,
            servings: profile.servings, startWeekday: weekday, skipSlots: skips,
            mustHave: profile.mustHave, likes: profile.likes,
            pinnedRecipeIds: Array(pinned).sorted(), onlyMyRecipes: profile.onlyMyRecipes, goals: profile.goals
        )
    }

    func generate() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (p, raw) = try await APIClient.shared.plan(makeRequest())
            plan = p
            planRaw = raw
            usedFallback = false
            checked = []
            persistPlan()
        } catch {
            errorMessage = error.localizedDescription
            loadFallback()
        }
    }

    func loadFallback() {
        guard let url = Bundle.main.url(forResource: "FallbackPlan", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let p = try? JSON.decoder.decode(Plan.self, from: data) else { return }
        plan = p
        planRaw = data
        usedFallback = true
        persistPlan()
    }

    func adopt(_ p: Plan, raw: Data) {
        plan = p; planRaw = raw; usedFallback = false; checked = []
        persistPlan()
    }

    func revealPlan() {
        route = .main
        if !isSignedIn, !UserDefaults.standard.bool(forKey: "save_prompt_shown") {
            UserDefaults.standard.set(true, forKey: "save_prompt_shown")
            Task { try? await Task.sleep(nanoseconds: 900_000_000); showSavePrompt = true }
        }
    }

    // MARK: recipes

    func loadRecipes() async {
        guard serverReachable else { return }
        recipes = (try? await APIClient.shared.myRecipes()) ?? []
        pinned = pinned.filter { id in recipes.contains { $0.id == id } || catalog.recipes?.contains { $0.id == id } == true }
    }

    func saveRecipe(raw: Data, name: String, meals: Int, pin: Bool) async throws {
        try await APIClient.shared.saveRecipe(raw: raw, name: name, meals: meals)
        await loadRecipes()
        if pin, let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let r = obj["recipe"] as? [String: Any], let id = r["id"] as? String {
            setPinned(id, true)
        }
    }

    func deleteRecipe(_ id: String) async {
        try? await APIClient.shared.deleteRecipe(id: id)
        setPinned(id, false)
        await loadRecipes()
    }

    func setPinned(_ id: String, _ on: Bool) {
        if on { pinned.insert(id) } else { pinned.remove(id) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinned")
    }

    // MARK: calendar & notifications

    func connectCalendar() async -> Bool {
        let ok = await calendar.requestAccess()
        profile.useCalendar = ok
        if ok { _ = calendar.conflicts(days: 7, mealsPerDay: profile.mealsPerDay) }
        return ok
    }

    func applyNotificationSetting() {
        if profile.notifications {
            Task {
                if await NotificationManager.requestPermission() {
                    NotificationManager.scheduleWeekly(shopWeekday: profile.shopWeekday, name: profile.name)
                } else {
                    profile.notifications = false
                    persistProfile()
                }
            }
        } else {
            NotificationManager.cancel()
        }
    }

    // MARK: auth

    func register(email: String, password: String, name: String) async throws {
        let r = try await APIClient.shared.register(email: email, password: password, name: name)
        APIClient.shared.token = r.token
        user = r.user
        if profile.name.isEmpty { profile.name = name }
        persistUser(); persistProfile()
        if profile.onboardingComplete { try? await APIClient.shared.putProfile(profile) }
        await loadRecipes()
    }

    func login(email: String, password: String) async throws {
        let r = try await APIClient.shared.login(email: email, password: password)
        APIClient.shared.token = r.token
        user = r.user
        persistUser()
        await loadRecipes()
        if let remote = try? await APIClient.shared.getProfile(), remote.onboardingComplete {
            profile = remote; persistProfile(); route = .building
        } else if profile.onboardingComplete {
            try? await APIClient.shared.putProfile(profile)
            route = plan == nil ? .building : .main
        } else {
            route = .onboarding
        }
    }

    // MARK: Auth0

    func signInWithAuth0(signUp: Bool = false) {
        #if canImport(Auth0)
        var webAuth = Auth0.webAuth().audience(Self.auth0Audience).scope("openid profile email offline_access")
        if signUp { webAuth = webAuth.parameters(["screen_hint": "signup"]) }
        webAuth.start { result in
            Task { @MainActor in
                switch result {
                case .success(let credentials):
                    try? self.credentialsManager.store(credentials: credentials)
                    await self.applyAuth0(credentials)
                case .failure(let error):
                    print("AUTH0 FAILURE:", error)
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        #else
        errorMessage = "Add the Auth0 package to enable this."
        #endif
    }

    func restoreAuth0Session() async {
        #if canImport(Auth0)
        guard credentialsManager.canRenew() else { return }
        let creds: Credentials? = await withCheckedContinuation { cont in
            credentialsManager.credentials { cont.resume(returning: try? $0.get()) }
        }
        if let c = creds { await applyAuth0(c, navigate: false) }
        #endif
    }

#if canImport(Auth0)
private func applyAuth0(_ credentials: Credentials, navigate: Bool = true) async {
    APIClient.shared.token = credentials.accessToken
    let claims = try? decode(jwt: credentials.idToken)
    user = AuthUser(id: claims?.subject ?? "auth0",
                    email: claims?["email"].string ?? "Signed in with Auth0",
                    name: claims?["name"].string ?? profile.name)
    persistUser()
    await loadRecipes()
    if let remote = try? await APIClient.shared.getProfile(), remote.onboardingComplete {
        profile = remote; persistProfile()
    } else if profile.onboardingComplete {
        try? await APIClient.shared.putProfile(profile)
    }
    guard navigate else { return }
    if route == .login || route == .welcome {
        route = profile.onboardingComplete ? (plan == nil ? .building : .main) : .onboarding
    }
}
#endif

    func signOut() {
        #if canImport(Auth0)
        try? credentialsManager.clear()
        #endif
        APIClient.shared.token = nil
        user = nil
        recipes = []
        try? FileManager.default.removeItem(at: userFile)
    }

    func resetEverything() {
        signOut()
        plan = nil; planRaw = nil; profile = UserProfile(); checked = []; pinned = []
        try? FileManager.default.removeItem(at: planFile)
        try? FileManager.default.removeItem(at: profileFile)
        for k in ["checked", "pinned", "save_prompt_shown", "plan_started"] { UserDefaults.standard.removeObject(forKey: k) }
        NotificationManager.cancel()
        route = .welcome
    }

    // MARK: shopping

    func toggleChecked(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
        UserDefaults.standard.set(Array(checked), forKey: "checked")
    }

    // MARK: persistence

    func saveProfile() {
        persistProfile()
        if serverReachable { Task { try? await APIClient.shared.putProfile(profile) } }
    }

    private func persistPlan() {
        if let raw = planRaw { try? raw.write(to: planFile) }
        UserDefaults.standard.set(Date(), forKey: "plan_started")
    }
    private func persistProfile() { if let d = try? JSON.encoder.encode(profile) { try? d.write(to: profileFile) } }
    private func persistUser() { if let d = try? JSON.encoder.encode(user) { try? d.write(to: userFile) } }

    private func restore() {
        if let d = try? Data(contentsOf: profileFile), let p = try? JSON.decoder.decode(UserProfile.self, from: d) { profile = p }
        if let d = try? Data(contentsOf: userFile), let u = try? JSON.decoder.decode(AuthUser.self, from: d), APIClient.shared.token != nil { user = u }
        if let d = try? Data(contentsOf: planFile), let p = try? JSON.decoder.decode(Plan.self, from: d) { plan = p; planRaw = d }
    }
}
