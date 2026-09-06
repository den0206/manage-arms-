# 署名・公証のセットアップ

Apple Developer Program 登録後、**Developer ID 署名 + 公証**で配布できるようにするまでの、
**人間が 1 回だけやる作業**。パイプラインそのものは `.github/workflows/release.yml` が正本。

## 0. なぜ Developer ID なのか

manage-arms は `~/.claude` `~/.cursor` `~/.codex` `~/.agents` を読み書きし、
`claude` / `codex` / `gemini` CLI を `Process` で起動する。これは **App Sandbox と非互換**
（`Resources/ManageArms.entitlements` で `app-sandbox = false`）。
サンドボックスは Mac App Store の必須要件なので、**App Store は選択肢にならない**。
残るのは Developer ID 署名 + 公証（notarization）による直接配布の一択。

配布物には次の 3 つがすべて要る。1 つでも欠けるとユーザー側で警告が出る。

| 要素 | 何のため | 欠けるとどうなる |
|------|----------|------------------|
| Developer ID 署名 | 開発者の同定 | 「開発元を確認できません」 |
| Hardened Runtime | 公証の必須要件 | 公証が Invalid で返る |
| セキュアタイムスタンプ | 公証の必須要件 | 公証が Invalid で返る |

`Scripts/build-app.sh` は release ビルドかつ実 ID 指定のときこの 3 つを自動で満たす
（`--options runtime` は常時、`--timestamp` は `SIGN_IDENTITY != "-" && CONFIG=release` のとき）。

> **未署名の配布物は作れないようにしてある。**
> `Scripts/build-app.sh` は `CONFIG=release` でアドホック署名だとエラーで止まり
> （`ALLOW_ADHOC=1` で明示的に外せる。配布不可）、`release.yml` はシークレットが
> 1 つでも欠けているとビルドに入る前に落ちる。

---

## 1. Team ID を控える

developer.apple.com → Account → Membership details → **Team ID**（英数 10 文字）。
署名 ID 文字列と `NOTARY_TEAM_ID` の両方で使う。

## 2. Developer ID Application 証明書

1. キーチェーンアクセス → 証明書アシスタント → **認証局に証明書を要求**
   - 「ディスクに保存」+「鍵ペア情報を指定」にチェック（2048 bit / RSA）
   - **秘密鍵はログインキーチェーンに作られる**。これが本体で、失うと証明書は使えない
2. developer.apple.com → Certificates → **+** → **Developer ID Application**
   - Profile Type: **G2 Sub-CA (Xcode 11.4.1 or later)**
   - CSR をアップロード → `.cer` をダウンロード → ダブルクリックで取り込む
   - 発行できるのは **Account Holder のみ**。個人アカウントでは **最大 5 枚**なので作り直しは慎重に

## 3. ⚠️ 中間証明書を入れる（ここで必ずハマる）

**症状**: 証明書を取り込んだのに

```
$ security find-identity -v -p codesigning
     0 valid identities found
```

**原因**: 中間証明書 `Developer ID Certification Authority (G2)` がキーチェーンに無く、
証明書チェーンがルートまで繋がらない。**Xcode は中間証明書を自動インストールしない。**

**見分け方**: `-v`（有効なもののみ）を外すと証明書自体は見つかる。

```
$ security find-identity -p codesigning      # -v なし
  1) 9433CB0B… "Developer ID Application: … (…)"   ← ペアは存在する
     1 identities found
  Valid identities only
     0 valid identities found                       ← が、有効と判定されない

$ codesign --sign "Developer ID Application: …" <何か>
  Warning: unable to build chain to self-signed root for signer "…"
  errSecInternalComponent
```

**対処**:

```bash
curl -fsSLO https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
security import DeveloperIDG2CA.cer -k ~/Library/Keychains/login.keychain-db
# もしくはダウンロードした .cer をダブルクリック
```

上位の `Apple Root CA` は macOS のシステムルートに同梱済みなので、**この 1 枚を足すだけ**で繋がる。

```
$ codesign -dvvv <署名済み> | grep Authority
Authority=Developer ID Application: … (…)
Authority=Developer ID Certification Authority     ← これが入る
Authority=Apple Root CA
```

## 4. 公証用の App 用パスワード

account.apple.com → サインインとセキュリティ → **App用パスワード** → 生成（`xxxx-xxxx-xxxx-xxxx`）。
**Apple ID のパスワードとは別物**。一度しか表示されない。

ローカルで公証を試すなら、キーチェーンに保存しておくと以後 `--keychain-profile` で使える:

```bash
xcrun notarytool store-credentials manage-arms-notary \
  --apple-id "<Apple ID>" --team-id "<TEAMID>" --password "xxxx-xxxx-xxxx-xxxx"
```

## 5. CI 用に `.p12` を書き出す

キーチェーンアクセス → 「自分の証明書」→ 対象証明書を右クリック → **書き出す**（`.p12` 形式）。

- **必ず秘密鍵込みで書き出す**（「自分の証明書」カテゴリから出せば鍵と中間証明書も含まれる）
- 書き出しパスワード = `MACOS_CERT_PASSWORD`
- `base64 -i developerID.p12 | pbcopy` → `MACOS_CERT_P12`

## 6. GitHub Secrets（8 つすべて必須）

リポジトリ → Settings → Secrets and variables → Actions

| シークレット | 値 |
|---|---|
| `MACOS_CERT_P12` | §5 の base64 文字列 |
| `MACOS_CERT_PASSWORD` | `.p12` の書き出しパスワード |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: 名前 (TEAMID)` |
| `KEYCHAIN_PASSWORD` | CI 用一時キーチェーンのパスワード（任意の非空値） |
| `NOTARY_APPLE_ID` | Apple ID（メール） |
| `NOTARY_TEAM_ID` | §1 の Team ID |
| `NOTARY_PASSWORD` | §4 の App 用パスワード |
| `RELEASES_TOKEN` | 公開リポジトリ `den0206/manage-arms-releases` に `contents:write` を持つ PAT |

1 つでも欠けると `release.yml` は最初のステップで落ちる（未署名の DMG は作らない）。

`RELEASES_TOKEN` が要るのは、**Release を別リポジトリへ publish する**ため。
`GITHUB_TOKEN` は自リポジトリにしか書けない。fine-grained PAT なら
`den0206/manage-arms-releases` のみにスコープを絞り、権限は Contents: Read and write だけでよい。

> 証明書・パスワードは GitHub Secrets にのみ置き、ワークフロー本文・ログには出さない。
> `base64` の復号は `$RUNNER_TEMP` 上で行い、キーチェーンはジョブ終了で破棄される。

---

## 7. 署名・公証の順序（なぜ 2 回公証するのか）

**`.app` と DMG の両方**に署名とチケットが要る。片方だけでは穴が開く。

```
1. .app をビルド + Developer ID 署名（+ runtime + timestamp）
2. .app を zip 化 → 公証 → 【元の .app に】ステープル
3. ステープル済みの .app から DMG を作る
4. DMG 自体に Developer ID 署名（+ timestamp）
5. DMG を公証 → ステープル
6. stapler validate / spctl で検証
```

| やらないと | 何が起きるか |
|---|---|
| `.app` にステープルしない | ユーザーが `/Applications` にドラッグしたアプリにチケットが無く、**初回起動が Apple へのオンライン照会に依存**（オフラインだと弾かれ得る） |
| DMG に署名しない | `spctl -a -t open --context context:primary-signature` が `rejected / source=no usable signature` |

- `notarytool` は `.app` ディレクトリを直接受け取れないので、提出は zip
  （`ditto -c -k --keepParent`）。チケットは中身の CDHash に紐づくので、
  **staple は zip ではなく元の `.app` に対して**行う。
- ステープルは `Contents/CodeResources` にチケットを置くだけで**コード署名は有効なまま**
  （直後に `codesign --verify --strict` を走らせて担保している）。

## 8. ローカルで確かめる

```bash
security find-identity -v -p codesigning          # 1 つ以上出ること（0 なら §3）

SIGN_IDENTITY="Developer ID Application: 名前 (TEAMID)" ./Scripts/build-app.sh
codesign -dvvv .build/release/ManageArms.app 2>&1 | grep -E 'Authority|flags|Timestamp'
# flags に runtime が入り、Authority が 3 段（アプリ / 中間 / Apple Root CA）出れば正しい

./Scripts/make-dmg.sh .build/release/ManageArms.app ManageArms-local.dmg "ManageArms local"
```

公証まで試す場合（§4 でキーチェーンに保存済みとして）:

```bash
ditto -c -k --keepParent .build/release/ManageArms.app /tmp/ManageArms.zip
xcrun notarytool submit /tmp/ManageArms.zip --keychain-profile manage-arms-notary --wait
xcrun stapler staple .build/release/ManageArms.app
spctl -a -vv .build/release/ManageArms.app        # accepted と出ること
```

公証が Invalid で返ったら、ログを読む:

```bash
xcrun notarytool log <submission-id> --keychain-profile manage-arms-notary
```

## 9. リリース手順

1. `CHANGELOG.md` の `[Unreleased]` に**英語で**変更点が入っているか確認する
   （そのまま Release 本文になる。**手で版見出しへ移さないこと** — CI がやる）
2. `main` から `release/Ver_X.Y.Z` ブランチを切って push
3. `release.yml` が シークレット検査 → テスト → 署名ビルド → `.app` 公証・ステープル → DMG →
   DMG 署名・公証・ステープル → Gatekeeper 検証 → **公開リポジトリへ Release 公開** →
   ソースへ同じタグを付与 → `main` へ CHANGELOG 反映
4. 公開先は `den0206/manage-arms-releases`（公開）。**ソースはこのまま Private**。
   利用者はそちらの Releases から DMG を取る
5. 同じ `Ver_X.Y.Z` が既にあれば、上書きせず `Ver_X.Y.Z+1`、`+2` … と採番して公開する
   （公開済みリリースは不変。`+N` は同一 `X.Y.Z` の再ビルド番号）
6. 公開リポジトリ側は Release の公開を受けて `sync-release-docs.yml` が走り、
   README の最新版表示・バッジ・CHANGELOG・Issue テンプレートの記入例を追従させる
