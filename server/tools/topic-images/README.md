# 토픽 카테고리 기본 이미지

`app/static/topics/<카테고리>.jpg`를 만드는 스크립트예요. `photos/<카테고리>.jpg` 실사 사진을 배경으로 깔고, 가운데 반투명 원 위에 lucide 아이콘(ISC)을 얹어요.

```bash
cd tools/topic-images
npm i @resvg/resvg-js lucide-static sharp
node gen.mjs ../../app/static/topics
```

- 배경 사진은 Openverse에서 찾은 CC0 사진이에요. 출처는 `photos/CREDITS.md`에 있어요.
- 사진을 바꿀 땐 2:1(1440×720) JPG로 잘라서 `photos/`에 넣어요. 가운데 원이 사진 한가운데를 가리니까, 주인공이 한쪽에 있는 사진이 좋아요.
- `node_modules`는 `deploy-server.command`의 rsync로 홈서버에 같이 넘어가지 않게 다 쓰면 지워요.
- 예전 `.png` 이미지는 그 전에 만들어진 토픽 카드가 아직 가리키고 있어서 남겨 뒀어요.

카테고리를 추가하면 `app/services/categories.py`, `gen.mjs`의 `CATS`, `photos/`, iOS `TopicCategory.symbol`을 같이 고쳐요.
