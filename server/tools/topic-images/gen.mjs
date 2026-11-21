// 토픽 카테고리 기본 이미지 생성: 실사 배경(CC0, photos/) + 가운데 lucide 아이콘(ISC)
import { Resvg } from "@resvg/resvg-js";
import sharp from "sharp";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [, , outDir] = process.argv;
mkdirSync(outDir, { recursive: true });
const here = dirname(fileURLToPath(import.meta.url));
const W = 960, H = 480;

// key: [lucide 아이콘, 아이콘 색상(hue)]. 배경 사진은 photos/<key>.jpg
const CATS = {
  movie: ["clapperboard", 230], show: ["mic-vocal", 280], event: ["party-popper", 20],
  exhibition: ["frame", 330], shopping: ["shopping-bag", 300], food: ["utensils", 35],
  cafe: ["coffee", 28], place: ["map-pin", 160], sports: ["trophy", 200],
  nature: ["cloud-sun", 190], news: ["megaphone", 0], pet: ["paw-print", 45],
  game: ["gamepad-2", 250], etc: ["message-circle", 220],
};

const inner = (name) =>
  readFileSync(join(here, "node_modules/lucide-static/icons", `${name}.svg`), "utf8")
    .replace(/<!--.*?-->/s, "").replace(/<svg[^>]*>/s, "").replace("</svg>", "");

const hsl = (h, s, l) => `hsl(${h} ${s}% ${l}%)`;

for (const [key, [icon, h]] of Object.entries(CATS)) {
  const paths = inner(icon);
  const photo = `data:image/jpeg;base64,${readFileSync(join(here, "photos", `${key}.jpg`)).toString("base64")}`;
  const cx = W / 2, cy = H / 2, r = 120;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <filter id="blur" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="14"/></filter>
    <clipPath id="disc"><circle cx="${cx}" cy="${cy}" r="${r}"/></clipPath>
    <radialGradient id="vignette" cx="0.5" cy="0.5" r="0.75">
      <stop offset="0.45" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="0.35"/>
    </radialGradient>
  </defs>
  <image href="${photo}" width="${W}" height="${H}" preserveAspectRatio="xMidYMid slice"/>
  <rect width="${W}" height="${H}" fill="#000" opacity="0.22"/>
  <rect width="${W}" height="${H}" fill="url(#vignette)"/>
  <g clip-path="url(#disc)">
    <image href="${photo}" width="${W}" height="${H}" preserveAspectRatio="xMidYMid slice" filter="url(#blur)"/>
    <circle cx="${cx}" cy="${cy}" r="${r}" fill="${hsl(h, 30, 98)}" opacity="0.84"/>
  </g>
  <circle cx="${cx}" cy="${cy}" r="${r - 0.75}" fill="none" stroke="#fff" stroke-opacity="0.55" stroke-width="1.5"/>
  <g transform="translate(${cx - 66} ${cy - 66}) scale(5.5)" stroke="${hsl(h, 28, 32)}" stroke-width="1.6" fill="none" stroke-linecap="round" stroke-linejoin="round">${paths}</g>
</svg>`;
  const png = new Resvg(svg, { fitTo: { mode: "original" } }).render().asPng();
  const jpg = await sharp(png).jpeg({ quality: 80, mozjpeg: true }).toBuffer();
  writeFileSync(join(outDir, `${key}.jpg`), jpg);
  console.log(key, jpg.length);
}
