# Agent instructions

作業前に [CLAUDE.md](CLAUDE.md) を読むこと。ここには規則を複製しない。

- 移行後の仕様: [docs/product-requirements.md](docs/product-requirements.md) と `docs/agent-tool-*.md`
- Phase 0 完了までは現行 Mac App の実装確認に [DESIGN.md](DESIGN.md) を使う
- Agent Tool の判断では常に `docs/` を優先する

リポジトリ固有のコマンド:

- `/review-for-merge` — マージ前レビューと完了チェック
- `/commit-by-feature` — レビュー後に機能単位でコミット
