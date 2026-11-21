from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", env_ignore_empty=True)

    # 기본
    env: str = "dev"  # dev | prod
    public_base_url: str = "http://localhost:8000"
    database_url: str = "sqlite+aiosqlite:///./ripple.db"
    redis_url: str = "redis://localhost:6379/0"
    media_dir: str = "./media"

    # 토큰
    jwt_secret: str = "change-me"
    access_ttl_minutes: int = 60 * 24
    refresh_ttl_days: int = 30

    # 개발용 로그인 (시뮬레이터·테스트·데모). 운영에서는 반드시 false
    allow_dev_login: bool = True

    # Kakao
    kakao_app_id: int | None = None  # 내 앱 ID. 설정하면 토큰의 app_id와 비교
    kakao_rest_api_key: str | None = None  # 좌표 → 행정구역 변환용

    # Apple
    apple_bundle_id: str = "com.kdh.ripple"
    apple_team_id: str | None = None
    apple_key_id: str | None = None
    apple_private_key: str | None = None  # .p8 내용 (토큰 교환·해지용)

    # 앱푸시 (APNs 토큰 인증 키, 팀 공용). 키가 없으면 보내지 않고 로그만 남김
    apns_key_id: str | None = None
    apns_private_key: str | None = None  # .p8 내용, 줄바꿈은 \n
    apns_key_path: str | None = None  # .p8 파일 경로 (apns_private_key 대신)
    nearby_push_window_s: int = 30 * 60  # 백그라운드 사용자의 마지막 위치를 이만큼 믿음
    nearby_pair_cooldown_s: int = 10 * 60  # 같은 (나, 상대) 짝에 "근처에 사람이 있어요"를 다시 보내는 최소 간격

    # 번호인증
    phone_hmac_secret: str = "change-me-too"
    sms_provider: str = "console"  # console | sendon
    # 센드온 SMS API 계정
    sendon_base_url: str = "https://api.sendon.io"
    sendon_user_id: str | None = None
    sendon_api_key: str | None = None
    sendon_sender: str | None = None  # 등록된 발신번호
    # 센드온 허용 IP 밖에서 돌릴 때 허용된 서버를 거쳐 보냄. 예: socks5://127.0.0.1:18080 (ssh -D)
    sendon_proxy: str | None = None
    demo_phone: str | None = None  # 심사용 데모 번호
    demo_code: str = "000000"

    # 위치·방
    radius_m: int = 200
    room_leave_m: int = 300
    room_leave_grace_s: int = 180
    presence_ttl_s: int = 60
    # 시연 중 레이더 문제 추적용. 위치 보고마다 결과·근처 인원·가장 가까운 사람 거리를 로그로 남김 (좌표는 안 남김)
    presence_log: bool = False
    room_idle_close_s: int = 30 * 60
    message_retention_h: int = 24

    # 토픽
    topic_classifier: str = "rule"  # rule | claude | llm
    # Claude API (TOPIC_CLASSIFIER=claude). 분류처럼 짧고 많은 호출이라 Haiku가 기본
    anthropic_api_key: str | None = None
    claude_model: str = "claude-haiku-5-5"
    claude_timeout_s: float = 8.0  # 워커가 분류를 기다리는 동안 다른 작업이 멈추므로 짧게
    # OpenAI 호환 (Ollama 등, TOPIC_CLASSIFIER=llm)
    llm_base_url: str = "http://localhost:11434/v1"
    llm_api_key: str = "ollama"
    llm_model: str = "gemma4:e4b"
    topic_candidate_ttl_s: int = 600

    # 시연용 데모 봇. 0이면 꺼짐. 실제 사용자 주변에 봇을 띄우고 방에 같이 들어가 대화한다
    demo_bots: int = 0
    topic_reminder_s: int = 600
    run_worker_inline: bool = True  # api 프로세스 안에서 워커 실행 (개발용)


@lru_cache
def get_settings() -> Settings:
    return Settings()
