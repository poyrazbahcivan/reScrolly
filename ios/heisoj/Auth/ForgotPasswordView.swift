import SwiftUI

struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State var prefill: String
    @State private var sent = false
    @State private var busy = false

    init(prefill: String) { _prefill = State(initialValue: prefill) }

    var body: some View {
        NavigationStack {
            Screen {
                VStack(alignment: .leading, spacing: 24) {
                    if sent {
                        StepHeader(title: "Check your email", subtitle: "If an account exists for \(prefill), a reset link is on its way.")
                        PrimaryButton(title: "Done") { dismiss() }
                    } else {
                        StepHeader(title: "Reset your password", subtitle: "We'll send a link to the email on your account.")
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: "Email")
                            InputField(placeholder: "you@example.com", text: $prefill, keyboard: .emailAddress, contentType: .emailAddress)
                        }
                        PrimaryButton(title: "Send reset link", isLoading: busy, enabled: prefill.contains("@")) {
                            busy = true
                            Task { try? await APIClient.shared.forgot(email: prefill); busy = false; sent = true }
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
