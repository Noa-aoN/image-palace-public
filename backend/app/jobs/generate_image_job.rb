class GenerateImageJob < ApplicationJob
  include ImageGenerationErrorHandling
  # 共有の置き場へ収めるところは、神託の絵と同じものを使う（鍵がずれると作り直しになる）
  include SharedMediaWriting

  queue_as :default

  # OpenAI レート制限・ネットワーク障害に対して指数バックオフでリトライ
  # 15s → 60s → 240s の間隔で最大3回リトライ（計4回実行）
  # 全リトライ消費後に failed にする
  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    item_id = job.arguments[0]
    job.send(:mark_failed!, item_id, error)
    Rails.logger.error "[GenerateImageJob] ALL RETRIES EXHAUSTED item_id=#{item_id} error=#{error.message}"
  end

  def perform(item_id, force_generate: false, use_meaning: false)
    item = Item.find_by(id: item_id)
    return unless item

    item.with_lock do
      item.reload
      current_media = item.primary_media
      if item.generation_status == "completed" &&
         current_media&.file&.attached? &&
         blob_available?(current_media.file.blob) &&
         !force_generate
        Rails.logger.info "[GenerateImageJob] SKIP item_id=#{item.id} status=completed"
        return
      end

      item.update_generation_status!("processing")
      # スタイル・カスタム指示を反映した有効プロンプトと、そのキャッシュキー。
      # use_meaning が true なら意味・説明文も補足として加える（再生成オプション）。
      # provider/model が変わればキャッシュも分ける（既定 openai/gpt-image-1 は後方互換で素のキー）。
      fingerprint = Images::PromptFingerprint.call(item, include_meaning: use_meaning)
      effective_prompt = fingerprint.prompt
      model_key = fingerprint.model_key
      cache_key = fingerprint.cache_key
      # 何を注文したかを残す。失敗したあと「入力を変えたか」を突き合わせるのに使う
      item.update!(metadata: item.metadata.merge("prompt_fingerprint" => fingerprint.digest))
      # プロンプト全文はユーザー入力（個人情報・機密語句を含み得る）なのでログに残さない。
      # 相関用にハッシュの先頭と長さだけ記録する。
      prompt_key = fingerprint.digest[0, 8]
      Rails.logger.info "[GenerateImageJob] START item_id=#{item.id} prompt_key=#{prompt_key} prompt_len=#{effective_prompt.length}"

      lock_shared_media_cache!(cache_key) unless force_generate
      cached = force_generate ? nil : cached_shared_media(cache_key)

      if cached
        Rails.logger.info "[GenerateImageJob] CACHE HIT prompt_key=#{prompt_key} shared_media_id=#{cached.id}"
        attach_from_shared_media(item, cached)
        record_cached_usage!(item, cached)
      else
        if !force_generate && SharedMedia.for_prompt(cache_key).exists?
          Rails.logger.warn "[GenerateImageJob] CACHE STALE prompt_key=#{prompt_key}"
        end
        Rails.logger.info "[GenerateImageJob] CACHE MISS prompt_key=#{prompt_key}"
        result = GenerateImageService.call(
          prompt: effective_prompt, aspect_ratio: item.aspect_ratio,
          kind: "item", user_id: item.user_id, model_key: model_key, mode: item.image_mode
        )
        shared_media = create_shared_media!(
          shared_media_key(cache_key, force_generate:, user: item.user),
          user_id: item.user_id, metadata: result.metadata
        )
        # 切り出す比は、実際に頼んだ実寸から決まる。
        # 任意サイズを受けるモデルなら比ぴったりで返るので、ここは nil になる。
        #
        # 保存の長辺は `save_dimension`（段が言わなければ作った実寸のまま）。
        # `save_max_px` を素で渡していたころは、段が何も言っていないと 800px へ縮み、
        # **作るのに払った画素を捨てていた**
        attach_image_data(
          shared_media, result.image_data, result.content_type,
          crop_ratio: result.resolution&.crop_ratio,
          max_dimension: result.resolution&.save_dimension
        )
        attach_from_shared_media(item, shared_media)
      end

      item.update_generation_status!("completed")
      notify_completed!(item)
      Rails.logger.info "[GenerateImageJob] COMPLETE item_id=#{item.id}"
    end
  rescue StandardError => e
    # 400（ポリシー違反・曖昧な入力）や請求上限・クォータ枯渇はリトライしても回復しないため、
    # retry_on に渡さず即 failed にする。回復し得るエラー（通信・レート制限等）のみ再送出する。
    raise unless non_retryable?(e)

    Rails.logger.warn "[GenerateImageJob] NON-RETRYABLE item_id=#{item_id} code=#{openai_error_code(e) || e.class} -> failed"
    notify_quota_exhausted(e) if quota_error?(e)
    mark_failed!(item_id, e)
  end

  private

  # キャッシュで済んだぶんも1枚として記録する。
  #
  # 同じ単語の2人目以降は API を呼ばずに済むが、**クレジットは同じだけ消費している**。
  # 記録しないと、利用者から見て「減ったのに作った覚えがない」状態になる。
  # 原価は掛かっていないので cached: true を立て、収支の集計からは外す。
  # モデル名は実際にその絵を作ったときのものを共有画像から引く。
  def record_cached_usage!(item, shared_media)
    metadata = shared_media.metadata || {}
    ImageUsage.record!(
      kind: "item",
      provider: metadata["provider"] || "unknown",
      model: metadata["model"] || "unknown",
      size: metadata["size"],
      quality: metadata["quality"],
      user_id: item.user_id,
      cached: true
    )
  end

  def attach_from_shared_media(item, shared_media)
    media = item.primary_media || item.medias.build
    media.assign_attributes(
      media_type: "image",
      metadata: shared_media.metadata,
      position: 0,
      # **実物の印を外す。** 作り直しでは同じ行を使い回すので、実物（PD / CC0）の
      # あとに AI で描き直すと、`shared_asset_id` が残ったままになっていた。
      # 画面は「出どころ」をこの列から決めているので、AI が描いた絵に
      # 「実物・史料 — メトロポリタン美術館 / …」が付いたままになる
      shared_asset: nil,
      # 作り直しでは同じ行を使い回すので、毎回入れ直す。
      # そうしないと、一度承認した枠に新しい絵が覆い無しで入ってしまう
      needs_approval: safeguard?(item)
    )
    media.save!

    item.medias.where.not(id: media.id).destroy_all
    media.file.attach(shared_media.file.blob)
    # どの絵を使ったかを残す。**絵は増やさない**（行を1つ足すだけ）。
    # ここを残していなかったので、作り直すと前の絵へ戻る道が無かった
    ItemMediaGeneration.record!(
      item: item, shared_media: shared_media,
      prompt: shared_media.normalized_prompt, model: shared_media.metadata["model"]
    )
    # 事前生成済みサムネがあれば参照（CDN 直配信用）。無い古いキャッシュは未添付のままで OK。
    media.thumb.attach(shared_media.thumb.blob) if shared_media.thumb.attached?
  end

  # 絵を直視しないで済むようにするか。利用者ごとの設定（既定は切）
  def safeguard?(item)
    item.user&.setting&.image_safeguard || false
  end

  def mark_failed!(item_id, error)
    item = Item.find_by(id: item_id)
    return unless item

    message = user_facing_error_message(error)
    item.mark_generation_failed!(
      message: message,
      code: error.class.name,
      kind: failure_kind(error)
    )
    # 無料の作り直しを使い切ってもなお絵が出なかったなら、その注文は終わり。
    # 先にもらった 1cr を返す（返す条件は RefundFailedGeneration が持つ）。
    # ここで転んでも、失敗そのものの記録と通知は残す
    begin
      ::Billing::RefundFailedGeneration.call(item)
    rescue StandardError => e
      Rails.logger.warn "[GenerateImageJob] REFUND FAILED item_id=#{item.id} #{e.class}: #{e.message}"
    end
    notify_failed!(item, message)
  end

  # 生成の結果をお知らせに残す。ページを離れていても後から結果に気づけるようにする。
  # 通知の生成で本処理を壊さないよう、失敗してもログに残すだけにする。
  def notify_completed!(item)
    Notifications::CreateService.call(
      user: item.user,
      kind: "item_generation_completed",
      title: "「#{item.title}」の画像生成が完了しました",
      url: "/items/#{item.id}",
      payload: { "item_id" => item.id }
    )
  rescue StandardError => e
    Rails.logger.error "[GenerateImageJob] NOTIFY FAILED item_id=#{item.id} error=#{e.message}"
  end

  def notify_failed!(item, message)
    Notifications::CreateService.call(
      user: item.user,
      kind: "item_generation_failed",
      title: "「#{item.title}」の画像生成に失敗しました",
      body: message,
      url: "/items/#{item.id}",
      payload: { "item_id" => item.id }
    )
  rescue StandardError => e
    Rails.logger.error "[GenerateImageJob] NOTIFY FAILED item_id=#{item.id} error=#{e.message}"
  end
end
