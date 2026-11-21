# Ripple

SM@THON 해커톤용 iOS 앱. 반경 안에 있는 사람들이 같은 동네 채팅방에 들어가고, AI가 대화에서 같은 주제를 찾으면 토픽방을 만든다.

- 서버: `server/` FastAPI. 테스트는 `cd server && .venv/bin/python -m pytest -q` (항상 `SMS_PROVIDER=console`로 돈다).
- iOS: `ios/` SwiftUI, XcodeGen(`project.yml`). `ios/Config/*.xcconfig.example`을 복사해 키와 서버 주소를 채운 뒤 `xcodegen generate`.
- 비밀값(`.env`, xcconfig, `.p8`)과 운영 문서(HANDOFF.md, 배포 스크립트)는 git에 올리지 않는다. 로컬에만 있다.
- 한국어 커밋 메시지, 한 커밋에 한 가지 변경.
