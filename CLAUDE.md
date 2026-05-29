# ブランチ運用ルール (厳守)

> **本ルールの canonical source**: [`git@github.com:yuya-MCPs/mcps-overview.git`](https://github.com/yuya-MCPs/mcps-overview)
> 本書はそのコピー。差分が生じた場合は canonical を正とする。

このプロジェクトで開発支援を行う際は、以下を絶対に守ること。

## 鉄則

1. **PR マージ直後に作業ブランチを削除する**
   - `mcp__github__merge_pull_request` 等でマージ後、`delete_branch` 系ツールが
     あれば即座に呼ぶ
   - ツールが無い場合は、削除コマンドまたは GitHub UI 手順を即座に
     ユーザーに提示し、忘れない仕組みを最初の commit で導入する
2. **新規ブランチ作成前に既存ブランチを `list_branches` で確認する**
   - `main` / `master` / `develop` 以外のブランチが滞留していたら
     クリーンアップ提案を先にする
3. **`main` / `master` / `develop` には絶対に直 push しない**
   - branch protection 未設定でもルール上の主ブランチには直 push しない
4. **`claude/*` 形式のセッション固有ブランチは作らない**
   - ブランチ名は必ず `<type>/<short-description>` 形式 (下記)

## ブランチ命名規則

| プレフィックス | 用途 |
|---|---|
| `feat/`     | 新機能追加 |
| `fix/`      | バグ修正 |
| `refactor/` | リファクタリング (動作不変) |
| `docs/`     | ドキュメントのみ |
| `test/`     | テストのみ |
| `chore/`    | 依存更新・雑務 |
| `ci/`       | CI/CD 設定 |

## プロジェクト初期セットアップ時の必須作業

新規リポジトリで作業を始める場合、**最初の PR** に以下を含める:

1. `.github/workflows/auto-delete-merged.yml` (マージ時自動削除)
2. `.github/workflows/cleanup-stale-branches.yml` (手動一掃)
3. `.github/workflows/setup-branch-protection.yml` (main 保護)
4. `docs/MAINTENANCE.md` または同等のドキュメント (本書がこれを兼ねる場合あり)

雛形は本 repo `.github/workflows/` にあり、canonical は上記 yuya-MCPs/mcps-overview を参照。

## 既存プロジェクト介入時の最初の作業

`list_branches` で滞留を確認 → 多ければ:

1. ユーザーに「マージ済みブランチが N 個滞留しているので最初に
   クリーンアップ workflow を入れてよいか」確認
2. 同意があれば上記 3 ワークフローを最初の PR として投入
3. ユーザーに `workflow_dispatch` で「Cleanup stale branches」と
   「Setup branch protection」を順に実行してもらう

## セルフチェック (PR を作る前 / マージ後 必ず実施)

- [ ] 作業ブランチ名は規約に合っているか
- [ ] マージ後、ブランチが消えているか確認した
- [ ] 自動削除ワークフローが入っているか確認した (無ければ追加)
- [ ] `claude/*` 形式のブランチを残していないか

---

## 本 repo (homelab-setup) における例外

現行ブランチ `claude/trusting-curie-SWcm8` は、本ルール導入前に harness の初期指示で作成されたもの。
**これを最後の `claude/*` ブランチとし**、マージ後は本ルールに従う:

- マージ後、`claude/trusting-curie-SWcm8` は削除 (auto-delete ワークフローで自動化)
- 以降の作業は `docs/<topic>`, `feat/<topic>`, `chore/<topic>` 等で起票
- branch protection は merge 後に `workflow_dispatch` で適用
