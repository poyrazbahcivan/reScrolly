import AVFoundation
import Combine
import SwiftUI

struct CookView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List {
            if let plan = state.plan {
                ForEach(plan.sessions) { s in
                    Section {
                        NavigationLink { SessionView(session: s, plan: plan) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.label).font(.headline).foregroundStyle(Theme.ink)
                                Text("\(s.recipeIds.count) recipes · \(Fmt.minutes(s.activeMinutes)) hands on · \(Fmt.minutes(s.totalMinutes)) total")
                                    .font(.subheadline).foregroundStyle(Theme.ink2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Cook")
    }
}

struct SessionView: View {
    let session: Session
    let plan: Plan

    var body: some View {
        List {
            Section {
                Text("Cook in this order. Things that feed later recipes come first.").font(.subheadline).foregroundStyle(Theme.ink2)
            }
            ForEach(Array(session.recipeIds.enumerated()), id: \.element) { idx, rid in
                if let r = plan.recipe(rid) {
                    NavigationLink { RecipeView(recipe: r, plan: plan) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(idx + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink3).frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).foregroundStyle(Theme.ink)
                                Text(meta(r)).font(.caption).foregroundStyle(Theme.ink2)
                                if !r.produces.isEmpty {
                                    Text("Makes " + r.produces.map { "\($0.name.lowercased()) for later" }.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(session.label)
    }

    private func meta(_ r: PlanRecipe) -> String {
        var parts = ["\(Fmt.minutes(r.activeMinutes)) hands on"]
        if r.totalMinutes > r.activeMinutes { parts.append("\(Fmt.minutes(r.totalMinutes)) total") }
        if r.meals > 0 { parts.append("\(r.meals) meals") }
        return parts.joined(separator: " · ")
    }
}

struct RecipeView: View {
    let recipe: PlanRecipe
    let plan: Plan
    @State private var step = 0
    @State private var readAloud = false
    @StateObject private var voice = StepVoice()

    var body: some View {
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            if !recipe.consumes.isEmpty {
                                Label("Uses " + recipe.consumes.map { "\(Fmt.qty($0.qty, $0.unit)) \($0.name.lowercased())" }.joined(separator: ", "), systemImage: "arrow.turn.down.right")
                                    .font(.subheadline).foregroundStyle(Theme.accent)
                            }
                            ForEach(recipe.ingredients) { i in
                                HStack {
                                    Text(i.name).foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text(Fmt.qty(i.qty, i.unit)).foregroundStyle(Theme.ink2).monospacedDigit()
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                    if !recipe.steps.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Step \(step + 1) of \(recipe.steps.count)").font(.caption).foregroundStyle(Theme.ink3)
                                Text(recipe.steps[step]).font(.title3).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("Back") { step = max(0, step - 1) }.disabled(step == 0)
                                    Spacer()
                                    Button {
                                        readAloud.toggle()
                                        if readAloud { voice.speak(recipe.steps[step]) } else { voice.stop() }
                                    } label: {
                                        Image(systemName: readAloud ? "speaker.wave.2.fill" : "speaker.wave.2").font(.title3)
                                    }
                                    .accessibilityLabel(readAloud ? "Stop reading steps aloud" : "Read steps aloud")
                                    Spacer()
                                    Button(step == recipe.steps.count - 1 ? "Done" : "Next") { step = min(recipe.steps.count - 1, step + 1) }
                                        .buttonStyle(.borderedProminent).disabled(step == recipe.steps.count - 1)
                                }
                            }
                        }
                    }
                    if !recipe.produces.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Keep for later").font(.headline).foregroundStyle(Theme.ink)
                                ForEach(recipe.produces) { p in
                                    Text("\(p.name), about \(Fmt.qty(p.qty, p.unit)). Keeps \(recipe.keepsDays) days in the fridge.").font(.subheadline).foregroundStyle(Theme.ink)
                                }
                                let users = plan.recipes.filter { r in r.consumes.contains { c in recipe.produces.contains { $0.id == c.id } } }
                                if !users.isEmpty {
                                    Text("Used in " + users.map(\.name).joined(separator: ", ") + ".").font(.subheadline).foregroundStyle(Theme.ink2)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: step) { _, s in if readAloud, s < recipe.steps.count { voice.speak(recipe.steps[s]) } }
        .onDisappear { voice.stop() }
    }
}

/// Reads a cook step aloud, because hands are wet. ElevenLabs through the server when it's
/// configured, the phone's own voice otherwise.
@MainActor
final class StepVoice: ObservableObject {
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var generation = 0
    private static var serverVoice = true   // off for the session after the first miss

    func speak(_ text: String) {
        stop()
        let mine = generation
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        Task {
            if Self.serverVoice {
                if let data = try? await APIClient.shared.speech(for: String(text.prefix(800))), let p = try? AVAudioPlayer(data: data) {
                    guard mine == generation else { return }
                    player = p
                    p.play()
                    return
                }
                Self.serverVoice = false
            }
            guard mine == generation else { return }
            let u = AVSpeechUtterance(string: text)
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            synth.speak(u)
        }
    }

    func stop() {
        generation += 1
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
