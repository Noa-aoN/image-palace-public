class Item < ApplicationRecord
  # カードの絵を出すのに要る添付一式。一覧で `includes(Item::MEDIA_INCLUDES)` と書く。
  #
  # thumb を入れ忘れると、1枚ごとに「サムネある？」「その実体は？」と2往復ずつ聞きに行く。
  # DB は隣の部屋には無い（nrt から Neon まで片道70ms）ので、24枚並べるだけで数秒が消える。
  # file だけ読んで安心しないこと
  # 絵をまとめて読む。**実物の元の行も一緒に引く**——出典を出すたびに
  # 1行ずつ引きに行くと、一覧の行数だけ問い合わせが増える
  MEDIA_INCLUDES = {
    medias: [ { file_attachment: :blob }, { thumb_attachment: :blob }, :shared_asset ]
  }.freeze

  # カード画像の縦横比（定義は AspectRatios に集約）
  validates :aspect_ratio, inclusion: { in: AspectRatios::KEYS }
  # 生成品質の段。null = 標準（段を持たない行が受け持つ）
  # 段を持たない（nil）のが「標準」。空文字は normalize_image_mode が nil へ倒す。
  # **言葉はこちらで書く**——既定のままだと "Image mode is not included in the list" が
  # そのまま画面へ出る（この口は利用者が押した結果を返すところ）
  validates :image_mode, inclusion: { in: ImageRoute::MODES, message: "は選べない生成品質です" },
                         allow_nil: true

  # 「この語を、どの意味で扱うか」の決まり具合。
  #
  #   none     … 決める必要が無い（そもそも多義でない・引けなかった）
  #   pending  … **確認待ち**。訊くべき語だが、まだ選ばれていない
  #   resolved … 選ばれた（読まれ方で自動に決めた場合もここ）
  SENSE_STATUSES = %w[none pending resolved].freeze
  validates :sense_status, inclusion: { in: SENSE_STATUSES }

  # 意味が決まるまで待っているカード。**まだ何も作っていない**
  scope :awaiting_sense, -> { where(sense_status: "pending") }

  def sense_pending? = sense_status == "pending"

  # 決まった意味の見出し（「アポローン」「アポロ計画」）。決まっていなければ nil。
  # **探しものの手がかり**なので、実物を探す道（`MediaRetrieval`）はこちらを使う
  def sense_label = sense_pending? ? nil : sense["title"].presence

  # 画面に添える短い札（「工学」「アニメ」「人」）。
  #
  # 見出し語の右に括弧で置くので、**見出しをそのまま出しても意味が無い**——
  # 「CAD（CAD）」になるだけ。札が無い語では、見出しの括弧の中へ倒す
  def sense_mark
    return nil if sense_pending?

    mark = sense["qualifier"].presence || short_sense_title
    # **見出し語と同じ札は出さない。** 「発酵（発酵）」は何も見分けていない
    return nil if mark.nil? || mark.casecmp?(title.to_s)

    mark
  end
  # 「タイタン (衛星)」→「衛星」、「image（辞書的な意味）」→「辞書的な意味」。
  #
  # **見出し語と同じ字は、右に添えても見分けにならない。** Wikipedia の
  # 曖昧さ回避の見出しは、もともとこの括弧で見分けるために付いている。
  # 括弧が無ければ見出しをそのまま使う（短い語ではそれで足りる）
  def short_sense_title
    text = sense["title"].to_s.strip
    return nil if text.blank? || title.blank?

    text[/\A#{Regexp.escape(title)}\s*[（(](.+)[）)]\z/, 1].presence || text
  end

  belongs_to :user
  belongs_to :item_type
  has_many :meanings, dependent: :destroy
  has_many :item_properties, dependent: :destroy
  # 調査（1回の生成で1行。いまは最新だけを読む）
  has_many :item_researches, dependent: :destroy
  # 紙面のタブ（このカードだけの耳）
  has_many :paper_chapters, dependent: :destroy
  has_many :item_reviews, dependent: :destroy
  has_many :medias, dependent: :destroy
  # これまでに使った絵の記録（絵そのものは shared_medias にある）
  has_many :item_media_generations, dependent: :destroy
  has_many :box_items, dependent: :destroy
  has_many :boxes, through: :box_items
  has_many :box_entries, as: :entry, dependent: :destroy
  has_many :item_tags, dependent: :destroy
  has_many :tags, through: :item_tags
  has_many :from_relations, class_name: "Relation", foreign_key: :from_item_id, dependent: :destroy
  has_many :to_relations, class_name: "Relation", foreign_key: :to_item_id, dependent: :destroy
  has_many :view_items, dependent: :destroy
  has_many :views, through: :view_items
  # ノートの枡に置いたカード。**関連を張っていなかったころは、
  # ノートに置いたカードを消そうとすると外部キーで落ちていた**（500）。
  # 盤に置いたカード（`view_items`）と同じで、カードが消えれば枡も消える
  has_many :note_blocks, dependent: :destroy
  # ロード種別スペースのポイントに割り当て。カード削除時はポイントを空にする（nullify）
  has_many :space_points, dependent: :nullify

  # 絵を作るモデルの指定。null は「おまかせ」＝そのときの既定。
  #
  # 選べないキー（鍵が外された・古い指定が残っている）は保存時に null へ丸める。
  # 弾いてしまうと、鍵を1つ外しただけで過去のカードが編集できなくなる。
  before_validation :normalize_image_model
  before_validation :normalize_image_mode

  GENERATION_STATUSES = %w[pending processing completed failed].freeze
  GENERATION_ERROR_KEYS = %w[generation_error generation_error_code generation_failure_kind].freeze
  MAX_TITLE_LENGTH = 100
  # 画像の下ごしらえ（説明文・情景プロンプト）の状態。none は未使用・無効時
  BRIEF_STATUSES = %w[none pending processing completed failed].freeze
  MAX_IMAGE_DESCRIPTION_LENGTH = 2000
  MAX_SCENE_PROMPT_LENGTH = 1000

  # 画像への指示をどう作るか。空（未指定）は brief と同じ＝既定の経路。
  #   word     … 単語をそのまま画像生成へ渡す（下ごしらえ無し。最初期のやり方）
  #   brief    … 単語から説明文と情景を起こす（IMAGE_BRIEF_ENABLED の既定の経路）
  #   research … 先に意味・説明を調べ、それをもとに指示を書き直す
  #
  # カードごとに覚える。作り直しのときも同じ経路をたどらないと、
  # 「単語そのまま」で作ったカードが作り直しただけで別のやり方に化ける。
  PROMPT_SOURCES = %w[word brief research].freeze
  # 画像への指示の作り方の既定。
  #
  # **調べてから絵にする**（research）を既定にする。多義語・専門用語・固有名詞は、
  # 単語だけを見て情景を起こすと別のものの絵になる（「アポロ」が神か宇宙計画か）。
  # 先に意味・説明を作り、それをもとに指示を書き直せば、その語の絵になる。
  #
  # **絵の使い回しは効かなくなる。** 指示がカード固有になるので、
  # 同じ単語でも別の絵として作られる。ただし実測で使い回せていたのは 0.9%
  # （344回中3回）で、いま失うものはほとんど無い。
  # 使い回しが効くようになったら（利用者が増えて同じ語が重なったら）見直すこと。
  #
  # 書き直しそのものは無料（`scene_rewrite_internal` は FREE_KINDS）。
  # 意味・説明の生成は既定で走っているので、ここで増える費用も無い
  DEFAULT_PROMPT_SOURCE = "research"

  store_accessor :metadata, :generation_error, :generation_error_code, :generation_failure_kind,
                 :style, :custom_prompt, :framing,
                 :prompt_source, :block_view

  # カード1枚ごとの見え方（どのブロックを出すか・並び順）。
  # 中身は { "hidden" => [key...], "order" => [key...] }。
  # 種別の設定（どの項目を持つか）とは別で、こちらは**この1枚だけ**に効く。
  MAX_BLOCK_KEYS = 100
  MAX_BLOCK_KEY_LENGTH = 64

  validates :title, presence: true, length: { maximum: MAX_TITLE_LENGTH }
  validates :generation_status, inclusion: { in: GENERATION_STATUSES }
  validates :style, inclusion: { in: PromptBuilderService::STYLES }, allow_blank: true
  validates :custom_prompt, length: { maximum: PromptBuilderService::CUSTOM_PROMPT_MAX_LENGTH }, allow_blank: true
  validates :framing, inclusion: { in: PromptBuilderService::FRAMINGS }, allow_blank: true
  validates :prompt_source, inclusion: { in: PROMPT_SOURCES }, allow_blank: true
  validates :brief_status, inclusion: { in: BRIEF_STATUSES }
  validates :image_description, length: { maximum: MAX_IMAGE_DESCRIPTION_LENGTH }, allow_blank: true
  validates :scene_prompt, length: { maximum: MAX_SCENE_PROMPT_LENGTH }, allow_blank: true

  # 当月（月初〜）に作成されたアイテム。月間生成上限の判定・残量表示に使う
  scope :created_this_month, -> { where(created_at: Time.current.beginning_of_month..) }

  # 生成が pending/processing のまま滞留している孤児候補。
  # デプロイ/再起動で Solid Queue のワーカーが pruned されると処理中ジョブが失われ、
  # アイテムが「生成中」のまま取り残される。cutoff より更新が古いものを stuck とみなす。
  #
  # **意味の確認待ちは拾わない。** あれは滞留ではなく、人を待っている状態。
  # 拾うと、選ばれていない意味のまま絵が作られる（しかも黙って費用が出る）
  scope :stuck_generation, ->(cutoff) {
    where(generation_status: %w[pending processing])
      .where.not(sense_status: "pending")
      .where(updated_at: ..cutoff)
  }

  # 隠しているブロックのキー。未設定なら空
  def hidden_block_keys
    Array((block_view || {})["hidden"])
  end

  # そのカードでは持たない項目。畳んでいる（hidden）のとは意味が違う。
  # 持たない項目は AI の穴埋めの対象からも外す
  def omitted_block_keys
    Array((block_view || {})["omitted"])
  end

  # 並び順の指定。未設定なら空（画面側の既定の並びを使う）
  def ordered_block_keys
    Array((block_view || {})["order"])
  end

  # カードごとの幅（何列ぶんを占めるか）。決めていないものは1列。
  # 列数そのものは端末ごとの設定なので、ここには持たない
  def block_spans
    spans = (block_view || {})["spans"]
    spans.is_a?(Hash) ? spans : {}
  end

  # 列への振り分けを自分で決めるか。**書いていなければ自動**。
  # 自動＝列の中を上から順に流し、どこで折り返すかは画面が決める
  def block_auto_flow?
    (block_view || {})["auto_flow"] != false
  end

  # 章割りのうち、**利用者が移したぶんだけ**（カードの鍵 → 章の鍵）。
  #
  # 導いただけのものは書かない。書いてしまうと、あとで既定の割り方を直したときに、
  # 触ってもいないカードだけが古い割り方のまま取り残される。
  # どう導くかを知っているのは画面側なので、ここは受け取った覚えを持つだけ。
  def block_chapters
    chapters = (block_view || {})["chapters"]
    chapters.is_a?(Hash) ? chapters : {}
  end

  # 紙面での段の使い方（カードの鍵 → "solo" / "pair"）。
  #
  # **書いていない項目は自動で組む**（短いもの同士を横に並べる）。
  # ここに入るのは、利用者が紙面で落とす場所を選んで決めたぶんだけ
  def block_row_flow
    flow = (block_view || {})["row_flow"]
    flow.is_a?(Hash) ? flow : {}
  end

  # 自分で決めるときの、列ごとの個数（左から順）。
  # 列の数そのものは端末ごとの設定なので、ここには持たない。
  # **足りないぶんは最後の列へ回す**（数を書き換えてもカードが消えない）
  def block_column_counts
    counts = (block_view || {})["column_counts"]
    counts.is_a?(Array) ? counts.map { |n| n.to_i.clamp(0, 99) } : []
  end

  # 未指定のカード（旧データ・既定のまま作られたもの）は既定の経路として扱う
  def effective_prompt_source
    prompt_source.presence || DEFAULT_PROMPT_SOURCE
  end

  def normalize_image_model
    return if image_model.blank?

    self.image_model = nil unless GenerateImageService.selectable_key?(image_model)
  end

  # 生成品質の段。**空は「標準」**（段を持たない）。
  #
  # 画面の段は3つ（節約・標準・高品質）だが、持っているのは saver / fine の2つだけで、
  # 標準は**段が無いこと**で表す。画面はその段の鍵として空文字を渡してくるので、
  # そのまま入れると「一覧に含まれていません」で弾かれる——
  # 作り直しで何かを変えるたびに、英語のまま画面へ出ていた。
  #
  # モデルのほう（`normalize_image_model`）は最初からこう整えてある。片方だけ
  # 素通りだったのが食い違いで、**同じ作法に揃える**
  def normalize_image_mode
    self.image_mode = nil if image_mode.blank?
  end

  def primary_media
    if association(:medias).loaded?
      medias.min_by { |media| [ media.position || Float::INFINITY, media.created_at ] }
    else
      medias.ordered.first || medias.first
    end
  end

  # 語全体を1つにまとめた文。**0〜1件**。
  #
  # ## 個別の意味とは、はっきり分ける
  #
  # 個々の意味（`detail_meanings`）は、これから**それぞれが絵・例文・出典・
  # AIチェック・関連を持つ単位**になっていく。総括はそのどれでもなく、
  # 「このカードは何の話か」を1行で言うためだけのもの。
  # 混ぜて1つの並びで返していたころは、総括を1番に数えるせいで
  # 個々の意味が2から始まっていた。
  #
  # **置き場所は行のまま**（`meanings` の `kind: summary`）。AIチェックも
  # 書き直しも取り消しも、行に対する仕組みがそのまま効くため。
  # ただし**外へ出す形では必ず分ける**（API も画面も別物として扱う）ので、
  # あとで別の器へ移しても、読む側は何も変えずに済む。
  def summary_meaning
    sorted_meanings.find(&:summary?)
  end

  # 個々の意味。**総括を含まない。** 番号を振るのも、絵や例文を持つのもこちら
  def detail_meanings
    sorted_meanings.reject(&:summary?)
  end

  # このカードを一言で表す文。**絵の指示・AIチェック・一覧・学習が読む1件。**
  #
  # 順に、
  #   1. 利用者が選んだ行（`primary_meaning_id`）
  #   2. 総括
  #   3. 個々の意味の先頭（日本語を優先）
  #
  # **選んだものが最優先。** 2 と 3 だけだったころは、総括を書いた瞬間に代表が
  # 黙って総括へ移り、選び直す手も消えていた（並び順が代表を兼ねていたため）。
  #
  # 総括を持つカードでいちばん上の意味を返していたら、`image` というカードの絵が
  # 「写真」の絵になる——語全体を覚えたくてまとめた人の意図と食い違う。
  # だから**選んでいないあいだは総括が勝つ**ままにする
  def primary_meaning
    chosen_primary_meaning ||
      summary_meaning ||
      detail_meanings.find { |m| m.language_code == "ja" } ||
      detail_meanings.first
  end

  # 利用者が選んだ代表。**読んである行の中から探す**——
  # id だけを信じて引くと、問い合わせが1本増えるうえ、
  # 消えた直後のカードで「この表には無い行」を指したまま返ってしまう
  def chosen_primary_meaning
    return nil if primary_meaning_id.blank?

    meanings.find { |m| m.id == primary_meaning_id }
  end

  # 意味を、読む順に並べて返す。
  #
  # 並べ替えはメモリ上で行う。`meanings.ordered` のようにスコープを挟むと二重に効く。
  # ひとつは、まだ保存していないカード（build して meanings.build した状態）で
  # 組み立てた中身が見えなくなること。プロンプト組み立てはその状態でも通る。
  # もうひとつは、`includes` で読んであっても問い合わせが1本増えること。
  # 一覧は1ページ24枚なので、そのまま24往復になる。DB は隣の部屋には無く
  # （nrt から Neon まで片道70ms）、これが一覧の待ち時間の半分近くを占めていた。
  #
  # 覚えさせない（メモ化しない）。作ってすぐ読む道筋があり、覚えると
  # 足したばかりの意味が見えなくなる。並べ替える相手は数件なので安い
  def sorted_meanings
    meanings.to_a.sort_by { |m| [ m.position || Float::INFINITY, m.created_at || Time.zone.at(0) ] }
  end

  # ユーザーが説明文・情景プロンプトを手で直したか。直したものは自動生成で上書きしない
  def brief_edited?
    brief_edited_at.present?
  end

  def metadata_without_generation_error
    (metadata || {}).except(*GENERATION_ERROR_KEYS)
  end

  def update_generation_status!(status)
    next_metadata = metadata_without_generation_error
    # 出来上がったら、無料の作り直し回数は0に戻す。
    # 残したままだと、ずっと後で1回失敗しただけで即クレジットを取ることになる
    next_metadata = next_metadata.except("free_retries") if status == "completed"
    update!(generation_status: status, metadata: next_metadata)
  end

  # kind は失敗の種類（ImageGenerationErrorHandling::FAILURE_KINDS）。
  # 「もう一度押して直るのか」を、押す前に判断するために残す
  def mark_generation_failed!(message:, code: nil, kind: nil)
    update!(
      generation_status: "failed",
      metadata: metadata_without_generation_error.merge(
        "generation_error" => message,
        "generation_error_code" => code,
        "generation_failure_kind" => kind
      ).compact
    )
  end
end
