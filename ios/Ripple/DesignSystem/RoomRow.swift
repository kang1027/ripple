import SwiftUI

/// 토픽방 목록 한 줄 (디자인 RegionalRooms 행). 커버 64 + #제목 + 장소 + 시각 + 인원
struct TopicRoomRow: View {
    let topic: TopicOut
    var place: String?
    var muted = false
    var showChevron: Bool { !topic.isMember }

    var body: some View {
        HStack(spacing: 12) {
            TopicImage(url: topic.imageUrl, category: topic.category)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xxl))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(TopicTitle.hashtag(topic.title))
                        .appFont(17, .heavy)
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(1)
                    if muted || topic.muted == true {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.mutedForeground)
                            .accessibilityLabel("알림 꺼짐")
                    }
                }
                if let place = topic.placeName ?? place, !place.isEmpty {
                    Text(place)
                        .appFont(12)
                        .foregroundStyle(Theme.mutedForeground)
                        .padding(.top, 4)
                }
                Text(topic.createdAt.map { "생성 " + DateText.full($0) } ?? "최근 대화 \(topic.lastMessageAt.formatted(.relative(presentation: .named)))")
                    .appFont(11)
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.top, 4)
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill").font(.system(size: 10))
                    Text("\(topic.memberCount)명 · \(topic.isMember ? "대화 이어가기" : "참여하기")")
                }
                .appFont(12, .semibold)
                .foregroundStyle(Theme.primary)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
        .padding(.vertical, 16)
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.xxl).fill(Theme.card))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.xxl))
    }
}

enum DateText {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy.MM.dd HH:mm"
        return f
    }()

    /// 2026.11.21 14:30
    static func full(_ date: Date) -> String { formatter.string(from: date) }
}

enum TopicTitle {
    /// 토픽 제목 앞에 #을 붙인다. 이미 붙어 있으면 그대로 둔다
    static func hashtag(_ title: String) -> String {
        title.hasPrefix("#") ? title : "#\(title)"
    }
}

/// 목록 화면 맨 위 큰 제목 (30pt)
struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .appFont(30, .heavy)
            .foregroundStyle(Theme.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
    }
}

/// 빈 목록 안내
struct EmptyState: View {
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Text(title).appFont(16, .bold).foregroundStyle(Theme.foreground)
            Text(message)
                .appFont(14)
                .foregroundStyle(Theme.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            if let action {
                Button(action: action.run) {
                    Text(action.title)
                        .appFont(14, .semibold)
                        .foregroundStyle(Theme.foreground)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.xl).fill(Theme.secondary))
                }
                .buttonStyle(PressStyle())
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}
