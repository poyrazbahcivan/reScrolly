import SwiftUI

/// Shown while the solver runs. The steps are real: they describe what the
/// engine is doing, in order. Short on purpose, since the solve takes under a second.
struct BuildingPlanView: View {
    @EnvironmentObject var state: AppState
    @State private var done = 0
    @State private var attempt = 0
    @State private var showServer = false
    private let steps = [
        "Filtering recipes you can make",
        "Choosing recipes that share ingredients",
        "Ordering cook sessions so nothing rots",
        "Building your shopping list",
    ]

    var body: some View {
        Screen {
            VStack(alignment: .leading, spacing: 28) {
                Spacer()
                StepHeader(title: state.profile.name.isEmpty ? "Building your week" : "Building your week, \(state.profile.name)",
                           subtitle: "\(Fmt.money0(state.profile.budget)), cooking \(state.profile.cookSessions == 1 ? "once" : "\(state.profile.cookSessions) times").")
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().stroke(Theme.line, lineWidth: 1.5).frame(width: 22, height: 22)
                                if i < done { Circle().fill(Theme.accent).frame(width: 22, height: 22); Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                                else if i == done { ProgressView().controlSize(.small) }
                            }
                            Text(s).font(.body).foregroundStyle(i <= done ? Theme.ink : Theme.ink3)
                        }
                    }
                }
                Spacer()
                if let e = state.errorMessage, state.usedFallback {
                    InlineNotice(text: "Couldn't reach the server (\(e)). Showing a sample week instead. You can plan your own once you're connected.", tone: .warn)
                }
                if done >= steps.count, state.plan != nil {
                    PrimaryButton(title: "See my week") { state.revealPlan() }
                }
                if done >= steps.count, state.plan == nil {
                    InlineNotice(text: state.errorMessage ?? "Couldn't build a plan.", tone: .warn)
                    PrimaryButton(title: "Try again") { attempt += 1 }
                    SecondaryButton(title: "Server settings") { showServer = true }
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showServer) { NavigationStack { ServerView() } }
        .task(id: attempt) {
            done = 0
            async let solve: () = state.generate()
            for i in 0..<steps.count {
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation { done = i + 1 }
            }
            await solve
            withAnimation { done = steps.count }
        }
    }
}
