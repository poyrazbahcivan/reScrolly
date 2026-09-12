import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var state: AppState
    @State private var showCreate = false
    @State private var showLogin = false
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.accentSoft).frame(width: 52, height: 52)
                        Text(initials).font(.headline).foregroundStyle(Theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.profile.name.isEmpty ? (state.user?.name.isEmpty == false ? state.user!.name : "Guest") : state.profile.name).font(.headline).foregroundStyle(Theme.ink)
                        Text(state.user?.email ?? "Not signed in. Plans live on this phone.").font(.subheadline).foregroundStyle(Theme.ink2)
                    }
                }
                .padding(.vertical, 6)
                if !state.isSignedIn {
                    Button("Create an account") { showCreate = true }
                    Button("Log in") { showLogin = true }
                    Button("Continue with Auth0") { state.signInWithAuth0() }
                }
            }

            Section("Your setup") {
                RowLink(title: "Feeding", subtitle: state.profile.servings == 1 ? "Just me" : "\(state.profile.servings) people", systemImage: "person.2") { EditStepView(step: .servings) }
                RowLink(title: "Diet", subtitle: state.profile.dietLabel, systemImage: "fork.knife") { EditStepView(step: .diet) }
                RowLink(title: "Avoiding", subtitle: state.profile.avoid.isEmpty ? "Nothing" : state.profile.avoid.map { tag in Labels.allergens.first { $0.0 == tag }?.1 ?? tag }.joined(separator: ", "), systemImage: "hand.raised") { EditStepView(step: .avoid) }
                RowLink(title: "Won't eat", subtitle: state.profile.wontEat.isEmpty ? "Nothing specific" : names(state.profile.wontEat), systemImage: "xmark.circle") { EditStepView(step: .wontEat) }
                RowLink(title: "Must have", subtitle: state.profile.mustHave.isEmpty ? "No requests" : names(state.profile.mustHave), systemImage: "star") { EditStepView(step: .mustHave) }
                RowLink(title: "Likes", subtitle: state.profile.likes.isEmpty ? "No preference" : state.profile.likes.map(Labels.like).joined(separator: ", "), systemImage: "heart") { EditStepView(step: .likes) }
                RowLink(title: "Kitchen", subtitle: state.profile.equipment.map { Labels.equipment[$0] ?? $0.humanized }.joined(separator: ", "), systemImage: "cooktop") { EditStepView(step: .kitchen) }
                RowLink(title: "Cooking level", subtitle: state.profile.levelLabel, systemImage: "flame") { EditStepView(step: .skill) }
                RowLink(title: "Budget", subtitle: "\(Fmt.money0(state.profile.budget)) a week", systemImage: "dollarsign.circle") { EditStepView(step: .budget) }
                RowLink(title: "Cooking", subtitle: "\(state.profile.cookSessions) \(state.profile.cookSessions == 1 ? "time" : "times") a week, \(state.profile.mealsPerDay) meals a day", systemImage: "calendar") { EditCookingView() }
                RowLink(title: "Shopping day", subtitle: Labels.weekdays[state.profile.shopWeekday] + (state.profile.notifications ? ", reminder on" : ""), systemImage: "cart") { EditStepView(step: .shopDay) }
                RowLink(title: "Calendar", subtitle: state.profile.useCalendar && state.calendar.authorized ? "Connected" : "Not connected", systemImage: "calendar.badge.clock") { EditStepView(step: .calendar) }
            }

            Section {
                Toggle(isOn: $state.profile.onlyMyRecipes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only plan with my recipes").foregroundStyle(Theme.ink)
                        Text("Off: your recipes plus the catalog. On: just yours.").font(.caption).foregroundStyle(Theme.ink2)
                    }
                }
                .tint(Theme.accent)
                .onChange(of: state.profile.onlyMyRecipes) { _, _ in state.saveProfile() }
            }

            Section("Plans") {
                RowLink(title: "Saved weeks", systemImage: "tray.full") { SavedPlansView() }
                Button {
                    Task { await state.replan() }
                } label: { Label("Plan a new week", systemImage: "arrow.clockwise") }
            }

            Section("Account") {
                RowLink(title: "Data & privacy", systemImage: "lock") { PrivacyView() }
                RowLink(title: "Notifications", subtitle: state.profile.notifications ? "On" : "Off", systemImage: "bell") { NotificationsView() }
                RowLink(title: "Server", subtitle: state.serverReachable ? "Connected" : "Offline", systemImage: "network") { ServerView() }
                if state.isSignedIn {
                    Button("Sign out") { state.signOut() }
                }
            }

            Section {
                Button("Erase everything on this phone", role: .destructive) { confirmReset = true }
            } footer: {
                Text("heisoj 1.1 · Cook a few times. Eat all week.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Profile")
        .sheet(isPresented: $showCreate) { CreateAccountView() }
        .sheet(isPresented: $showLogin) { LoginSheet() }
        .confirmationDialog("Erase everything?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { state.resetEverything() }
        } message: { Text("Removes your plan, preferences, and sign-in from this phone. Your account, if you have one, is untouched.") }
    }

    private var initials: String {
        let n = state.profile.name.isEmpty ? (state.user?.name ?? "") : state.profile.name
        return n.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased().ifEmpty("·")
    }
    private func names(_ ids: [String]) -> String {
        ids.map { id in state.catalog.ingredients?.first { $0.id == id }?.name ?? id.humanized }.joined(separator: ", ")
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

/// Login inside a sheet, for users already in the app as a guest.
struct LoginSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Screen {
                VStack(alignment: .leading, spacing: 20) {
                    StepHeader(title: "Log in", subtitle: "Your current week stays on this phone either way.")
                    VStack(alignment: .leading, spacing: 6) { FieldLabel(text: "Email"); InputField(placeholder: "you@example.com", text: $email, keyboard: .emailAddress, contentType: .emailAddress) }
                    VStack(alignment: .leading, spacing: 6) { FieldLabel(text: "Password"); InputField(placeholder: "Password", text: $password, secure: true, contentType: .password) }
                    if let e = error { InlineNotice(text: e, tone: .warn) }
                    PrimaryButton(title: "Log in", isLoading: busy, enabled: email.contains("@") && password.count >= 8) {
                        busy = true; error = nil
                        Task {
                            do { try await state.login(email: email, password: password); dismiss() }
                            catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }
                    Spacer()
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Reuses an onboarding step as an editor. Saving re-plans.
struct EditStepView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let step: OnboardingStep

    var body: some View {
        Screen {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        StepHeader(title: step.title, subtitle: step.subtitle)
                        StepContent(step: step, profile: $state.profile, catalog: state.catalog)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                VStack(spacing: 10) {
                    PrimaryButton(title: "Save and replan", enabled: StepContent.isValid(step, state.profile)) {
                        Task { await state.replan() }
                    }
                    TrustNote(text: "Changing this rebuilds your week from scratch.")
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EditCookingView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Screen {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 16) {
                            StepHeader(title: OnboardingStep.frequency.title)
                            FrequencyStep(profile: $state.profile)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            StepHeader(title: OnboardingStep.meals.title)
                            MealsStep(profile: $state.profile)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                PrimaryButton(title: "Save and replan") { Task { await state.replan() } }
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SavedPlansView: View {
    @EnvironmentObject var state: AppState
    @State private var saved: [SavedPlanSummary] = []
    @State private var name = "My week"
    @State private var message: String?
    @State private var loading = true

    var body: some View {
        List {
            Section("Save the current week") {
                TextField("Name", text: $name)
                Button("Save") {
                    Task {
                        guard let raw = state.planRaw else { return }
                        do { try await APIClient.shared.savePlan(name: name, raw: raw); message = "Saved."; await reload() }
                        catch { message = error.localizedDescription }
                    }
                }
                .disabled(state.planRaw == nil || !state.serverReachable)
                if !state.isSignedIn { Text("Saved to this device. Create an account to keep them across devices.").font(.footnote).foregroundStyle(Theme.ink2) }
            }
            Section("Saved") {
                if loading { ProgressView() }
                else if saved.isEmpty { Text("Nothing saved yet.").foregroundStyle(Theme.ink3) }
                ForEach(saved) { s in
                    Button {
                        Task {
                            do { let (p, raw) = try await APIClient.shared.loadPlan(id: s.id); state.adopt(p, raw: raw); message = "Loaded \(s.name)." }
                            catch { message = error.localizedDescription }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).foregroundStyle(Theme.ink)
                            Text("\(Fmt.money(s.totalCost)) · \(s.mealsPlanned) of \(s.mealsRequired) meals").font(.caption).foregroundStyle(Theme.ink2)
                        }
                    }
                }
                .onDelete { idx in
                    Task { for i in idx { try? await APIClient.shared.deletePlan(id: saved[i].id) }; await reload() }
                }
            }
            if let m = message { Section { Text(m).font(.footnote).foregroundStyle(Theme.ink2) } }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Saved weeks")
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        saved = (try? await APIClient.shared.myPlans()) ?? []
        loading = false
    }
}

struct PrivacyView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        List {
            Section("What we store") {
                Text("Your food preferences: diet, things you avoid, kitchen equipment, budget, and how often you cook.")
                Text("If you create an account: your email and a hashed password. Never the password itself.")
                Text("Plans you choose to save.")
            }
            Section("What we don't") {
                Text("Location, contacts, photos, health data, or anything from other apps.")
                Text("Your answers are never sold or shared.")
            }
            Section("Where it lives") {
                Text(state.isSignedIn ? "On this phone and in your account." : "On this phone only, until you create an account.")
            }
            Section {
                Text("Planning runs on a rule-based optimizer. There is no language model reading your data.")
                    .font(.footnote).foregroundStyle(Theme.ink2)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Data & privacy")
    }
}

struct NotificationsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        List {
            Section {
                Toggle("Weekly check-in", isOn: $state.profile.notifications)
                    .onChange(of: state.profile.notifications) { _, _ in state.saveProfile(); state.applyNotificationSetting() }
            } footer: {
                Text("One notification the evening before your shopping day (\(Labels.weekdays[state.profile.shopWeekday])), asking whether anything changed. Off by default. Permission is only requested when you turn this on.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Notifications")
    }
}

struct ServerView: View {
    @EnvironmentObject var state: AppState
    @State private var url = APIClient.shared.baseURL.absoluteString
    @State private var message: String?
    var body: some View {
        List {
            Section("Address") {
                TextField(APIClient.defaultServer, text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Connect") {
                    if let u = URL(string: url) {
                        APIClient.shared.baseURL = u
                        Task {
                            state.serverReachable = (try? await APIClient.shared.health()) ?? false
                            message = state.serverReachable ? "Connected." : "Not reachable."
                        }
                    }
                }
            }
            Section("Status") {
                HStack { Text("Server"); Spacer(); Text(state.serverReachable ? "Connected" : "Offline").foregroundStyle(Theme.ink2) }
                HStack { Text("Signed in"); Spacer(); Text(state.isSignedIn ? "Yes" : "No").foregroundStyle(Theme.ink2) }
                HStack { Text("Current plan"); Spacer(); Text(state.usedFallback ? "Sample" : "Live").foregroundStyle(Theme.ink2) }
            }
            Section {
                Button("Use the default server") {
                    url = APIClient.defaultServer
                    APIClient.shared.baseURL = URL(string: APIClient.defaultServer)!
                    Task { state.serverReachable = (try? await APIClient.shared.health()) ?? false; message = state.serverReachable ? "Connected." : "Not reachable." }
                }
                Button("Load the sample week") { state.loadFallback() }
            } footer: { Text("The sample week is bundled in the app for demos with no network.") }
            if let m = message { Section { Text(m).font(.footnote).foregroundStyle(Theme.ink2) } }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Server")
    }
}
