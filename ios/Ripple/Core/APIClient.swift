import Foundation

struct APIError: LocalizedError {
    let status: Int
    let code: String

    var errorDescription: String? { APIError.messages[code] ?? "문제가 생겼어요. 잠시 후 다시 시도해 주세요. (\(code))" }

    static let messages: [String: String] = [
        "invalid_phone": "휴대폰 번호를 다시 확인해 주세요.",
        "otp_cooldown": "잠시 후 다시 요청해 주세요. (1분)",
        "otp_daily_limit": "오늘 인증 요청 횟수를 모두 썼어요.",
        "otp_expired": "인증번호가 만료됐어요. 다시 받아 주세요.",
        "otp_wrong_code": "인증번호가 맞지 않아요.",
        "otp_too_many_attempts": "입력 횟수를 초과했어요. 인증번호를 다시 받아 주세요.",
        "otp_phone_mismatch": "인증번호를 받은 번호와 달라요.",
        "phone_already_used": "이미 가입된 번호예요.",
        "sms_send_failed": "인증번호를 보내지 못했어요. 잠시 후 다시 시도해 주세요.",
        "nickname_length": "닉네임은 2~12자로 정해 주세요.",
        "nickname_banned": "사용할 수 없는 닉네임이에요.",
        "nickname_taken": "이미 사용 중인 닉네임이에요.",
        "no_fresh_location": "위치를 확인하는 중이에요. 잠시 후 다시 시도해 주세요.",
        "not_in_room": "방 범위를 벗어나 참여할 수 없어요.",
        "invalid_image": "이미지를 읽을 수 없어요.",
        "file_too_large": "사진 용량이 너무 커요.",
        "network": "네트워크 연결을 확인해 주세요.",
    ]
}

@MainActor
final class APIClient {
    static let shared = APIClient()

    var onUnauthorized: (() -> Void)?
    private let tokens = TokenStore.shared
    private let session = URLSession.shared

    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = DateParser.parse(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: raw))
        }
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: (any Encodable)? = nil,
        auth: Bool = true,
        retry: Bool = true
    ) async throws -> T {
        var req = URLRequest(url: AppConfig.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(body)
        }
        return try await perform(req, auth: auth, retry: retry)
    }

    func uploadImage<T: Decodable>(_ path: String, jpeg: Data) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: AppConfig.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var data = Data()
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n".utf8))
        data.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        data.append(jpeg)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = data
        return try await perform(req, auth: true, retry: true)
    }

    private func perform<T: Decodable>(_ original: URLRequest, auth: Bool, retry: Bool) async throws -> T {
        var req = original
        if auth, let token = tokens.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError(status: 0, code: "network")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401, auth, retry, await refreshTokens() {
            return try await perform(original, auth: auth, retry: false)
        }
        if status == 401, auth {
            tokens.clear()
            onUnauthorized?()
        }
        guard (200..<300).contains(status) else {
            throw APIError(status: status, code: Self.detail(from: data))
        }
        return try decoder.decode(T.self, from: data)
    }

    private func refreshTokens() async -> Bool {
        guard let refresh = tokens.refreshToken else { return false }
        struct Body: Encodable { let refreshToken: String }
        do {
            let out: TokenOut = try await request("POST", "/auth/refresh", body: Body(refreshToken: refresh), auth: false, retry: false)
            tokens.save(access: out.accessToken, refresh: out.refreshToken)
            return true
        } catch {
            return false
        }
    }

    private static func detail(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "unknown" }
        if let s = obj["detail"] as? String { return s }
        return "validation_error"
    }
}

/// 서버 날짜: 2026-11-21T05:19:31.701786Z 처럼 소수점 6자리일 수 있음
enum DateParser {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        var s = raw
        // 타임존 표기가 없으면 UTC로 간주
        if !(s.hasSuffix("Z") || s.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil) {
            s += "Z"
        }
        // 소수점은 3자리로 자름
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let frac = String(s[r].prefix(4))
            s.replaceSubrange(r, with: frac)
        }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
}
