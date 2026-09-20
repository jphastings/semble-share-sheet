import SembleKit
import SwiftUI

/// The "you're all set" screen shown once a session exists.
struct SignedInView: View {
    let account: AccountModel
    let session: Session

    private var displayName: String {
        if let handle = session.handle, !handle.isEmpty {
            return "@" + handle
        }
        return session.did
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    SembleTitle()
                    Text("Signed in as \(displayName)")
                        .font(.subheadline)
                        .foregroundStyle(Color.sembleMutedText)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("“Add to Semble” is now in your share sheet. Move it to your preferred location by choosing “Edit actions” at the bottom.")
                        .font(.body)
                        .foregroundStyle(Color.sembleText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        step(1, "Share a link from Safari or any app.")
                        step(2, "Scroll down the list of actions.")
                        step(3, "Tap Add to Semble.")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sembleSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Link(destination: AppEnvironment.sembleWebsiteURL) {
                    Text("Open Semble")
                }
                .buttonStyle(.semble)

                Button("Log out") {
                    account.signOut()
                }
                .font(.footnote)
                .foregroundStyle(Color.sembleMutedText)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background {
            Color.sembleBackground.ignoresSafeArea()
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(Color.sembleOrange)
                }
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(Color.sembleText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
