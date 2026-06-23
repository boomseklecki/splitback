import SwiftUI
import UIKit
import LinkKit

/// Presents Plaid Link for a given link token. On success, hands back the public token (the caller
/// exchanges it). Works in the simulator once the backend issues a link token.
struct PlaidLinkView: UIViewControllerRepresentable {
    let linkToken: String
    /// When set, resume an OAuth flow interrupted by app termination instead of opening Link fresh.
    var resumeRedirect: URL? = nil
    var onSuccess: (_ publicToken: String) -> Void
    var onExit: () -> Void = {}

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = HostController()
        controller.onFirstAppear = { [weak controller] in
            guard let controller else { return }
            context.coordinator.present(from: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Hosts the Plaid handler and presents it once it's in the window hierarchy.
    final class HostController: UIViewController {
        var onFirstAppear: (@MainActor () -> Void)?
        private var appeared = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !appeared else { return }
            appeared = true
            onFirstAppear?()
        }
    }

    @MainActor
    final class Coordinator {
        private let parent: PlaidLinkView
        private var handler: Handler?

        init(_ parent: PlaidLinkView) { self.parent = parent }

        func present(from controller: UIViewController) {
            var configuration = LinkTokenConfiguration(token: parent.linkToken) { [parent] success in
                PlaidLinkDiagnosticsStore.shared.clear()  // the attempt succeeded — drop any prior error
                parent.onSuccess(success.publicToken)
            }
            // Capture the exit's session/request ids + error so a failed link can be reported to Plaid.
            configuration.onExit = { [parent] exit in
                PlaidLinkDiagnosticsStore.shared.record(Self.diagnostics(token: parent.linkToken, exit: exit))
                parent.onExit()
            }

            switch Plaid.create(configuration) {
            case let .success(handler):
                self.handler = handler
                PlaidLinkSession.shared.register(handler)
                if let redirect = parent.resumeRedirect {
                    // App was terminated mid-OAuth; resume from the redirect rather than reopening.
                    handler.resumeAfterTermination(from: redirect)
                } else {
                    handler.open(presentUsing: .viewController(controller))
                }
            case let .failure(error):
                PlaidLinkDiagnosticsStore.shared.record(
                    PlaidLinkDiagnostics(linkToken: parent.linkToken,
                                         errorMessage: "Plaid.create failed: \(String(describing: error))"))
                parent.onExit()
            }
        }

        /// Maps LinkKit's `LinkExit` (error + session metadata) to our stored diagnostics.
        private static func diagnostics(token: String, exit: LinkExit) -> PlaidLinkDiagnostics {
            let metadata = exit.metadata
            return PlaidLinkDiagnostics(
                linkToken: token,
                linkSessionID: metadata.linkSessionID,
                requestID: metadata.requestID,
                institutionName: metadata.institution?.name,
                institutionID: metadata.institution.map { String(describing: $0.id) },
                status: metadata.status.map { String(describing: $0) },
                errorCode: exit.error.map { String(describing: $0.errorCode) },
                errorMessage: exit.error?.errorMessage,
                displayMessage: exit.error?.displayMessage
            )
        }
    }
}
