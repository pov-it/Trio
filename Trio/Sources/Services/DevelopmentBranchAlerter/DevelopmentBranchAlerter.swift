import Foundation
import SwiftUI

/// Drives the startup warning shown when Trio was built from anything other than the released
/// `main` branch.
///
/// The branch name is recorded at build time by `scripts/capture-build-details.sh` and read back
/// through `BuildDetails.trioBranch`. That value is the branch name, an exact tag when the build
/// came from a detached checkout, or the literal `detached` - so anything other than `main` is
/// treated as a build the average user should not be running.
///
/// After the user taps I'm a Tester, acknowledgment is stored in UserDefaults for that branch
/// so this personal TestFlight fork is not nagged on every cold start. A different branch
/// still warns once.
///
/// Compile with `DEV_BRANCH_WARNING_DISABLED` to suppress the warning.
@MainActor final class DevelopmentBranchAlerter: ObservableObject {
    static let shared = DevelopmentBranchAlerter()

    private init() {}

    // MARK: - Constants

    private static let releaseBranchName = "main"
    private static let developmentBranchName = "dev"

    static let returnToReleaseURL = URL(string: "https://triodocs.org/install/return-to-main/")!

    // MARK: - State

    /// Whether the warning should currently be on screen.
    @Published var isPresented = false

    /// Branch the running build came from, resolved when the warning is raised.
    private(set) var branch = ""

    /// Reset with the process, so a first-launch warning still shows once.
    private var hasBeenAcknowledgedThisLaunch = false

    private static func acknowledgedKey(for branch: String) -> String {
        "DevelopmentBranchAlerter.acknowledged.\(branch)"
    }

    private static func isAcknowledged(branch: String) -> Bool {
        guard !branch.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: acknowledgedKey(for: branch))
    }

    // MARK: - Public

    /// Raises the warning if this build did not come from `main`, at most once
    /// per branch until the user taps I'm a Tester (persisted).
    func alertIfNeeded() {
        #if DEV_BRANCH_WARNING_DISABLED
            return
        #else
            guard !hasBeenAcknowledgedThisLaunch else {
                return
            }

            let branch = BuildDetails.shared.trioBranch
            guard branch != Self.releaseBranchName else {
                return
            }
            guard !Self.isAcknowledged(branch: branch) else {
                hasBeenAcknowledgedThisLaunch = true
                return
            }

            self.branch = branch
            isPresented = true
        #endif
    }

    /// Marks the warning as dealt with for this launch **and** this branch.
    func acknowledge() {
        hasBeenAcknowledgedThisLaunch = true
        if !branch.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.acknowledgedKey(for: branch))
        }
    }

    /// Warning body for the branch this build came from.
    ///
    /// The `dev` branch is named directly, because that is the branch testers opt into and the one
    /// the documentation describes. Any other value names whatever was actually built.
    var message: String {
        if branch == Self.developmentBranchName {
            return String(
                localized: "This is the development version of Trio, built from the dev branch.\n\nAny updates on this branch may contain new, lightly tested features, and may be unsafe. If you are not a tester, please do not use this branch, and switch to main.",
                comment: "Body of the warning shown on builds from the dev branch"
            )
        }

        return String(
            localized: "This version of Trio was built from '\(branch)', not the released main branch.\n\nAny updates on this branch may contain new, lightly tested features, and may be unsafe. If you are not a tester, please do not use this branch, and switch to main.",
            comment: "Body of the warning shown on builds from a branch other than main or dev; the placeholder is the branch name"
        )
    }
}

// MARK: - Presentation

extension View {
    /// Presents the non-release build warning.
    ///
    /// The alert offers no cancel: the user either acknowledges that they are testing, or opens the
    /// documentation on returning to the released version.
    func developmentBranchWarning(_ alerter: DevelopmentBranchAlerter) -> some View {
        alert(
            Text("Hey Trioneer, watch out!", comment: "Title of the warning shown on builds that are not from the main branch"),
            isPresented: Binding(
                get: { alerter.isPresented },
                set: { newValue in
                    alerter.isPresented = newValue
                    if !newValue {
                        alerter.acknowledge()
                    }
                }
            )
        ) {
            Button(String(
                localized: "I'm a Tester",
                comment: "Button that dismisses the non-release build warning"
            )) {
                alerter.acknowledge()
            }

            Button(String(
                localized: "How to Return to Main",
                comment: "Button on the non-release build warning that opens documentation about returning to main"
            )) {
                alerter.acknowledge()
                UIApplication.shared.open(DevelopmentBranchAlerter.returnToReleaseURL)
            }
        } message: {
            Text(alerter.message)
        }
    }
}
