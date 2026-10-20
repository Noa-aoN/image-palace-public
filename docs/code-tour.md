# コードの案内

抜粋した 22 ファイルを、**読む価値のある順**に並べています。
パスは本体（非公開リポジトリ）と同じです。抜粋なので、ここから呼ばれている
クラスの多くはこのリポジトリにありません。読むのに困らない範囲で選びました。

コメントは本体のままです。このプロジェクトでは
**「何をしているか」ではなく「なぜそうなっているか」**をコードに書いています。

---

## 1. 1枚の絵ができるまで

| ファイル | 読みどころ |
|---|---|
| [generate_image_job.rb](../backend/app/jobs/generate_image_job.rb) | 非同期生成の本体。キャッシュの判定・失敗の種類分け・返金・通知まで1本で追える。リトライは指数バックオフ（15秒・60秒・240秒）で、**全部使い切ってから** failed にする |
| [shared_media_writing.rb](../backend/app/jobs/concerns/shared_media_writing.rb) | 絵を「世界で1枚の置き場」へ収めるところ。鍵が食い違うと作り直し＝**代金を二度払わせる**ので、カードの絵と神託の絵で同じ収め方を共有している。PostgreSQL のアドバイザリロックで、同じ鍵の同時生成を1本に絞る |
| [prompt_fingerprint.rb](../backend/app/services/images/prompt_fingerprint.rb) | 「入力が変わったか」を判定する仕組み。画面は指示欄が空でも `custom_prompt: ""` を送るので、**渡されたか**では判定できない。実際に供給側へ渡る文字列を突き合わせる |

## 2. 同時に押されたときに、1本だけ通す

| ファイル | 読みどころ |
|---|---|
| [accept_regeneration.rb](../backend/app/services/images/accept_regeneration.rb) | 作り直しの受付。**行を押さえてから状態を読み直す**。待たない理由（生成ジョブが行を握り続ける・本番の `statement_timeout` で 500 になる）と、`lock_timeout` を `deadlock_timeout` より短くした理由をコメントに残してある |
| [accept_regeneration_spec.rb](../backend/spec/services/images/accept_regeneration_spec.rb) | それを**実スレッド2本**で確かめる。直す前は `expected: 1, got: 2`（2本とも受理・2回引き落とし）だった |
| [credit_concurrent_consume_spec.rb](../backend/spec/models/credit_concurrent_consume_spec.rb) | クレジットの引き落としの同時実行。「残高が足りなければ片方だけ」「分け合えるなら2本とも」の**両方**を固定している。後者を固定しているから、二重課金は行ロックで止めるしかないと分かる |

## 3. お金の決まり

| ファイル | 読みどころ |
|---|---|
| [retry_policy.rb](../backend/app/services/images/retry_policy.rb) | 失敗からの作り直しをどこまで無料にするか。**無料であることと、何度でも押せることは別**という分け方。方針違反・入力不備は「押しても直らない」ので止め、一時的な失敗は3回まで無料、入力を変えたら数え直し、ただし1日の天井あり |
| [credit_cost.rb](../backend/app/services/billing/credit_cost.rb) | 1回の生成で引く量。段（節約・標準・高品質）がモデルより強い理由は「利用者が選ぶのは段だから」 |

## 4. どのモデル・どの寸法で作るか（原価に直結する）

| ファイル | 読みどころ |
|---|---|
| [resolver.rb](../backend/app/services/image_routing/resolver.rb) | 利用者の指定・用途の方針・既定を**決まった順で1つに倒す**。「ほかに使えるモデルを総なめ」をやめた理由（既定が候補に埋もれて、設定から読めなくなる）。品質の既定を low にしたのは実測（見た目は同じ、原価は 2.3 倍差） |
| [size_resolver.rb](../backend/app/services/image_routing/size_resolver.rb) | 比を満たす実寸の決め方。**切り出しは最後の逃げ道**。保存の 1.28 倍を下限に作る理由（縮小で生成時の粗さをならす）まで数字で書いてある |
| [resolution.rb](../backend/app/services/image_routing/resolution.rb) | 1回ぶんの決定をまとめた値。ここから先、誰も「どのモデルで、どの寸法か」を考え直さない |

## 5. 安全

| ファイル | 読みどころ |
|---|---|
| [image_format.rb](../backend/app/services/image_format.rb) | libvips へ渡す前にマジックバイトで allowlist。**Content-Type は自己申告なので信用しない** |
| [vips.rb](../backend/config/initializers/vips.rb) | ローダの allowlist。`block_untrusted` が PDF・HEIF を止めないことが実測で分かったので、読み込みオペレーション全体を止めて3つだけ戻している |
| [vips_hardening_spec.rb](../backend/spec/security/vips_hardening_spec.rb) | その防御が**実際に効いている**ことを固定するテスト。「拒否された」だけでなく**拒否の理由**まで見る（ローダ不在と区別しないと、防御が外れた環境でも緑になる） |
| [prompt_moderator.rb](../backend/app/services/moderation/prompt_moderator.rb) | 2段の検査（ローカルのブロックリスト → OpenAI Moderation）。学習アプリなので**過剰ブロックを避ける**方針。`"sex" in "sussex"` の巻き込みを単語境界で防ぐ |
| [prompt_moderation.rb](../backend/app/controllers/concerns/prompt_moderation.rb) | 検査の呼び出し口を1つに揃えたもの。同じ検査が4箇所に散って、**入口ごとに掛け忘れ**が出ていた |
| [rack_attack.rb](../backend/config/initializers/rack_attack.rb) | 乱用対策。**IP を信用しない話**（`X-Forwarded-For` は呼ぶ側が書ける）と、口ごとの速度制限に加えて**1人あたりの総量**を置いた理由（1分20回を守って押し続けると1日で数万回になる） |
| [csp.ts](../frontend/src/lib/security/csp.ts) ／ [csp.test.ts](../frontend/test/lib/csp.test.ts) | CSP を組み立てる場所と、それを守るテスト。`img-src` に裸の `https:` を戻さない理由（XSS 時のトークン持ち出し）、HSTS を手元で出さない理由まで書いてある |

## 6. 速さ

| ファイル | 読みどころ |
|---|---|
| [query_counting.rb](../backend/spec/support/query_counting.rb) | 速さは環境で変わるので測らず、**問い合わせの本数**だけを数える道具 |
| [items_query_count_spec.rb](../backend/spec/requests/api/v1/items_query_count_spec.rb) | 「枚数を増やしても本数が増えない」を固定。サムネの添付を読み忘れていたときは 82 本・約 5.6 秒かかっていた |

## 7. 中核のモデル

| ファイル | 読みどころ |
|---|---|
| [item.rb](../backend/app/models/item.rb) | カード1枚。生成の状態・失敗の種類・意味の決まり具合・画面での見え方を持つ。`MEDIA_INCLUDES` のコメントが、このアプリの速さの勘所（DB は隣の部屋には無い） |
