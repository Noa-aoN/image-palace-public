import type { AuthTokens } from '@/types/auth'

/**
 * 鍵の取り違えを防ぐための道具。
 *
 * ## なぜ要るのか
 *
 * サーバーは**リクエストのたびに鍵を差し替える**
 * （`devise_token_auth` の `change_headers_on_each_request`）。
 * 差し替わったことに気づけるのは、そのリクエストを出したタブだけ。
 * タブを2つ開いていると、片方が動くたびにもう片方の手元の鍵が古くなる。
 *
 * 実際に起きていたこと——タブAで何か開く → タブBに戻る →
 * 未読の取得が走る → 401 →「しばらく経ったので、もう一度ログインしてください」。
 * **期限には遠く届いていない**（鍵7日・セッション上限30日）のに追い出される。
 *
 * ## 直し方は2段
 *
 *   1. 送る前に、**記憶の写しではなく保存されているほうを読む**（`readStoredTokens`）
 *   2. それでもすれ違ったら、**新しい鍵で1回だけやり直す**（`shouldRetryWithFreshToken`）
 *
 * 1 でほとんど起きなくなり、2 は本当に同時だったときの受け皿。
 * どちらも「古い鍵を長く抱えない」ことが目的で、順番待ちや錠は持ち込まない。
 */

/** zustand persist の保存先。`stores/auth.ts` の `name` と同じ */
export const AUTH_STORAGE_KEY = 'auth-storage'

type PersistedAuth = { state?: { tokens?: Partial<AuthTokens> | null } }

/**
 * 保存されている鍵。読めなければ `null`。
 *
 * **ここで投げない。** 鍵が読めないことと、画面が壊れることは別。
 * 読めなければ記憶の写しへ落ちればよい。
 */
export function readStoredTokens(storage?: Storage | null): AuthTokens | null {
  const store = storage ?? (typeof window === 'undefined' ? null : window.localStorage)
  if (!store) return null

  try {
    const raw = store.getItem(AUTH_STORAGE_KEY)
    if (!raw) return null

    const tokens = (JSON.parse(raw) as PersistedAuth).state?.tokens
    if (!tokens?.accessToken || !tokens.uid || !tokens.client) return null

    return {
      accessToken: tokens.accessToken,
      uid: tokens.uid,
      client: tokens.client,
      tokenType: tokens.tokenType ?? 'Bearer',
      expiry: tokens.expiry ?? '',
    }
  } catch {
    return null
  }
}

/**
 * 401 を、**新しい鍵でやり直すか**。
 *
 * やり直すのは「送った鍵と、いま保存されている鍵が違う」ときだけ。
 * これは別のタブが先に差し替えたという意味なので、新しいほうならまだ通る。
 *
 * 同じ鍵で断られたのなら、それは**本当に無効**——期限切れ・ログアウト済み・
 * セッション上限。やり直しても同じ答えしか返らないので、ログイン画面へ送る。
 *
 * 1回で打ち止めにする（`alreadyRetried`）。やり直した結果の 401 まで
 * 拾い直すと、鍵が壊れているときに永久に回り続ける。
 */
export function shouldRetryWithFreshToken({
  sent,
  stored,
  alreadyRetried,
}: {
  /** そのリクエストで実際に送った鍵 */
  sent: string | null | undefined
  /** いま保存されている鍵 */
  stored: string | null | undefined
  alreadyRetried: boolean
}): boolean {
  if (alreadyRetried) return false
  // 送っていない（ログイン前）／保存が無い（ログアウト済み）なら、やり直す先が無い
  if (!sent || !stored) return false

  return sent !== stored
}
