# frozen_string_literal: true

module Images
  # 作り直しの受付。**同時に2本来ても、通すのは1本だけ。**
  class AcceptRegeneration
    # 作り直せる状態。出来上がったものと、失敗したものだけ
    ACCEPTABLE = %w[failed completed].freeze

    NOT_ACCEPTABLE = "生成が完了または失敗したカードのみ再生成できます".freeze

    # 行を押さえられなかったときの断り。**状態を言い当てない**——
    # 掴んでいるのは生成ジョブとは限らないので、分かっているのは「重なった」ことだけ
    BUSY = "ほかの処理と重なりました。少し待ってからもう一度お試しください".freeze

    # 行が空くのを待つ上限。**待たないために置いている。**
    #
    # 生成ジョブは供給側への問い合わせのあいだ、ずっとカードの行を握る
    # （`generate_image_job.rb:21`）。素で待つと数十秒ブロックし、本番は
    # `statement_timeout`（30秒）に当たって 500 になる。その間 Puma の枠と
    # DB の接続を1つずつ占める。**押しても通らない要求のために、そこまで待つ意味は無い。**
    #
    # 1秒（PostgreSQL の `deadlock_timeout` の既定）より十分に短くしてある。
    # 語義の確定は users → items の順で行を取るので（`resolve_sense_service.rb:75`）、
    # 向きの逆な掴み合いが起こり得る。そのときは**こちらが先に諦めて相手を通す**
    # ——掴み合いの検出（40P01・500 になる）まで行かせない。
    LOCK_TIMEOUT_MS = 300

    Result = Struct.new(:error, keyword_init: true) do
      def accepted?
        error.nil?
      end
    end

    def self.call(...)
      new(...).call
    end

    # 行を押さえずに見るだけの判定。**外部への問い合わせの前に断るため**に置いている
    # （断る要求のために Moderation API を叩かない）。
    # 本当の判定はロックの中。ここを通ったあとに状態が変わり得る
    def self.acceptable?(item)
      ACCEPTABLE.include?(item.generation_status)
    end

    # instructions は画面から来た指示（custom_prompt / style / 比 / モデル / 段）。
    # **検査（モデレーション）は済んでいる前提**で受け取る
    def initialize(item:, user:, instructions: {}, use_meaning: false)
      @item = item
      @user = user
      @instructions = instructions
      @use_meaning = use_meaning
    end

    # **行を押さえてから状態を読み直す。** ここが隙間だった。
    #
    # 以前は「状態を見る」「クレジットを引く」「pending にする」が別々の
    # トランザクションで、カードの行は誰も押さえていなかった。同じカードへ
    # 作り直しが2本同時に来ると、**どちらも completed と判定して**それぞれ
    # 引き落とし、`force_generate: true` のジョブを2本積んでいた。
    # ジョブ側の重複防止は3段あるが（completed なら飛ばす・同じ注文は
    # キャッシュを使う・`normalized_prompt` の UNIQUE 制約）、**force では
    # 3段とも外れる**ので、プロバイダも2回呼ばれていた。
    # users 行のロックは過剰な引き落としを止めるだけで、二重課金は止めない。
    #
    # 負けた側は、読み直した状態が pending なので下の判定でそのまま断られる。
    # 行が空くのを待たされる側は `BUSY`（理由は LOCK_TIMEOUT_MS に書いた）。
    #
    # ジョブが積まれるのは、このトランザクションが確定したあと
    # （Solid Queue の adapter は `enqueue_after_transaction_commit?` が true）。
    # **巻き戻れば積まれない**ので「引き落としが無いのにジョブだけある」は起きない。
    # 逆向き（1回の引き落としに2本のジョブ）を止めているのは、上の行ロック。
    #
    # 受け付けなかったときは**何も書き換えない**。指示は当てるだけにして、
    # 保存は通すと決めたあとの `update_generation_status!` に任せている
    # （`update!` なので、溜めてある変更も一緒に入る）
    def call
      item.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT_MS}ms'")
        item.lock!

        next Result.new(error: NOT_ACCEPTABLE) unless self.class.acceptable?(item)

        was_completed = item.generation_status == "completed"
        item.assign_attributes(instructions) if instructions.present?

        # 語や指示が変われば、それは別の絵の注文。失敗の種類による縛りも回数の勘定も引き継がない。
        # 判定は「指示が渡されたか」ではなく、**実際に注文する文字列が変わったか**で行う
        # （画面は指示欄が空でも custom_prompt: "" を送り、単語や情景は別の口から変わるため）
        changed_input = RetryPolicy.input_changed?(item, include_meaning: use_meaning)

        # 失敗からの作り直しは、押して直るものか・何度目かを見てから通す。
        # 無料であることと、何度でも押せることは別（理由は RetryPolicy に置いた）
        decision = RetryPolicy.decide(target: item, changed_input: changed_input)
        next Result.new(error: decision.reason) unless was_completed || decision.allowed?

        # 出来上がったものを作り直すときはクレジットを使う。新しい画像を1枚作るので、
        # 原価は初回とまったく同じ。失敗からの作り直しは、無料の回数を使い切るまでは無料
        charge! if was_completed || decision.charge?
        unless was_completed
          RetryPolicy.count_free_retry!(item, reset: changed_input || decision.charge?, free: !decision.charge?)
        end

        # 出来上がったものの作り直しは、同じ絵を返しても意味が無いのでキャッシュを使わない。
        # 失敗からの作り直しは使う（注文が同じなら、既にある絵で足りる）
        item.update_generation_status!("pending")
        enqueue(force_generate: was_completed)
        Result.new(error: nil)
      end
    rescue ActiveRecord::LockWaitTimeout
      Result.new(error: BUSY)
    end

    private

    attr_reader :item, :user, :instructions, :use_meaning

    # 作り直しぶんのクレジットを、生成を積む前に消費する。
    # 積んでから足りないと分かると、画像だけ作られて課金できない状態になる。
    def charge!
      user.ensure_free_credits!
      cost = ::Billing::CreditCost.call(kind: :regeneration, model_key: item.image_model,
                                        mode: item.image_mode)

      user.with_lock do
        raise User::InsufficientCredits unless user.can_afford?(cost)

        user.consume_credits!(cost, item: item)
      end
    end

    # 画像への指示がまだ無いカードは、再生成のついでに下ごしらえから作り直す。
    # 既にある（＝作成時に作られた／手で直した）ものは、そのまま画像生成へ進めて
    # 無駄な問い合わせを増やさない。
    #
    # 「単語をそのまま」で作ったカードは、作り直しでも下ごしらえを挟まない。
    # 挟むと、作り直しただけで別のやり方の絵に化けてしまう。
    def enqueue(force_generate:)
      needs_brief = item.effective_prompt_source != "word" &&
                    item.scene_prompt.blank? && !item.brief_edited?
      if needs_brief
        GenerateBriefJob.perform_later(item.id, force_generate: force_generate, use_meaning: use_meaning)
      else
        GenerateImageJob.perform_later(item.id, force_generate: force_generate, use_meaning: use_meaning)
      end
    end
  end
end
