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

    # 段が何も言わないときに保存する長辺。
    #
    # **作るのに払った画素を、保存で捨てない。**
    # 生成は保存の 1.28 倍（`SizeResolver::DOWNSCALE_MARGIN`）を下限に作るので、
    # 既定では 1024〜1088px で返ってくる。それを 800px へ削っていたせいで、
    # 紙面に幅いっぱい（最大 1088 CSS px）で敷く絵だけが引き伸ばしになっていた
    # （Retina では device px で 2.7 倍）。
    #
    # 1088 は、紙面の幅（72rem − 余白 2rem）と、既定モデルが黄金比（横）で返す
    # 実寸（1088x672）が同じ数字だから。**生成の実寸は変えないので原価は動かない**
    # （`SizeResolver::DEFAULT_SAVE_MAX_PX` は 800 のまま）。
    # 増えるのはバイトだけ——実測で 1.66 倍（58KB → 97KB。12枚で bytes ∝ 画素^0.82）。
    #
    # 外から取り込む絵（アップロード・取り込み）の既定は
    # `OptimizeImageService::MAX_DIMENSION` のまま。**こちらは自分で作った絵の話**
    STORE_MAX_PX = 1088

    # 保存する長辺。段が決めていれば、そちらに従う（高品質の段など）
    def save_dimension
      save_max_px.presence || STORE_MAX_PX
    end
  end
end
