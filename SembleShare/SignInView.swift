import AuthenticationServices
import SwiftUI

/// The first screen: a handle field and an orange "Log in" button.
struct SignInView: View {
    let account: AccountModel

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var handle = ""
    @FocusState private var isHandleFocused: Bool

    private var canSubmit: Bool {
        !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !account.isSigningIn
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    SembleTitle()
                    Text("Sign in with your atmosphere account to save links to Semble from the share sheet.")
                        .font(.body)
                        .foregroundStyle(Color.sembleMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    handleField

                    Button {
                        submit()
                    } label: {
                        HStack(spacing: 8) {
                            if account.isSigningIn {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(account.isSigningIn ? "Logging in…" : "Log in")
                        }
                    }
                    .buttonStyle(.semble)
                    .disabled(!canSubmit)

                    if let error = account.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Semble is built by Cosmik Network. This app just adds it to your share sheet.")
                    .font(.footnote)
                    .foregroundStyle(Color.sembleMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            Color.sembleBackground.ignoresSafeArea()
        }
    }

    private var handleField: some View {
        TextField("you.bsky.social", text: $handle)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.username)
            .submitLabel(.go)
            .focused($isHandleFocused)
            .onSubmit(submit)
            .padding(14)
            .background(Color.sembleField)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHandleFocused ? Color.sembleOrange : Color.sembleBorder, lineWidth: 1)
            }
            .accessibilityLabel("Your handle")
    }

    private func submit() {
        guard canSubmit else { return }
        isHandleFocused = false
        let browser = webAuthenticationSession
        let model = account
        let typedHandle = handle
        Task {
            await model.signIn(account: typedHandle, using: browser)
        }
    }
}
