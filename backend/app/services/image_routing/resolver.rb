# frozen_string_literal: true

module ImageRouting
  # 「この用途の、この形を、何で作るか」を1か所で決める。
  #
  # 利用者から来た model 名や幅・高さを provider へ素通しさせないための関門でもある。
  # 入口で受け取るのは**登録簿の key** と **preset の名前**だけで、
  # 実際に provider へ送る model_id・実寸は、ここで許可済みの値へ解決してから渡す。
  class Resolver
    # 用途の要件を満たせるモデルが1つも無い
    class Unsatisfiable < StandardError; end

    # 品質の既定。**用途ごとの上書きは image_routes.quality が持つ。**
    #
    # low にしているのは実測の結果。代表10題（gpt-image-2.5-flare・4:3）で
    # low / medium / high を並べたが、**保存後（長辺 800px）の見た目が3段とも同じ**だった。
    # 品質の段が効くのは細部で、縮小で消える。速さもほとんど動かない
    # （low 12.4秒 / medium 12.1秒）。原価だけが 2.3 倍違う（$0.0040 / $0.0090）。
    #
    # 保存する寸法（OptimizeImageService::MAX_DIMENSION）を大きくしたら、ここも見直すこと。
    DEFAULT_QUALITY = "low"

    # 障害時に画面を通さず倒すための逃げ道。**登録簿より優先する。**
    # ここを resolver に置いているのは、生成に使う model_id と
    # キャッシュキーに使う model_id を1か所で決めるため（ずれると別物が共有される）。
    MODEL_ENV = { "openai" => "OPENAI_IMAGE_MODEL", "flux" => "FAL_IMAGE_MODEL" }.freeze
    QUALITY_ENV = "OPENAI_IMAGE_QUALITY".freeze

    # 登録簿の1行から、実際に provider へ送るモデル名を決める
    def self.model_id_for(model)
      return nil if model.nil?

      ENV[MODEL_ENV.fetch(model.provider, "")].presence || model.model_id
    end

    def self.call(use_case:, preset: nil, mode: nil, model_key: nil, transparent: nil)
      new(use_case: use_case, preset: preset, mode: mode, model_key: model_key,
          transparent: transparent).call
    end

    def initialize(use_case:, preset: nil, mode: nil, model_key: nil, transparent: nil)
      @use_case = use_case.to_s.presence || "unknown"
      @preset = preset
      @mode = mode
      @model_key = model_key
      @transparent = transparent
    end

    def call
      model = choose_model
      model_id = self.class.model_id_for(model)
      # 形（比）と、品質・解像度は**別の軸**。段を上げても比は変えない
      size = SizeResolver.call(preset: preset, model_id: model_id, save_max_px: policy.save_max_px)

      Resolution.new(
        use_case: @use_case,
        preset: preset,
        mode: @mode.presence,
        model_key: model.key,
        provider: model.provider,
        model_id: model_id,
        quality: ImageCapabilities.quality_for(model_id, wanted_quality),
        save_max_px: policy.save_max_px,
        credit_points: policy.credit_points,
        width: size.width,
        height: size.height,
        crop_ratio: size.crop_ratio,
        native: size.native,
        transparent: transparent?
      )
    end

    private

    # 用途の方針。行が1つも無ければ空のまま（＝登録簿の既定で動く）
    def policy
      @policy ||= PolicyResolver.call(use_case: @use_case, preset: @preset, mode: @mode)
    end

    # 形。決め方は PolicyResolver が持つ（カードを作るところと同じ道を通す）
    def preset
      @preset_resolved ||= PolicyResolver.preset_for(use_case: @use_case, requested: @preset, policy: policy)
    end

    # 品質。環境変数（障害時の逃げ道）→ 方針 → コードの既定
    def wanted_quality
      ENV[QUALITY_ENV].presence || policy.quality.presence || DEFAULT_QUALITY
    end

    # 透過。**用途の要件が最優先。** 呼び出し側の指定で切れないようにする
    def transparent?
      return true if ImageUseCases.transparency_required?(@use_case)

      @transparent == true
    end

    # 使うモデルを、**決まった順で**1つに決める。
    #
    #   1. 利用者の指定  … カードに保存された image_model
    #   2. route のモデル … 用途の方針（継承で解決した1つ）
    #   3. kind の既定    … default_for_kind。**最終フォールバック**
    #   4. 生成不能
    #
    # 各段の通過条件は「有効」「鍵がある」「用途の要件（勲章の透過）を満たす」。
    # 満たさなければ次の段へ落ちる。
    #
    # **「ほかに使えるモデルを総なめ」はしない。** 以前はしていたが、それだと
    # 既定が候補の1つに埋もれて、どのモデルで作られるのかが設定から読めなかった。
    # どの段でも決まらなければ止める——黙って知らないモデルで作るより、
    # 直すべき場所（route か既定）がはっきりする。
    def choose_model
      hit = candidates.find { |model| satisfies?(model) }
      return hit if hit

      raise Unsatisfiable,
            "#{ImageUseCases.label(@use_case)}に使えるモデルがありません" \
            "（route・既定のいずれも、鍵か用途の要件を満たしていません）"
    end

    # TODO(利用者への知らせ): カードに保存された選択が使えなくなったとき
    # （鍵を外した・止めた・1日の上限に当たった）、いまは黙って次の段へ落ちる。
    # 絵は出るが、利用者から見ると「前と違う絵柄になった」だけで理由が分からない。
    #
    # 「以前選んだモデルはいま使えないので、おまかせで作りました」と伝えたい。
    # 伝える場所は作り直しの画面か、カードの ⓘ（生成に使ったモデルは metadata にある）。
    # 今回のリリース対象外。落ちたことは image_usages の model を見れば後から追える。
    def candidates
      return preferred if forced_provider.blank?

      # 環境変数は **provider を倒すだけ**。その中での順序（利用者 → route → 既定）は変えない。
      # 以前は登録簿の並び順で選んでいたので、利用者が名指ししたモデルが
      # 同じ provider にあっても無視されていた
      within = preferred.select { |m| m.provider == forced_provider }
      return within if within.any?

      # 倒した先に、選ばれた／設定された行が1つも無いとき。
      # 「とにかくこちらへ」と言われている以上、鍵の有無も問わずに従う
      AiModel.registry.select { |m| m.kind == "image" && m.provider == forced_provider }
    end

    # 見る順：利用者の指定 → route のモデル → kind の既定
    def preferred
      @preferred ||= [
        model_for(GenerateImageService.usable_key(@model_key)),
        policy.ai_model,
        GenerateImageService.default_model
      ].compact.uniq(&:key)
    end

    def forced_provider
      @forced_provider ||= ENV["IMAGE_GENERATION_PROVIDER"].presence
    end

    def model_for(key)
      return nil if key.blank?

      AiModel.registry.find { |m| m.kind == "image" && m.key == key.to_s }
    end

    # 使える行か。**鍵の無いモデルは、方針で名指しされていても選ばない。**
    # 選ぶと生成の直前で鍵が無くて落ちる——方針の書き間違いを、絵の失敗として
    # 利用者に押し付けることになる。次の候補（登録簿の既定）へ落とす
    def satisfies?(model)
      # 環境変数で倒したときだけ、鍵の有無を問わない。
      # 「とにかくこちらへ」と言われている以上、鍵は付いている前提で従う
      return false unless forced_provider.present? || model.available?

      ImageUseCases.unmet_requirement(@use_case, self.class.model_id_for(model)).nil?
    end
  end
end
