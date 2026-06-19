import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Builds the generated `Client` with the URLSession transport, the configured base URL, the
/// fractional-seconds-tolerant date transcoder, and the bearer-auth middleware. Single place that
/// assembles the API client for repositories.
enum APIClientFactory {
    static func makeClient(
        baseURL: URL = APIConfig.baseURL,
        tokenStore: KeychainTokenStore = KeychainTokenStore()
    ) -> Client {
        Client(
            serverURL: baseURL,
            configuration: Configuration(dateTranscoder: FlexibleDateTranscoder()),
            transport: URLSessionTransport(),
            middlewares: [AuthMiddleware(tokenProvider: { tokenStore.load() })]
        )
    }
}
