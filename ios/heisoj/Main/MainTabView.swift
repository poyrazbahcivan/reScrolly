import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var state: AppState
    @State private var showImport = false

    var body: some View {
        TabView {
            NavigationStack { TodayView() }.tabItem { Label("Today", systemImage: "sun.max") }
            NavigationStack { PlanView() }.tabItem { Label("Week", systemImage: "calendar") }
            NavigationStack { RecipesView() }.tabItem { Label("Recipes", systemImage: "book") }
            NavigationStack { ShopView() }.tabItem { Label("Groceries", systemImage: "cart") }
            NavigationStack { ProfileView() }.tabItem { Label("You", systemImage: "person.crop.circle") }
        }
        .sheet(isPresented: $state.showSavePrompt) { SavePromptView() }
        .sheet(isPresented: $showImport) { RecipeImportView() }
        .onChange(of: state.pendingImportURL) { _, v in if v != nil { showImport = true } }
        .onAppear { if state.pendingImportURL != nil { showImport = true } }
    }
}

/// Shown once, after the first plan is revealed. Value first, commitment last.
struct SavePromptView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            Screen {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(Theme.accent)
                    StepHeader(title: "Your week is ready", subtitle: "Create an account to keep it, and to pick it up on any device.")
                    VStack(spacing: 12) {
                        PrimaryButton(title: "Create an account") { showCreate = true }
                        SecondaryButton(title: "Not now") { dismiss() }
                    }
                    TrustNote(text: "Everything already on this phone moves to the account. Nothing is lost by waiting.")
                    Spacer()
                }
                .padding(24)
            }
            .sheet(isPresented: $showCreate, onDismiss: { if state.isSignedIn { dismiss() } }) { CreateAccountView() }
        }
        .presentationDetents([.large])
    }
}
