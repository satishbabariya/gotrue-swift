import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public typealias AuthStateChangeCallback = (_ event: AuthChangeEvent, _ session: Session?) -> Void

public struct Subscription {
  let callback: AuthStateChangeCallback

  public let unsubscribe: () -> Void
}

public class GoTrueClient {
  var api: GoTrueApi
  var currentSession: Session?
  var autoRefreshToken: Bool
  var refreshTokenTimer: Timer?

  private let sessionManager: SessionManager
  private var stateChangeListeners: [String: Subscription] = [:]

  /// Receive a notification every time an auth event happens.
  /// - Returns: A subscription object which can be used to unsubscribe itself.
  public func onAuthStateChange(
    _ callback: @escaping (_ event: AuthChangeEvent, _ session: Session?) -> Void
  ) -> Subscription {
    let id = UUID().uuidString

    let subscription = Subscription(
      callback: callback,
      unsubscribe: { [weak self] in
        self?.stateChangeListeners[id] = nil
      }
    )

    stateChangeListeners[id] = subscription
    return subscription
  }

  public var user: User? {
    return currentSession?.user
  }

  public var session: Session? {
    return currentSession
  }

  /// Initializes the GoTrue Client with the provided parameters.
  /// - Parameters:
  ///   - url: URL of the GoTrue server.
  ///   - headers: Any headers to include with network requests.
  ///   - autoRefreshToken: Auto-refresh expired tokens.
  ///   - keychainAccessGroup: A shared keychain access group to use (Optional).
  public init(
    url: String = GoTrueConstants.defaultGotrueUrl,
    headers: [String: String] = [:],
    autoRefreshToken: Bool = true,
    keychainAccessGroup: String? = nil
  ) {
    api = GoTrueApi(url: url, headers: headers)
    self.autoRefreshToken = autoRefreshToken

    sessionManager = SessionManager(accessGroup: keychainAccessGroup)

    // Recover session from storage
    currentSession = sessionManager.getSession()
    if currentSession != nil {
      notifyAllStateChangeListeners(.signedIn)
    }
  }

  public func signUp(
    email: String, password: String, completion: @escaping (Result<User, Error>) -> Void
  ) {
    sessionManager.removeSession()
    api.signUpWithEmail(email: email, password: password, completion: completion)
  }

  public func signIn(
    email: String, password: String, completion: @escaping (Result<Session, Error>) -> Void
  ) {
    sessionManager.removeSession()

    api.signInWithEmail(email: email, password: password) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case let .success(session):
        self.saveSession(session: session)
        self.notifyAllStateChangeListeners(.signedIn)
        completion(.success(session))
      case let .failure(error):
        completion(.failure(error))
      }
    }
  }

  public func signIn(email: String, completion: @escaping (Result<Void, Error>) -> Void) {
    sessionManager.removeSession()
    api.sendMagicLinkEmail(email: email, completion: completion)
  }

  public func signIn(
    provider: Provider, options: ProviderOptions? = nil,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    sessionManager.removeSession()

    do {
      let providerURL = try api.getUrlForProvider(provider: provider, options: options)
      completion(.success(providerURL))
    } catch {
      completion(.failure(error))
    }
  }

  public func update(
    emailChangeToken: String? = nil, password: String? = nil, data: [String: Any]? = nil,
    completion: @escaping (Result<User, Error>) -> Void
  ) {
    guard let accessToken = currentSession?.accessToken else {
      completion(.failure(GoTrueError(message: "current session not found")))
      return
    }

    api.updateUser(
      accessToken: accessToken, emailChangeToken: emailChangeToken, password: password, data: data
    ) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case let .success(user):
        self.notifyAllStateChangeListeners(.userUpdated)
        self.currentSession?.user = user
        if let currentSession = self.currentSession {
          self.sessionManager.saveSession(currentSession)
        }
        completion(.success(user))
      case let .failure(error):
        completion(.failure(error))
      }
    }
  }

  public func getSessionFromUrl(url: String, completion: @escaping (Result<Session, Error>) -> Void)
  {
    let components = URLComponents(string: url)

    guard let queryItems = components?.queryItems,
      let accessToken: String = queryItems.first(where: { item in item.name == "access_token" })?
        .value,
      let expiresIn: String = queryItems.first(where: { item in item.name == "expires_in" })?.value,
      let refreshToken: String = queryItems.first(where: { item in item.name == "refresh_token" })?
        .value,
      let tokenType: String = queryItems.first(where: { item in item.name == "token_type" })?.value
    else {
      completion(.failure(GoTrueError(message: "bad credentials")))
      return
    }

    //        let providerToken = queryItems.first(where: { item in item.name == "provider_token" })?.value

    api.getUser(accessToken: accessToken) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case let .success(user):
        let session = Session(
          accessToken: accessToken, tokenType: tokenType, expiresIn: TimeInterval(expiresIn) ?? 0,
          refreshToken: refreshToken, user: user)
        self.saveSession(session: session)
        self.notifyAllStateChangeListeners(.signedIn)

        if let type: String = queryItems.first(where: { item in item.name == "type" })?.value,
          type == "recovery"
        {
          self.notifyAllStateChangeListeners(.passwordRecovery)
        }

        completion(.success(session))
      case let .failure(error):
        completion(.failure(error))
      }
    }
  }

  func saveSession(session: Session) {
    currentSession = session

    sessionManager.saveSession(session)

    if refreshTokenTimer != nil {
      refreshTokenTimer?.invalidate()
      refreshTokenTimer = nil
    }

    refreshTokenTimer = Timer(
      fireAt: Date().addingTimeInterval(session.expiresIn), interval: 0, target: self,
      selector: #selector(refreshToken), userInfo: nil, repeats: false)
  }

  @objc
  private func refreshToken() {
    callRefreshToken(refreshToken: currentSession?.refreshToken) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case let .success(session):
        self.saveSession(session: session)
        self.notifyAllStateChangeListeners(.signedIn)
      case let .failure(error):
        print(error.localizedDescription)
      }
    }
  }

  public func refreshSession(completion: @escaping (Result<Session, Error>) -> Void) {
    guard let refreshToken = currentSession?.refreshToken else {
      completion(.failure(GoTrueError(message: "Not logged in.")))
      return
    }
    callRefreshToken(refreshToken: refreshToken) { [weak self] result in
      switch result {
      case let .success(session):
        self?.saveSession(session: session)
      case let .failure(error):
        print(error.localizedDescription)
      }

      completion(result)
    }
  }

  public func signOut(completion: @escaping (Result<Any?, Error>) -> Void) {
    guard let accessToken = currentSession?.accessToken else {
      completion(.failure(GoTrueError(message: "current session not found")))
      return
    }

    sessionManager.removeSession()
    currentSession = nil
    notifyAllStateChangeListeners(.signedOut)

    api.signOut(accessToken: accessToken) { result in
      completion(result)
    }
  }

  private func callRefreshToken(
    refreshToken: String?, completion: @escaping (Result<Session, Error>) -> Void
  ) {
    guard let refreshToken = refreshToken else {
      completion(.failure(GoTrueError(message: "current session not found")))
      return
    }

    api.refreshAccessToken(refreshToken: refreshToken, completion: completion)
  }

  private func notifyAllStateChangeListeners(_ event: AuthChangeEvent) {
    stateChangeListeners.values.forEach {
      $0.callback(event, session)
    }
  }
}

#if compiler(>=5.5)
  @available(iOS 15.0.0, macOS 12.0.0, *)
  extension GoTrueClient {

    public func onAuthStateChange() -> AsyncStream<(AuthChangeEvent, Session?)> {
      AsyncStream { continuation in
        _ = onAuthStateChange { event, session in
          continuation.yield((event, session))
        }

        // How to stop subscription?
        // continuation.onTermination = { subscription.unsubscribe() }
      }
    }

    public func signUp(email: String, password: String) async throws -> User {
      try await withCheckedThrowingContinuation { continuation in
        signUp(email: email, password: password) { result in
          continuation.resume(with: result)
        }
      }
    }

    public func signIn(email: String, password: String) async throws -> Session {
      try await withCheckedThrowingContinuation { continuation in
        signIn(email: email, password: password) { result in
          continuation.resume(with: result)
        }
      }
    }

    public func signIn(email: String) async throws {
      try await withCheckedThrowingContinuation { continuation in
        signIn(email: email) { result in
          continuation.resume(with: result)
        }
      }
    }

    public func update(
      emailChangeToken: String? = nil, password: String? = nil, data: [String: Any]? = nil
    ) async throws -> User {
      try await withCheckedThrowingContinuation { continuation in
        update(emailChangeToken: emailChangeToken, password: password, data: data) { result in
          continuation.resume(with: result)
        }
      }
    }

    public func getSessionFromUrl(url: String) async throws -> Session {
      try await withCheckedThrowingContinuation { continuation in
        getSessionFromUrl(url: url) { result in
          continuation.resume(with: result)
        }
      }
    }

    public func refreshSession() async throws -> Session {
      try await withCheckedThrowingContinuation { continuation in
        refreshSession { result in
          continuation.resume(with: result)
        }
      }
    }

    public func signOut() async throws -> Any? {
      try await withCheckedThrowingContinuation { continuation in
        signOut { result in
          continuation.resume(with: result)
        }
      }
    }
  }
#endif
