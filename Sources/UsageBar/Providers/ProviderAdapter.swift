import Foundation

protocol ProviderAdapter: Sendable {
    var provider: ProviderKind { get }
    func fetchBalance(using credential: StoredCredential?) async throws -> ProviderBalanceSnapshot
}

enum ProviderError: LocalizedError {
    case missingCredential
    case invalidResponse
    case emptyPayload
    case unauthorized
    case rateLimited
    case serverError(Int)
    case networkFailure(String)
    case unsupportedFeature(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "No credential configured."
        case .invalidResponse:
            "The provider response could not be parsed."
        case .emptyPayload:
            "The provider returned an empty payload."
        case .unauthorized:
            "The saved credential is no longer authorized."
        case .rateLimited:
            "The provider rate-limited the balance request."
        case .serverError(let code):
            "The provider returned HTTP \(code)."
        case .networkFailure(let message):
            "Network request failed: \(message)"
        case .unsupportedFeature(let message):
            message
        }
    }
}

struct ProviderHTTPClient {
    var session: URLSession = .shared

    func dataRequest(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200 ..< 300:
                guard data.isEmpty == false else {
                    throw ProviderError.emptyPayload
                }
                return (data, httpResponse)
            case 401, 403:
                throw ProviderError.unauthorized
            case 429:
                throw ProviderError.rateLimited
            default:
                throw ProviderError.serverError(httpResponse.statusCode)
            }
        } catch let error as ProviderError {
            throw error
        } catch let error as URLError {
            throw ProviderError.networkFailure(error.localizedDescription)
        }
    }

    func jsonRequest(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> Any {
        let (data, _) = try await dataRequest(
            url: url,
            method: method,
            headers: headers,
            body: body
        )
        return try JSONSerialization.jsonObject(with: data)
    }

    func textRequest(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> String {
        let (data, _) = try await dataRequest(
            url: url,
            method: method,
            headers: headers,
            body: body
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderError.invalidResponse
        }
        return text
    }
}
