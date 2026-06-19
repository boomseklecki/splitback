import SwiftUI
import Foundation
import OpenAPIRuntime

private let unreachableMessage =
    "Couldn't reach the server. Make sure the backend is running and the base URL (Settings) is correct."

/// Converts a thrown error into a user-facing message (BackendError messages preferred, transport
/// failures shown as a short "can't reach the server" note rather than a raw NSURLError dump).
func errorMessage(_ error: Error) -> String {
    if let backend = error as? BackendError { return backend.errorDescription ?? "Request failed." }
    if error is URLError { return unreachableMessage }
    if let clientError = error as? ClientError, clientError.underlyingError is URLError {
        return unreachableMessage
    }
    return error.localizedDescription
}

private struct ErrorAlertModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(
            "Something went wrong",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(message ?? "") }
        )
    }
}

extension View {
    /// Presents an alert whenever `message` is non-nil.
    func errorAlert(_ message: Binding<String?>) -> some View {
        modifier(ErrorAlertModifier(message: message))
    }
}
