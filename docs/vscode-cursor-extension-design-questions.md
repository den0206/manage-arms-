# Agent Tool — 設計決定記録

## D-1. 対応環境

macOS、Linux、Windows のすべてで機能を提供する。OS 固有のパスは VS Code と
Node.js 標準ライブラリで解決し、リンクは macOS/Linux で symlink、Windows で
junction または hardlink を使う。

## D-2. 実装

すべての管理ロジックは拡張内の TypeScript モジュールで実行する。配布物に
プラットフォーム固有の実行ファイルは含めない。

## D-3. 保存先

可変メタデータは `context.globalStorageUri` の `registry.json` だけに保存する。
Skill と Subagent の実体はエージェントが読む既知の管理ルートに置く。

## D-4. 安全な書き込み

`writeGuard.ts`、`registry.ts`、`mcpScanner.ts` だけが書き込みを行う。
名前、親ディレクトリ、symlink/junction、管理ルートを検証してから操作する。

## D-5. 削除

削除は確認後に実行する。Undo と恒久バックアップは持たない。

## D-6. UI

Dashboard は表示中だけ一覧の再取得と MCP ポーリングを行う。View を閉じるか
非表示にした時点でタイマー、キャッシュ、スナップショットを破棄する。

## D-7. 信頼境界

未信頼ワークスペースと Remote 環境では書き込み操作を拒否する。走査対象は
`source.ts` のホワイトリストに限定する。

## D-8. プロセス状態

MCP サーバーの状態は登録済み定義とプロセス親子関係を照合して判断する。
ホームやワークスペースを再帰走査しない。

## D-9. 配布と検証

Node.js の型検査・テスト・不変条件検査を 3 OS で実行する。Cursor の E2E は
固定した Cursor Stable を macOS で実行する。第三者 GitHub Action は完全 SHA を使う。

## D-10. ブラウザ拡張の位置づけ

Chrome / Edge 向けの拡張を同じリポジトリで提供する。IDE 拡張とは独立して動作し、
ブラウザ拡張だけで検知から導入まで完結する。IDE 拡張の導入も起動も前提にしない。

localhost ブリッジと native messaging host は採らない。前者は IDE 拡張が待受主体になるため
未導入・未起動の利用者で導入が成立せず、後者は配布物にプラットフォーム固有の実行ファイルが
必要になり D-2 と衝突する。

## D-11. ブラウザからの書き込み

File System Access API を使う。利用者がディレクトリを選んで許可した範囲だけに書き込み、
ハンドルは IndexedDB に保持する。常駐プロセスを持たない。

Chromium はホームディレクトリ直下の選択を拒否するが、その配下は選べる。symlink は作れないため、
D-3 の共有ストアとリンクの方式はブラウザ側では再現しない（D-13）。

## D-12. ブラウザ拡張が扱う種別

Skill と Subagent だけを扱う。

- MCP は URL に手がかりが無く、公式サイトの JSON を貼る既存導線が最頻である。
- Plugin は `installed_plugins.json` への登録が必要で、IDE 拡張も書き込みを CLI に委譲している。
  ファイルを置いてもエージェントが認識しない。

`supports()` により、Gemini CLI は MCP だけを対象にするため導入先に現れない。Codex は Skill だけ。

## D-13. 実体の置き場

`~/.agents/skills` を読むエージェント（Cursor / Codex）には、そこへ 1 つだけ置く。存在しない
環境では各エージェント直下へ置く。Claude は `~/.agents` を読まないので常に `~/.claude/skills`
へ直接置く。

IDE 拡張が張った symlink はブラウザ拡張から辿れない。両者が入れたものは相互に不可視となる。

## D-14. 取得元の台帳

ブラウザ拡張は導入先ルートの `.agent-tool/<name>.json` に取得元と commit SHA を書く。
エントリごとに 1 ファイルにして read-modify-write を避ける。ブラウザ拡張はプロセス間ロックを
取れない。

IDE 拡張は走査時にこれを `registry.json` へ取り込み、取り込んだファイルを削除する。走査は
`.` で始まる名前を除外するため、台帳がスキルとして誤検出されることはない。取り込みにより、
IDE 拡張の削除・無効化・更新検知がそのまま働く。利用者が自分で置いた実体は台帳を持たないので
管理下に入らない。

台帳と実体ツリー SHA-256（D-11）は役割が違う。台帳はブラウザ拡張から IDE 拡張への片方向の
引き渡しに使い、SHA-256 はブラウザ拡張自身が削除してよいかの判定に使う。互いを代替しない。

## D-15. 実体を失った entry

IDE 拡張は、走査できたルートに属する entry だけを実体と照合し、実体が無ければ registry から
除く。走査できなかったルート（開いていないプロジェクト）の entry は残す。project スコープの
entry を巻き込んで消さないための条件である。

## D-16. ブラウザ拡張の検知

`host_permissions` は検知用の github.com / skills.sh / agentsdirectory.dev と、取得用の
raw.githubusercontent.com / codeload.github.com に限る。content script が Shadow DOM でバナーを描き、
ページの CSS と隔てる。検知の ON / OFF 設定を持つ。

バナーを出す前に `raw.githubusercontent.com` へ実在確認する。閲覧中の URL は外部へ送らない。
URL だけで取得元が決まらない agentsdirectory.dev は、開いているページの JSON-LD を DOM から
読む。入力フォームに貼られたときだけ取得しに行く。

## D-17. ブラウザ拡張の画面

`showDirectoryPicker()` はポップアップから呼ぶとポップアップが閉じて処理が中断する。導入・
許可・一覧は専用タブで行う。MV3 の service worker がアイドルで停止する問題も、取得と展開を
専用タブで行うことで回避する。

## D-18. リポジトリ構成と配布

`ide/` `browser/` `core/` に分け、`test/` はルートに集約する。ルートの `package.json` は 1 つ、
`browser/manifest.json` を別に持つ。

版は拡張ごとに独立させ、タグの接頭辞（`ide-v*` / `browser-v*`）でリリースを分岐する。片方の
修正でもう片方をストア審査に出さないための分離である。配布は Chrome Web Store と Edge Add-ons。
