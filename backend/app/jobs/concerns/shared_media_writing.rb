# frozen_string_literal: true

require "stringio"

# 作った絵を、世界で1枚の置き場（`shared_medias`）へ収めるところ。
#
# カードの絵（`GenerateImageJob`）と、神託で引いた絵（`GenerateOracleImageJob`）は
# **同じ鍵・同じ収め方**でなければならない。引いた絵をあとで迎えたときに、
# 鍵が食い違うと作り直しになり、**代金をもう一度払わせる**ことになる。
#
# 切り出し・サムネ・LQIP の作り方も、写し取ると片方だけ古くなるのでここに置く。
module SharedMediaWriting
  extend ActiveSupport::Concern

  private

  def cached_shared_media(normalized)
    SharedMedia.for_prompt(normalized).detect { |shared| blob_available?(shared.file.blob) }
  end

  def create_shared_media!(normalized, user_id:, metadata:)
    SharedMedia.create!(normalized_prompt: normalized, user_id: user_id, metadata: metadata)
  rescue ActiveRecord::RecordNotUnique
    shared_media = cached_shared_media(normalized)
    return shared_media if shared_media

    raise
  end

  # 作った絵をどの鍵で置くか。
  #
  # 既定は指示そのもの（＝同じ指示の人が使い回せる）。
  # 「ほかの人に使わせない」と決めている人のぶんは、その人だけの鍵で置く。
  # **取る側は変えない。** ほかの人が作った絵は今までどおり使う
  # （切ると待ち時間も原価も跳ね上がるうえ、同じ絵がもう1枚できるだけ）。
  def shared_media_key(normalized, force_generate: false, user: nil)
    return "#{normalized}\nforce:#{SecureRandom.uuid}" if force_generate
    return normalized if share_generated_images?(user)

    "#{normalized}\nprivate:#{user.id}"
  end

  def share_generated_images?(user)
    user.nil? || user.setting.nil? || user.setting.share_generated_images
  end

  def lock_shared_media_cache!(normalized)
    key = Digest::SHA256.hexdigest(normalized)[0, 15].to_i(16)
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{key})")
  end

  # crop_ratio: 生成 API が直接出せない比（黄金比など）へ切り出すときに渡す
  def attach_image_data(shared_media, image_data, content_type, crop_ratio: nil, max_dimension: nil)
    # 保存前にリサイズ + WebP 変換でストレージ・配信コストを抑える。
    # あわせて一覧用サムネ(480px)と LQIP プレースホルダも生成する。
    optimized = OptimizeImageService.call(
      image_data: image_data,
      content_type: content_type,
      crop_ratio: crop_ratio,
      max_dimension: max_dimension
    )

    shared_media.file.attach(
      io: StringIO.new(optimized.data),
      filename: "#{SecureRandom.uuid}.#{optimized.extension}",
      content_type: optimized.content_type
    )

    if optimized.thumb_data
      shared_media.thumb.attach(
        io: StringIO.new(optimized.thumb_data),
        filename: "#{SecureRandom.uuid}.webp",
        content_type: "image/webp"
      )
    end

    # LQIP（data URL）はメタデータに保存し、serializer 経由でフロントのプレースホルダに使う。
    shared_media.update!(metadata: shared_media.metadata.merge("lqip" => optimized.lqip)) if optimized.lqip
  end

  # 実体が本当に置いてあるか。**判定そのものは Storage::BlobAvailability が持つ**
  # （一覧の組み立てと絵を作るジョブで、同じ判定を写し取っていた）
  def blob_available?(blob)
    ::Storage::BlobAvailability.available?(blob)
  end
end
