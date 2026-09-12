import Foundation

enum APIError: LocalizedError {
    case badStatus(Int, String)
    case offline
    case timedOut
    var errorDescription: String? {
        switch self {
        case .badStatus(_, let m):
            if let d = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any], let detail = d["detail"] as? String { return detail }
            return "Something went wrong on the server."
        case .offline: return "Can't reach the server. Check your connection."
        case .timedOut: return "The server took too long to answer. Try again."
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    /// Production API. Served from a Mac through a Cloudflare Tunnel; HTTPS end to end,
    /// so no App Transport Security exceptions anywhere in the project.
    static let defaultServer = "https://hs.poyraz.us"

    var baseURL: URL {
        get { URL(string: UserDefaults.standard.string(forKey: "server_url") ?? Self.defaultServer) ?? URL(string: Self.defaultServer)! }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: "server_url") }
    }

    var token: String? {
        get { Keychain.get("token") }
        set { if let v = newValue { Keychain.set(v, for: "token") } else { Keychain.delete("token") } }
    }

    let deviceId: String = {
        if let id = UserDefaults.standard.string(forKey: "device_id") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "device_id")
        return id
    }()

    private func request(_ path: String, method: String = "GET", body: Data? = nil, auth: Bool = true, timeout: TimeInterval = 12) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        if auth, let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where e.code == .timedOut { throw APIError.timedOut }
        catch { throw APIError.offline }
        guard let http = resp as? HTTPURLResponse else { throw APIError.offline }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // meta
    func health() async throws -> Bool { _ = try await request("health", auth: false); return true }
    func catalog() async throws -> CatalogInfo { try JSON.decoder.decode(CatalogInfo.self, from: try await request("catalog", auth: false)) }

    // auth
    func register(email: String, password: String, name: String) async throws -> AuthResponse {
        let body = try JSON.encoder.encode(RegisterBody(email: email, password: password, name: name, deviceId: deviceId))
        return try JSON.decoder.decode(AuthResponse.self, from: try await request("auth/register", method: "POST", body: body, auth: false))
    }
    func login(email: String, password: String) async throws -> AuthResponse {
        let body = try JSON.encoder.encode(LoginBody(email: email, password: password, deviceId: deviceId))
        return try JSON.decoder.decode(AuthResponse.self, from: try await request("auth/login", method: "POST", body: body, auth: false))
    }
    func forgot(email: String) async throws {
        _ = try await request("auth/forgot", method: "POST", body: try JSONSerialization.data(withJSONObject: ["email": email]), auth: false)
    }
    func me() async throws -> WhoAmI { try JSON.decoder.decode(WhoAmI.self, from: try await request("auth/me")) }

    // profile
    func getProfile() async throws -> UserProfile { try JSON.decoder.decode(UserProfile.self, from: try await request("profile")) }
    func putProfile(_ p: UserProfile) async throws { _ = try await request("profile", method: "PUT", body: try JSON.encoder.encode(p)) }

    // recipes
    /// `images` are JPEG pages of one recipe, read on the server. Reading waits on the model, so the timeout is long.
    func importRecipe(source: String, url: String = "", text: String = "", hint: String = "", images: [Data] = []) async throws -> (ImportResult, Data) {
        let payload: [String: Any] = ["source": source, "url": url, "text": text, "hint": hint, "images": images.map { $0.base64EncodedString() }]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request("recipes/import", method: "POST", body: body, auth: false, timeout: 90)
        return (try JSON.decoder.decode(ImportResult.self, from: data), data)
    }
    /// `raw` is the exact bytes /recipes/import returned, so the server shape round-trips untouched.
    func saveRecipe(raw: Data, name: String, meals: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: Self.edited(raw: raw, name: name, meals: meals))
        _ = try await request("recipes", method: "POST", body: body)
    }
    /// What the recipe would do to this week: cost change, shared ingredients, what it replaces.
    func fit(raw: Data, name: String, meals: Int, plan planRequest: PlanRequest) async throws -> RecipeFit {
        var obj = try Self.edited(raw: raw, name: name, meals: meals)
        obj["request"] = try JSONSerialization.jsonObject(with: JSON.encoder.encode(planRequest))
        let data = try await request("recipes/fit", method: "POST", body: try JSONSerialization.data(withJSONObject: obj), timeout: 30)
        return try JSON.decoder.decode(RecipeFit.self, from: data)
    }
    private static func edited(raw: Data, name: String, meals: Int) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
        var recipe = obj["recipe"] as? [String: Any] ?? [:]
        recipe["name"] = name
        recipe["meals"] = meals
        return ["recipe": recipe, "custom_ingredients": obj["custom_ingredients"] ?? []]
    }
    func myRecipes() async throws -> [UserRecipe] { try JSON.decoder.decode([UserRecipe].self, from: try await request("recipes")) }
    func deleteRecipe(id: String) async throws { _ = try await request("recipes/\(id)", method: "DELETE") }

    // voice
    func speech(for text: String) async throws -> Data {
        try await request("tts", method: "POST", body: try JSONSerialization.data(withJSONObject: ["text": text]), auth: false)
    }

    // planning (authenticated so the user's recipes are in the pool)
    func plan(_ r: PlanRequest) async throws -> (Plan, Data) {
        let data = try await request("plan", method: "POST", body: try JSON.encoder.encode(r))
        return (try JSON.decoder.decode(Plan.self, from: data), data)
    }
    func savePlan(name: String, raw: Data) async throws {
        let planObj = try JSONSerialization.jsonObject(with: raw)
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "plan": planObj])
        _ = try await request("plans", method: "POST", body: body)
    }
    func myPlans() async throws -> [SavedPlanSummary] { try JSON.decoder.decode([SavedPlanSummary].self, from: try await request("plans")) }
    func loadPlan(id: String) async throws -> (Plan, Data) {
        let data = try await request("plans/\(id)")
        let saved = try JSON.decoder.decode(SavedPlan.self, from: data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let raw = try JSONSerialization.data(withJSONObject: obj?["plan"] ?? [:])
        return (saved.plan, raw)
    }
    func deletePlan(id: String) async throws { _ = try await request("plans/\(id)", method: "DELETE") }
}
