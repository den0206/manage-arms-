# manage-arms 設計ドキュメント

AI コーディングエージェント（Claude Code / Cursor / Codex / Gemini CLI）の
周辺リソース — MCP・Skills・Subagents・Plugins —
を 1 つの GUI で横断管理する macOS アプリ。

- **プラットフォーム**: macOS 26 以降 / SwiftUI
- **配布**: DMG の直配布（App Sandbox 非対応のため App Store 不可）。公開先は
  [den0206/manage-arms-releases](https://github.com/den0206/manage-arms-releases)。13 章
- **状態**: **v1〜v4 実装済み**（Skills / Subagents / Plugins / 使用実績 / MCP / 権限）、
  および **配布基盤**（`.app` 組み立て / 署名・公証 / DMG / CI）。テスト 322 件
- **実装**: SPM パッケージ。`swift test` / `CONFIG=debug UNIVERSAL=0 ./Scripts/build-app.sh`
  （`.xcodeproj` は不要。実 CLI・実ネットワークを使う確認は `MANUAL=1 swift test`）
- **作業の進め方**: [CLAUDE.md](CLAUDE.md)。利用者向けの入口は [README.md](README.md)
- **最終更新**: 2026-09-06（配布を公開リポジトリ manage-arms-releases に分け、+N 採番にした）

---

## 1. 解こうとしている問題

同じリソースを、エージェントごとに、別々の場所へ、別々の書式で登録し直している。

実測した具体例（このマシンの実データ）:

- `ponytail` プラグイン v4.9.0（同一 commit SHA）が、**5 プロジェクトに個別インストール**されている
- スキルの取得元を管理するために、ユーザーが `skills-registry.json` + `update-skills.py` を**手作りしている**
- **インストール済みスキル 26 件のうち、使用実績があるのは 7 件**（3.9 で実測）
- `chrome-devtools` が Cursor に登録されているが、**起動しているかは設定を見ても分からない**（3.9）

どれも「横断ビューが無いこと」が原因。これがアプリの存在理由。

### やらないこと

| 対象外 | 理由 |
|---|---|
| model / env / theme / statusLine などの素の設定 | 各 CLI に `/config` がある。作っても使われない |
| Cursor extensions（1.6 GB） | VSCode 拡張であってエージェント要素ではない |
| **Hooks** | 3 エージェントで**イベント名が 1 つも揃っていない**（`PostToolUse` / `afterAgentResponse` / …）。変換は最難関なのに、書き込みは `~/.claude/settings.json` の直接編集が要り 3.1 と衝突する。Codex の `trusted_hash` も未解明。**費用対効果が合わない** |
| **Commands / Rules** | `CLAUDE.md` / `AGENTS.md` / `.cursorrules` はエディタで直接開いた方が早い。横断ビューにしても得るものが無い |
| エージェントのディスク使用量の掃除機能 | このアプリの仕事ではない |
| Windows / Linux 対応 | macOS 単体に絞る |

---

## 2. 対象エージェントと実態

扱うのは **4 種別だけ**（`enum Kind`）。Hooks / Commands / Rules は 1 章の通り対象外。

| | MCP | Skills | Subagents | Plugins |
|---|---|---|---|---|
| **Claude Code** | `claude mcp` CLI | `~/.claude/skills/<n>/SKILL.md` のみ | `~/.claude/agents/*.md` | `claude plugin` CLI |
| **Cursor** | `~/.cursor/mcp.json`（CLI 無） | 9 ルートを走査（3.2） | `~/.cursor/agents/` | `~/.cursor/plugins/` |
| **Codex** | `codex mcp` CLI | `~/.codex/skills/` + `~/.agents/skills/` | — | `codex plugin` CLI |
| **Gemini CLI** | `gemini mcp` CLI | — | — | — |

非対応のセルは UI 上でグレーアウトし、**無理に変換しない**。

---

## 3. 中核となる設計判断

### 3.1 書き込みは各 CLI に委譲する

`~/.claude.json` は **98 KB** あり、MCP 設定だけでなくプロジェクト履歴・
オンボーディング状態・キャッシュが同居している。ここをアプリが読んで
書き戻すと、Claude Code の実行中に競合して**ユーザーの全状態を破壊する**。
`~/.codex/config.toml` も、素朴に読み書きするとコメントが消える。

したがって:

| 操作 | 実装 |
|---|---|
| MCP 追加/削除（Claude / Codex / Gemini） | `Process` で `<cli> mcp add\|remove` を実行 |
| MCP 追加/削除（Cursor） | `~/.cursor/mcp.json` を直接編集（専用の小さいファイルなので安全） |
| Plugin 追加/削除/更新（Claude） | `claude plugin install\|uninstall\|update` |
| Plugin 追加/削除（Codex） | `codex plugin add\|remove`（`update` が無いため remove + add） |
| Skill / Subagent 有効化 | 実体を配置 + `FileManager.createSymbolicLink`（3.2） |
| Skill / Subagent 無効化 | 実体を退避ディレクトリへ移動 + symlink 削除（実体は消さない。3.2） |
| 権限の削除 | `settings.json` / `settings.local.json` の `permissions` キーのみ書き換え（8 章）。**9 章のホワイトリストの唯一の例外**。バックアップ + アトミック |
| 一覧読み取り | 列挙されたファイルの直読み + `<cli> mcp list --json` |

自前で設定ファイルを組み立てる箇所が消えるため、**一番壊れやすいコードが存在しなくなる**。

### 3.2 実体は `~/.agents/skills/` に置き、symlink は Claude 用の 1 本だけ

**検証済み（2026-09-05・spike #1 / #2）。** 各エージェントが実際に走査するスキルルートを
バイナリと `codex debug prompt-input` から確定させた。

| 走査元 → | Claude | Cursor | Codex |
|---|---|---|---|
| `~/.claude/skills/` | ✅ | ✅ | ❌ |
| `~/.codex/skills/` | ❌ | ✅ | ✅ |
| `~/.cursor/skills/` | ❌ | ✅ | ❌ |
| `~/.cursor/skills-cursor/` | ❌ | ✅（Cursor 自前管理） | ❌ |
| `~/.agents/skills/` | ❌ | ✅ | ✅ |
| `~/.grok/skills/` | ❌ | ✅ | ❌ |

**Cursor は他エージェントのディレクトリを直接読む。** 実際のコードに 9 個のルートが
配列で埋まっている:

```js
[".cursor/skills/", ".cursor/skills-cursor/", ".cursor/cloud-skills/",
 ".cursor/plugins/", ".claude/skills/", ".claude/plugins/",
 ".codex/skills/", ".grok/skills/", ".agents/skills/"]
```

Codex も `~/.agents/skills` を第 2 のスキルルート（`r1`）として読む。
`codex debug prompt-input` の出力で確認済み:

```
### Skill roots
- `r0` = ~/.codex/skills
- `r1` = ~/.agents/skills
- `r2` = ~/.codex/skills/.system
```

したがって配置はこうなる:

```
~/.agents/skills/my-skill/SKILL.md        ← 実体（1 箇所）
  → Cursor が読む     （symlink 不要）
  → Codex が読む      （symlink 不要）
  → ~/.claude/skills/my-skill  へ symlink 1 本だけ張る
```

**symlink はスキル 1 つにつき 1 本、Claude のためだけ。** 当初の「3 本張る」設計より
さらに小さくなった。

#### 有効/無効は「全エージェント一括」。エージェント別の on/off は提供しない（確定）

Cursor と Codex は `~/.agents/skills/` を直接読むため、実体を置いた時点で有効になり、
アプリが個別に無効化する手段が無い。symlink で制御できるのは Claude だけ。
さらに Cursor は `.claude/skills/` も `.codex/skills/` も走査するため、
**どの配置方式を採っても「Cursor だけ無効」は原理的に不可能**。

したがって Skills の有効/無効は行単位（全対応エージェント一括）とし、
マトリクスのセルは表示専用にする（5.2 参照）。無効化は
`~/.agents/skills/<name>` を退避ディレクトリへ移動 + Claude symlink 削除で行う。

**Claude が symlink を辿ることは実測で確認済み。** `~/.claude/skills/` に symlink を
張った瞬間、起動中の Claude Code セッションのスキル一覧に現れた（再起動不要）。
逆に `~/.agents/skills/find-skills` は一覧に現れないため、
Claude がそのルートを読まないことも確定している。

#### `~/.agents/skills/` を選ぶ理由

`~/.claude/skills/` に実体を置いても symlink は 1 本（Codex 向け）で同数になるが、
`~/.agents/skills/` を採る:

- **エージェント中立**。他社製品の設定ディレクトリの中にアプリのデータを置かない
- **既存エコシステムと相互運用できる。** `~/.agents/.skill-lock.json` が既にあり、
  `vercel-labs/skills` が 8 エージェント（amp / codex / cursor / gemini-cli /
  github-copilot / kimi-cli / opencode / claude-code）向けにこの場所を使っている

#### `~/.cursor/skills-cursor/` には触らない

`.sync-manifest.json` と `.cursor-managed-skills-manifest.json`（`builtinSkillIds` /
`managedSkillIds`）を持つ Cursor 専用の管理領域。**Cursor は `~/.agents/skills` を読むので
ここに何かを置く必要が最初から無い。** 剪定されるかどうかを気にする必要もなくなった。

#### Subagents

Skills と同じ構造だが、共有ルートの慣習が無い。
`~/.claude/agents/` と `~/.cursor/agents/` へそれぞれ symlink する。

### 3.3 `git clone` を使わない

`git clone --depth 1` は `.git/` を残す。スキル本体が 20 KB でも数 MB が
アプリの保存領域に永久に溜まる。

→ `https://github.com/{repo}/archive/refs/heads/{branch}.zip` を
`FileManager.temporaryDirectory` にダウンロードして展開し、`subdir` だけコピーして
一時ディレクトリを破棄する。`.git` はそもそも生成されない。
（`update-skills.py:43,166` と同じ方式）

- **ダウンロードは `URLSession.downloadTask`**（ファイルに直接書く）。
  `Data(contentsOf:)` は使わない — メモリに全部載る
- **サイズ上限を設ける（50 MB）。** monorepo の zipball は subdir が 20 KB でも
  数百 MB になり得る（実測: `torvalds/linux` は 310 MB）。
  **codeload は GET には `Content-Length` を返す**（HEAD には返さないので
  `curl -I` では見えない）。最初の進捗コールバックで全体サイズが判明するため、
  **10 KB 書いた時点で中断できる**（実測 0.1 秒）。返らない場合の保険として
  書き込み量による中断も残す。エラーにはリポジトリ名と実サイズを添える
- **⚠️ completion handler 付きの `downloadTask` はデリゲートの進捗コールバックを
  無効化する。** 中断するにはデリゲート駆動にして継続を自分で resume する必要がある。
  ここを間違えると 310 MB を最後まで落としてから拒否することになる（実測 74 秒）
- **展開は `/usr/bin/ditto -xk` に委譲する。** Foundation に zip 展開 API は無く、
  ZIPFoundation 等の依存を足すより OS 同梱バイナリに任せる方が
  メモリにも載らず依存もゼロ。**Zip Slip 安全であることは実測済み**（spike #13）—
  `../evil.txt` や `a/../../evil.txt` は拒否ではなく `../` が除去されて
  展開先の内側に着地する。自前でエントリ名を検証する必要は無い

### 3.4 走査対象はホワイトリスト

`~/.claude` を素朴に走査すると `projects/` の **129 MB / 145 ファイル**、
`file-history/` の 17 MB、`~/.codex/logs_2.sqlite` の 44 MB を踏む。
1 回のスキャンで数百 MB の I/O が走り UI が固まる。

除外リスト方式だと新しいディレクトリが増えた時に踏むため、**逆にする**。

```swift
// 読むのはこれだけ。列挙にないパスは存在しても触らない。
enum Source {
    case file(String)    // ~/.cursor/mcp.json, ~/.claude/settings.json
    case dir(String)     // ~/.claude/skills, ~/.claude/agents, ~/.agents/skills,
                         // App Support の agents/（Subagent 実体）と
                         // disabled-skills/（無効化スキルの表示に必要。9 章）
    case cli([String])   // ["claude", "mcp", "list", "--json"]
}
```

`file-history` / `logs_*.sqlite` / `cache` / `archived_sessions` は
列挙に載らない = 一生読まない。

**例外: `projects` / `sessions` は「使用実績の集計」のためだけに限定形で読む（3.9）。**
一覧スキャンでは触らない。`case usageLog(String)` として別ケースに分け、
明示的な集計操作からしか呼ばれないようにする。

### 3.5 常駐しない・状態を持たない

- **FSEvents で監視しない。** 監視スレッドとイベントバッファが常時メモリに乗り、
  Claude Code が `projects/` に書くたびにコールバックが飛ぶ。
  代わりに `NSApplication.didBecomeActiveNotification` で再スキャンする。
  ただし **CLI 呼び出し（`claude mcp list` は node 起動を伴い秒単位）は毎回走らせない** —
  ファイル走査はアクティブ化ごと、CLI 呼び出しは前回から一定間隔
  （数分）空いた時だけ再実行する
- **メニューバーに常駐する（既定 ON、設定で OFF にできる）。** ブラウザ検知は
  ウィンドウを閉じている間こそ効く機能なので、閉じたら終了する形とは両立しない。
  OFF にすれば `applicationShouldTerminateAfterLastWindowClosed` が true に戻り、
  従来どおり閉じた時点でプロセスごと終わる
- **外観（ライト / ダーク / システム）は設定で切り替えられる。** 既定はシステム追従で、
  選んだときだけ `registry.json` の `appearance` に残る。**`NSApplication.appearance` を
  差し替える** — `.preferredColorScheme` はウィンドウの中しか変わらず、
  メニューバーのメニュー・シート・パネルが取り残される
- **常駐中に抱えるのは設定と検知の状態だけ。** ウィンドウを閉じた時点で
  `inventory` / `permissions` / 重複集計を捨てる（`AppModel.releaseForBackground`）。
  一覧は開いたときにどうせ読み直す（キャッシュしない）ので、
  持ち続ける理由が無い。**常駐だけの状態では走査を一度もしない** —
  起動直後の走査もウィンドウが出てから
- **例外はブラウザ検知の 1 つだけ**（6 章）。次の 2 つを同時に満たす間だけ
  前面ブラウザに URL を訊く: 設定が ON・既知ブラウザが前面。
  間隔は 2 段階で、URL が変わっている間（閲覧中）は 3 秒、同じページに 30 秒留まったら
  15 秒に落とす。**Apple Event 1 回は安くない**（AppleScript の実行を伴う）ので、
  常駐して投げ続けると CPU を使う。開いたままのページは何度訊いても同じ答えしか返さない。
  `NSWorkspace.didActivateApplicationNotification` で前面が変わった時にタイマーを
  張り直し、ブラウザ以外が前面なら**タイマーごと止める**。
  自分のウィンドウを見ている間もブラウザは前面でないので止まっている
- **sqlite / Core Data / SwiftData を使わない。** 永続化するのは `registry.json` のみ
- **スキャン結果をキャッシュしない。** 再スキャンはファイル数十個 + CLI 数回で完了する。
  キャッシュは「実際の設定とズレる」という管理アプリとして最悪のバグを生む
- **`Process` の出力はパイプを読み切って即破棄**

### 3.6 エージェント抽象に protocol を切らない

`protocol` を切ると実装がエージェントの数だけファイルに散って読めなくなる。
`enum Agent` + `switch` で書く。**エージェントが増えても protocol にしない** —
増えたときに必要なのは「実装の差し替え口」ではなく「埋め忘れの検出」で、
それは `default` の無い `switch` がコンパイルエラーとして出してくれる。

#### エージェントを 1 つ増やすとき

**`Agent.swift` の `case` を足して、赤くなった `switch` を埋めるだけで終わる**状態を保つ。
以下は `default` を持たないので、埋め忘れは必ずビルドが落ちる:

| 何を答えるか | 場所 |
|---|---|
| 表示名 / CLI 名 / 設定ディレクトリ | `Agent.displayName` / `cliName` / `configDir` |
| どの種別に対応するか（3.7） | `Agent.supports(_:)` |
| 走査するスキル / Subagent ルート（3.2） | `Agent.skillRoots` / `subagentRoots` |
| MCP / プラグインの読み取り元（3.1） | `Agent.mcpSource` / `pluginSources` |
| MCP の追加・削除コマンド | `MCPCommand.add` / `remove` |
| プラグインの読み取り経路 | `PluginScanner.scan` |
| `ps` からの見分け方（3.9） | `Agent.processMarkers` |

**走査対象（`Source.skills` / `subagents` / `mcp` / `plugins`）は `Agent` から導出する。**
ホワイトリスト（3.4）であることは変わらず、列挙の出どころが `Agent` に一本化されるだけ。
二重に書くと、片方だけ足したときに「宣言はあるのに一生読まれないルート」が
**エラーを出さずに**でき、マトリクスが全部「未導入」になる。
`SourceTests` の「Agent が宣言したルートは必ず走査対象に載る」がこれを検査する。

一覧・サイドバー・ホームの列は `Agent.allCases` を回しているので、追加するだけで増える。

### 3.7 エージェントを自動検出し、未検出は非活性にする

インストールされていないエージェントの列を、有効そうに見せてはいけない。
クリックしてから「CLI がありません」と出るのは最悪の体験になる。

**⚠️ 最大の罠: GUI アプリの `PATH` はターミナルと違う。**
launchd から起動された GUI アプリの `PATH` は `/usr/bin:/bin:/usr/sbin:/sbin` のみ。
実測すると、3 つの CLI すべてがこの `PATH` では**見つからない**:

```
claude   /opt/homebrew/bin/claude   → launchd の PATH では NOT FOUND
codex    /opt/homebrew/bin/codex    → NOT FOUND
gemini   /opt/homebrew/bin/gemini   → NOT FOUND
```

`Process` で素朴に `claude` を起動すると、ターミナルからのデバッグ実行では動くのに
**Finder から起動した瞬間に全エージェントが「未検出」になる**。

出荷済みアプリで実際にこうなっている。起動中の Cursor Helper の環境変数:

```
PATH=/usr/bin:/bin:/usr/sbin:/sbin
```

検出は次の順で行う:

1. **ログインシェルから `PATH` を取得する** — `$SHELL -l -c 'echo $PATH'` を 1 回だけ実行し、
   得られた `PATH` を以後すべての `Process` に渡す。mise / asdf / nvm の shim も含めてこれで拾える
2. **既知のパスを直接探す** — 1 が失敗した場合の保険。
   `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.bun/bin`, `~/.volta/bin`
3. **設定ディレクトリの存在を見る** — `~/.claude`, `~/.cursor`, `~/.codex`, `~/.gemini`
4. **手動でパスを指定できる逃げ道を用意する** — ⚙️ エージェント画面から

検出できたら `<cli> --version` でバージョンも取る（実測: `2.1.236 (Claude Code)` /
`codex-cli 0.153.2` / `0.46.0` と書式がバラバラなので、パースは緩く行い、
失敗しても「検出済み・バージョン不明」として扱う）。

#### 5 つの状態を区別する

| 状態 | 意味 | UI |
|---|---|---|
| **検出済み** | CLI があり実行できる | 通常表示 |
| **設定のみ** | `~/.codex` はあるが CLI が見つからない | 非活性。既存リソースは**読み取り表示する** |
| **未検出** | CLI も設定ディレクトリも無い | 列ごと非活性 + 「未検出」 |
| **管理対象外** | 利用者がスイッチをオフにした | サイドバーから消える。ホームの一覧には残る |
| **非対応** | 検出済みだがそのリソース種別を持たない（例: Gemini の Skills） | `—` |

**「未検出」と「非対応」を混ぜない。** Gemini CLI は検出できても Skills の概念が無い。
同じグレーで表示すると、ユーザーは「Gemini を入れれば使えるようになる」と誤解する。

**「設定のみ」で既存リソースを隠さない。** CLI が PATH から外れただけで
設定は生きていることがある。ここで「無い」と表示すると、ユーザーは重複して追加してしまう。
読み取り専用で表示し、変更操作だけを無効化する。

#### 後から入ったエージェントを活性化する

再検出は**ウィンドウがアクティブになった時**（`NSApplication.didBecomeActiveNotification`）
に行う。3.5 の「常駐しない」と同じ仕組みに相乗りさせる。
別ウィンドウでインストールして戻ってくれば活性化している。

`$SHELL -l -c` は数十 ms かかるため、**検出結果はプロセスが生きている間だけ保持**し、
再検出は非同期で行って UI をブロックしない。永続化はしない（ズレの原因になる）。

#### 保存するのは「利用者が決めたこと」だけ（確定）

検出は自動のまま。エージェントの一覧に手動の操作を 2 つだけ置き、
`registry.json` の `agents` に持つ（4.1）。**検出結果は保存しない。**

| 操作 | 保存する値 | 効果 |
|---|---|---|
| スイッチをオフ | `enabled: false` | `Detection.disabled`。サイドバーから外し、そのエージェントの MCP / Plugin を**走査しない** |
| 「CLI のパスを指定…」 | `path` | `Detector.detect(override:)` に渡る。`PATH` 解決に失敗する環境の逃げ道 |

- **既定は「有効」。** エントリが無いエージェントも有効なので、
  対応エージェントを増やしたときは何も書かなくても自動で並ぶ
  （「新しいエージェントを自動設定」に相当するスイッチは**作らない** — 常にそうする）。
- **既定値に戻した設定はファイルから消す**（`Registry.update`）。
  意味の無い行を唯一の永続ファイルに増やさない（9 章）。
- **オフはファイルを一切触らない。** 表示と走査の対象から外すだけ。
  ここで実体を移動すると、3.1 の「書き込みは各 CLI に委譲する」が崩れる。
- **「未検出」と「管理対象外」を別の文言で出す。** 同じ灰色にすると
  「入れ直せば直る」と誤解する（「未検出」と「非対応」を混ぜない、と同じ理由）。
- **手動指定は毎回実在を確かめ、消えていたら `PATH` 解決に戻す。** 保存した時点では
  実行できても、アンインストールや Homebrew の移動で消える。検証しないと
  「検出済み（緑）」のまま全操作が失敗する、最も直しにくい状態になる。
- **検出済みを「有効」と呼ばない。** スイッチと、スキルの有効/無効が既にその語を使っている。
  1 行に `[有効] (ON)` が並ぶと、どちらが何を指すのか読めない。

### 3.8 テストのために `Environment` を注入する

ホームディレクトリのパス・コマンド実行・ネットワークを直接呼ぶと、
テストが実ユーザーの `~/.claude` を書き換えてしまう。**これは事故になる。**

すべての外部依存を 1 つの構造体に集約し、テストでは差し替える。

```swift
struct Environment {
    var home: URL
    var run: ([String]) throws -> String      // CLI 実行
    var download: (URL) async throws -> URL   // zip 取得
    var now: () -> Date

    static let live = Environment(...)
    static func test(home: URL) -> Environment { ... }   // 一時ディレクトリを指す
}
```

3.6 で「protocol を切らない」と決めたが、**ここだけは例外**。
protocol ではなく構造体 + クロージャなので実装は 1 つのまま、テスト時だけ差し替えられる。

### 3.9 「使用中」の検知 — MCP だけが本当にリアルタイムで光る

**リソース種別によって「使用中」の意味がまったく違う。** ここを混ぜると
実装できない UI を約束することになる。

| リソース | 実行実体 | 「使用中」の性質 |
|---|---|---|
| **MCP** | **独立した常駐プロセス** | **状態**。起動している / していない |
| Skills | 無し（プロンプトに注入されるテキスト） | 瞬間的イベント。1 ターンで消える |
| Subagents | 無し（同上） | 同上 |
| Plugins | 無し（skills / commands の入れ物） | 同上 |

**MCP だけが「今この瞬間の状態」を持つ。** 他は「使われた」という過去の点でしかなく、
点灯させても一瞬で消えるので UI として成立しない。

#### MCP: プロセス検出で光らせる（実測で確認済み）

MCP サーバーは独立プロセスとして常駐しており、親を辿れば**どのエージェントが
掴んでいるか**まで分かる。実測:

```
87446  chrome-devtools-mcp
  └ 87431  npm exec chrome-devtools-mcp@latest
      └ 87139  Cursor Helper: mcp-process
          └ 87070  /Applications/Cursor.app/.../Cursor      ← 所属エージェント確定
```

`ps -eo pid,ppid,command` 1 回で全部取れる。**常駐もポーリングも不要**で、
3.5 と衝突しない。`didBecomeActive` の再スキャンに相乗りさせる。

```
chrome-devtools   MCP   ● 実行中（Cursor が使用中・2 時間 6 分）
supabase          MCP   ○ 停止中
```

これは「設定上は登録されているが実際には起動していない」という、
設定ファイルを見るだけでは絶対に分からない情報になる。**登録と実態のズレの可視化**で、
このアプリの目的そのもの。

#### Skills / Plugins: リアルタイムではなく「最終使用日」を出す

点灯ではなく**いつ最後に使われたか**を表示する。リアルタイム性は要らず、
セッションログから取れる。実測で抽出できることを確認済み:

```
2026-09-04T23:02  Skill  {'skill': 'artifact-design'}
2026-09-03T09:48  Skill  {'skill': 'review-for-merge'}
```

Claude は `~/.claude/projects/*/*.jsonl` の `tool_use: Skill`、Codex は
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` の `type: skill` と `SKILL.md` 読み込み、
Cursor は `~/.cursor/projects/**/agent-transcripts/**/*.jsonl` の `tool_use: Read` を使う。
Cursor の行には時刻が無いため、最終使用日は transcript の更新時刻で近似する。

**そしてこれが、リアルタイム点灯よりはるかに価値がある。** 実測:

```
インストール済みスキル 26 件 / 過去に使用実績のあるスキル 7 件
```

「今使われている」より**「入れたまま一度も使っていない」**の方が行動につながる。
1 章の散らかり検出（`ponytail` の 5 重複）と同じ問題の別の顔であり、
アプリを「入れる道具」から**「捨てる判断ができる道具」**に変える。

#### 集計結果はキャッシュしてよい（3.5 の例外）

3.5 で「スキャン結果をキャッシュしない」と決めたのは、
**現在の設定状態**がキャッシュとズレると管理アプリとして最悪だから。
一方**過去の使用実績は変化しない** — セッションログは追記のみで、
書き終わったファイルが後から変わることはない。キャッシュしても嘘にならない。

したがって:

- `registry.json` に Agent ごとの走査時刻 `scannedSources` と集計結果を持つ
- 2 回目以降は **mtime がそれより新しいログだけ**読む（増分スキャン）
- 実測では 3 Agent の全走査が **2.54 秒**、増分が **0.013 秒**
- 初回は複数 Agent のログ全体を読むため、**明示的な「使用状況を分析」ボタン**から
  バックグラウンドで実行し、進捗を出す。起動時には走らせない

#### やらないこと: hooks を仕込んでの通知

`PostToolUse` フックを登録すれば正確なリアルタイム通知が得られる
（`vibe-island-bridge` が実際にこの方式で動いている）。だが
**`~/.claude/settings.json` への書き込みが必要**で、3.1 の
「他人の設定ファイルを書き換えない」に真っ向から反する。**採らない。**
リアルタイム性が必要なのは MCP だけで、それはプロセス検出で足りている。

---

## 4. データモデル

### 4.1 registry.json

アプリが永続化する唯一のファイル。数 KB。
既存の `skills-registry.json` のスキーマを継承し、更新管理用のフィールドを足したもの。

```json
{
  "resources": [
    {
      "name": "ui-ux-pro-max",
      "kind": "skill",
      "repo": "nextlevelbuilder/ui-ux-pro-max-skill",
      "branch": "main",
      "subdir": "src/ui-ux-pro-max",
      "sha": "abc1234",
      "pinned": false
    }
  ],
  "repos": {
    "nextlevelbuilder/ui-ux-pro-max-skill#main": {
      "etag": "W/\"...\"",
      "latestSha": "def5678",
      "checkedAt": "2026-09-05T07:00:00Z"
    }
  },
  "agents": {
    "gemini": { "enabled": false },
    "codex":  { "path": "/opt/homebrew/bin/codex" }
  }
}
```

- `repo` / `branch` / `subdir` — 取得元。更新と再取得に必要な最小情報
- `sha` — 導入時のコミット。更新判定の基準
- `pinned` — 更新を止める。上流が方針転換した時に必要
- `agents` — エージェントごとの手動設定（3.7）。**利用者が決めたことだけ**を持ち、
  検出結果は入れない。既定値（有効・パス未指定）のエントリは書かない
- `repos` — **ETag と更新チェック結果は repo/branch 単位で持つ**。
  7.3 の「リポジトリ単位で束ねる」と対応する。リソースごとに持つと
  同一リポジトリ由来のスキル間で値が重複・不整合になる

**MCP と Plugin はここに載せない。** 実体の所在は各エージェントが持っており、
アプリが二重に記録すると必ずズレる。

#### `~/.agents/.skill-lock.json` との関係（確定）

3.2 で実体の置き場を `~/.agents/skills/` にしたため、既存の
`~/.agents/.skill-lock.json`（`vercel-labs/skills` が使用）と同じ場所を共有する。
スキーマはほぼ同型:

```json
"find-skills": {
  "source": "vercel-labs/skills", "sourceType": "github",
  "sourceUrl": "https://github.com/vercel-labs/skills.git",
  "skillPath": "skills/find-skills/SKILL.md",
  "skillFolderHash": "c2f31172...", "installedAt": "...", "updatedAt": "..."
}
```

**自前の `registry.json` を持ち、`.skill-lock.json` は読み取り専用で参照する。**
3.1「他人の設定ファイルを書き換えない」と同じ理由。他社がスキーマを変えても壊れず、
書き込み競合も起きず、`pinned` のような自前フィールドを置く場所も確保できる。

`.skill-lock.json` に載っていて `registry.json` に無いスキルは
**「外部管理」として一覧に表示し、変更操作は出さない**（4.2 / 5.2 / 9 章）。
表示しないと「あるはずのスキルが一覧に無い」状態になり、ユーザーが重複追加する。

### 4.2 メモリ上のモデル

```swift
enum Agent  { case claude, cursor, codex, gemini }
enum Kind   { case mcp, skill, subagent, plugin }
enum State  {
    case absent        // 未導入
    case inherited     // ユーザー全体から継承（プロジェクトスコープ表示時）
    case explicit      // このスコープで明示的に導入
    case external      // 他ツールが管理。表示のみ・操作不可（9 章）
    case undetected    // エージェント自体が未検出。Agent の検出状態から導出（3.7）
    case unsupported   // そのエージェントにこのリソース種別が無い
}

struct Resource {
    let name: String
    let kind: Kind
    let summary: String            // frontmatter の description / MCP のコマンド
    var state: [Agent: State]
}
```

---

## 5. スコープ

### 5.1 実態

| リソース | ユーザー全体 | プロジェクト（git 共有） | ローカル（gitignore） |
|---|---|---|---|
| MCP | `~/.claude.json` | `<proj>/.mcp.json` | `~/.claude.json` の projects 配下 |
| Skills | `~/.claude/skills/` | `<proj>/.claude/skills/` および `<proj>/<sub>/.claude/skills/` | — |
| Subagents | `~/.claude/agents/` | `<proj>/.claude/agents/` | — |
| Plugins | `installed_plugins.json` scope: `user` | — | scope: `local` + `projectPath` |
| Permissions | `~/.claude/settings.json` | `<proj>/.claude/settings.json` | `settings.local.json`（実際はここに集中） |

**プロジェクトの一覧は `~/.claude.json` の `projects` キーから取る**（`ProjectScan.projectPaths`）。
パスが動的で静的列挙にできない、3.4 の唯一の例外。読むのは各プロジェクトの
`.claude/skills` / `.claude/agents` / `.mcp.json` / `.claude/settings*.json` **だけ**で、
`~/.claude/projects/`（140 MB のセッションログ）とは別物。

#### スキルはサブディレクトリの `.claude/skills` も読む

Claude Code はプロジェクト直下だけでなく、作業ディレクトリ下のサブディレクトリの
`.claude/skills` も読む（monorepo のパッケージが自前のスキルを持てる）。
直下しか見ないと、その分が画面から完全に消える。

3.4 のホワイトリストを広げるので、上限を固定で持つ（`ProjectScan.skillRoots`）:
**プロジェクト直下から 3 段まで**、隠しディレクトリと依存物の置き場
（`node_modules` / `Pods` / `vendor` / `target` / `dist` / `build` / `out`）には降りない。
途中で読むのはディレクトリ名だけで、`.claude/skills` 以外は一切開かない。
実測（20 プロジェクト）: 訪問 614 ディレクトリ / 72 ms。9 章の起動 300 ms 以内に収まる。

同名が競合したときだけ Claude は修飾名 `apps/web:deploy` を使い、競合が無ければ
`/deploy` で呼べる。**表示もこれに合わせる** — 勝手に修飾すると呼び出し名を偽ることになる。
削除コマンドと `WriteGuard` の許可ルートも同じ集合から作る。片方だけルート直下に
絞ると、一覧には出るのに削除だけ「保護対象」と嘘をつく行ができる。

親ディレクトリ側（プロジェクトより上）は読まない。ホワイトリストの外になる。

**Subagent は対象外。** `<proj>/<sub>/.claude/agents` を読むかは未実測で、
3.7 の「推測で埋めない」に倣う。

実測（19 プロジェクト）: 4 プロジェクトに `.claude/skills` が 15 件、
1 プロジェクトに `.claude/agents` が 3 件、1 プロジェクトに project スコープの MCP。
**これらは v1 では 1 件も画面に出ていなかった** — ユーザースコープしか走査していなかったため。

### 5.2 UI

タブでもツリーでもなく、**ウィンドウ上部のスコープセレクタ 1 つ**で切り替える。
CSS の cascade と同じ見え方にする。

```
┌─ スコープ: [ ユーザー全体 ▾ ] ────────────────── [+ 追加] ─┐
│                                                             │
│  リソース                    Claude  Cursor  Codex  Gemini  │
│  ─────────────────────────────────────────────────────────  │
│  chrome-devtools      MCP      ●       ●       ○      ○     │
│  ponytail          Plugin      ●       ●       ●      —     │
│  codiff             Skill      ●       ○       ○      —     │
│  review-bugbot   Subagent      ○       ●       —      —     │
└─────────────────────────────────────────────────────────────┘
      ● 有効   ○ 未導入   — 非対応
```

プロジェクトを選ぶと、継承が薄く表示される:

```
┌─ スコープ: [ Free-Projects/reborn ▾ ] ──────────────────────┐
│                                                             │
│  chrome-devtools      MCP      ◐       ◐       ○      ○     │
│  ponytail          Plugin      ●       —       —      —     │
│     ⚠ 同じ v4.9.0 が他 4 プロジェクトにも個別導入されています  │
│        [ ユーザー全体に昇格して 5 件を統合 ]                  │
└─────────────────────────────────────────────────────────────┘
      ◐ ユーザー全体から継承   ● このスコープで明示
```

セルは 3 状態（未導入 / 継承 / 明示）。

**ただし Skills のセルは表示専用。** 3.2 の通り Cursor / Codex は共有ルートを
直接読むため、エージェント別の on/off は存在しない。Skills の有効/無効は
行単位の一括操作にする。クリックで昇格・降格できるのは
エージェント別に実体を持つリソース（MCP / Plugins）のみ。

**プロジェクトスコープは v1 では読み取り表示のみ（確定）。**
`<proj>/.claude/skills/` への symlink は `~/` 配下を指す絶対パスが
git 共有で他マシン・他メンバーの環境を壊すため、ユーザースコープと同じ方式が使えない。
継承表示と重複警告（散らかり検出）は読み取りだけで成立するので v1 の価値は保てる。
プロジェクトスコープへの書き込み（実体コピー方式）は需要を見てから。

> **v2.6 で 8 章の「エージェントごとに 1 画面」に置き換えた。**\n> ここの横断マトリクスは、初心者が最初に見る画面としては情報が多すぎた。\n> 状態の定義（3 状態・非対応と未検出の区別）はそのまま各画面で使っている。\n\n**散らかりの検出と統合提案が、このアプリ最大の見せ場**になる。
`ponytail` が 5 プロジェクトに同一バージョンで重複しているのは、
まさにこのビューが無いから起きている。

### 5.3 使用実績の列（3.9）

「入れたまま使っていない」を可視化する列を足す。実測で
**インストール済み 26 件に対し使用実績があるのは 7 件**だった。

```
  リソース              最終使用      Claude Cursor Codex Gemini
  ────────────────────────────────────────────────────────────
  review-for-merge      2 日前          ●      ○     ○     —
  chrome-devtools  MCP  ● 実行中        ○      ●     ○     ○
                        （Cursor が使用中・2h06m）
  webview-ui            1 か月前        ●      ○     ○     —
  supabase-postgres     未使用          ●      ○     ○     —
                        ⚠ 導入から 3 か月・使用実績なし  [削除]
```

- **MCP は実行中プロセスを検出して光らせる**（3.9）。他は最終使用日
- 「未使用」に削除導線を置く。**このアプリを「入れる道具」から
  「捨てる判断ができる道具」に変える**のがこの列の役目

**この列は 4 つの状態を持ち、1 つも混ぜてはいけない**（3.7 の
「未検出と非対応を混ぜない」と同じ原則）:

| 表示 | 意味 |
|---|---|
| `● 実行中`（緑） | **MCP のみ。** プロセスが生きている。所属エージェントと稼働時間を tooltip に出す |
| `停止中` | **MCP のみ。** 登録されているがプロセスが無い |
| `—`（淡） | **未集計**。まだ「使用状況を分析」を押していない |
| `─` | **観測範囲外**。使用ログを読めない Agent にしか存在しない |
| `未使用`（橙） | 集計した範囲で一度も使われていない。**削除の候補** |
| `2 日前` | 最終使用日 |

MCP は最終使用日より**実行状態を優先**する。3.9 の通り MCP だけが
「今この瞬間の状態」を持ち、そちらの方が情報量が多い。

**「観測範囲外」を「未使用」と出すと嘘になる。** ログ対応前には実際にこれが起き、
Cursor 専用スキルが全部「未使用」と表示された。現在は Claude / Codex / Cursor を観測する。

---

## 6. 追加フロー

入力欄は **1 つだけ**。ペーストされた文字列を見て分岐する。

| 入力 | 解釈 |
|---|---|
| `{"mcpServers": {...}}` | MCP。公式サイトの JSON をそのままコピペできる（最頻の導線） |
| `https://github.com/owner/repo/tree/main/skills/foo` | `repo` / `branch` / `subdir` に分解して zip 取得 → 中身で種別判定 |
| `https://skills.sh/owner/repo/skill` | カタログページ。`owner/repo` だけ採る（下記） |
| `npx -y foo-mcp` などのコマンド行 | MCP のコマンドとして解釈 |

種別判定は取得した中身を見る: `SKILL.md` があれば Skill、
`.claude-plugin/plugin.json` があれば Plugin、frontmatter に `tools:` があれば Subagent。
**Plugin と Skill は排他ではない** — marketplace を兼ねたリポジトリは両方を持つので、
どちらかで打ち切らず併記して確認画面で選ばせる。

リポジトリ直下を貼られた場合、スキルは何段か下に並んでいる。`skills/<name>`
（vercel-labs/skills）だけでなく `skills/<category>/<name>`（mattpocock/skills）もあるので
**3 段までたどる**。Subagent の判定は指されたディレクトリ直下だけで行う —
下層の `.md` まで frontmatter を読むと、ただの文書が候補に混ざる。

skills.sh のようなカタログは配布元ではない。実体は GitHub にあるので `owner/repo` に翻訳する。
`skills.sh/<owner>/<repo>/<skill>` の 3 番目は**ディレクトリ名であってパスではない**
（`grilling` の実体は `skills/productivity/grilling`）ため subdir にはできず、
候補一覧の初期絞り込みにだけ使う。ページの HTML から GitHub リンクを拾う方法は採らない —
ページ構造の変更で静かに壊れるうえ、取得物の中身以外から推測しない方針に反する。

**自動では入れない。** README からのコマンド抽出は必ず外すため、勝手にインストールすると
初心者ほど詰む。

```
解釈結果 → 確認画面（編集可能）→ 導入先エージェントを選択 → 追加
```

### ブラウザで開いたページから追加する（既定 ON）

URL を手で貼らずに済ませる導線。**既定は ON** — メニューバー常駐が既定になり、
この検知がアプリの主機能になったため。ブラウザ制御の許可（TCC）は最初に既知ブラウザが
前面へ来たときに求め、拒否されたら設定を OFF に戻す（ON なのに動かない状態を残さない）。

**システム通知は使わない。** 見つけたものは**メニューバーアイコンを緑にして**知らせ、
ウィンドウを開いていれば上部の帯にも出す。通知にすると許可がもう 1 つ増え
（デバッグビルドのように登録されていないバンドルではそもそも下りない）、
消し方も利用者に委ねることになる。**ノード 1 つだけ緑にするのでは 18pt では気づけない**
（実機で確認）ので、図案ごと色を変える。

緑が戻る条件は 3 つ: 「追加する」・「今はしない」・**そのページから離れたとき**。
離れて戻ったらまた緑にする（自分で消したわけではないので `seen` から外す）。
ブラウザが前面でない間は消さない — URL が読めないだけで、
メニューを触っている最中かもしれない。

アイコンは**アプリアイコンと同じ図案**（ハブ＋斜め 4 方向のノード）を 18pt で描き直す。
SF Symbol に寄せると「1 つの GUI から 4 エージェントを束ねる」という図が崩れる。

**`MenuBarExtra` のラベルはまるごとテンプレートとして描かれる**（実機で確認）。
`Circle().fill(.green)` を重ねても単色に潰れるので、検知中だけ
`isTemplate = false` の画像 +`.renderingMode(.original)` に差し替える。
通常時はテンプレートのままにして、明暗の追従とメニュー選択中の反転を OS に任せる。

**件数は出さない。** 出せるのは常に最新の 1 件で、ノード 1 つで足りる。

```
ブラウザが前面 → 3〜15秒ごとに前面タブのURL → パス名で候補 → rawで実在を確認 → メニューバーが緑に
                                                                    ↓「追加する」
                                              取得済みの確認画面（上と同じ AddSheet）
```

| 段 | やること | 代償 |
|---|---|---|
| 前面監視 | `NSWorkspace` で前面アプリを見て、既知ブラウザのときだけタイマーを回す。同じページに留まっている間は 15 秒へ落とす | 3.5 の例外（常駐が前提） |
| URL 取得 | 事前コンパイルした `NSAppleScript` を使い回す（`osascript` のプロセス起動をしない） | ブラウザごとの TCC 許可 |
| 候補にする | パス名だけで判定。`skills.sh/<owner>/<repo>/<skill>`、`/skills/`、`/plugins/`・`/.claude-plugin/`、`/agents/` | ネットワーク不要 |
| 確定する | `raw.githubusercontent.com` へ HEAD（`SKILL.md` / `plugin.json` / `marketplace.json` / 指定された `.md`）。**どれか 200 なら本物**、404・通信失敗は黙る | 実測 0.2 秒。GitHub API の 60 req/h 枠は使わない |
| 見せる | メニューバーのアイコンが緑になる。開くと「スキル『名前』を見つけました」＋［追加する］［今はしない］ | 通知の許可を求めない |

**MCP は URL からは拾わない。** リポジトリ URL に手がかりが無く、公式サイトの JSON を
コピペする既存導線の方が確実。**Subagent はファイルを指す URL だけ** — ディレクトリを
指されても中のファイル名が分からず、実在を確かめられない。
カタログのリポジトリページ（`skills.sh/<owner>/<repo>`）も拾わない — 名前が決まらない。

**取得した URL は保存しない。** 対象ホストかどうかを見たら捨てる。ログにも出さない。
重複抑止は起動中のメモリ（`Set<String>`）だけで、`registry.json` には残さない。
併せて**既に導入済みのものは通知しない**（`Registry.resources` の repo / subdir / 名前と照合）。
**subdir が両方 nil のときは一致とみなさない** — カタログ URL は subdir を持たないので、
nil 同士を突き合わせると「同じリポジトリの別スキル」まで導入済み扱いになる
（`mattpocock/skills` の `grilling` を入れると `grill-me` が出なくなっていた）。
これが一番うるさい誤検知を消す。

`skills.sh` には `/about` や `/agent/claude-code` といった**予約パス**があり、
これを `owner/repo` と読むと存在しないリポジトリを取得しに行く。除外は
`GitHubURL.catalog` に置き、検知と手貼りの両方に効かせる。

---

## 7. 更新フロー

### 7.1 リソースごとの実態

| リソース | 更新 | 検知 | 適用 |
|---|---|---|---|
| **Plugins (Claude)** | ✅ | `claude plugin list` | `claude plugin update <name>` |
| **Plugins (Codex)** | △ | `codex plugin list` | `remove` + `add` |
| **Skills** | ✅ | GitHub commit SHA 比較 | zip 再取得 |
| **Subagents** | ✅ | 同上 | 同上 |
| **MCP** | ❌ | — | — |

### 7.2 MCP に更新機能を作らない

実際に登録されている MCP はこの形:

```json
"chrome-devtools": { "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest"] }
```

`npx` が起動のたびに npm から最新を取るため、アプリが更新する余地が無い。
「更新」ボタンを置いても押すと何も起きない偽ボタンになる。

**MCP に必要なのは更新機能ではなくピン留め管理。**

```
chrome-devtools   MCP   @latest（起動ごとに最新を取得）
                        ⚠ サイレントに壊れる可能性  [1.4.2 にピン留め]
```

ピン留めされている場合だけ npm registry と比較して新バージョンを通知できる。

### 7.3 GitHub API のコスト制約

未認証で **60 リクエスト/時**（実測 `x-ratelimit-limit: 60`）。素朴に作ると詰む。

1. **リポジトリ単位で束ねる** — `GET /repos/{repo}/commits/{branch}` 1 回で、
   同一リポジトリ由来の全スキルを判定できる
2. **ETag を保存し `If-None-Match` を付ける** — 変化なしなら 304 が返る。
   **⚠️ 実測では 304 もレート制限を消費する**（残り 43 → 42 → 41 → 40）。
   GitHub の従来のドキュメント記載と異なるので、304 を当てにした設計にはしない。
   ETag の利点は本文が転送されないこと（帯域）と「変化なし」が確実に分かることで、
   **レート制限を守っているのは 1 と 3**
3. **起動時の自動チェックはしない** — 明示的な「更新を確認」ボタン + 1 日 1 回のスロットル。
   3.5 の「常駐しない」と整合する

### 7.4 更新は差分を見せてから適用する

Skills / Subagents の中身は**プロンプト**。黙って差し替えるとエージェントの挙動が変わり、
原因追跡が不可能になる。追加は簡単でよいが、**更新は diff を見せる**。

```
ui-ux-pro-max を更新    abc1234 → def5678（3 コミット）

  SKILL.md
  - Always use Tailwind v3 syntax
  + Always use Tailwind v4 syntax
                          [ 更新する ] [ このバージョンで固定 ]
```

適用手順は **一時ディレクトリに展開 → 検証 → 差し替え → 失敗ならロールバック**。
Cursor / Codex は `~/.agents/skills/` を直読みし Claude は symlink 越しに読むため、
**実体を差し替えるだけで 3 エージェントすべてに同時反映される**（3.2）。

### 7.5 Claude の自動更新と衝突させない

`known_marketplaces.json` の `ponytail` には **`autoUpdate: true`** が付いており、
Claude Code が既に自動更新している。ここにアプリが手を出すと二重管理になる。

→ `autoUpdate: true` のプラグインは「Claude Code が自動更新」と表示し、
更新ボタンを出さない。トグルで `autoUpdate` を切った時だけアプリが引き受ける。

### 7.6 一覧の見え方

```
📦 リソース                              [ 更新を確認 ]  [ すべて更新 ]
──────────────────────────────────────────────────────────────────
ui-ux-pro-max            Skill    ● 3 コミット新しい     [差分] [更新]
supabase-postgres-…      Skill    最新                        [固定]
web-design-guidelines    Skill    📌 固定中（2 コミット遅れ）
ponytail                 Plugin   Claude Code が自動更新
swift-lsp                Plugin   1.0.0 → 1.2.0            [更新]
chrome-devtools          MCP      @latest（常に最新）    [ピン留め]
```

---

## 8. 画面構成

**エージェントごとに 1 画面**にする。1 つの表に 4 エージェント × 4 種別を詰めると、
初心者は「自分の Claude に何が入っているのか」を読み取れない
（v1 は 5.2 のマトリクスで作ったが、実際に使うと横断ビューより先に
「このエージェントの中身」が知りたい、という順序だった）。

```
サイドバー              内容
────────────────────────────────────────────────────────────
🏠 ホーム               追加の入口（URL を貼る）・探す場所・検出状況
   Claude Code    3     このエージェントが持っているもの
   Cursor         2
   Codex          1
   Gemini CLI     未検出
🔒 権限                 permissions.allow の横断掃除
```

- **エージェントにアイコンを付けない（確定）。** 名前が既に一意なので、
  記号を足しても読み取れる情報は増えない。実物のアプリのアイコンを
  `NSWorkspace` から引いていた時期があるが、入っているアプリしだいで
  4 行のうち 2 行だけ色付きになり、揃わない列になっていた
- サイドバーの数字は**ユーザー自身が入れたものの件数**（同梱のものは数えない）
- 未検出のエージェントも消さずに薄く出す（3.7 —「設定のみで既存リソースを隠さない」）

### 8.1 見た目の語彙（`Theme` / `Motion`）

**画面をまたいで揃うべき数値は `Sources/ManageArms/Theme.swift` に置き、各画面はそこから引く。**
カードの角丸や節の間隔が画面ごとに 14 と 16 で混ざると、リッチではなく雑に見える。
（部品の内側の詰めまで縛らない。縛ると `Theme.pad - 4` のような式が並んで、かえって読めなくなる）

| | 中身 | 使うところ |
|---|---|---|
| 間隔 | 4 / 8 / 16 / 24 の 4 段だけ | 中間の値が要ると感じたら、たいてい階層の作り方が間違っている |
| 角丸 | 6（小物: チップ・入力欄）/ 10（カード） | システムのボタン・テキストフィールドに合わせる |
| `Theme.glyph` | 行頭アイコンの列幅 20 | **全画面で同じ値。** 行が何行になっても本文の左端が縦に揃う |
| `card()` | 罫線で囲うだけ（影なし） | ホーム・エージェントカード・候補行 |
| `Pill` / `StatusDot` / `StatTile` | 件数・状態・要約の共通部品 | 同じ意味を 3 通りの見た目で出さない |
| `WrapLayout` | 折り返す横並び | 件数が環境しだいで増えるチップ（実測 18 件） |

**階層は「余白 → 文字の太さ → 罫線」の順に作る。** グラデーション・ドロップシャドウ・
種別ごとの色分けは持たない。装飾で情報を作ろうとすると、
どの macOS アプリにも似ていない画面になる（デモとしては派手だが、毎日使うと疲れる）。

**色は意味があるときだけ使う** — 緑=稼働 / 橙=注意 / 赤=破壊 / アクセント=選択と主要ボタン。
無彩色にしたものと、その理由:

- **種別のアイコン**（`KindIcon`）— 色付きの角丸タイルを 1 行ごとに並べると、
  一覧が模様になって、名前より先にアイコンが目に入る
- **`permissions` の `allow`** — 大多数なので、色を付けるのは少数派の `deny` / `ask` だけ。
  全行が緑だと、意味が正反対の 2 件が緑の中に埋もれる
- **絞り込みが既に言っていること** — 「使い捨て」表示で全行に「マシン固有」の橙を出さない。
  一覧が橙に染まると、印として機能しなくなる

**動きは `Motion` 経由でしか書かない。** `Motion.pop` / `gentle` / `count` は
`Animation?` を返し、**「動きを減らす」（`accessibilityDisplayShouldReduceMotion`）が
入っている環境では `nil` を返して静止する**。アクセシビリティは削らない（CLAUDE.md）。

動かすのは、**状態が実際に変わったところだけ**:

- スコープのチップ — 選択中の下敷きだけが `matchedGeometryEffect` で移動する。
  全体をフェードさせるより「どこからどこへ移ったか」が分かる
- 件数 — `contentTransition(.numericText())`。再読み込みで数字が変わったことに気づける
- 実行中の MCP — 脈打つ点（`RunningDot`）。**一覧の中で本当に「今」を表すのはこれだけ**
  なので、点滅する要素をこれ以外に増やさない（3.9）
- 読み込み中 — 上端の 2px の帯（`BusyBar`）。中央にスピナーを出して一覧を隠さない

### ホーム

追加導線を最初に置く。**「どうやって入れるのか」が分からない、が最大の詰まり所**だった。

```
スキル・サブエージェントを追加する
  使いたいスキルの GitHub ページを開き、その URL をそのまま貼り付けてください。
  [ https://github.com/owner/repo/tree/main/skills/foo ] [追加]
  探す: anthropics/skills · github.com/topics/claude-skills
  中身を確認するまで何も入りません

  MCP 1 │ スキル 10 │ サブエージェント 3 │ プラグイン 4
  ⚠ 読み込めないものが 2 件あります（異常なときだけ出る）

エージェント
  Claude Code   2.1.236  /opt/homebrew/bin/claude   15  [検出済み] › (ON )
  Cursor        ~/.cursor（CLI なし・設定を直接読む）  1  [検出済み] › (ON )
  Gemini CLI    インストールするか、CLI のパスを指定してください  [未検出]  ( OFF)
  ⊕ CLI のパスを指定…
  検出できたエージェントは自動で並びます。オフにしたものは一覧から外れるだけです。
```

**貼る URL の入手先は、貼る場所と同じ箱に置く。** 「どこで見つける？」を独立した節に
切り出すと、追加の話なのに追加導線から離れる。脚注 1 行で足りる。

**ホームに置かないもの**（一度置いて外した）:

- **入れたものの名前を並べたチップの壁** — 押せないので眺めるだけになる。同じ一覧は
  各エージェント画面にあり、そちらでは切り替えと削除ができる。件数が環境しだいで
  増える（実測 18）ため、環境が育つほどホームが壊れていく。要るのは規模（件数）と、
  異常があるという事実だけ
- **エージェント 1 つにつき 1 枚のカード** — 4 行の表と同じ情報に 4 倍の縁が付く。
  囲みは 1 枚にして、行の中で名前・状態・バージョン・件数を横に並べる

**Cursor は CLI が無い**（`cursor-agent` は存在しない）ので、空欄にせず理由を書く。
CLI が無いこと自体は異常ではないので「未検出」とは表示しない（3.7 の 5 状態）。

**手動の操作はこの 1 枚に閉じる**（3.7「保存するのは利用者が決めたことだけ」）。
右端のスイッチで管理対象から外し、下端の 1 か所で `PATH` に無い CLI のパスを教える。

- **スイッチは行のボタンの外に出す。** 中に入れると、切り替えたつもりが画面遷移になる
- **「CLI のパスを指定…」は行ごとに置かず、一覧の下に 1 つだけ置く**。
  行ごとのボタンは 4 行ぶんの飾りになり、普段は誰も押さない
- **「新しいエージェントを自動設定」のスイッチは作らない。** 常に自動検出する（3.5）ので、
  オフにできる意味が無い

### エージェント 1 つ分の画面

```
Claude Code
  スキル
    codiff          2 日前          [有効 ●] [🗑]
    webview-ui      1 か月前        [有効 ●] [🗑]
    supabase-doc    一度も使っていません  [無効 ○] [🗑]
  サブエージェント
    review-bugbot   使用状況は不明   [有効 ●] [🗑]

  ▸ ほかのツールが入れたもの 18 件
     これらは各 CLI や他のツールが管理しています。追加・削除できません。
```

- 畳む基準は「操作できるか」ではなく**「自分で入れたか」**。
  registry.json に無くても、`claude plugin install` で入れた `ponytail@ponytail` は
  ユーザーのものであって、Cursor 同梱の `automate` とは別物
  （`ResourceRow.Origin` — 実装当初は `isManaged` で畳んで、
  **自分で入れたものが「ほかのツールが入れたもの」に埋もれた**）
- 操作できないものも同じ行の形で出し、代わりに**どこで管理されているかを書く** —
  「消せない」と「消し方が分からない」を同じ見た目にしない
- **例外は MCP のピン留め**（7.2）: 消せはしないが `@latest` の固定はできるので操作を出す
- **リンク切れ・SKILL.md 欠落は誰からも見えないが、置き場のあるエージェントに出す**
  （`ResourceRow.roots` / `isUnusable`）。`state` だけで絞ると、
  掃除すべきゴミが画面から消える（実測: `~/.claude/skills/codiff` は
  アンインストール済みアプリを指したまま残っていた）
- 無効化中のものは**どのエージェントからも見えない**が、管理対象なら一覧に残す。
  ここで落とすと再有効化する導線が消える（`Inventory.rows(for:)`）
- 非活性セルの理由は tooltip に出す — 「Codex CLI が見つかりません」/
  「Gemini CLI に Skills はありません」。**この 2 つを同じ文言にしない**

### 出どころの 3 分類

`ResourceRow.Origin`。**「自分で入れたもの」と「最初から入っていたもの」を混ぜない。**

| | 意味 | 画面での扱い |
|---|---|---|
| `managed` | registry.json にある = このアプリで入れた | 切り替え・削除ができる |
| `user` | 自分で入れたが経路が違う（`claude plugin install` / 他アプリ同梱 / MCP 設定） | 一覧に並べ、管理元（`claude plugin` など）を書く |
| `bundled` | エージェント同梱（`~/.cursor/skills-cursor` の automate 等 24 件） | 折りたたむ |

判定は `Inventory.origin`（純粋関数・テスト済み）。同梱ルートは
`Agent.bundledSkillRoots` の 2 つだけで、**同名のものが自分の置き場にもあれば
それは自分のもの**とする。MCP は設定を書いたのがユーザー自身なので常に `user`。

Plugin だけは例外がある。**Codex は自社の既定プラグインを CLI が返す一覧に混ぜてくる**
（`openai-curated-remote` の `plugin-management` / `openai-templates` /
`deep-research-work`）。見分けるのは推測ではなく CLI が返すメタデータで、
`installPolicy: INSTALLED_BY_DEFAULT` が付く（実測）。これを `bundled` として扱う —
ユーザー全体に「削除」付きで並べると、自分で入れた分が埋もれるうえ、
消してもエージェントが入れ直すものに削除ボタンを出すことになる
（`codex plugin remove` は成功を返すが消えないことを実測で確認）。

#### 既定判定の裏取り（2026-09-06 実測）

| 種別 | エージェント | 根拠 | 実測 |
|---|---|---|---|
| Skill | Cursor | `~/.cursor/skills-cursor` | ✅ 24 件 |
| Skill | Cursor | `~/.cursor/cloud-skills` | このマシンには未生成 |
| Skill | Codex | `~/.codex/skills/.system` | ✅ 6 件（`imagegen` / `openai-docs` / `plugin-creator` / `review-agent` / `skill-creator` / `skill-installer`） |
| Skill | Claude | — | 同梱スキル（`/doctor` `/code-review` 等）は CLI の中にあり、走査ルートに現れない |
| Subagent | 全部 | — | `Explore` / `Plan` / `general-purpose` は CLI 内蔵。`~/.claude/agents` は空 |
| Plugin | Codex | `installPolicy: INSTALLED_BY_DEFAULT` | ✅ 3 件 |
| Plugin | Claude | `isBuiltIn` / `managed` / `scope: managed` | ⚠️ **未観測**（実際の出力にこれらのキーは無い） |
| MCP | 全部 | `isBuiltIn` / `managed` | ⚠️ **未観測**（このマシンに MCP 登録は 0 件） |

**⚠️ の 2 つは、印の名前を当てにいっている状態。** 名前を増やしても同じことが繰り返される
（`installPolicy` を知らなかったのがまさにそれ）。そこで**判定を厚くするのではなく、
効果を確かめる**方に寄せる: Plugin と MCP の削除は CLI の終了コードを信用せず、
実行後にもう一度読んで消えたことを確認し、残っていればエラーにする
（`PluginManager.remove` / `MCPManager.remove` / `MCPManager.removeProject`）。
どの CLI がどんな印を新しく付けても、「消えない削除」だけは必ず表に出る。
`bundled` の分類は引き続き**実測した印だけ**で行い、語感で推測しない。

**確認は「残っていると読めたとき」だけ失敗にする。** 読めなかったのを失敗と混ぜると、
`MCPPin.pin`（remove → add）が復元前に中断して設定が消えたままになる。
プロジェクト側は `byProject` が project と local を 1 つの表に畳むので、
名前の有無ではなく**消したスコープが残っているか**で見る
（同名が両方にあると、片方を消しただけで「消えていない」と誤判定する）。

### スコープの見せ方（5.1）— タブで 1 つずつ

**1 つの表にユーザー全体とプロジェクトを混ぜない。** 混ぜると
「これはどこで効いているのか」を毎行バッジで読み解く羽目になる。
縦に積んでも今度はスクロールで迷うので、**タブにして同時に見せるのは 1 つだけ**にする。

```
Claude Code
[ 👤 ユーザー全体 3 ][ 📁 auto-free 1 ][ 📁 dangarous-map 4 ][ 📁 reborn 4 ][ 📦 同梱 24 ]
どのプロジェクトでも使えます。
──────────────────────────────────────────────
スキル 1
  codiff   ⚠ 読み込めません
プラグイン 2
  ponytail@ponytail  v4.9.0
    ‼ 3 プロジェクトにも個別に入っています
       auto-free · reborn · terminal-for-ai-cli
```

- タブは **ユーザー全体 / プロジェクトごと / エージェント同梱**（`Inventory.scoped(for:)`）
- **プロジェクトの数は環境しだいで増える**（実測 19）ので、固定幅のセグメントではなく
  横スクロールのチップにする。プロジェクトのタブでは `Finder で開く` を添える
- タブの中は種別（MCP / スキル / サブエージェント / プラグイン）でまとめ、件数を出す
- **`both`（両方に入っている）は両方のタブに出す。** それが二重に入っている事実そのもの。
  ユーザー全体側には「N プロジェクトにも個別に入っています」、
  プロジェクト側には「ユーザー全体にもあります。こちら側は消せます」と、
  **同じ状態でも読み手の位置で書き分ける**
- 行ごとのスコープバッジは**やめた**。タブが既に言っているので、
  行に残すのは重複しているときの警告だけ

プロジェクトにしか無いものは `state` に出てこないので**行ごと作る**
（`ProjectScan.onlyRows`）。見えるのは Claude だけとする —
`<proj>/.claude/` を他エージェントが読むかは未実測で、
3.7 の「非対応と未検出を混ぜない」に倣って推測で埋めない。

### 行の見分け

1 件が「名前 / 説明 2 行 / 使用実績 / 管理元 / 警告」と縦に伸びるので、
**素の一覧だと 1 枚の壁に見える**（実際にそう報告された）。

- 行の頭に**種別の色付きアイコン**を置く。どこで 1 件が始まるかの目印
- 区切りは `listRowSeparator(.visible)` で OS のものを使う。**縞
  （`alternatingRowBackgrounds()`）は入れない** — 中身の無い下部まで縞が伸びて
  「まだ何かある」ように見えた。行頭のアイコンとホバーの反転で境目は足りている
- 補足は**できるだけ 1 行に畳む**（使用実績・更新・管理元を横に並べる）。
  独立した行にしてよいのは警告だけ

### プロジェクトからの一括削除

5.2 の「統合提案」の実装。プロジェクトのタブから
`このプロジェクトの N 件を削除…`、ユーザー全体のタブで重複している行から
`プロジェクト側 N 件を削除…` で確認シートを開く。

**シートには実行するコマンドをそのまま並べる。** 何が消えるか分からないボタンを作らない。
実行は `sh -c` に**表示したのと同じ文字列**を渡す（画面と実行を食い違わせない）。

| 対象 | 扱い |
|---|---|
| Plugin（`-s local`） | **実行する。** `installed_plugins.json` は CLI の管理物（3.1） |
| MCP の `local` スコープ | **実行する。** 実体は `~/.claude.json` |
| MCP の `project` スコープ | **実行しない。** `<proj>/.mcp.json` は git 共有のファイル |
| Skill / Subagent | **実行しない。** `<proj>/.claude/skills/` はリポジトリの中 |

**ユーザーのリポジトリには書かない**（5.2 の「プロジェクトスコープは読み取り表示のみ」）。
消えたことに気づくのは別のマシンや他のメンバーで、git の履歴にも出る。
実行しない分は**コマンドをまとめてコピー**できるようにして、判断を人に残す。
判定は `ResourceRow.isRemovalExecutable`（純粋関数・テスト済み）。

### 「消せないもの」の消し方を出す

registry.json に無いものは `WriteGuard` が弾く（9 章）。**そこで終わりにしない。**
行の `削除するには…` から、実在を確認したコマンドだけを出してコピーさせる:

| 種別 | ユーザー全体のタブ | プロジェクトのタブ |
|---|---|---|
| Plugin | `<cli> plugin remove <id> -s user` | `cd '<proj>' && <cli> plugin remove <id> -s local` |
| MCP | `<cli> mcp remove <name> -s user`。**Cursor は CLI が無いので `~/.cursor/mcp.json`** | `cd '<proj>' && <cli> mcp remove <name> -s <project\|local>` |
| Skill / Subagent | `rm -rf ~/.agents/skills/<name>` | `rm -rf '<proj>/.claude/skills/<name>'` |
| 同梱 | **コマンドを出さない。** 消してもエージェントの更新で戻る | — |

**スコープを既定に任せない。** `claude plugin remove` の既定は `-s user` なので、
プロジェクトのタブでそのまま出すと**ユーザー全体の分が消える**（実際にそう出していた）。
MCP の `-s` は走査で分かった実際のスコープを載せる
（`<proj>/.mcp.json` は `project`、`~/.claude.json` の projects 配下は `local`）。
パスは空白を含みうるのでクォートする。組み立ては
`ResourceRow.removalCommand`（純粋関数・テスト済み）。

**`<cli>` はその画面のエージェントのもの。** ここを `claude` で固定すると、
Cursor の MCP に `claude mcp remove chrome-devtools` を出すことになり、
消えないうえに**別のエージェントの同名サーバーを消しうる**（実際にそう出していた）。
行の「管理元」表示も同じ理由でエージェントごとに書く。

**コマンドをでっち上げない。** 存在しないサブコマンドを出すと、
初心者はエラーの原因を自分の操作だと思う。

### 自分で入れたものの削除

取り込み（adopt）は**廃止した**。registry に載せてから消す、という
遠回りをしなくても、ユーザーが自分で入れた Skill / Subagent は
そのまま 1 件ずつゴミ箱へ移せる（15 章）。

| 状態 | 扱い |
|---|---|
| 実体が既知の配置ルートの直下にある | **削除できる。** パスを 1 つ選ばせ、`WriteGuard.assertUserArtifact` で検証してゴミ箱へ移す |
| エージェント同梱（`Agent.bundledSkillRoots` / `.codex/skills/.system`） | 削除しない。`同梱・変更不可` を出す |
| Plugin 配下・リンクの向き先 | 削除しない。**リンクは外すが、その先の実体には触らない** |
| MCP / Plugin | ファイルを消さず、各 CLI の削除コマンドに委譲する（3.1） |

**完全削除しない。** `trashItem` でゴミ箱へ移すので Finder から戻せる。
プロジェクト配下のファイルは git で共有されるので、確認ダイアログで
「他のメンバーや別のマシンにも影響する」ことを明示する。
まとめて消す一括削除シートは従来どおり**コマンドを見せるだけ**
（`ResourceRow.isRemovalExecutable`、5.2）。

### 削除

無効化（実体を退避）とは別に、**削除**を置く。7 章までの導線は「入れる」と
「更新する」しかなく、**入れたものを捨てる手段が無かった**（5.3 の
「捨てる判断ができる道具にする」に対して、判断だけできて実行できない状態）。

- 実体は `FileManager.trashItem` で**ゴミ箱へ移す**。完全削除しない —
  初心者が誤って消しても Finder から戻せる
- symlink は `removeItem`（リンク切れをゴミ箱に残しても意味が無い）
- 通るのは `WriteGuard` の経路だけ。registry.json に無いものは削除できない（9 章）
- 確認ダイアログを必ず挟み、「ゴミ箱へ移動します」と明記する

### 権限画面

各プロジェクトの `settings.local.json` に `permissions.allow` が蓄積している。
実測（11 プロジェクト）:

```
371 件の allow
  ├ マシン固有（使い捨て候補） 22 件
  │   Bash(git -C /Users/…/secondary-simulator log --oneline -15)
  └ 複数プロジェクトに重複     31 種類 / 75 件
      7× WebSearch    7× WebFetch(domain:github.com)
```

3 つのフィルタで絞り、チェックして一括削除する。

| フィルタ | 中身 |
|---|---|
| **使い捨て** | `env.home` の絶対パスを含む = 他のマシンでも他のプロジェクトでも使えない |
| **重複** | 複数プロジェクトに同じエントリ。5.2 の散らかり検出と同じ問題 |
| すべて | 371 件 |

**判定は `/Users/` のハードコードではなく `env.home` 基準。**
そうしないとテストが実ユーザーのパスに依存する（3.8）。

#### 9 章のホワイトリストの唯一の例外

`WriteGuard` は**削除・移動**を守るもので、ここは「ファイルの中の 1 キーを
書き換える」別の操作。`PermissionWriter` に専用のガードを置き、
次を全部満たす時だけ通す:

1. ファイル名が `settings.json` / `settings.local.json` に**完全一致**する
2. 場所が `.claude` ディレクトリの**直下**である（`..` で抜けられない）
3. 操作が `permissions.<bucket>` の配列からの**削除**である

**`permissions` 以外のキーには一切触らない。** 実測で `enabledPlugins` /
`hooks` / `extraKnownMarketplaces` が同居しており、消すと別の設定が壊れる。

削除前の中身は `~/Library/Application Support/ManageArms/permission-backups/`
に残す。**プロジェクト側に `.bak` を作らない** — git status に出てしまう。

---

## 9. アプリ自身のリソース規律

### 保存領域

```
~/Library/Application Support/ManageArms/
  registry.json          数 KB
  agents/<name>.md       Subagent 実体（共有ルートの慣習が無いためここに置く）
  disabled-skills/       無効化した Skill の退避先（3.2）
```

**Skill の実体はここではなく `~/.agents/skills/` に置く（3.2 で確定）。**
App Support に置くと Cursor / Codex から見えず、symlink を 3 本張る旧設計に戻ってしまう。

**キャッシュディレクトリを持たない。** 一時展開は `temporaryDirectory` で完結し
OS が回収する。アプリが自前の掃除機能を持たなくて済む状態にすることが、
最も確実なストレージ管理。そのために明示が必要なのは 2 点:

- **`URLSession` のディスクキャッシュを切る** — デフォルト設定のままだと
  `~/Library/Caches/<bundle-id>/Cache.db` が勝手に生えて宣言と矛盾する。
  `URLSessionConfiguration` で `urlCache = nil` にする。
  HTTP キャッシュは 7.3 の ETag を registry で自前管理しており、二重に持つ理由が無い
- **`registry.json` はアトミックに書く** — 唯一の永続ファイルなので、
  書き込み中のクラッシュで壊れると全リソースの出所情報が飛ぶ。
  `Data.write(to:options:.atomic)`（一時ファイル + rename）。1 行で済む

### frontmatter だけ読む

一覧に必要なのは `name` と `description` のみ。スキルが 100 個あっても本文は要らない。

```swift
let h = try FileHandle(forReadingFrom: url)
defer { try? h.close() }
let head = try h.read(upToCount: 4096) ?? Data()   // 先頭 4 KB だけ
```

本文は詳細ペインを開いた時に読み、閉じたら捨てる。

### 目標値

**RSS ではなく `phys_footprint` で見る**（`footprint -p <pid>`）。RSS は
SwiftUI / AppKit の共有ページを含むため 150 MB 前後になり、アプリが実際に
抱えている量を表さない。

| 項目 | 目標 | 実測（release, 2026-09-06） |
|---|---|---|
| 常駐時（ウィンドウを閉じた状態） | 表示中を超えない | 65 MB |
| ウィンドウ表示中 | < 80 MB | 71 MB（peak） |
| アプリ自身のディスク使用 | < 5 MB（ユーザーが入れたスキルを除く） | — |
| 起動 → 一覧表示 | < 300 ms | — |

常駐時の 65 MB はほぼ GUI フレームワークの取り分で、ウィンドウを閉じた時点で
一覧を捨てても大きくは戻らない（`free` されてもページは OS へ返らない）。
**それでも捨てるのは、開いている間に増えた分を持ち越さないため。**
0 に戻したい利用者向けの答えは常駐 OFF（設定）で、機能追加ではない。

### 触ってよい対象の限定（ホワイトリスト・確定）

削除・移動の安全策は「触ってはいけないパスの列挙」ではなく
**「触ってよい対象の限定」**で行う。3.4 の走査範囲と同じ発想で、
新しいリソース種別を足しても安全側に倒れる。

**アプリが削除・移動してよいのは次の 2 つだけ:**

1. **自分が張った symlink** — リンク先が `~/.agents/skills/` 配下であることを
   `resolvingSymlinksInPath` で検証したもののみ
2. **`registry.json` に載っている実体** — `~/.agents/skills/<name>/`

これ以外は一切触らない。特に **`registry.json` に無いスキル**
（`vercel-labs/skills` が入れた `find-skills` など）は
「外部管理」として表示するだけで、変更操作を提供しない（4.2 / 5.2）。

**念のための二重チェック。** 上のホワイトリストに通っても、
次のパスに一致する操作は無条件で拒否する:

```
auth.json, oauth_creds.json, settings.json,
*.sqlite, ~/.claude.json, ~/.codex/config.toml
```

`~/.codex/auth.json` は認証トークンで、誤爆すると全ログインが飛ぶ。
ホワイトリストの実装ミス 1 つで到達しうる場所なので、二重にする価値がある。

ファイル削除を伴う操作は `rm` ではなく `FileManager.trashItem`（ゴミ箱へ移動）を使う。

### 走査範囲のテスト

**`Source` の全ケースを展開し、`projects` / `sessions` / `logs_` / `file-history` /
`cache` / `archived_sessions` を含むパスが 1 つも出てこないことを assert する。**

ここが破られると 3.4 / 3.5 / 9 の対策がすべて無意味になる。詳細は 10 章。

---

## 10. テスト戦略

**テストは積極的に書く。** このアプリはユーザーのホームディレクトリを書き換え、
symlink を張り、外部コマンドを実行する。壊れ方が「設定が消える」「エージェントが起動しなくなる」
という取り返しのつかない形になるため、手で確認して済ませる領域ではない。

前提は 3.8 の `Environment` 注入。**テストは一時ディレクトリに作った偽のホームだけを触り、
実ユーザーの `~/.claude` には絶対に到達しない。**

### 10.1 純粋関数（最も厚く書く）

外部依存が無く高速。ここが一番壊れやすく、一番テストしやすい。

| 対象 | 押さえるケース |
|---|---|
| **GitHub URL パース** | `/tree/main/skills/foo` / `/blob/` / 末尾スラッシュ / `.git` 付き / リポジトリ直下（`subdir` 無し） / **ブランチ名に `/` を含む**（`feature/x` は `tree/feature/x/skills/foo` となり `subdir` との境界が曖昧）/ 不正 URL |
| **ペースト入力の種別判定** | `mcpServers` JSON / GitHub URL / `npx` コマンド行 / 前後の空白・改行付き / どれでもない文字列 |
| **frontmatter パース** | 正常 / `---` 無し / CRLF / **4 KB 境界で frontmatter が切れる**（3.4 で先頭 4 KB しか読まないため）/ 本文中に `---` がある / `description` 欠落 |
| **MCP スキーマ変換** | stdio（`command` + `args` + `env`）/ HTTP（`url` + `headers`）/ 各エージェント形式への往復変換で情報が落ちないこと |
| **スコープ解決** | `absent` / `inherited` / `explicit` の判定。ユーザー全体とプロジェクトの両方に存在する場合 |
| **更新判定** | sha 一致 / 不一致 / `pinned: true` は更新対象にしない / ETag 304 |
| **バージョン文字列パース** | `2.1.236 (Claude Code)` / `codex-cli 0.153.2` / `0.46.0` / パース失敗時に「バージョン不明」へ落ちること |
| **使用実績の抽出（3.9）** | Claude の `tool_use: Skill`、Codex の `type: skill` / `SKILL.md` 読み込み、Cursor の `tool_use: Read`、`mcp__*` を拾えること / 書き込みや patch 内の `SKILL.md` を誤認しないこと / 壊れた JSONL 行を飛ばして続行すること / `plugin:skill` 形式の分解 / **未集計と「未使用」を別の値として返すこと**（5.3） |
| **MCP プロセスの所属判定（3.9）** | `ps` 出力から PPID を辿って Cursor / Claude / Codex に到達すること / 親が既に死んでいる孤児プロセス / どのエージェントにも辿り着かない場合に「不明」を返すこと |

### 10.2 走査範囲（設計の生命線）

**`Source` の全ケースを展開し、`projects` / `sessions` / `logs_` / `file-history` /
`cache` / `archived_sessions` を含むパスが 1 つも出てこないことを assert する。**

ここが破られると 3.4 / 3.5 / 9 の対策がすべて無意味になる。
新しい `Source` を足した誰かが、このテストで止まるようにしておく。

**使用実績ログは別扱い（3.4 / 3.9）。** `projects` / `sessions` を読んでよい
唯一の経路なので、**一覧スキャンの経路から `UsageScanner` が呼ばれないこと**を
別途 assert する。ここが混ざると 3.4 の「129 MB を踏まない」が崩れる。

### 10.3 ファイルシステム操作（偽ホームで実行）

一時ディレクトリに `~/.claude/skills` などの構造を作って検証する。

- **symlink を張る → 一覧に出る → 外す → 消える**（往復）
- **無効化で実体が消えないこと** — `removeItem` が symlink だけを消し、
  リンク先のスキル本体を巻き込まないこと。**最重要**
- **無効化 → 再有効化の往復** — `~/.agents/skills/<name>` が退避ディレクトリへ移動し、
  再有効化で元の場所に戻り、Claude symlink も張り直されること（3.2）
- **ホワイトリストの外に出ないこと**（9 章） — `registry.json` に無いスキル
  （外部管理）に削除・移動を試みると拒否されること。
  リンク先が `~/.agents/skills/` 配下でない symlink も削除しないこと
- **既に同名のファイル/ディレクトリがある場合に上書きしないこと**
- **リンク切れ symlink の扱い** — `~/.claude/skills/codiff` が実際にこの状態にある。
  クラッシュせず「リンク切れ」と表示できること
- **二重チェックのパスに削除操作が到達しないこと**（`auth.json` など。9 章）
- **zip 展開** — `subdir` だけが取り出されること / 一時ディレクトリが必ず後始末されること /
  **`../` を含むエントリが展開先の外に出ないこと** — spike #13 で `ditto` の
  安全性は確認済みだが、OS 更新で挙動が変わった時に気づくためリグレッションとして残す
- **サイズ上限（50 MB）で中断されること**（3.3） — 上限超過時に
  部分ダウンロードしたファイルが残らないこと

### 10.4 CLI 呼び出し（フェイクで実行）

`Environment.run` を差し替え、**実際の CLI は起動しない**。

- `claude mcp add` に渡す引数が正しく組み立てられること（特に `--` 以降の扱い）
- 終了コード非 0 のときにエラーを握り潰さず UI に出すこと
- **標準出力が壊れた JSON でもクラッシュしないこと**
- タイムアウトで固まらないこと

### 10.5 ゴールデンテスト

実機から採取して匿名化した設定ファイルを `Tests/Fixtures/` に置き、パースできることを検証する。
アプリが読む対象は他社製品の出力であり、**予告なく書式が変わる**。
CLI を更新して壊れたことに気づける唯一の手段になる。

```
Tests/Fixtures/
  claude/.claude.json           mcpServers と 98 KB ぶんの同居キー
  cursor/mcp.json               stdio 形式
  codex/mcp-list.json           codex mcp list --json の出力
  claude/installed_plugins.json user + local × 5 の重複ケース
  claude/known_marketplaces.json autoUpdate: true を含む
  claude/session.jsonl          Skill / mcp__ の tool_use を含む（3.9）
  ps/snapshot.txt               MCP が親子 3 段になっている実物（3.9）
```

### 10.6 書かないもの

- SwiftUI ビューのスナップショットテスト — 壊れやすく、得るものが少ない
- 実際の CLI を起動する統合テスト — 環境依存で CI に載らない。手動確認に回す
- ネットワークを実際に叩くテスト — GitHub のレート制限（60/時）を食う

---

## 11. 実装順序

### v1 — Skills（実装済み）

実装で判明し、設計に反映した事実:

| 発見 | 反映先 |
|---|---|
| `URL.path()` はパーセントエンコードする。App Support は必ず空白を含むため `FileManager` が全滅する | 全箇所 `path(percentEncoded: false)`。空白入りパスの回帰テスト 2 件 |
| completion handler 付き `downloadTask` はデリゲートの進捗を無効化する | 3.3。デリゲート駆動に変更（74 秒 → 0.1 秒） |
| **304 もレート制限を消費する**（GitHub の従来の記載と異なる） | 7.3。守っているのは repo 単位の束ねとスロットル |
| リンク切れ symlink を「有効」と表示していた | `Skill.isLoadable`。ディレクトリに在ることと読み込まれることは別 |
| SwiftUI の `@Environment` と `ManageArmsCore.Environment` が衝突する | 使用側で `@SwiftUI.Environment` と修飾 |
| Grid に固定幅列を足すと可変列が 0 まで潰れる | 名前列に `minWidth` |


Skills は「追加・更新・スコープ表示・配布」の 4 機能すべてを
1 リソースで通しで検証できる唯一の対象。動く実装（`update-skills.py`）も既にある。
スコープは 5.2 の通り v1 では読み取り表示のみ。

0. **`Environment` 注入（3.8）とテスト土台** — 偽ホームで動くテストが書ける状態を先に作る。
   ここを後回しにすると、以降のテストが実ユーザーの `~/.claude` を触りに行く
1. **エージェント検出（3.7）** — ログインシェル経由の `PATH` 解決と 4 状態の判定。
   **Finder から起動して検出できることを必ず確認する**（ターミナル実行では罠が露見しない）
2. `Source` 列挙とホワイトリストスキャン + 走査範囲テスト（10.2）
3. 一覧 UI（マトリクス表示、スコープセレクタ、非活性列）
4. 実体配置 + Claude symlink による有効化 / 無効化（**spike #11 の二重読み込み確認を含む**）
5. zip 取得による追加（URL ペースト）
6. `registry.json` + ETag による更新チェックと差分表示

各ステップは 10 章の該当テストとセットで進める。テストを後追いにしない。

### v2 — Subagents / Plugins（実装済み）

**Subagents**: 実体は `~/Library/Application Support/ManageArms/agents/<name>.md`。
共有ルートの慣習が無いため **symlink は 2 本**（`~/.claude/agents/` と `~/.cursor/agents/`）。
Cursor は Skills では 9 ルートを走査するが、**Subagent は `.cursor/agents` しか読まない**（実測）。

識別子は**ファイル名**で、frontmatter の `name` ではない。ズレると有効化 / 無効化が
ファイルを見つけられなくなる。

**Plugins**: `claude plugin list --json` / `codex plugin list --json` を読む。
`installed_plugins.json` を直接読むより CLI の出力の方が scope と projectPath が揃っている。
**書き込みはしない** — 更新は各 CLI が持ち、`autoUpdate` の衝突も避けられる（7.5）。

実測で重複検出が発火:

```
[claude] ponytail@ponytail v4.9.0 scope=local auto=true → auto-free
[claude] ponytail@ponytail v4.9.0 scope=local auto=true → reborn
[claude] ponytail@ponytail v4.9.0 scope=local auto=true → terminal-for-ai-cli
[claude] ponytail@ponytail v4.9.0 scope=user  auto=true
⚠️ 3 プロジェクトに重複導入
```

**種別フィルタを追加した。** 26 件のスキルの下にプラグインが埋もれるため、
すべて / Skills / Subagents / Plugins で絞り込む（存在する種別だけ出す）。

### v2.5 — 使用実績の集計（実装済み）

`UsageScanner` + `registry.usage` + 5.3 の 1 列。実測値:

```
全走査   2.54 秒（Claude / Codex / Cursor）
増分     0.013 秒（Agent ごとの走査時刻と mtime で絞り込み）
検出     22 件（実環境、未導入の Skill を含む）
```

実装で判明し、設計に反映した事実:

| 発見 | 反映先 |
|---|---|
| Claude だけの走査では Codex / Cursor の使用が「未使用」になる | 3 Agent のログを走査し、`ResourceRow.usageObservable` も同じ範囲にする |
| 旧 registry の全体走査時刻を流用すると、新規対応 Agent の過去ログを飛ばす | Agent ごとの `scannedSources` を追加し、未走査の Agent だけ初回に全履歴を埋める |
| Cursor transcript の行には時刻が無い | ファイル更新時刻を最終使用日の近似値にする |
| 合成された `Codable` は欠けたキーを既定値で埋めない。`usage` を足した瞬間、旧 `registry.json` が読めず**導入済みスキルの取得元が全部飛ぶ** | `Registry.init(from:)` を明示し `decodeIfPresent`。以後フィールドを足しても壊れない |
| `ISO8601DateFormatter` は `Sendable` でなく `static` に置けない | 日付解析を「名前が取れた行」の後ろに移し、その場で生成（全履歴で数十回） |
| `inout` は `Task.detached` に渡せない | `refreshed(_:env:)` は値を返す。全走査は数秒かかりメインスレッドでは回せない |
| `#expect` の中の `allSatisfy(\.isEmpty)` はマクロが `rethrows` と誤解して展開に失敗する | `MCPTests`。マクロの外で評価する |

Codex の明示呼び出しは `type: skill`、暗黙使用は `SKILL.md` の読み込みとして残る。
実行コマンドだけを解析し、patch やファイル操作に含まれるパスは使用と数えない。

### v3 — MCP（実装済み）

CLI 委譲 + Cursor の `mcp.json` 直接編集 + 実行中プロセス検出（3.9）+ ピン留め（7.2）。
実測:

```
ps 1 回で 1155 プロセスを 0.2 秒で走査
● chrome-devtools — Cursor · 稼働 22:05 · pid 87431
npm: chrome-devtools-mcp@latest → @1.8.0 に固定
```

実装で判明し、設計に反映した事実:

| 発見 | 反映先 |
|---|---|
| **Codex は Cursor の拡張の中に入っていることがある**（`~/.cursor/extensions/openai.chatgpt-…/bin/…/codex`）。パスに `cursor` が含まれるため、先に Cursor 判定すると取り違える | `ProcessScanner.agent(ofCommand:)` は**実行ファイル名を先に見る** |
| 1 つの MCP が `npm exec` → 本体 → watchdog の 3 プロセスに分かれる | 一致した集合の中で**親を持たないもの**を起点にする。稼働時間もそれが正しい |
| `npx` / `node` で照合すると無関係なプロセスに当たる | 共通語と 3 文字以下を除外。**手掛かりが残らなければ照合しない** — 誤って「実行中」と出すより無害 |
| 列を 1 つ足したらウィンドウ右端で操作列が切れた | 最小幅 1000 → 1160 |

**プロセス検出は「登録と実態のズレ」の可視化そのもの。**
設定ファイルを読むだけでは「登録されているのに起動していない」は絶対に分からない。

ピン留めは `remove` → `add` で登録し直す（`claude mcp` に差し替えが無いため）。
**`add` が失敗したら元の定義で入れ直す** — 中途半端に消えている方が害が大きい。

### v4 — 権限（実装済み）

Hooks / Commands / Rules は対象外に決まった（1 章）ため、v4 は権限画面のみ。
実測で 371 件 / 11 プロジェクト、うち使い捨て 22 件・重複 75 件を検出（8 章）。

実装で判明し、設計に反映した事実:

| 発見 | 反映先 |
|---|---|
| プロジェクトのパスは**動的**で `Source` の静的列挙に載らない | `UsageScanner` と同じく専用の入り口にする。プロジェクト一覧は `~/.claude.json` の `projects` キーから取る（`~/.claude/projects/` の 140 MB は読まない） |
| `settings.json` は `WriteGuard.deniedNames` に入っている | `WriteGuard` は削除・移動用。書き換えは別操作なので `PermissionWriter` に専用ガードを置いた |
| `permissions` の隣に `enabledPlugins` / `hooks` / `extraKnownMarketplaces` が同居 | ルート辞書を読んで `permissions` だけ差し替える（`MCPManager.editCursor` と同じ形） |
| テストの偽ホームで、`~/.claude.json` の `projects`（絶対パス）を home 確定前に組み立てて全滅した | フィクスチャを `(URL) -> [String: String]` のクロージャ形にした |
| macOS の `/var` → `/private/var` symlink で `isInside` が偽陰性になる | 実 home は symlink ではないので実害なし。`isInside` は fail-closed なので拒否側に倒れる。テスト側で解決 |

### v5 — 画面の作り直しと削除（実装済み）

「何が入っているか分かるが、どう足してどう捨てるのか分からない」という
初心者からの指摘への対応。**機能ではなく導線の問題**だったので、
横断マトリクスをエージェントごとの画面に割り、追加をホームの一番上に置いた（8 章）。

| 発見 | 反映先 |
|---|---|
| 消せないもの（他ツール管理・CLI 管理）を同じ見た目で並べると「削除の仕方が分からない」に見える | 操作できるものだけ本体に出し、残りは畳む（8 章） |
| 入れる・更新するはあるのに**捨てる手段が無かった** | `SkillManager.remove` / `SubagentManager.remove`。実体はゴミ箱へ移す |
| 無効化中の行は `state` が全エージェント `absent` になり、エージェント別に絞ると消える | `Inventory.rows(for:)` で管理対象の退避中を拾う（再有効化の導線） |
| 常時非活性のスコープセレクタが「壊れている」ように見える | v1 で選べない以上、出さない（5.2） |
| `isManaged` で畳んだら、**ユーザーが自分で入れた `ponytail@ponytail` が「ほかのツールが入れたもの」に埋もれた** | 畳む基準を「自分で入れたか」に変えた（`ResourceRow.Origin`） |
| リンク切れの `codiff` がどのエージェントの画面にも出なくなった（`state` が全部 `absent` のため） | `ResourceRow.roots` で置き場から拾い、`isUnusable` として警告付きで出す |
| **プロジェクト配下を走査しておらず、4 プロジェクト 15 件のスキルと project スコープの MCP が 1 件も出ていなかった** | `ProjectScan.projectPaths` 経由。行が無いものは作る |
| ユーザー全体とプロジェクトを 1 つの表に混ぜ、行のバッジで区別させたら読めなかった。縦に積み直しても長すぎた | スコープをタブにして、同時に見せる表を 1 つにした（`Inventory.scoped(for:)`） |
| 自分で入れたスキルが「表示だけ」で、切り替えも削除もできないまま | 既知の配置ルート直下のものは 1 件ずつゴミ箱へ移せる（`SkillManager.removeExisting`、15 章） |
| プロジェクトの分を消すコマンドが既定スコープ（`-s user`）のままで、**ユーザー全体を消す**ものになっていた | スコープと `cd` をコマンドに焼き込む（`ResourceRow.removalCommand`） |
| 「消せない」とだけ書いてあるので、どうすれば消えるのか分からない | `削除するには…` で CLI コマンド or 実体パスを出してコピーさせる |
| エージェントのアイコンが 4 つとも同じで、選択中がどれか分からない | アイコンをやめた（8 章）。名前だけで一意に読める |

---

## 12. spike の結果と未検証項目

### 解決済み（2026-09-05〜06 実測）

| # | 項目 | 結果 |
|---|---|---|
| 1 | Cursor が symlink されたスキルを辿るか / 同期マネージャに消されないか | **問い自体が消えた。** Cursor は `~/.agents/skills` を含む 9 ルートを走査するため、`~/.cursor/skills-cursor/` に何も置かない。同期マネージャと関わらない（3.2） |
| 2 | Codex が symlink されたスキルを辿るか | **✅ 辿る。** `codex debug prompt-input` で symlink 版・実体コピー版の両方が `<skills_instructions>` に載ることを確認。さらに `~/.agents/skills` を第 2 ルート（`r1`）として読むため symlink すら不要 |
| — | Claude が symlink を辿るか | **✅ 辿る。** `~/.claude/skills/` に symlink を張った瞬間、起動中セッションのスキル一覧に反映された |
| — | GUI アプリの `PATH` 問題 | **✅ 確定。** 3 CLI すべて launchd の `PATH` では見つからない。起動中の Cursor Helper も `PATH=/usr/bin:/bin:/usr/sbin:/sbin` で動いている（3.7） |
| — | MCP の実行中検出と所属エージェント特定 | **✅ 可能。** `chrome-devtools-mcp` が独立プロセスとして常駐。PPID を辿ると `Cursor Helper: mcp-process` → `Cursor.app` に到達し、どのエージェントが掴んでいるか確定できる（3.9） |
| — | Skills の使用実績がログから取れるか | **✅ 取れる。** Claude は `tool_use: Skill`、Codex は `type: skill` と `SKILL.md` 読み込み、Cursor は `tool_use: Read` に残る（3.9） |
| 14 | Cursor の使用実績ログの形式 | **✅ 確定。** `~/.cursor/projects/**/agent-transcripts/**/*.jsonl`。行時刻が無いためファイル更新時刻で近似する |
| 9 | `.skill-lock.json` を registry として流用するか | **決定: 流用しない。** 自前 `registry.json` を持ち、`.skill-lock.json` は読み取り専用（4.1） |
| 13 | `ditto -xk` の Zip Slip 耐性 | **✅ 安全。** `../escaped.txt` / `a/../../escaped2.txt` を含む zip を展開したところ、`../` が除去され全て展開先の内側に着地。脱出なし。自前検証は不要（3.3） |

検証に使った道具（実装時のデバッグにも使う）:

- **`codex debug prompt-input`** — API を呼ばずにモデルへ渡るプロンプトを JSON で出力する。
  スキルルートと読み込み済みスキルが全部見える
- **Cursor のスキルルート配列** — `/Applications/Cursor.app/Contents/Resources/app/out/` を
  文字列検索すると走査対象がそのまま出てくる

### 未検証

| # | 項目 | 影響 |
|---|---|---|
| 3 | `codex mcp add` の引数仕様（現在 0 件登録のため未確認） | MCP 実装時 |
| ~~4~~ | ~~`~/.codex/hooks.json` の `trusted_hash`~~ | **不要になった。** Hooks は対象外（1 章） |
| 5 | `claude plugin list` が更新の有無を出力するか | 出さない場合は marketplace 側を見る |
| 6 | Gemini CLI に Skills 相当があるか（`~/.gemini` には無い） | 対応表の確定 |
| 7 | 実行中の Claude Code / Codex プロセス検出（`pgrep`）が必要か | 設定書き換え時の競合警告。**プロセス名が `Cursor` ではないため `pgrep -x` は使えない**（実測）。`pgrep -f` を使う |
| 8 | `$SHELL -l -c 'echo $PATH'` が全環境で機能するか（fish / nushell） | 失敗時は手動パス指定へ誘導（3.7） |
| 10 | `~/.cursor/cloud-skills/` / `~/.grok/skills/` の扱い | 対応表に載せるか |
| 11 | Cursor が同一スキルを二重に読まないか — 実体 `~/.agents/skills/` と Claude 用 symlink `~/.claude/skills/` の両方を走査するため、重複排除の有無を確認 | v1 の symlink 実装（11 章ステップ 4） |
| 12 | Plugin の scope 移動（local → user）を `claude plugin` CLI が対応しているか | 5.2 の「ユーザー全体に昇格」ボタンの実現性。v2 着手前に確認 |
| 16 | ウィンドウを閉じた常駐状態で App Nap が 3 秒タイマーを間引かないか（ブラウザ検知、6 章） | 間引かれるなら `ProcessInfo.beginActivity` で抑止するか、その状態では諦めるかの判断。**常駐が既定になったぶん影響が大きい** |
| ~~17~~ | ~~メニューバーの緑が明・暗どちらでも見えるか~~ | **解決。** `MenuBarExtra` のラベルはまるごとテンプレートとして描かれるので、検知中だけ非テンプレート画像に差し替える。図案ごと緑にしたため外観への依存が無くなった（明るい外観で実機確認済み） |
| 15 | Plugin 由来の skill / command を使用実績から逆引きできるか（実測では `ponytail:ponytail-review` と `plugin:skill` 形式で記録されていた） | 3.9 の Plugin 行の最終使用日。命名規則が全プラグインで一貫しているか要確認 |

---

## 13. 配布

### 13.1 App Store は選択肢にならない

このアプリは `~/.claude` `~/.cursor` `~/.codex` `~/.agents` を読み書きし、
`claude` / `codex` / `gemini` CLI を `Process` で起動する。これは **App Sandbox と非互換**。
サンドボックスは Mac App Store の必須要件なので、残るのは
**Developer ID 署名 + 公証による直接配布の一択**。

配布物には次の 3 つがすべて要る。1 つでも欠けると利用者側で警告が出る。

| 要素 | 何のため | 欠けるとどうなる |
|---|---|---|
| Developer ID 署名 | 開発者の同定 | 「開発元を確認できません」 |
| Hardened Runtime | 公証の必須要件 | 公証が Invalid で返る |
| セキュアタイムスタンプ | 公証の必須要件 | 公証が Invalid で返る |

Hardened Runtime 下でも、子プロセス（`$SHELL -l -c` / 各 CLI）の起動に
追加の entitlement は要らない。3.7 の `PATH` 解決はそのまま動く。

### 13.1.1 最低 OS は macOS 26

`Package.swift` の `platforms: [.macOS(.v26)]`、`Info.plist` の `LSMinimumSystemVersion`、
CI の `runs-on` の 3 か所を必ず揃える。ズレると「手元では通るのに配布物が起動しない」が起きる。

- `.macOS(.v26)` は **swift-tools-version 6.2 以降でないと `'v26' is unavailable`** になる。
  そのためマニフェストは 6.2、CI ランナーは macOS 26 SDK を持つ `macos-26` を使う
- 最低 OS を上げると対象ユーザーは狭まる。下げ直すときも上記 3 か所と
  `README.md` / `README.ja.md` を同時に直す

### 13.2 `.xcodeproj` を持たず、`.app` を script で組む

`Scripts/build-app.sh` が SwiftPM の成果物から `.app` を手組みして署名する。
**同じスクリプトが CI とローカルの両方で動く**（CI 専用の隠れロジックを持たせない）。

`swift run` では `Bundle.main` が Info.plist・アイコン・`.lproj` を解決できない。
3.7 の `PATH` の罠も `.app` にして初めて再現するため、**動作確認は必ず `.app` で行う**。

**デバッグ版は別アプリとして組む。** bundle id に `.debug` を付け、`Environment.live` が
それを見て保存先を `Application Support/ManageArms Debug` に分ける。開発中のリビルドが
インストール済みリリース版の `registry.json` を壊さないため。

> 分離できるのは `appSupport` 配下だけ。`~/.agents/skills` と `~/.claude/skills` は
> home 基準の共有ルート（3.2）なので分離できず、**デバッグ版でも有効化・無効化は実環境に効く**。

### 13.3 未署名の配布物を作らせない

未署名／アドホック署名の DMG は Gatekeeper に弾かれる配布物にしかならず、
一度出回ると回収できない。そこで**二重にガードする**。

| どこ | 何をする |
|---|---|
| `Scripts/build-app.sh` | `CONFIG=release` でアドホック署名ならエラーで停止（`ALLOW_ADHOC=1` で明示的に外せる。配布不可） |
| `.github/workflows/release.yml` | 署名・公証の 7 シークレットが 1 つでも欠けていたら checkout より前に停止 |

### 13.4 署名・公証の順序

**`.app` と DMG の両方**に署名とチケットが要る。片方だけだと穴が開く。

```
1. .app をビルド + Developer ID 署名（+ runtime + timestamp）
2. .app を zip 化 → 公証 → 【元の .app に】ステープル
3. ステープル済みの .app から DMG を作る
4. DMG 自体に Developer ID 署名（+ timestamp）
5. DMG を公証 → ステープル
6. stapler validate / spctl で検証
```

- **`.app` にステープルしないと初回起動がオンライン依存になる。** DMG のチケットは
  DMG にしか付かないため、利用者が `/Applications` へドラッグしたアプリにはチケットが無い
- **DMG を署名しないと** `spctl -a -t open --context context:primary-signature` が
  `no usable signature` になる

手順と罠（中間証明書が無いと `0 valid identities` になる件を含む）は `docs/signing.md`。

### 13.5 設置場所ガード

DMG を開いてそのまま起動されることが実際に起きる。その状態でスキルを有効化すると、
ユーザーは「入れた」つもりなのに、ディスクイメージを取り出した瞬間にアプリが消える。
**実体（`~/.agents/skills`）と symlink は残るので壊れはしない**が、管理する手段だけが
無くなるという分かりにくい状態になる。起動時にこれを潰す。

判定は純粋関数（`InstallLocationClassifier`）に置き、OS を触る部分だけを
アプリシェル側（`InstallLocationGuard`）に持つ。

| 分類 | 促す | 理由 |
|---|---|---|
| `applications` | — | 正規の設置場所 |
| `readOnlyVolume` | ✓ | マウント中の DMG から直接起動している |
| `removableVolume` | ✓ | 外付けディスク |
| `translocated` | ✓ | Gatekeeper のアプリ移動保護（読み取り専用に見えるので**先に判定する**） |
| `elsewhere` | — | 内蔵ディスク上の Applications 外。意図してそこに置いている場合があり、開発ビルド（`.build/…`）で毎回ダイアログが出るのを避ける |

- 移動は `ditto`（拡張属性とコード署名の完全性を保つ）。**元は消さない** —
  DMG は読み取り専用で消せず、外付け上のユーザーのファイルを勝手に消さないため
- コピー後に `xattr -dr com.apple.quarantine`。残すと移動後の初回起動でまた確認が出る
- 同一 bundle id が生きているうちに `open` しても既存インスタンスが前面に来るだけなので、
  親の終了を待ってから開くヘルパー（`sh`）に委ねる

### 13.6 バージョニングとリリース

- `main` から `release/Ver_X.Y.Z` を切って push すると CI が全部やる
- **配布は公開リポジトリ `den0206/manage-arms-releases`、ソースは Private のまま**（13.8）
- **公開済みリリースは不変。** 同じタグが既にあれば上書きせず、`X.Y.Z` は保ったまま
  `+N` を付けて採番する（`Ver_0.0.1` があれば `Ver_0.0.1+1`）
- `CFBundleShortVersionString` は Apple の形式要件で数値 3 成分のみ。
  再ビルド番号込みの完全版は独自キー `MAFullVersion` に持つ（アップデート確認を作るときに使う）
- Release 本文は `CHANGELOG.md` の `[Unreleased]` を CI が版見出しへ切り出したもの。
  **手で移さない**

### 13.7 やらないこと

| 対象外 | 理由 |
|---|---|
| **アプリ内自己更新** | 検証を誤ると更新経路がマルウェアの侵入口になる。`codesign -R` の designated requirement、TOCTOU、置換ヘルパー、再起動をまたぐ結果通知と、費用対効果が合わない。まずは「アップデート確認 → リリースページを開く」で止める |
| Sparkle 等の更新フレームワーク | 依存ライブラリゼロの方針。そもそも自己更新をやらない |

### 13.8 配布は公開リポジトリ、ソースは Private

DMG は誰でも取れる必要があるが、ソースを公開する必要は無い。そこで
**Release だけを公開リポジトリ `den0206/manage-arms-releases` に出す**。
利用者向けドキュメント（README 2 言語・CHANGELOG・デモ GIF・Issue テンプレート）は
そちらに置き、このリポジトリの README は開発者向けのまま残す。

| 決めたこと | 理由 |
|---|---|
| Release の publish 先は `RELEASES_REPO`（公開） | ダウンロード URL を公開したまま、ソースは Private に保てる |
| `RELEASES_TOKEN`（PAT）で書く | `GITHUB_TOKEN` は自リポジトリにしか書けない |
| 既存タグの照会も公開リポジトリの `ls-remote` | **タグの権威は publish 先**。ソース側のタグは記録用の写しなので、採番の基準にすると食い違う |
| 公開後にソースへも同じタグを push | 配布物とビルド元コミットの対応を残す |
| README の版依存表示はマーカーで囲む | 公開リポジトリの `sync-release-docs.yml` が Release 公開を受けて書き換える。**マーカーの外にベタ書きすると古いまま取り残される** |
| Release バッジは版を URL に埋めた静的バッジ | 動的バッジは URL が変わらないため、GitHub の画像プロキシが旧版を掴んだままになる |

---

## 付録: 実測データ（2026-09-05）

判断の根拠。数値が大きく変わったら設計を見直す。

```
~/.cursor   1.6 GB   extensions 1.6G / projects 18M / skills-cursor 320K
~/.codex    163 MB   logs_2.sqlite 44M / sessions 20M / cache 16M / skills 508K
~/.claude   160 MB   projects 129M (145 セッション / 20 プロジェクト)
                     file-history 17M / plugins 12M
~/.claude.json  96 KB
~/.gemini       80 KB
```

- CLI: `claude` `codex` `gemini` は導入済み。`cursor-agent` は無し
- MCP 登録数: Cursor に `chrome-devtools` 1 件のみ。Codex は 0 件
- Skills: `~/.claude/skills/codiff`（Codiff.app が張った symlink・現在リンク切れ）、
  `~/.cursor/skills-cursor/` に 26 件
- Plugins: `swift-lsp@claude-plugins-official`（user）、
  `ponytail@ponytail` v4.9.0（local × 5 プロジェクト）
- 使用実績: インストール済みスキル 33 件に対し、3 Agent のログに残るのは 9 件（3.9）
- プロジェクト側: `.claude/` を持つプロジェクト 12 件

## 15. 既存Toolの管理と互換性検証（2026-09-06）

この節は、初期設計の「registry登録済みのみ削除」「CLIを案内するだけのMCP追加」
「アクティブ化時だけの起動状態取得」を更新する。ユーザーの依頼に基づく仕様変更。

- 追加画面は Skills/Subagents・MCP・Plugin を選択する。MCPはJSON、HTTP URL、
  引用符付き起動コマンドを受け付ける。シェル展開はしない。MCPとPluginの導入先は
  Agentごとに選び、ユーザー全体スコープに入れる。プロジェクトへの新規追加は未対応。
- Pluginの追加はClaudeの `plugin install`、Codexの `plugin add` に委譲する。
  配布元URLの登録とPluginの導入は別の操作で、後者が失敗しても前者は残ると表示する。
  Cursor Pluginの読み書きには引き続き未対応。CLIの非対話導入に対応しないPluginは
  CLIのエラーを表示する。任意のインストールスクリプトを自動承認しない。
- ユーザーが既に入れたSkill/Subagentは、既知の配置ルートの直下の1件を指定して
  ゴミ箱へ移せる。`WriteGuard.assertUserArtifact` で親ディレクトリと実パスを検証し、
  同梱領域・Plugin配下へのリンクを拒否する。リンク先の実体は削除しない。
  アプリ管理下の共有リソースは従来の切替を残し「共有先すべてで有効」と明示する。
- 同梱SkillはCursorの既知ルートとCodex `.codex/skills/.system` を保護する。
  MCP/Pluginで `isBuiltIn` / `managed` / `installPolicy: INSTALLED_BY_DEFAULT` 等の
  保護メタデータを得た場合も変更を拒否する。
  初回検出や公式配布元というだけでは同梱と推測しない。未知の同梱形式の判定には
  Agent側が提供する情報の追加検証が必要。
- MCP/Pluginの行はAgent別の識別子を持つ。registryは名前と種別の組で更新する。
  MCPの固定は選択した1 Agentだけに作用し、Cursorではその他の設定キーを保持する。
- 壊れたCursor JSONとregistryを空として上書きしない。CLI失敗・未対応のJSON形式を
  「0件」と混同せず一覧の診断表示に出す。引数・環境変数・HTTPヘッダの保持を検証する。
- ウィンドウが表示されている間だけ3秒間隔で `ps` を読む。設定一覧・CLIの全走査は
  毎回行わない。常駐しない。表示は「起動検出／起動未確認」で、HTTP接続や不明な所属を
  「停止」と断定しない。MCPの実際の呼び出し開始・終了イベントの検知は未実装。
- プロジェクト設定の走査対象は `~/.claude.json` の `projects` キーだけから採る
  （`ProjectScan.projectPaths`）。ホーム全体を再帰走査しない。**手で足す導線は置かない** —
  Claude で一度でも開いたフォルダは自動で載るため、実測 19 件をすべて拾えており、
  ボタンは一度も使われないまま「足せるのに外せない設定」になっていた。
  `Registry.projects` は既に値がある人のために読み取りだけ残す。
- 通常の回帰テストに加え、`AgentCompatibilityTests` を明示実行できる。
  子プロセスに一時HOMEと作業ディレクトリを与え、認証情報を引き継がない。
  MCPの追加→一覧→削除、引数・環境変数・HTTPヘッダの保持とPluginのCLI契約を確認する。
  Plugin本体のインストールやGUIの操作テストは含まない。
- `Scripts/check-agent-compatibility.sh <claude|codex|gemini> [version]` は一時領域へ
  指定CLIを取得して上記検証を実行する。CIは手動実行（workflow_dispatch）で最新版を検証する。
  ローカルにあるCLIだけを使う場合は `COMPAT_AGENT=claude swift test --filter AgentCompatibilityTests`。
  Cursorは偽設定によるテストと実機での確認を組み合わせる。
