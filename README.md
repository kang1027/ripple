# Ripple (가칭: 같은 공간 채팅)

반경 200m 안의 사람들을 레이더로 찾아 자동 단톡방을 열고, 대화에서 같은 주제가 이어지면 AI 봇이 토픽 방을 만들어 주는 iOS 앱.

```
server/   FastAPI + Postgres + Redis (+ Worker)
ios/      SwiftUI (iOS 17+), XcodeGen 프로젝트
```

## 1. 서버 실행

### 가장 빠른 방법 (로컬, SQLite + Redis)

```bash
cd server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env          # JWT_SECRET, PHONE_HMAC_SECRET 채우기
brew services start redis     # 또는 docker run -p 6379:6379 redis:7
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

- 문서: http://localhost:8000/docs
- `SMS_PROVIDER=console` 이면 인증번호가 서버 로그에 찍힘
- 테스트: `pytest -q`

### Docker Compose (Postgres + Redis + Worker)

```bash
cd server && cp .env.example .env && docker compose up --build
```

## 2. iOS 실행

```bash
brew install xcodegen
cd ios && xcodegen && open Ripple.xcodeproj
```

1. 팀 `GGR9HG6DB8`, 번들 ID `com.kdh.ripple` (`project.yml`). 바꾸면 `xcodegen` 다시 실행
2. `Config/*.xcconfig.example` 세 개를 `.example` 없이 복사하고, `Shared.xcconfig`의 `KAKAO_NATIVE_APP_KEY` 입력 (세 파일은 git에 안 올라감)
3. 서버 주소: `Config/Debug.xcconfig` (시뮬레이터는 localhost, 실기기는 맥의 로컬 IP)
4. Debug 빌드에는 **개발 로그인**이 있어서 카카오·애플 설정 없이도 바로 테스트 가능
   - 서버 `.env`의 `DEMO_PHONE`을 설정하면 그 번호는 `DEMO_CODE`로 인증 통과
5. 시뮬레이터 위치: Xcode > Debug > Simulate Location, 또는 Features > Location > Custom

## 3. 외부 키 설정

| 항목 | 어디서 | 넣는 곳 |
| --- | --- | --- |
| 카카오 네이티브 앱 키 | 카카오 디벨로퍼스 > 앱 키 | `ios/Config/Shared.xcconfig` |
| 카카오 앱 ID (숫자) | 카카오 디벨로퍼스 > 앱 설정 | `server/.env` `KAKAO_APP_ID` |
| 카카오 REST 키 | 〃 (동네 이름 표시용) | `server/.env` `KAKAO_REST_API_KEY` |
| Apple 번들 ID | Apple Developer | `server/.env` `APPLE_BUNDLE_ID` |
| Apple 로그인 키(.p8) | Apple Developer > Keys | `server/.env` (탈퇴 시 토큰 해지용, 없어도 로그인은 됨) |
| 센드온 | 센드온 계정 | `server/.env` `SMS_PROVIDER=sendon` + `SENDON_*` |

카카오 디벨로퍼스 > 플랫폼 > iOS에 번들 ID 등록 필요.

## 4. 빠르게 동작시키려고 남겨둔 것 (TODO)

- [ ] 센드온 요청 필드명 확인: `server/app/services/sms.py`
- [x] 토픽 AI: `TOPIC_CLASSIFIER=claude` + `ANTHROPIC_API_KEY` (Claude Haiku 5.5). 키가 없거나 API가 실패하면 규칙 분류(`app/topics_seed.json`)로 넘어감
- [ ] Claude API 키: Ripple 전용 키로 교체
- [ ] DB 마이그레이션: 지금은 서버 시작 시 `create_all`. 스키마가 자주 바뀌면 Alembic 도입
- [ ] 디자인 반영: `ios/Ripple/DesignSystem/DS.swift`의 토큰·컴포넌트만 교체
- [ ] TestFlight: Release 서버 https 주소, `ALLOW_DEV_LOGIN=false`, 심사용 데모 번호

## 5. API 요약

| 메서드 | 경로 | 설명 |
| --- | --- | --- |
| POST | /auth/kakao, /auth/apple, /auth/dev | 로그인 → 토큰 + status |
| POST | /auth/refresh | 토큰 갱신 |
| POST | /auth/phone/request, /auth/phone/verify | 번호인증 |
| GET/PATCH/DELETE | /me | 내 정보, 닉네임, 탈퇴 |
| POST | /me/avatar | 프로필 사진 (EXIF 제거, 512px) |
| POST | /presence | 위치 보고 (15초마다, 포그라운드) |
| GET | /nearby | 반경 200m 인원·프사 |
| POST | /rooms/join | 방 배정 또는 생성 |
| GET | /rooms/{id}, /rooms/{id}/messages, /rooms/{id}/topics | 방 정보·메시지·토픽 |
| POST | /rooms/{id}/leave | 방 나가기 |
| GET/POST | /topics/{id}, /topics/{id}/join, /topics/{id}/messages | 토픽 방 |
| POST/GET/DELETE | /reports, /blocks | 신고·차단 |
| WS | /ws/rooms/{id}?token=, /ws/topics/{id}?token= | 실시간 채팅 |
