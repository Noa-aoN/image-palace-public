// @vitest-environment jsdom
import { describe, expect, it } from 'vitest'

/*
  画像が本当に届くか。

  **一度丸ごと落ちていた。** `apiClient` は既定で `Content-Type: application/json`
  を付けるが、axios はその型のまま FormData を渡されると **JSON へ畳む**。
  File は JSON にできないので `{}` になり、サーバーには「ファイルが無い」と届く
  （実測: `Parameters: {"key"=>"zu-1", "file"=>{}}`）。

  上げる口は5つ（ボックス・ビューの表紙・盤の背景・空間・読みもの）あり、
  呼ぶ側はどれも FormData を渡すだけ。**押しても何も起きない**種類の壊れ方なので、
  網の外で起きると気づけない。ここは通信せず、最後に何が送られるかだけを見る。
*/

async function sent(body: unknown) {
  const { apiClient } = await import('@/lib/api/client')
  apiClient.defaults.adapter = async (config) => ({
    data: { body: config.data, type: config.headers['Content-Type'] },
    status: 200,
    statusText: 'OK',
    headers: {},
    config,
  })

  const res = await apiClient.post('/api/v1/test', body)
  return res.data as { body: unknown; type: unknown }
}

describe('画像を上げるとき', () => {
  it('FormData は畳まれず、そのまま送られる', async () => {
    const form = new FormData()
    form.append('key', 'zu-1')
    form.append('file', new Blob(['png のつもり'], { type: 'image/png' }), 'a.png')

    const out = await sent(form)

    expect(out.body).toBeInstanceOf(FormData)
    // **肝は application/json を残さないこと。** 型そのものは axios が
    // 送り口で付け直す（FormData なら境界付きの multipart をブラウザに任せる）
    expect(out.type).not.toBe('application/json')
  })

  it('ふつうの値は、これまでどおり JSON で送られる', async () => {
    const out = await sent({ post: { title: 'こんにちは' } })

    expect(out.body).toBe('{"post":{"title":"こんにちは"}}')
    expect(out.type).toBe('application/json')
  })
})
