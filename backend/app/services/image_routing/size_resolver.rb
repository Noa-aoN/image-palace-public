# frozen_string_literal: true

module ImageRouting
  # 「この形を、このモデルで、どの実寸で作るか」を決める。
  #
  # **切り出しは最後の逃げ道。** 上から順に：
  #   1. 任意サイズを受けるなら、比ぴったりの実寸を計算する
  #   2. 受けないなら、既製サイズに比が一致するものを探す
  #   3. どちらも無いときだけ、いちばん削らずに済む既製サイズから切り出す
  #
  # 1 を 2 より先に見るのは、既製サイズが必要より大きいことがあるため。
  # たとえば 2:3 の既製は 1024x1536 だが、保存は長辺 800px なので
  # 704x1056 で足り、そのぶん安い（実測で3割）。
  module SizeResolver
    # 保存に対して、生成をどれだけ大きく作るか。
    #
    # 下限ぎりぎり（800px 保存に対して 816x816）まで小さくすると縮小が 1.02 倍しかなく、
    # 生成時の粗さがそのまま焼き付く。1.28 倍あれば出力1画素あたり元の1.6画素が平均される。
    # 比によって余裕がばらつかないよう、長辺で揃える。
    DOWNSCALE_MARGIN = 1.28

    # **生成をどれだけ大きく作るかの基準。** 保存の長辺（Resolution::STORE_MAX_PX）
    # とは別の数字で、こちらを上げると実際に作る画素が増える＝原価が上がる。
    # 保存だけを 1088px に上げたときも、ここは動かしていない
    DEFAULT_SAVE_MAX_PX = 800

    # 既定の保存に対する生成の長辺の下限
    MIN_LONG_EDGE = (DEFAULT_SAVE_MAX_PX * DOWNSCALE_MARGIN).ceil

    # 比のずれの許容。0.2% は 800px に対して 2px 未満。
    # ここを緩めると、黄金比のつもりで 1.625（0.43% ずれ）が選ばれる
    RATIO_TOLERANCE = 0.002

    # 長辺をどこまで伸ばして探すか。これで見つからない比は既製サイズへ落とす
    SEARCH_HEADROOM = 1.6

    Size = Struct.new(:width, :height, :crop_ratio, :native, keyword_init: true) do
      def to_s
        "#{width}x#{height}"
      end

      def native?
        native
      end
    end

    module_function

    # preset は AspectRatios のキー。model_id は provider へ渡す実際のモデル名。
    # save_max_px を渡すと、その保存に見合う大きさで作る（大きく保存するなら大きく作る）
    def call(preset:, model_id:, save_max_px: nil)
      ratio = AspectRatios.fetch(preset)[:ratio].to_f
      capability = ImageCapabilities.for(model_id)
      floor = min_long_edge_for(save_max_px)

      custom_size(ratio, capability[:custom], floor) ||
        exact_size(ratio, capability[:sizes], floor) ||
        cropped_size(ratio, capability[:sizes])
    end

    def min_long_edge_for(save_max_px)
      (save_max_px.presence || DEFAULT_SAVE_MAX_PX).to_i.then { |px| (px * DOWNSCALE_MARGIN).ceil }
    end

    # 1. 任意サイズ：制約を満たすいちばん小さい実寸
    def custom_size(ratio, custom, floor = MIN_LONG_EDGE)
      return nil if custom.blank?

      step = custom[:multiple_of]
      best = nil
      long = round_to(floor, step, :up)
      limit = floor * SEARCH_HEADROOM

      while long <= limit
        short = round_to(ratio >= 1 ? long / ratio : long * ratio, step, :nearest)
        width, height = ratio >= 1 ? [ long, short ] : [ short, long ]
        error = ((width.to_f / height) - ratio).abs / ratio

        if error <= RATIO_TOLERANCE && within?(width, height, custom)
          candidate = [ width * height, error, width, height ]
          best = candidate if best.nil? || (candidate <=> best) == -1
        end
        long += step
      end
      return nil if best.nil?

      Size.new(width: best[2], height: best[3], crop_ratio: nil, native: true)
    end

    # 2. 既製サイズに比が一致するもの。**小さすぎるものは使わない**
    # （大きく保存すると言われているのに、既製の小さいほうを選ぶと引き伸ばしになる）
    def exact_size(ratio, sizes, floor = MIN_LONG_EDGE)
      hit = Array(sizes).select { |s| parse(s).max >= floor }
                        .find { |s| ratio_error(s, ratio) <= RATIO_TOLERANCE }
      return nil if hit.nil?

      w, h = parse(hit)
      Size.new(width: w, height: h, crop_ratio: nil, native: true)
    end

    # 3. 逃げ道：いちばん削らずに済む既製サイズから切り出す
    def cropped_size(ratio, sizes)
      list = Array(sizes).presence || ImageCapabilities::UNKNOWN[:sizes]
      pick = list.min_by { |s| crop_loss(s, ratio) }
      w, h = parse(pick)
      Size.new(width: w, height: h, crop_ratio: ratio, native: false)
    end

    # 切り出しで捨てる面積の割合（0.0〜1.0）
    def crop_loss(size, ratio)
      w, h = parse(size)
      source = w.to_f / h
      1 - ([ source, ratio ].min / [ source, ratio ].max)
    end

    def ratio_error(size, ratio)
      w, h = parse(size)
      ((w.to_f / h) - ratio).abs / ratio
    end

    def parse(size)
      size.to_s.split("x").map(&:to_i)
    end

    def within?(width, height, custom)
      px = width * height
      r = width.to_f / height
      px >= custom[:min_px] && px <= custom[:max_px] &&
        r >= custom[:min_ratio] && r <= custom[:max_ratio]
    end

    def round_to(value, step, mode)
      n = value.to_f / step
      rounded = mode == :up ? n.ceil : n.round
      [ rounded, 1 ].max * step
    end
  end
end
