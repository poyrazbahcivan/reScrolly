import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case name, goals, servings, diet, avoid, wontEat, mustHave, likes, skill, kitchen, budget, frequency, meals, shopDay, calendar

    var title: String {
        switch self {
        case .name: return "What should we call you?"
        case .goals: return "What do you want out of this?"
        case .servings: return "How many people are you feeding?"
        case .diet: return "How do you eat?"
        case .avoid: return "Anything you avoid?"
        case .wontEat: return "Anything you just won't eat?"
        case .mustHave: return "Anything that has to be in the week?"
        case .likes: return "What do you like?"
        case .skill: return "How comfortable are you in a kitchen?"
        case .kitchen: return "What's in your kitchen?"
        case .budget: return "What's your weekly food budget?"
        case .frequency: return "How many times will you actually cook?"
        case .meals: return "How many meals a day should we plan?"
        case .shopDay: return "When do you shop?"
        case .calendar: return "Should we check your calendar?"
        }
    }

    var subtitle: String {
        switch self {
        case .name: return "First name is fine."
        case .goals: return "Pick any that fit. This shapes what we optimize for."
        case .servings: return "Every quantity on the shopping list scales to this."
        case .diet: return "This decides which recipes are even on the table."
        case .avoid: return "Allergens and categories. These are hard limits, never suggestions."
        case .wontEat: return "Specific ingredients. Cilantro, mushrooms, whatever. Also a hard limit."
        case .mustHave: return "Ingredients you want to see this week. We'll fit them in if the budget allows."
        case .likes: return "Nudges the plan toward what you'll actually want to eat."
        case .skill: return "Sets how much hands-on time each cooking session gets."
        case .kitchen: return "We only plan recipes you can physically make."
        case .budget: return "One shopping trip. We stay under it, always."
        case .frequency: return "Be honest. The plan is built around this number."
        case .meals: return "Breakfast is optional. Most people plan lunch and dinner."
        case .shopDay: return "We'll check in the evening before, in case anything changed."
        case .calendar: return "If there's dinner on your calendar, we won't plan dinner that night."
        }
    }

    var optional: Bool { [.name, .goals, .wontEat, .mustHave, .likes, .calendar].contains(self) }
}

struct OnboardingFlow: View {
    @EnvironmentObject var state: AppState
    @State private var step: OnboardingStep = .name
    @State private var saving = false

    private var index: Int { OnboardingStep.allCases.firstIndex(of: step) ?? 0 }
    private var count: Int { OnboardingStep.allCases.count }

    var body: some View {
        Screen {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        StepHeader(title: step.title, subtitle: step.subtitle)
                        StepContent(step: step, profile: $state.profile, catalog: state.catalog)
                    }
                    .padding(24)
                    .padding(.bottom, 24)
                }
                footer
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Button { back() } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold)).foregroundStyle(Theme.ink).frame(width: 40, height: 40)
                }
                Spacer()
                Text("\(index + 1) of \(count)").font(.caption.weight(.medium)).foregroundStyle(Theme.ink3)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            ProgressBar(progress: Double(index + 1) / Double(count))
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            PrimaryButton(title: step == .calendar ? "Build my week" : "Continue", isLoading: saving, enabled: StepContent.isValid(step, state.profile)) { next() }
            if step.optional { TextButton(title: "Skip") { next() } } else { Color.clear.frame(height: 20) }
        }
        .padding(.horizontal, 24).padding(.bottom, 12)
        .background(Theme.background)
    }

    private func next() {
        if let n = OnboardingStep(rawValue: step.rawValue + 1) {
            withAnimation(.easeInOut(duration: 0.2)) { step = n }
        } else {
            saving = true
            Task { await state.finishOnboarding(); saving = false }
        }
    }

    private func back() {
        if let p = OnboardingStep(rawValue: step.rawValue - 1) { withAnimation(.easeInOut(duration: 0.2)) { step = p } }
        else { state.backToWelcome() }
    }
}

/// One view per step. Reused from Profile as an editor, so each step reads and
/// writes the profile directly and has no state of its own.
struct StepContent: View {
    let step: OnboardingStep
    @Binding var profile: UserProfile
    let catalog: CatalogInfo

    static func isValid(_ step: OnboardingStep, _ p: UserProfile) -> Bool {
        step == .kitchen ? !p.equipment.isEmpty : true
    }

    var body: some View {
        switch step {
        case .name: NameStep(profile: $profile)
        case .goals: GoalsStep(profile: $profile)
        case .servings: ServingsStep(profile: $profile)
        case .diet: DietStep(profile: $profile)
        case .avoid: AvoidStep(profile: $profile)
        case .wontEat: IngredientPickStep(selection: $profile.wontEat, catalog: catalog, exclude: profile.mustHave, prompt: "Search ingredients", tone: .warn)
        case .mustHave: IngredientPickStep(selection: $profile.mustHave, catalog: catalog, exclude: profile.wontEat, prompt: "Search ingredients", tone: .info)
        case .likes: LikesStep(profile: $profile, catalog: catalog)
        case .skill: SkillStep(profile: $profile)
        case .kitchen: KitchenStep(profile: $profile, options: catalog.equipment)
        case .budget: BudgetStep(profile: $profile)
        case .frequency: FrequencyStep(profile: $profile)
        case .meals: MealsStep(profile: $profile)
        case .shopDay: ShopDayStep(profile: $profile)
        case .calendar: CalendarStep(profile: $profile)
        }
    }
}
