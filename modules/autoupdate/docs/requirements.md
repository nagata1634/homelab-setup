# Auto-update モジュール 要件定義書

最終更新: 2026-05-29 / ステータス: ドラフト v0.1

> 全体像とグローバル設計パラメータは [`../../../docs/overview.md`](../../../docs/overview.md) を参照。

---

## 1. 目的

- 各 OS / コンテナを **常に最新のリリースに自動追従** し、人手によるメンテナンスを最小化。
- セキュリティパッチの遅延をゼロに近づける。
- ロールバック可能性を確保し、自動更新による障害リスクを軽減。

## 2. 依存

| 種別 | 依存先 | 内容 |
|------|-------|------|
| 受領 | (全モジュール) | 更新対象 OS / コンテナ |
| 制約 | kerberos | KDC の更新ウィンドウは他より遅らせる (循環停止回避) |
| 制約 | pxe | PXE 配信用イメージのタグ更新 |
| 制約 | wireguard | WG サーバの更新ウィンドウ |
| 外部 | Renovate Bot | コンテナ tag PR 自動生成 |

## 3. スコープ

### 3.1 In Scope
| ID | 項目 | 内容 |
|----|------|------|
| U-01 | Fedora CoreOS 自動更新 | zincati による periodic 戦略 |
| U-02 | Fedora Silverblue 自動更新 | rpm-ostree + systemd timer |
| U-03 | Windows 自動更新 | WUfB (Windows Update for Business) |
| U-04 | コンテナイメージ更新 | Renovate で PR ベース、承認制 |
| U-05 | 更新失敗の通知 | Webhook / メール / Grafana アラート |
| U-06 | 起動失敗時の自動 rollback | ostree の世代切替 |
| U-07 | 更新ウィンドウの調整 | KDC とクライアントの再起動を時差化 |
| U-08 | KDC pre-reboot バックアップ | zincati フックで DB スナップショット |

### 3.2 Out of Scope
- ファームウェア / BIOS 自動更新 (手動承認制)
- QNAP QTS 自動更新 (QTS GUI 設定に委譲)
- ベアメタル LSI / RAID コントローラ更新

## 4. OS 別方針

| OS | メカニズム | 自動化 | ロールバック |
|----|-----------|-------|------------|
| **Fedora CoreOS** | rpm-ostree + **zincati** (標準) | リリースストリーム購読、`update strategy` 制御 | `rpm-ostree rollback` |
| **Fedora Silverblue** | rpm-ostree + systemd timer | `rpm-ostree upgrade` を週次実行 | 同上 |
| **QNAP QTS** | QTS Auto Update | GUI で自動有効化 | スナップショット依存 |
| **Windows** | WUfB | GP / Intune で「自動 DL + アクティブ時間外再起動」 | 「以前のビルドに戻す」(10 日以内) |
| **コンテナ** | Renovate | tag pin + PR 自動作成、merge で適用 | Compose の image タグを前版に戻す |

## 5. Fedora CoreOS 自動更新 (詳細)

### 5.1 zincati 設定例
`/etc/zincati/config.d/55-homelab.toml`:
```toml
[updates]
strategy = "periodic"

[[updates.periodic.window]]
days = [ "Sun" ]
start_time = "03:00"
length_minutes = 60
```

### 5.2 再起動戦略
| 戦略 | 説明 | 用途 |
|------|------|------|
| `immediate` | 検出即時再起動 | 検証マシン |
| `periodic` | 指定曜日/時間帯のみ | **本番推奨** |
| `fleet_lock` | 複数台で排他制御 | HA 構成 (Phase 6) |

### 5.3 ロールバック
- 起動失敗 → ostree が自動で前世代を選択
- 手動: `rpm-ostree rollback && systemctl reboot`
- 確認: `rpm-ostree status` で 2 世代が見える

## 6. 機能要件

| ID | 要件 | 受け入れ基準 |
|----|------|------------|
| FR-U-01 | FCOS が自動でリリース追従 | 公開から ≤ 7 日以内に適用 |
| FR-U-02 | 週次指定時間帯のみ再起動 | 平日昼間は再起動しない |
| FR-U-03 | 起動失敗時に自動 rollback | カーネルパニック等で前世代起動 |
| FR-U-04 | Windows は業務時間外に再起動 | アクティブ時間 9:00-22:00 尊重 |
| FR-U-05 | コンテナは PR ベース更新 | 自動 apply なし、merge で適用 |
| FR-U-06 | KDC は更新前に DB バックアップ | pre-reboot hook で実行 |
| FR-U-07 | 更新失敗を通知 | Webhook が発火 |

## 7. 非機能要件

| ID | 内容 |
|----|------|
| NFR-U-01 | 更新ログを 90 日保存 |
| NFR-U-02 | KDC と クライアントの更新ウィンドウを 24 時間以上ずらす |
| NFR-U-03 | Renovate PR は週次まとめ (洪水回避) |
| NFR-U-04 | rollback 可能 (ostree 世代保持 ≥ 3) |

## 8. リスクと対策

| # | リスク | 対策 |
|---|-------|------|
| R-U-1 | 自動更新で互換性破壊 (Samba メジャー版アップ等) | コンテナは tag pin、OS は `stable` ストリームのみ |
| R-U-2 | 全ノード同時再起動で認証断 | KDC とクライアントで更新ウィンドウを時差化 |
| R-U-3 | rollback できない更新 (ファーム等) | ファームは手動承認 |
| R-U-4 | Renovate PR が大量に来て放置 | 週次まとめ、Auto-merge は patch のみ許可 |
| R-U-5 | zincati 設定ミスで未更新 | Prometheus で `rpm-ostree status` を監視、アラート |

## 9. 設計パラメータ

| 項目 | 暫定値 | 備考 |
|------|-------|------|
| FCOS ストリーム | `stable` | グローバル参照 |
| FCOS 再起動ウィンドウ | 日曜 03:00 / 60 分 | KDC は 04:00 |
| Windows アクティブ時間 | 9:00 - 22:00 | |
| Windows 再起動 | 平日 03:00 | |
| Renovate スケジュール | `before 6am on monday` | 週次まとめ |
| ostree 世代保持 | 3 | デフォルトは 2 |

## 10. 成果物 (Phase 4 完了時)

- 本 `docs/requirements.md`
- `fcos/zincati-config.toml`
- `fcos/pre-reboot-hook.sh` (KDC バックアップ等)
- `windows/WUfB-policy.admx` or Intune 設定エクスポート
- `containers/renovate.json5`
- `monitoring/update-alert.yml` (Prometheus / Grafana)
- `docs/runbook.md` (rollback 手順 / 緊急時の更新停止)

## 11. レビュー履歴

| 日付 | 版 | 変更点 |
|------|----|--------|
| 2026-05-29 | v0.1 | モジュール分離に伴う初版 |
