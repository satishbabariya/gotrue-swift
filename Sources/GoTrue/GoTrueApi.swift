import AnyCodable
import Foundation
import SimpleHTTP

struct GoTrueHeaders: RequestAdapter {
    var additionalHeaders: [String: String] = [:]

  func adapt(_ client: HTTPClientProtocol, _ request: inout URLRequest) async throws {
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      additionalHeaders.forEach { field, value in
          request.setValue(value, forHTTPHeaderField: field)
      }
  }
}

struct APIKeyRequestAdapter: RequestAdapter {
  let apiKey: String

  func adapt(_ client: HTTPClientProtocol, _ request: inout URLRequest) async throws {
    request.setValue(apiKey, forHTTPHeaderField: "apikey")
  }
}

struct Authenticator: RequestAdapter {
  func adapt(_ client: HTTPClientProtocol, _ request: inout URLRequest) async throws {
    let session = try await Env.sessionManager.session()
    request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
  }
}

struct APIErrorInterceptor: ResponseInterceptor {
  func intercept(_ client: HTTPClientProtocol, _ result: Result<Response, Error>) async throws
    -> Response
  {
    do {
      return try result.get()
    } catch let error as APIError {
      let response = try error.response.decoded(to: ErrorResponse.self)
      throw GoTrueError(
        statusCode: error.response.statusCode,
        message: response.msg ?? response.message
          ?? "Error: status_code=\(error.response.statusCode)"
      )
    } catch {
      throw error
    }
  }

  private struct ErrorResponse: Decodable {
    let msg: String?
    let message: String?
  }
}

extension HTTPClient {
    static func goTrueClient(url: URL, apiKey: String, additionalHeaders: [String: String] = [:]) -> HTTPClient {
    HTTPClient(
      baseURL: url,
      adapters: [
        DefaultHeaders(),
        GoTrueHeaders(additionalHeaders: additionalHeaders),
        APIKeyRequestAdapter(apiKey: apiKey)
      ],
      interceptors: [StatusCodeValidator()]
    )
  }
}

class GoTrueApi {
  func signUpWithEmail(email: String, password: String) async throws -> User {
    try await Env.httpClient.request(
      Endpoint(
        path: "signup", method: .post,
        body: try JSONEncoder().encode(["email": email, "password": password]))
    ).decoded(to: User.self)
  }

  func signInWithEmail(email: String, password: String) async throws -> Session {
    try await Env.httpClient.request(
      Endpoint(
        path: "/token", method: .post, query: [URLQueryItem(name: "grant_type", value: "password")],
        body: try JSONEncoder().encode(["email": email, "password": password])
      )
    ).decoded(to: Session.self)
  }

  func sendMagicLinkEmail(email: String) async throws {
    _ = try await Env.httpClient.request(
      Endpoint(path: "magiclink", method: .post, body: try JSONEncoder().encode(["email": email])))
  }

  func getUrlForProvider(provider: Provider, options: ProviderOptions?) throws -> URL {
    guard
      var components = URLComponents(
        url: Env.url().appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)
    else {
      throw GoTrueError.badURL
    }

    var queryItems: [URLQueryItem] = []
    queryItems.append(URLQueryItem(name: "provider", value: provider.rawValue))
    if let options = options {
      if let scopes = options.scopes {
        queryItems.append(URLQueryItem(name: "scopes", value: scopes))
      }
      if let redirectTo = options.redirectTo {
        queryItems.append(URLQueryItem(name: "redirect_to", value: redirectTo))
      }
    }

    components.queryItems = queryItems

    guard let url = components.url else {
      throw GoTrueError.badURL
    }

    return url
  }

  func refreshAccessToken(refreshToken: String) async throws -> Session {
    try await Env.httpClient.request(
      Endpoint(
        path: "/token", method: .post,
        query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
        body: try JSONEncoder().encode(["refresh_token": refreshToken])
      )
    )
    .decoded(to: Session.self)
  }

  func signOut() async throws {
    _ = try await Env.httpClient.request(
      Endpoint(path: "/logout", method: .post, additionalAdapters: [Authenticator()]))
  }

  func updateUser(params: UpdateUserParams) async throws -> User {
    try await Env.httpClient.request(
      Endpoint(
        path: "/user", method: .put, body: try JSONEncoder().encode(params),
        additionalAdapters: [Authenticator()])
    ).decoded(to: User.self)
  }

  func getUser() async throws -> User {
    try await Env.httpClient.request(
      Endpoint(path: "/user", method: .get, additionalAdapters: [Authenticator()])
    ).decoded(to: User.self)
  }
}
