import Foundation

struct TokenOut: Decodable {
    let accessToken: String
    let refreshToken: String
    let status: String
    let isNew: Bool
}

struct UserOut: Decodable, Equatable {
    let id: String
    var nickname: String?
    var avatarUrl: String?
    var status: String
}

struct PresenceOut: Decodable {
    let ok: Bool
    let reason: String?
    /// 이번 위치로 범위를 벗어나 빠진 방
    let leftRooms: [String]?
    /// 거리로 빠졌던 방에 다시 다가와 자동으로 다시 들어간 방
    let joinedRooms: [String]?
}

struct NearbyOut: Decodable {
    let count: Int
    let avatars: [String?]
    let radiusM: Int
}

struct MemberBrief: Decodable, Hashable {
    let id: String
    let nickname: String?
    let avatarUrl: String?
}

struct RoomOut: Decodable, Hashable, Identifiable {
    let id: String
    var areaName: String
    var memberCount: Int
    var avatars: [String?]
    var isMember: Bool
    var readOnly: Bool
}

struct TopicOut: Decodable, Hashable, Identifiable {
    let id: String
    let roomId: String
    let title: String
    let summary: String
    let category: String
    let imageUrl: String?
    var memberCount: Int
    let lastMessageAt: Date
    var isMember: Bool
}

/// 채팅 탭: 지금 들어가 있는 방 + 참여한 토픽
struct ChatsOut: Decodable {
    let room: RoomOut?
    let topics: [TopicOut]
}

/// 토픽 카드 메시지의 meta
struct TopicMeta: Decodable, Hashable {
    let topicId: String
    let title: String
    let summary: String
    let category: String
    let imageUrl: String?
    let memberCount: Int
    let reminder: Bool?
}

enum MessageType {
    static let text = "text"
    static let system = "system"
    static let topicCard = "topic_card"
}

struct MessageOut: Decodable, Hashable, Identifiable {
    let id: Int
    let roomId: String
    let topicId: String?
    let type: String
    let body: String
    let meta: TopicMeta?
    let sender: MemberBrief?
    let createdAt: Date
    let clientId: String?

    enum CodingKeys: String, CodingKey {
        case id, roomId, topicId, type, body, meta, sender, createdAt, clientId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        roomId = try c.decode(String.self, forKey: .roomId)
        topicId = try c.decodeIfPresent(String.self, forKey: .topicId)
        type = try c.decode(String.self, forKey: .type)
        body = try c.decode(String.self, forKey: .body)
        // meta는 토픽 카드일 때만 의미가 있으므로 실패해도 무시
        meta = try? c.decodeIfPresent(TopicMeta.self, forKey: .meta)
        sender = try c.decodeIfPresent(MemberBrief.self, forKey: .sender)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
    }
}

/// WebSocket으로 오는 이벤트
struct WSEvent: Decodable {
    let type: String
    let message: MessageOut?
    let memberCount: Int?
    let avatars: [String?]?
    let topic: TopicOut?
    let userId: String?
    let code: String?
}

struct OkResponse: Decodable {}

enum TopicCategory {
    /// 서버 app/services/categories.py 의 키와 맞춘다. 이미지를 못 받을 때 쓰는 아이콘
    static func symbol(_ category: String) -> String {
        switch category {
        case "movie": return "film"
        case "show": return "music.mic"
        case "event": return "party.popper"
        case "exhibition": return "photo.artframe"
        case "shopping": return "bag"
        case "food": return "fork.knife"
        case "cafe": return "cup.and.saucer"
        case "place": return "mappin.and.ellipse"
        case "sports": return "trophy"
        case "nature": return "cloud.sun"
        case "news": return "megaphone"
        case "pet": return "pawprint"
        case "game": return "gamecontroller"
        default: return "bubble.left.and.bubble.right"
        }
    }
}
