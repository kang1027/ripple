# Ripple 서버 운영 종료와 재배포 가이드

## 현재 상태 (2026-11-22)

- 해커톤 시연이 끝나서 운영 서버를 내렸습니다. 공개 API 주소는 더 이상 응답하지 않습니다.
- 서버와 iOS 코드는 전부 이 레포에 있습니다. 운영 서버에만 있던 코드는 없습니다.
- 운영 DB(테스트 계정 19명, 프로필 사진 8장)는 서버 운영자가 따로 백업해 두었습니다. 레포에는 들어 있지 않습니다.
- 다시 띄울 일이 생기면 아래 절차대로 새 서버에 올리면 됩니다.

## 1. 서버 구성 요약

- FastAPI 한 프로세스. `server/Dockerfile`로 이미지를 만듭니다(`python:3.12-slim`).
- 상태 저장
  - DB: SQLite 기본(`DATABASE_URL=sqlite+aiosqlite:////data/ripple.db`). Postgres(`postgresql+asyncpg://…`)도 됩니다.
  - 파일: 프로필 사진은 `MEDIA_DIR`(예: `/data/media`)에 저장됩니다. 토픽 카테고리 이미지는 이미지 안 `app/static`에 들어 있습니다.
  - Redis: `REDIS_URL=fake://`면 메모리 안 fakeredis, 실제 Redis 주소면 그쪽을 씁니다.
- 스키마: 마이그레이션 도구가 없습니다. 서버가 시작할 때 `create_all()`로 테이블을 만들고, 모델에 새로 생긴 nullable 컬럼만 추가합니다(`app/db.py`).
- 헬스체크: `GET /health` → `{"ok": true}`

## 2. 꼭 지켜야 하는 조건

| 조건 | 이유 | 근거 |
|---|---|---|
| API 프로세스는 1개만 | 방 입장 중복을 프로세스 안 lock으로 막습니다. 두 벌 띄우면 방이 둘 생길 수 있습니다 | `app/routers/geo.py` `_join_lock` |
| `REDIS_URL=fake://`면 `RUN_WORKER_INLINE=true` | 워커를 따로 띄우면 메모리 Redis를 공유하지 못합니다 | `app/redis_client.py`, `app/main.py` |
| 재배포는 정지 → 시작 순서 | 두 벌이 잠깐이라도 겹치면 위 조건이 깨집니다. SQLite도 동시 쓰기에 약합니다 | |
| 운영에선 `ENV=prod`, `ALLOW_DEV_LOGIN=false` | 공개 서버에서 개발용 로그인을 열면 아무 계정이나 만들 수 있습니다 | `app/config.py` |
| 기존 데이터를 살릴 땐 `JWT_SECRET`, `PHONE_HMAC_SECRET`을 예전 값 그대로 | `JWT_SECRET`이 바뀌면 세션이 끊기고, `PHONE_HMAC_SECRET`이 바뀌면 저장된 전화번호 해시와 맞지 않아 번호당 1계정 검사가 깨집니다. 빈 DB로 시작하면 새로 만들어도 됩니다 | `app/security.py` |

fakeredis를 쓰면 위치, 근처 알림 상태, 웹소켓 접속 표시가 재시작할 때 지워집니다. 앱이 2초마다 위치를 다시 보내므로 곧 회복됩니다.

## 3. 환경 변수

전체 목록과 설명은 `server/.env.example`에 있습니다.

**필수**
- `ENV=prod`, `PUBLIC_BASE_URL`(앱이 보는 공개 주소, 경로 접두어 포함), `JWT_SECRET`, `PHONE_HMAC_SECRET`(`python -c "import secrets;print(secrets.token_hex(32))"`로 각각 생성), `ALLOW_DEV_LOGIN=false`
- `DATABASE_URL`, `REDIS_URL`, `RUN_WORKER_INLINE`, `MEDIA_DIR`

**외부 서비스 키**
- 카카오: `KAKAO_APP_ID`, `KAKAO_REST_API_KEY`
- 애플: `APPLE_BUNDLE_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`
- 앱푸시: `APNS_KEY_ID`, `APNS_PRIVATE_KEY`(`.p8` 내용, 줄바꿈은 `\n`) 또는 `APNS_KEY_PATH`
- 번호인증: `SMS_PROVIDER`(`console`|`sendon`), `SENDON_USER_ID`, `SENDON_API_KEY`, `SENDON_SENDER`, 심사용 `DEMO_PHONE`, `DEMO_CODE`
- 토픽 AI: `TOPIC_CLASSIFIER`(`rule`|`claude`|`llm`), `ANTHROPIC_API_KEY`, `CLAUDE_MODEL`

**시연 때 바꿨던 값** (운영에선 넣지 않으면 기본값)

| 키 | 시연 값 | 기본값 |
|---|---|---|
| `RADIUS_M` | 25 | 200 |
| `ROOM_LEAVE_M` | 40 | 300 |
| `ROOM_LEAVE_GRACE_S` | 4 | 180 |
| `ROOM_IDLE_CLOSE_S` | 180 | 1800 |
| `PRESENCE_LOG` | true | false |
| `NEARBY_PAIR_COOLDOWN_S` | 60 | 600 |
| `DEMO_BOTS` / `DEMO_SCRIPT` | 8 / true (녹화 때만) | 0 / false |

**외부 서비스 조건**
- 센드온(SMS)은 등록된 허용 IP에서만 발송됩니다. 새 서버 IP를 센드온 콘솔에 등록하거나, `SENDON_PROXY`(socks5)로 허용 IP를 거치거나, `SMS_PROVIDER=console`로 둡니다. 안 하면 인증문자 요청이 502 `sms_send_failed`로 실패합니다.
- 카카오·애플 로그인과 APNs, Claude API는 서버 IP 제한이 없습니다.

## 4. 새 서버 띄우기

### 4-1. 권장: 컨테이너 1개 + SQLite + 볼륨 (시연 때와 같은 구성)

```bash
git clone https://github.com/kang1027/ripple.git && cd ripple/server
docker build -t ripple-server .
mkdir -p /srv/ripple/data
# /srv/ripple/ripple.env 에 3장 값들 + 아래 네 줄
#   DATABASE_URL=sqlite+aiosqlite:////data/ripple.db
#   REDIS_URL=fake://
#   RUN_WORKER_INLINE=true
#   MEDIA_DIR=/data/media
docker run -d --name ripple --restart unless-stopped \
  --env-file /srv/ripple/ripple.env \
  -v /srv/ripple/data:/data -p 127.0.0.1:8000:8000 \
  ripple-server \
  uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --forwarded-allow-ips "*"
curl -fsS http://127.0.0.1:8000/health
```

- `.env` 파일에서 주석은 반드시 별도 줄에 씁니다. 값 뒤의 `#`는 값으로 읽힙니다.
- `Dockerfile` 기본 CMD에는 `--forwarded-allow-ips`가 없습니다. 리버스 프록시 뒤에 둘 때는 위처럼 붙입니다.
- 이미지는 서버 CPU 아키텍처에 맞게 그 서버에서 빌드합니다.

### 4-2. 선택: docker-compose (Postgres + Redis + 별도 워커)

`server/docker-compose.yml`은 api, worker, postgres16, redis7을 띄웁니다. 운영에 쓰기 전에 확인할 것:
- compose가 `DATABASE_URL`을 Postgres로 덮어씁니다. SQLite 백업은 이 구성에서 쓰이지 않고, SQLite → Postgres로 옮기는 도구는 없습니다.
- Postgres 계정이 `ripple:ripple`로 고정돼 있습니다. 바꾸고, 5432 포트는 외부에 열지 않습니다.
- api 서비스에 `--forwarded-allow-ips`가 없어서 프록시 뒤에 둘 땐 `command`로 덮어씁니다.
- 실제 Redis를 써도 api는 1개여야 합니다(2장).

### 4-3. 리버스 프록시

- 앱은 루트(`/`)에서 서빙됩니다. 경로 접두어(예: `/ripple`) 아래에 둘 땐 프록시가 접두어를 떼고 넘겨야 합니다.
- 웹소켓(`/ws/rooms/{id}`, `/ws/topics/{id}`)을 넘겨야 합니다.

```caddy
# 도메인 루트로 서빙
<공개 도메인> {
  reverse_proxy 127.0.0.1:8000
}

# 경로 접두어 아래로 서빙 (PUBLIC_BASE_URL=https://<도메인>/ripple)
handle_path /ripple* {
  reverse_proxy 127.0.0.1:8000
}
```

nginx는 `proxy_set_header Upgrade $http_upgrade;`, `proxy_set_header Connection "upgrade";`가 필요합니다.

## 5. iOS 앱 연결

- 서버 주소는 빌드에 들어갑니다. `ios/Config/*.xcconfig.example`을 복사해 `API_BASE_URL`을 새 주소로 채우고 `xcodegen generate` 후 빌드합니다.
- xcconfig에서 `//`는 주석이라 URL은 `https:/$()/<도메인>/ripple`처럼 씁니다.

## 6. 백업 데이터로 복원할 때만

빈 DB로 시작하면 이 장은 건너뜁니다.

1. 백업의 `ripple.db`와 `media/`를 `/srv/ripple/data/`에 넣습니다.
2. `JWT_SECRET`, `PHONE_HMAC_SECRET`은 예전 운영 값을 씁니다(2장).
3. 공개 주소가 예전과 다르면, 서버를 시작하기 전에 DB 안 절대 URL을 바꿉니다. `users.avatar_url`, 토픽 카드 메시지 `messages.meta`(`image_url`, `cover_url`), `topics.image_url`에 `PUBLIC_BASE_URL`이 들어 있습니다.

```bash
OLD=https://<옛 주소>; NEW=https://<새 주소>
python3 - "$OLD" "$NEW" /srv/ripple/data/ripple.db <<'EOF'
import sqlite3, sys
old, new, path = sys.argv[1:]
c = sqlite3.connect(path)
c.execute("update users set avatar_url = replace(avatar_url, ?, ?) where avatar_url like ?", (old, new, old + "%"))
c.execute("update topics set image_url = replace(image_url, ?, ?) where image_url like ?", (old, new, old + "%"))
c.execute("update messages set meta = replace(meta, ?, ?) where meta like ?", (old, new, "%" + old + "%"))
c.commit()
print(c.execute("pragma integrity_check").fetchone())
EOF
```

메시지는 원래 7일만 보관해서(`MESSAGE_RETENTION_H=168`) 오래된 백업이면 서버가 뜬 뒤 정리됩니다.

## 7. 띄운 뒤 확인

1. `curl https://<공개 주소>/health`
2. 실기기에서 카카오/애플 로그인 → 번호인증 문자 수신 → 닉네임·프로필 사진 → 레이더 → 동네방 입장
3. 폰 두 대로 같은 주제를 4자 이상으로 말해서 토픽 카드가 뜨는지 확인
4. 앱을 내린 상태에서 푸시가 오는지 확인

서버 테스트: `cd server && .venv/bin/python -m pytest -q` (테스트는 `SMS_PROVIDER=console`, `TOPIC_CLASSIFIER=rule`을 강제해서 실제 문자·API를 부르지 않습니다)
