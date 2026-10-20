require "rails_helper"

# 作り直しの受付が「1本だけ」であることを、実際に2本走らせて確かめる。
#
# ここだけは例をトランザクションで包まない。包むと別の接続から相手のデータが
# 見えず、「同時に同じカードを作り直す」状況が作れない。後片付けは自分でやる。
RSpec.describe Images::AcceptRegeneration do
  self.use_transactional_tests = false

  let(:pt) { Billing::POINTS_PER_CREDIT }
  let!(:user) { create(:user, :confirmed) }

  after do
    User.where(id: user.id).destroy_all
    # この例はトランザクションに包まれないので、作った行は自分で消す
    ProviderIncident.delete_all
  end

  describe "同時に2本来たとき" do
    it "通るのは1本だけ。引き落としもジョブも1回ずつ" do
      user.grant_credits!(10 * pt, kind: "campaign", expires_at: 5.days.from_now)
      item = create(:item, :completed, user: user)

      results = [ nil, nil ]
      start = Queue.new
      threads = 2.times.map do |i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            start.pop
            results[i] = described_class.call(item: Item.find(item.id), user: User.find(user.id))
          rescue StandardError => e
            results[i] = e
          end
        end
      end
      2.times { start << :go }
      threads.each(&:join)

      # 負けた側も**例外ではなく断り**で返ること（例外だと 500 になる）。
      # 読み直して pending を見たか、行が空くのを待てずに諦めたか、どちらでもよい
      expect(results).to all(be_a(described_class::Result))
      accepted, rejected = results.partition(&:accepted?)
      expect(accepted.size).to eq(1)
      expect(rejected.map(&:error))
        .to eq([ described_class::NOT_ACCEPTABLE ]).or eq([ described_class::BUSY ])

      expect(user.credit_transactions.where(kind: "consumption").count).to eq(1)
      expect(item.reload.generation_status).to eq("pending")
      # 下ごしらえがまだ無いカードなので、積まれるのはそちらから（force は引き継ぐ）
      expect(GenerateBriefJob).to have_been_enqueued.exactly(:once)
        .with(item.id, force_generate: true, use_meaning: false)
    end
  end

  describe "行が別の処理に押さえられているとき" do
    # 生成ジョブは供給側への問い合わせのあいだ、ずっとカードの行を握る。
    # **そこで待つと本番は statement_timeout で 500 になる**ので、待たずに断る
    it "空くのを待たずに断る" do
      user.grant_credits!(10 * pt, kind: "campaign", expires_at: 5.days.from_now)
      item = create(:item, :completed, user: user)

      locked = Queue.new
      release = Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Item.find(item.id).with_lock do
            locked << :locked
            release.pop(timeout: 5) # 直っていないときにテストを止めないための上限
          end
        end
      end
      locked.pop

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = described_class.call(item: Item.find(item.id), user: user)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 2
      expect(result.error).to eq(described_class::BUSY)
      expect(user.credit_transactions.where(kind: "consumption").count).to eq(0)
      expect(enqueued_jobs).to be_empty
      expect(item.reload.generation_status).to eq("completed")
    ensure
      release << :go
      holder&.join
    end
  end

  describe "断ったとき" do
    it "画面から来た指示を書き込まない" do
      # 供給側が止まっているあいだ、クォータで失敗したカードは作り直せない
      ProviderIncident.record!(provider: "openai", kind: ProviderIncident::QUOTA_EXHAUSTED)
      item = create(:item, :failed, user: user, custom_prompt: "まえの指示")
      item.update!(generation_failure_kind: "quota")

      result = described_class.call(
        item: Item.find(item.id), user: user, instructions: { custom_prompt: "あとの指示" }
      )

      expect(result).not_to be_accepted
      expect(item.reload.custom_prompt).to eq("まえの指示")
      expect(item.generation_status).to eq("failed")
    end
  end
end
