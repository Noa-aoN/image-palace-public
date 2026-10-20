# frozen_string_literal: true

module ImageRouting
  # 生成1回ぶんの決定。**ここから先、誰も「どのモデルで、どの寸法か」を考え直さない。**
  Resolution = Struct.new(
    :use_case, :preset, :mode, :model_key, :provider, :model_id,
    :quality, :save_max_px, :credit_points,
    :width, :height, :crop_ratio, :native, :transparent,
    keyword_init: true
  ) do
    def size
      "#{width}x#{height}"
    end

    def native?
      native
    end

    # 記録（image_usages）へそのまま渡せる形
    def to_usage
      { use_case: use_case, preset: preset, provider: provider, model: model_id,
        quality: quality, size: size, native: native, crop_ratio: crop_ratio,
        transparent: transparent }
    end

    # 保存する長辺。段が決めていなければ、いつもの大きさ
    def save_dimension
      save_max_px.presence || OptimizeImageService::MAX_DIMENSION
    end
  end
end
