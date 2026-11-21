import Foundation

enum AppConfig {
    static var apiBaseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String ?? ""
        return URL(string: raw) ?? URL(string: "http://localhost:8000")!
    }

    static var kakaoAppKey: String {
        Bundle.main.object(forInfoDictionaryKey: "KAKAO_NATIVE_APP_KEY") as? String ?? ""
    }

    /// ws(s)://host/ws/...
    static func webSocketURL(path: String, token: String) -> URL? {
        guard var comps = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        // base에 경로 접두사(/ripple)가 있을 수 있어 덮어쓰지 않고 이어 붙인다
        let prefix = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = prefix + path
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        return comps.url
    }
}
