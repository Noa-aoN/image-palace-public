/**
 * 入力を 1 枚ずつの言葉に切り分ける。**カードを作る入口はどれもここを通す。**
 *
 * 基本は改行のみ。カンマや読点は言葉の中に現れるため、既定で区切りにすると
 * 「Hello, world」「1,000」「彼は、走った」が意図せず分かれてしまう。
 * タブは表計算から貼ったときの列区切りで、言葉の中には現れないので常に区切る。
 *
 * カンマ・読点で区切りたい場合は splitByPunctuation を立てる（フォーム側の任意設定）。
 * 全角カンマも対象に含める（半角だけだと日本語入力で取りこぼす）。
 *
 * **入口ごとに書かない。** 以前はここが作成フォームとエントランスの2か所にあり、
 * エントランス側だけがカンマで割っていた。同じ「カードを作る」で、貼った表が
 * 片方では 1 枚・もう片方では 3 枚になっていた。
 */
export function parseTitles(raw: string, splitByPunctuation = false): string[] {
  const pattern = splitByPunctuation ? /[\n\t,，、]/ : /[\n\t]/
  return raw
    .split(pattern)
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
}

/** 1 つの言葉の長さの上限。サーバー側の検証と揃える */
export const MAX_TITLE_LENGTH = 100

/** 長すぎる言葉が混ざっているか。区切り直しを促すために使う */
export function hasTooLongTitle(titles: string[]): boolean {
  return titles.some((t) => t.length > MAX_TITLE_LENGTH)
}
