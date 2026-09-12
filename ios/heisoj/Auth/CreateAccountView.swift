import SwiftUI

/// Presented as a sheet, from Login or from the "save your week" prompt.
/// Creating an account migrates everything already on this device to the account.
struct CreateAccountView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?

    private var valid: Bool { email.contains("@") && password.count >= 8 && password == confirm }

    var body: some View {
        NavigationStack {
            Screen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        StepHeader(title: "Create your account", subtitle: "Keeps your plans across devices. Everything on this phone comes with you.")
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "Name")
                                InputField(placeholder: "Your name", text: $name, contentType: .name)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "Email")
                                InputField(placeholder: "you@example.com", text: $email, keyboard: .emailAddress, contentType: .emailAddress)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "Password")
                                InputField(placeholder: "At least 8 characters", text: $password, secure: true, contentType: .newPassword)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "Confirm password")
                                InputField(placeholder: "Same again", text: $confirm, secure: true, contentType: .newPassword)
                                if !confirm.isEmpty, confirm != password {
                                    Text("Passwords don't match.").font(.caption).foregroundStyle(Theme.warn)
                                }
                            }
                        }
                        if let e = error { InlineNotice(text: e, tone: .warn) }
                        PrimaryButton(title: "Create account", isLoading: busy, enabled: valid) { submit() }
                        TrustNote(text: "We store your email, a hashed password, and your food preferences. Nothing else.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if name.isEmpty { name = state.profile.name } }
        }
    }

    private func submit() {
        busy = true; error = nil
        Task {
            do {
                try await state.register(email: email.trimmingCharacters(in: .whitespaces), password: password, name: name)
                dismiss()
                if state.route == .login { state.route = state.profile.onboardingComplete ? (state.plan == nil ? .building : .main) : .onboarding }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
