import AVFoundation
import Combine
import SwiftUI

/// One cook: the recipes in the order to make them, as a numbered timeline.
struct SessionView: View {
    let session: Session
    let plan: Plan

    var body: some View {
        let recipes = session.recipeIds.compactMap { plan.recipe($0) }
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FlowLayout(spacing: 6) {
                        Pill(text: "\(recipes.count) \(recipes.count == 1 ? "recipe" : "recipes")", systemImage: "list.number")
                        Pill(text: "\(Fmt.minutes(session.activeMinutes)) hands on", systemImage: "hand.raised")
                        Pill(text: "\(Fmt.minutes(session.totalMinutes)) total", systemImage: "clock")
                    }
                    Text("Cook in this order. Anything that feeds a later recipe comes first.")
                        .font(.subheadline).foregroundStyle(Theme.ink2)
                    VStack(spacing: 0) {
                        ForEach(Array(recipes.enumerated()), id: \.element.id) { idx, r in
                            NavigationLink { RecipeView(recipe: r, plan: plan) } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Text("\(idx + 1)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(Color.white)
                                        .frame(width: 28, height: 28)
                                        .background(Theme.accent, in: Circle())
                                    HStack(spacing: 12) {
                                        RecipeThumb(id: r.id, name: r.name, tags: r.tags ?? [], moods: r.moods ?? [], size: 48)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(r.name).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                                            Text(meta(r)).font(.caption).foregroundStyle(Theme.ink2)
                                            if !r.produces.isEmpty {
                                                Label("Makes " + r.produces.map { $0.name.lowercased() }.joined(separator: ", ") + " for later",
                                                      systemImage: "arrow.turn.down.right")
                                                    .font(.caption).foregroundStyle(Theme.accent)
                                            }
                                        }
                                        Spacer(minLength: 4)
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                                    }
                                    .padding(.bottom, 22)
                                }
                                .background(alignment: .topLeading) {
                                    if idx < recipes.count - 1 {
                                        Rectangle().fill(Theme.line).frame(width: 2).padding(.top, 30).offset(x: 13)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle(session.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func meta(_ r: PlanRecipe) -> String {
        var parts = ["\(Fmt.minutes(r.activeMinutes)) hands on"]
        if r.totalMinutes > r.activeMinutes { parts.append("\(Fmt.minutes(r.totalMinutes)) total") }
        if r.meals > 0 { parts.append("\(r.meals) meals") }
        return parts.joined(separator: " · ")
    }
}

/// A recipe from the plan. Ingredients to tick off, then one step at a time with big type,
/// Back and Next, and read-aloud for wet hands.
struct RecipeView: View {
    let recipe: PlanRecipe
    let plan: Plan
    @State private var part: Part = .ingredients
    @State private var step = 0
    @State private var readAloud = false
    @StateObject private var voice = StepVoice()

    enum Part: String, CaseIterable, Identifiable {
        case ingredients = "Ingredients", cook = "Cook"
        var id: String { rawValue }
    }

    var body: some View {
        Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        RecipeThumb(id: recipe.id, name: recipe.name, tags: recipe.tags ?? [], moods: recipe.moods ?? [], size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recipe.name).font(.title2.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text(summary).font(.caption).foregroundStyle(Theme.ink2)
                        }
                    }
                    if !recipe.consumes.isEmpty {
                        Label("Uses " + recipe.consumes.map { "\(Fmt.qty($0.qty, $0.unit)) \($0.name.lowercased())" }.joined(separator: ", ") + " from an earlier cook",
                              systemImage: "arrow.turn.down.right")
                            .font(.subheadline).foregroundStyle(Theme.accent)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Picker("Show", selection: $part) {
                        ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch part {
                    case .ingredients:
                        IngredientList(items: recipe.ingredients, checkable: true)
                        if !recipe.produces.isEmpty { keepCard }
                    case .cook:
                        stepCard
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: step) { _, s in if readAloud, s < recipe.steps.count { voice.speak(Fmt.text(recipe.steps[s])) } }
        .onChange(of: part) { _, p in if p != .cook { readAloud = false; voice.stop() } }
        .onDisappear { voice.stop() }
    }

    private var summary: String {
        "\(recipe.meals) meals · \(Fmt.minutes(recipe.activeMinutes)) hands on · keeps \(recipe.keepsDays) \(recipe.keepsDays == 1 ? "day" : "days")"
    }

    @ViewBuilder private var stepCard: some View {
        if recipe.steps.isEmpty {
            InlineNotice(text: "No steps for this one.")
        } else {
            let s = min(step, recipe.steps.count - 1)
            let last = s == recipe.steps.count - 1
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 4) {
                    ForEach(0..<recipe.steps.count, id: \.self) { i in
                        Capsule().fill(i <= s ? Theme.accent : Theme.line).frame(height: 4)
                    }
                }
                HStack {
                    Text("Step \(s + 1) of \(recipe.steps.count)").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                    Spacer()
                    Button {
                        readAloud.toggle()
                        if readAloud { voice.speak(Fmt.text(recipe.steps[s])) } else { voice.stop() }
                    } label: {
                        Label(readAloud ? "Reading aloud" : "Read aloud", systemImage: readAloud ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }
                Text(Fmt.text(recipe.steps[s]))
                    .font(.title3)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .id(s)
                    .transition(.opacity)
                HStack(spacing: 10) {
                    SecondaryButton(title: "Back", systemImage: "chevron.left") { withAnimation(.snappy) { step = max(0, s - 1) } }
                        .disabled(s == 0)
                        .opacity(s == 0 ? 0.4 : 1)
                    PrimaryButton(title: last ? "Done" : "Next") {
                        withAnimation(.snappy) {
                            if last { part = .ingredients; step = 0 } else { step = s + 1 }
                        }
                    }
                }
            }
            .padding(18)
            .cardStyle(radius: 18)
            .sensoryFeedback(.selection, trigger: step)
        }
    }

    private var keepCard: some View {
        let users = plan.recipes.filter { r in r.consumes.contains { c in recipe.produces.contains { $0.id == c.id } } }
        return VStack(alignment: .leading, spacing: 6) {
            Label("Keep for later", systemImage: "refrigerator").font(.headline).foregroundStyle(Theme.ink)
            ForEach(recipe.produces) { p in
                Text("\(p.name), about \(Fmt.qty(p.qty, p.unit)). Keeps \(recipe.keepsDays) days in the fridge.").font(.subheadline).foregroundStyle(Theme.ink)
            }
            if !users.isEmpty {
                Text("Goes into " + users.map(\.name).joined(separator: ", ") + ".").font(.subheadline).foregroundStyle(Theme.ink2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
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
