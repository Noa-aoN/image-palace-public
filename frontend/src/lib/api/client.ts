import axios, { type InternalAxiosRequestConfig } from 'axios'
import { useAuthStore } from '@/stores/auth'
import { useItemsStore } from '@/stores/items'
import { isPublicPath } from '@/lib/auth/public-paths'
import {
  buildSessionEndRecord,
  loginPathWithNotice,
  markSessionEnded,
  reportSessionEnd,
} from '@/lib/auth/session-end'
import { readStoredTokens, shouldRetryWithFreshToken } from '@/lib/auth/token-sync'

/**
 * 送った鍵と、やり直したかどうかを、そのリクエストに付けて持ち回る。
 * 401 を受けた側は `error.config` しか見られないので、ここに残しておく。
 */
type TrackedRequest = InternalAxiosRequestConfig & {
  sentAccessToken?: string
  authRetried?: boolean
}

const AUTH_ERROR_EXCLUDED_PATHS = new Set([
  '/api/v1/auth',
  '/api/v1/auth/sign_in',
])

function resolveApiBaseUrl(): string | undefined {
  if (typeof window === 'undefined') {
    return process.env.INTERNAL_API_BASE_URL ?? process.env.NEXT_PUBLIC_API_BASE_URL
  }

  return process.env.NEXT_PUBLIC_API_BASE_URL
}

export function getBrowserApiBaseUrl(): string {
  return process.env.NEXT_PUBLIC_API_BASE_URL ?? ''
}

export const apiClient = axios.create({
  baseURL: resolveApiBaseUrl(),
  headers: { 'Content-Type': 'application/json' },
})

apiClient.interceptors.request.use((config: TrackedRequest) => {
  /* **画像を送るときは、既定の JSON を外す。**
     axios は Content-Type が application/json のままだと FormData を JSON へ
     畳んでしまい、File は `{}` になる（= サーバーには「ファイルが無い」と届く）。
     外しておけば、境界付きの multipart をブラウザが組む。
     ここを1か所で直す——上げる口は5つあり、呼ぶ側で付け忘れると静かに落ちる */
  if (typeof FormData !== 'undefined' && config.data instanceof FormData) {
    config.headers.delete('Content-Type')
  }

  /* **保存されているほうを先に読む。** サーバーは毎リクエストで鍵を差し替えるので、
     タブを2つ開いていると、片方が動くたびにもう片方の記憶が古くなる。
     保存先（localStorage）は全タブで1つなので、そこを正とすれば取り違えない。
     読めないとき（localStorage が無い・壊れている）だけ記憶の写しへ落ちる */
  const tokens = readStoredTokens() ?? useAuthStore.getState().tokens
  if (tokens?.accessToken && tokens.uid && tokens.client) {
    config.headers['access-token'] = tokens.accessToken
    config.headers['uid'] = tokens.uid
    config.headers['client'] = tokens.client
    config.headers['token-type'] = tokens.tokenType
    config.sentAccessToken = tokens.accessToken
  }
  return config
})

apiClient.interceptors.response.use(
  (response) => {
    const accessToken = response.headers['access-token']
    if (accessToken) {
      useAuthStore.getState().updateTokens({
        accessToken,
        uid: response.headers['uid'] ?? '',
        client: response.headers['client'] ?? '',
        tokenType: response.headers['token-type'] ?? 'Bearer',
        expiry: response.headers['expiry'] ?? '',
      })
    }
    return response
  },
  (error) => {
    const config = error.config as TrackedRequest | undefined

    /* **すれ違いなら、新しい鍵で1回だけやり直す。**
       送った鍵といま保存されている鍵が違うのは、待っているあいだに別のタブが
       差し替えたということ。新しいほうならまだ通るので、追い出す前に試す。
       同じ鍵で断られたのなら本当に無効なので、ここは通さず下の始末へ進む */
    if (
      error.response?.status === 401 &&
      config &&
      shouldRetryWithFreshToken({
        sent: config.sentAccessToken,
        stored: readStoredTokens()?.accessToken,
        alreadyRetried: config.authRetried === true,
      })
    ) {
      config.authRetried = true
      return apiClient.request(config)
    }

    const requestUrl = error.config?.url as string | undefined
    const path = requestUrl ? new URL(requestUrl, resolveApiBaseUrl()).pathname : undefined
    const shouldRedirectOnUnauthorized = path ? !AUTH_ERROR_EXCLUDED_PATHS.has(path) : true

    if (error.response?.status === 401 && shouldRedirectOnUnauthorized) {
      // ログイン無しで読めるページからは追い出さない。
      // 印は落とす（ヘッダーは未ログインの姿に変わる）が、いま読んでいるものは残す。
      // 送っていたころは、使い方やコラムを読んでいる最中に期限が切れると、
      // 読みかけの記事からログイン画面へ飛ばされていた
      const pathname = window.location.pathname
      const redirected = !isPublicPath(pathname)

      // **落とす前に期限を控える。** clearAuth のあとでは、
      // そのとき何を持っていたのかが分からなくなる
      const tokenExpiry = useAuthStore.getState().tokens?.expiry ?? null

      useItemsStore.getState().resetItems()
      useAuthStore.getState().clearAuth()
      // 認証が外れたことに気づいた側（AuthGuard）が先に送ることがある。
      // どちらが送っても同じ案内を出せるよう、切れたことを先に印しておく
      if (redirected) markSessionEnded()

      reportSessionEnd(
        buildSessionEndRecord({
          pathname,
          // 期限が切れていなくても終わることがある（使い続けたセッションの打ち切り）。
          // 理由を残さないと、`expired: false` の記録が不具合と見分けられない
          reason: (error.response?.data as { reason?: string } | undefined)?.reason ?? null,
          // **pathname だけを載せる。** requestUrl にはクエリが付く。
          // いまは載る値に秘密は無いが、あとで付いたものが記録へ流れ込む道を作らない
          api: path ?? '(不明)',
          tokenExpiry,
          redirected,
          now: new Date(),
        })
      )

      if (redirected) {
        // なぜログイン画面に居るのかを URL で渡す（読んだ側が印を消す）
        window.location.href = loginPathWithNotice()
      }
    }
    return Promise.reject(error)
  }
)
