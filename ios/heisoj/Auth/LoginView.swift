import SwiftUI

struct LoginView: View {
    @EnvironmentObject var state: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showForgot = false
    @State private var showCreate = false

    private var valid: Bool { email.contains("@") && password.count >= 8 }

    var body: some View {
        Screen {
            VStack(spacing: 0) {
                HStack {
                    Button { state.backToWelcome() } label: {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold)).foregroundStyle(Theme.ink).frame(width: 40, height: 40)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        StepHeader(title: "Welcome back", subtitle: "Log in to pick up your week where you left it.")
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "Email")
                                InputField(placeholder: "you@example.com", text: $email, keyboard: .emailAddress, contentType: .emailAddress)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "Password")
                                InputField(placeholder: "At least 8 characters", text: $password, secure: true, contentType: .password)
                            }
                            HStack { Spacer(); TextButton(title: "Forgot password?") { showForgot = true } }
                        }
                        if let e = error { InlineNotice(text: e, tone: .warn) }
                        PrimaryButton(title: "Log in", isLoading: busy, enabled: valid) { submit() }

                        HStack {
                            Rectangle().fill(Theme.line).frame(height: 1)
                            Text("or").font(.caption).foregroundStyle(Theme.ink3)
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                        SecondaryButton(title: "Continue with Auth0", systemImage: "person.crop.circle.badge.checkmark") {
                            state.signInWithAuth0()
                        }
                        SecondaryButton(title: "Create an account", systemImage: "person.badge.plus") { showCreate = true }
                        SecondaryButton(title: "Continue without an account") { state.startOnboarding() }
                        TrustNote(text: "Passwords are hashed before storage. We never see them in plain text.")
                    }
                    .padding(24)
                }
            }
        }
        .sheet(isPresented: $showForgot) { ForgotPasswordView(prefill: email) }
        .sheet(isPresented: $showCreate) { CreateAccountView() }
    }

    private func submit() {
        busy = true; error = nil
        Task {
            do { try await state.login(email: email.trimmingCharacters(in: .whitespaces), password: password) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
