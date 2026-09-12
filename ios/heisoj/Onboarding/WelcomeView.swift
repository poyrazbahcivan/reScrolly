import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    @State private var showServer = false

    var body: some View {
        Screen {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    Text("heisoj")
                        .font(.system(size: 15, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(Theme.accent)
                    Text("Cook a few times.\nEat all week.")
                        .font(.system(size: 40, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineSpacing(2)
                    Text("Set a budget and how often you'll actually cook. Get one shopping trip, a cooking plan, and every meal for the week, with nothing rotting in the fridge.")
                        .font(.body).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(spacing: 14) {
                    ValueRow(icon: "cart", text: "One shopping trip, sorted by aisle")
                    ValueRow(icon: "arrow.triangle.branch", text: "What you cook first becomes what you eat later")
                    ValueRow(icon: "leaf", text: "Every perishable used before it turns")
                }
                Spacer()
                VStack(spacing: 12) {
                    PrimaryButton(title: "Get started") { state.startOnboarding() }
                    SecondaryButton(title: "I already have an account") { state.openLogin() }
                    TrustNote(text: "Your answers stay on this phone until you choose to create an account.")
                        .padding(.top, 4)
                    Button("Server settings") { showServer = true }
                        .font(.caption).foregroundStyle(Theme.ink3).padding(.top, 2)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showServer) { NavigationStack { ServerView() } }
    }
}

private struct ValueRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(text).font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
        }
    }
}
