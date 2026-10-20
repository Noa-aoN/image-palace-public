# frozen_string_literal: true

module Billing
  # 生成1件あたりの消費コスト（ポイント）を返すポリシー。
  #
  # モデルごとの値は登録簿（AiModel）が持つ。原価の高いモデルを足したときに、
  # 消費クレジットを上げ忘れて粗利だけ減る、ということが起きないようにするため
  # 同じ行に並べてある。
  #
  # 登録簿に値が無ければ既定（1クレジット）。値を消しても止まらないようにする。
  module CreditCost
    module_function

    BASE_GENERATION = POINTS_PER_CREDIT

    # 見る順は **段（image_routes.mode）→ モデル → 既定**。
    #
    # 段のほうが強いのは、利用者が選ぶのが段だから（節約・標準・高品質）。
    # モデルは「おまかせ」が指しているので、値段の話は段でするほうが素直。
    #
    # 作り直しも新しい画像を1枚作るので、消費は初回と同じ。値引きの根拠が無い
    def call(kind: :item_generation, model_key: nil, mode: nil, use_case: "item", **_context)
      points_for_mode(use_case, mode) || points_for(model_key) || BASE_GENERATION
    end

    def points_for_mode(use_case, mode)
      ImageRouting::PolicyResolver.call(use_case: use_case, mode: mode).credit_points
    end

    def points_for(model_key)
      return nil if model_key.blank?

      model = AiModel.registry.find { |m| m.kind == "image" && m.key == model_key.to_s }
      model&.credit_points
    end
  end
end
