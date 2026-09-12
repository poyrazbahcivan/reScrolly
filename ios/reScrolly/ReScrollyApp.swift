import SwiftUI

@main
struct ReScrollyApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .tint(Theme.accent)
                .preferredColorScheme(.light)
                .task { await state.bootstrap() }
                .onOpenURL { url in
                    guard url.host == "import" || url.path.contains("import"),
                          let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value else { return }
                    state.pendingImportURL = q
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            switch state.route {
            case .loading:
                Theme.background.ignoresSafeArea()
            case .welcome:
                WelcomeView()
            case .onboarding:
                OnboardingFlow()
            case .login:
                LoginView()
            case .building:
                BuildingPlanView()
            case .main:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.route)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}
