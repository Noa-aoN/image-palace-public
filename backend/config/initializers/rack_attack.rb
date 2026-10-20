# frozen_string_literal: true

# API レート制限（Rack::Attack）
#
# 目的:
#   - 認証エンドポイントへのブルートフォースを抑止する
#   - 画像生成など高コストな操作の乱用を防ぐ
#   - 単一クライアントによる過剰なリクエストからサービスを守る
#
# カウンタは専用の MemoryStore に保持する。MVP は Fly.io 単一インスタンス想定のため
# プロセスローカルで十分。将来スケールアウトする場合は共有ストア（Solid Cache 等）へ差し替える。
class Rack::Attack
  # 数えるときに使う「相手」。
  #
  # **Rack や Rails が出す IP をそのまま使ってはいけない。** どちらも X-Forwarded-For から相手を割り出すが、
  # この値は呼ぶ側が自由に付けられる。信頼するプロキシを設定していないと、
  # ヘッダーを差し替えるだけで、ここの上限を全部すり抜けられる。
  #
  # api.imagepalace.app は Cloudflare を通さず、Fly のプロキシが直接受けている
  # （2026-08 時点。`cf-ray` が付かず、DNS も fly.dev を指す）。
  # Fly は受けた接続元を `Fly-Client-IP` に**上書きして**渡すので、こちらは詐称できない。
  #
  # ヘッダーが無いとき（手元・テスト・Fly を通らない経路）は、**接続元そのもの**を見る。
  # ここで `ip` に落としてはいけない。あれも X-Forwarded-For を見るので、
  # ヘッダーを外して叩くだけで詐称が復活する。REMOTE_ADDR は TCP の相手なので偽れない。
  #
  # 経路が変わったら（Cloudflare を api の前に置く等）、ここを見直すこと。
  # そのときは `CF-Connecting-IP` が正になるが、**fly.dev の直の口を閉じるのが先**。
  # 閉じないまま CF のヘッダーを信じると、直接叩いて詐称できてしまう。
  class Request < ::Rack::Request
    def client_ip
      get_header("HTTP_FLY_CLIENT_IP").presence || get_header("REMOTE_ADDR")
    end

    # 数えるときに使う「その人」。**IP では足りない口のためのもの。**
    #
    # 認証ヘッダーの uid は呼ぶ側が書けるが、書き換えると認証そのものが通らない（401）。
    # だから、生成まで届く呼び出しでは本人の uid と一致している。
    # uid ヘッダーを付けずに Authorization（Bearer）だけで来ても通るので、そちらからも読む
    def account_key
      uid = get_header("HTTP_UID").presence || bearer_uid
      uid && "uid:#{uid}"
    end

    private

    def bearer_uid
      auth = get_header("HTTP_AUTHORIZATION").to_s
      return unless auth.start_with?("Bearer ")

      JSON.parse(Base64.strict_decode64(auth.delete_prefix("Bearer ").strip))["uid"].presence
    rescue ArgumentError, JSON::ParserError, TypeError
      nil
    end
  end

  # 作り直しの上限（1人あたり）。0 以下で外す
  module Abuse
    module_function

    def cap(name, default)
      value = ENV.fetch(name, default.to_s).to_i
      value.positive? ? value : 1_000_000_000
    end
  end
end

class Rack::Attack
  self.cache.store = ActiveSupport::Cache::MemoryStore.new

  ### スロットル設定 ###

  # 全体の安全網: 1 IP あたり 5 分間で 300 リクエストまで。ヘルスチェックは除外する。
  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.client_ip unless req.path.start_with?("/api/v1/health", "/up")
  end

  # ログイン試行: ブルートフォース対策。1 IP あたり 20 秒間で 10 回まで。
  throttle("logins/ip", limit: 10, period: 20.seconds) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/auth/sign_in"
  end

  # 新規登録: 大量アカウント作成の抑制。1 IP あたり 60 秒間で 5 回まで。
  throttle("signups/ip", limit: 5, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/auth"
  end

  # 体験用の宮殿を建てる: 1 IP あたり 10 分間で 40 回まで。
  #
  # **粗くてよい。** 同じ端末からの連打は Cookie が止める（生きている宮殿へ戻す）ので、
  # ここが効くのは「Cookie を毎回捨ててくる」相手だけ。
  # 逆に絞りすぎると、40人の教室で一斉に押したときに巻き込む。
  # 1日と同時の上限は DB で数える（プロセスをまたいで正確に効かせるため）
  throttle("demo_sessions/ip", limit: 40, period: 10.minutes) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/demo"
  end

  # パスワード再設定・メール確認: 1 IP あたり 5 分間で 5 回まで。
  #
  # **ここは「送らせる」側と「当てにいく」側の両方がある。**
  #   POST    … 再送を繰り返させると、相手の受信箱を埋められる（メール爆撃）
  #   PUT/GET … 発行済みトークンの総当たり
  #
  # 二要素・パスキー・引き換えコードは個別に絞ってあるのに、ここだけ全体網
  # （300回/5分）しか無かった。認証の入口なので、同じ強さで扱う。
  throttle("password_resets/ip", limit: 5, period: 5.minutes) do |req|
    req.client_ip if req.path.start_with?("/api/v1/auth/password")
  end

  throttle("confirmations/ip", limit: 5, period: 5.minutes) do |req|
    req.client_ip if req.path.start_with?("/api/v1/auth/confirmation")
  end

  # 場所の引き当て: 1 IP あたり 60 秒間で 20 回まで。
  #
  # **こちらの都合ではなく、相手の決まり。** 引く先（Nominatim / OpenStreetMap）は
  # 毎秒1件までで、超えると使わせてもらえなくなる。引いた結果は言葉ごとに貯めるので
  # 同じ場所は1回しか叩かないが、**違う場所を連打されると貯めが効かない**。
  throttle("place_searches/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/places/search"
  end

  # カード作成（画像生成をトリガーし得る高コスト操作）: 1 IP あたり 60 秒間で 30 回まで。
  throttle("item_creates/ip", limit: 30, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/items"
  end

  # 意味生成（OpenAI Chat 呼び出しの高コスト操作）: 1 IP あたり 60 秒間で 30 回まで。
  # 一覧での一括「説明を付与」（1ページ=24件）を1パスで通せるようにしつつ上限は維持。
  # 超過分はフロントが 429 を待って再試行する。
  throttle("item_meaning/ip", limit: 30, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/meaning\z})
  end

  # タグ生成（OpenAI Chat 呼び出しの高コスト操作）: 1 IP あたり 60 秒間で 30 回まで。
  throttle("item_tags/ip", limit: 30, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/tags\z})
  end

  # ファクトチェック（OpenAI Chat 呼び出しの高コスト操作）: 1 IP あたり 60 秒間で 30 回まで。
  throttle("item_fact_check/ip", limit: 30, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/fact_check\z})
  end

  # 失敗カードの再生成（画像生成ジョブを再投入）: 1 IP あたり 60 秒間で 20 回まで。
  throttle("item_retry/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/retry\z})
  end

  # データエクスポート（全データを返す重い操作）: 1 IP あたり 5 分間で 10 回まで。
  # 単語の生成・点検（AI 呼び出し）。ワードリスト作成・アクロポリスから叩かれる。
  throttle("words_generate/ip", limit: 30, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/words/generate"
  end
  throttle("words_check/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/words/check"
  end
  throttle("account_export/ip", limit: 10, period: 5.minutes) do |req|
    req.client_ip if req.get? && req.path == "/api/v1/account/export"
  end

  # 画像アップロード（1件最大 10MB を libvips でデコードする高コスト操作）:
  # 1 IP あたり 60 秒間で 20 回まで。全体上限（300req/5分）だけだと
  # 10MB × 300 の転送と libvips のデコードを短時間に強いられるため、個別に絞る。
  # 運営の読みものの見出し画像も同じ経路（libvips を通る）なので、同じ枠で絞る
  UPLOAD_PATH = %r{\A/api/v1/(boxes|views|spaces)/[^/]+/(cover_image|background_image)\z|
                   \A/api/v1/admin/posts/[^/]+/(cover|body_images)\z}x
  throttle("image_uploads/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && UPLOAD_PATH.match?(req.path)
  end

  # 運営（管理）エンドポイント。総当たりで権限の有無を探られないよう、個別に絞る。
  # 正規の運営が普通に使う限り当たらない値にする。
  throttle("admin/ip", limit: 60, period: 60.seconds) do |req|
    req.client_ip if req.path.start_with?("/api/v1/admin/")
  end

  # キャンバスの AI 編集（1回の呼び出しが他より大きい）
  AI_EDIT_PATH = %r{\A/api/v1/views/[^/]+/ai_edit\z}
  throttle("canvas_ai_edit/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && AI_EDIT_PATH.match?(req.path)
  end

  # カバー画像の生成（画像生成＝高コスト）
  COVER_GENERATE_PATH = %r{\A/api/v1/(boxes|views|spaces)/[^/]+/cover_image/generate\z}
  throttle("cover_generate/ip", limit: 10, period: 60.seconds) do |req|
    req.client_ip if req.post? && COVER_GENERATE_PATH.match?(req.path)
  end

  # アバターの生成（画像生成＝高コスト）。自分の顔は何度も作り直すものではない。
  throttle("avatar_generate/ip", limit: 10, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/account/avatar"
  end

  # 記憶資産の点（作成・更新とも画像生成をトリガーし得る）。
  # 並べ替え（reorder）は画像を作らないうえドラッグで連続するので、ここには含めない。
  SPACE_POINT_PATH = %r{\A/api/v1/spaces/[^/]+/points(/(?!reorder\z)[^/]+)?\z}
  throttle("space_points/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if (req.post? || req.patch? || req.put?) && SPACE_POINT_PATH.match?(req.path)
  end

  # ノートの絵（1枚1クレジット）と、カードの項目の自由イメージ。
  #
  # **まとめて描ける道がある**（本文の語を選んで溜め、一度に投げる）ので、
  # ひと息に何本も飛ぶ。溜めの上限（12語）が一度に通る幅は残しつつ、
  # 押しっぱなしで走り続けないところで止める。
  #
  # **作り直し（`regenerate`）も同じ口として数える。** 1枚ぶんのクレジットを使い、
  # 同じ外部呼び出しをするのに、道が節を通らない（`/views/:id/blocks/:id/regenerate`）
  # ので、節を前提にした形では当たっていなかった
  NOTE_IMAGE_PATH = %r{
    \A/api/v1/views/[^/]+/
    (sections/[^/]+/blocks/generate_image|blocks/[^/]+/regenerate)\z
  }x
  FREE_IMAGE_PATH = %r{\A/api/v1/items/[^/]+/properties/[^/]+/free_image\z}
  throttle("free_images/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && (NOTE_IMAGE_PATH.match?(req.path) || FREE_IMAGE_PATH.match?(req.path))
  end

  # ノートの枡からカードを作る道。絵は作らないので費用は出ないが、
  # **押すだけでカードが増える**ので歯止めは要る（`POST /items` の
  # スロットルは道が違うため当たらない）
  NOTE_TO_CARD_PATH = %r{\A/api/v1/views/[^/]+/blocks/[^/]+/(to_card|promote)\z}
  throttle("note_to_card/ip", limit: 30, period: 60.seconds) do |req|
    req.client_ip if req.post? && NOTE_TO_CARD_PATH.match?(req.path)
  end

  # ノートの文章生成（要約・深掘り・問い・下書き）。OpenAI Chat 呼び出し
  NOTE_TEXT_PATH = %r{\A/api/v1/views/[^/]+/sections/[^/]+/(blocks/insight|compose)\z}
  throttle("note_ai/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && NOTE_TEXT_PATH.match?(req.path)
  end

  # 説明文・情景の作り直し（OpenAI Chat 呼び出し）
  throttle("item_brief/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/brief\z})
  end

  # カードの項目まわり（値・定義）。AI は通らないが、書き込みなので歯止めは要る
  PROPERTY_PATH = %r{\A/api/v1/(items/[^/]+/properties/[^/]+|property_definitions(/.*)?)\z}
  throttle("item_properties/ip", limit: 120, period: 60.seconds) do |req|
    req.client_ip if !req.get? && PROPERTY_PATH.match?(req.path)
  end

  # 意味・説明の追加・書き換え（AI は通らないが、書き込みなので歯止めは要る）
  MEANING_PATH = %r{\A/api/v1/items/[^/]+/meanings(/.*)?\z}
  throttle("item_meanings/ip", limit: 60, period: 60.seconds) do |req|
    req.client_ip if (req.post? || req.patch? || req.put? || req.delete?) && MEANING_PATH.match?(req.path)
  end

  # 項目のAI一括入力（OpenAI Chat 呼び出し）
  throttle("item_fill_properties/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/fill_properties\z})
  end

  # 項目の選定（OpenAI Chat 呼び出し）
  throttle("item_suggest_properties/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/suggest_properties\z})
  end

  # 意味・説明からの情景の書き直し（OpenAI Chat 呼び出し）
  throttle("item_scene_rewrite/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/scene_rewrite\z})
  end

  # 方針に触れた指示の書き直し（OpenAI Chat 呼び出し）
  throttle("item_policy_rewrite/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/policy_rewrite\z})
  end

  # Wikipedia の引き当て。
  #
  # こちらの負担は軽いが、外（Wikimedia）へ投げる口なので、
  # 相手の迷惑になる叩き方をこちらで止める。キャッシュが効くぶんは通る
  # Passkey の登録も、繰り返し叩かれる理由がない。網の側で止める
  throttle("passkeys/ip", limit: 20, period: 5.minutes) do |req|
    req.client_ip if (req.post? || req.patch? || req.delete?) && req.path.start_with?("/api/v1/passkeys")
  end

  # 二要素のコードは6桁しかない。総当たりを網の側でも止める
  throttle("totp/ip", limit: 20, period: 5.minutes) do |req|
    req.client_ip if req.post? && req.path.start_with?("/api/v1/totp")
  end

  throttle("wikipedia/ip", limit: 30, period: 60.seconds) do |req|
    req.client_ip if req.get? && req.path.in?([ "/api/v1/wikipedia/summary", "/api/v1/wikipedia/search" ])
  end

  # 問いを作る。調査より軽いが、押すほど積み上がるので枠を置く
  throttle("quiz/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/paper_chapters/[^/]+/generate\z})
  end

  # カードの調査。**1回が重い**（長い文章を書かせる）ので、少なめに。
  # 押したときだけ走るので、ふだんの使い方でここに当たることは無い
  throttle("research/ip", limit: 10, period: 60.seconds) do |req|
    req.client_ip if req.post? && req.path.match?(%r{\A/api/v1/items/[^/]+/research\z})
  end

  # 引き換えコードの入力。
  #
  # コードは 4〜32 文字の英数字で、短いものは総当たりで当てられる。
  # 当てられるとクレジットがそのまま出ていくので、試せる回数を絞る。
  # 手で打つぶんには足りる回数にしてある（打ち間違いの数回は通る）。
  throttle("code_redeem/ip", limit: 10, period: 10.minutes) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/campaign_codes/redeem"
  end

  # 供給側の疎通確認（OpenAI へ実際に1回投げる）。運営しか叩けないが、連打で外へ投げ続けないよう抑える
  throttle("admin_provider_check/ip", limit: 10, period: 5.minutes) do |req|
    req.client_ip if req.post? && req.path == "/api/v1/admin/provider_check"
  end

  # 絵を作り直す口（1人あたり）。
  #
  # 上の口ごとの上限は **IP あたり・1分あたり** なので、1分に20回を守って押し続けると
  # 1日に何万回も通る。1回ごとに供給側へ問い合わせが飛び、原価が出る。
  # 人の手で押す速さでは当たらない量にし、機械的に回し続けるものだけを止める。
  #
  # 数える口: カードの作り直し・ノートの絵・項目の自由イメージ・表紙・アバター。
  # どれも1回で絵を1枚作る。値は ENV で変えられる（IMAGE_REGEN_HOURLY_CAP / IMAGE_REGEN_DAILY_CAP）
  ITEM_RETRY_PATH = %r{\A/api/v1/items/[^/]+/retry\z}
  IMAGE_REGEN_PATHS = [ ITEM_RETRY_PATH, NOTE_IMAGE_PATH, FREE_IMAGE_PATH, COVER_GENERATE_PATH,
                        %r{\A/api/v1/account/avatar\z} ].freeze
  image_regen = ->(req) { req.account_key if req.post? && IMAGE_REGEN_PATHS.any? { |path| path.match?(req.path) } }
  throttle("image_regen/hour/user", limit: ->(_req) { Abuse.cap("IMAGE_REGEN_HOURLY_CAP", 60) },
                                    period: 1.hour, &image_regen)
  throttle("image_regen/day/user", limit: ->(_req) { Abuse.cap("IMAGE_REGEN_DAILY_CAP", 300) },
                                   period: 1.day, &image_regen)

  # パブリックドメインの実物を探す。AI は呼ばないが、押すたびに Wikipedia / Wikidata /
  # Commons / Met へ問い合わせる。向こうの利用規約上、こちらの口ごと止められるのがいちばん困る
  DISCOVER_PATH = %r{\A/api/v1/items/[^/]+/media_generations/discover\z}
  throttle("media_discover/ip", limit: 20, period: 60.seconds) do |req|
    req.client_ip if req.post? && DISCOVER_PATH.match?(req.path)
  end
  throttle("media_discover/hour/user", limit: ->(_req) { Abuse.cap("MEDIA_DISCOVER_HOURLY_CAP", 60) },
                                       period: 1.hour) do |req|
    req.account_key if req.post? && DISCOVER_PATH.match?(req.path)
  end

  ### スロットル時のレスポンス ###

  # 429 を JSON で返す。フロントエンドが一貫してエラー表示できるようにする。
  self.throttled_responder = lambda do |req|
    match_data = req.env["rack.attack.match_data"] || {}
    retry_after = match_data[:period].to_i

    headers = {
      "Content-Type" => "application/json",
      "Retry-After" => retry_after.to_s
    }
    body = { error: throttled_message(match_data[:name] || req.env["rack.attack.matched"]) }.to_json

    [ 429, headers, [ body ] ]
  end

  # 何で止めたかを言う。作り直しは「いつまで待てばよいか」が読めないと、押し直して数を増やす
  def self.throttled_message(name)
    case name.to_s
    when %r{\Aimage_regen/hour/}
      "短い時間に作り直しが続いたため、いったん止めています。1時間ほど置いてからお試しください。"
    when %r{\Aimage_regen/day/}
      "今日の作り直しの上限に達しました。明日またお試しください。"
    when %r{\Amedia_discover/}
      "実物を探す回数が続いたため、いったん止めています。しばらく置いてからお試しください。"
    else
      "リクエストが多すぎます。しばらく時間を置いてから再試行してください。"
    end
  end
end

# 1人あたりの上限で止めたことを、運営が後から見られるように残す。
#
# 監査ログ（/admin）に載せる。止めるたびに書くと、押し続けるほど行が増えるので、
# **同じ人・同じ上限は、その区切り（1時間・1日）に1行だけ**にする
ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  rule = req.env["rack.attack.matched"].to_s
  next unless rule.end_with?("/user")

  data = req.env["rack.attack.match_data"] || {}
  key = "abuse-logged:#{rule}:#{req.env['rack.attack.match_discriminator']}"
  next unless Rack::Attack.cache.store.write(key, 1, unless_exist: true, expires_in: data[:period].to_i.seconds)

  uid = req.env["rack.attack.match_discriminator"].to_s.delete_prefix("uid:")
  user = User.find_by(uid: uid)
  Rails.logger.warn "[abuse] THROTTLED rule=#{rule} user_id=#{user&.id} count=#{data[:count]} limit=#{data[:limit]}"
  AdminAuditLog.record!(
    actor: user, action: "abuse.throttled", target: user,
    details: { "rule" => rule, "path" => req.path, "count" => data[:count], "limit" => data[:limit] }
  )
rescue StandardError => e
  Rails.logger.error "[abuse] RECORD FAILED #{e.class}: #{e.message}"
end
