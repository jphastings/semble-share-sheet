import SembleKit
import SwiftUI

/// The container app. Its only jobs are signing the user in and explaining
/// where the share-sheet action lives; the real work is in `ShareExtension`.
@main
struct SembleShareApp: App {
    @State private var account: AccountModel

    init() {
        // Must run before `AccountModel` reads the session, and only here:
        // the extension shares the same Keychain item but must never clear
        // it out from under the app.
        clearSessionOnFreshInstall(store: AppEnvironment.sessionStore, defaults: AppEnvironment.appGroupDefaults)
        _account = State(initialValue: AccountModel())
    }

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
