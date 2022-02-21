public enum Provider: String {
    case apple
    case azure
    case bitbucket
    case discord
    case facebook
    case github
    case gitlab
    case google
    case linkedin
    case notion
    case slack
    case spotify
    case twitch
    case twitter
}

public struct ProviderOptions {
    public var redirectTo: String?
    public var scopes: String?

    public init(redirectTo: String?, scopes: String?) {
        self.redirectTo = redirectTo
        self.scopes = scopes
    }
}
