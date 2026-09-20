import SwiftUI

/// The container app. Its only jobs are signing the user in and explaining
/// where the share-sheet action lives; the real work is in `ShareExtension`.
@main
struct SembleShareApp: App {
    @State private var account = AccountModel()

    var body: some Scene {
        WindowGroup {
            RootView(account: account)
        }
    }
}

/// Switches between the sign-in screen and the "you're all set" screen.
struct RootView: View {
    let account: AccountModel

    var body: some View {
        if let session = account.session {
            SignedInView(account: account, session: session)
        } else {
            SignInView(account: account)
        }
    }
}
