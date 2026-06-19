import SwiftUI
import UIKit
import LinkKit

/// Presents Plaid Link for a given link token. On success, hands back the public token (the caller
/// exchanges it). Works in the simulator once the backend issues a link token.
struct PlaidLinkView: UIViewControllerRepresentable {
    let linkToken: String
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
        var onFirstAppear: (() -> Void)?
        private var appeared = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !appeared else { return }
            appeared = true
            onFirstAppear?()
        }
    }

    final class Coordinator {
        private let parent: PlaidLinkView
        private var handler: Handler?

        init(_ parent: PlaidLinkView) { self.parent = parent }

        func present(from controller: UIViewController) {
            var configuration = LinkTokenConfiguration(token: parent.linkToken) { [parent] success in
                parent.onSuccess(success.publicToken)
            }
            configuration.onExit = { [parent] _ in parent.onExit() }

            switch Plaid.create(configuration) {
            case let .success(handler):
                self.handler = handler
                handler.open(presentUsing: .viewController(controller))
            case .failure:
                parent.onExit()
            }
        }
    }
}
