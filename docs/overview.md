# Homelab Overview

QNAP TS-233 (ARM64) + Windows + Fedora Atomic を前提とした自宅 homelab の全体設計書。
個別モジュールの詳細は各 `modules/<name>/docs/requirements.md` を参照。

---

## モジュール一覧

| モジュール | 目的 | 状態 | 場所 |
|----------|-----|------|------|
| **kerberos** | Win/Linux ユーザ認証の一元化 (Samba AD DC + step-ca + MFA) | 要件定義中 | [`modules/kerberos/`](../modules/kerberos/) |
| **wireguard** | 外出先からの帰宅トンネル + LAN 通信の暗号化 | 要件定義中 | [`modules/wireguard/`](../modules/wireguard/) |
| **pxe** | iPXE による OS ネットブート + Kerberos 自動 join 復元 | 要件定義中 | [`modules/pxe/`](../modules/pxe/) |
| **autoupdate** | Fedora CoreOS (zincati) / Windows (WUfB) / コンテナ自動更新 | 要件定義中 | [`modules/autoupdate/`](../modules/autoupdate/) |

各モジュールは将来的に独立 repo (`nagata1634/homelab-<name>`) として切り出すことを想定したレイアウト。
分離時は `git subtree split --prefix=modules/<name> -b split-<name>` で履歴を保ったまま抽出可能。

---

## 依存関係

```
                ┌──────────────┐
                │  kerberos    │  ← 全認証の基盤 (最初に構築)
                └──────────────┘
                  ▲       ▲
                  │       │
        ┌─────────┘       └─────────┐
        │                            │
┌──────────────┐            ┌──────────────┐
│  wireguard   │            │     pxe      │
│ (外出先から  │            │ (OS 復元時に │
│  KDC へ到達) │            │  realm join) │
└──────────────┘            └──────────────┘
        │                            │
        └────────────┬───────────────┘
                     ▼
            ┌──────────────┐
            │  autoupdate  │  ← 全モジュールの維持
            └──────────────┘
```

| From → To | 依存内容 |
|-----------|---------|
| wireguard → kerberos | 外出先クライアントの DNS / KDC 到達性確保 |
| pxe → kerberos | プロビジョニング時の自動 realm join (Ignition / unattend に CA 証明書を埋め込み) |
| autoupdate → kerberos | KDC の自動更新は他より遅らせる (循環停止回避) |
| autoupdate → pxe | コンテナ tag pin 管理 |
| autoupdate → wireguard | WG コンテナの更新 |

---

## フェーズ計画

| Phase | テーマ | 主担当モジュール | 状態 |
|-------|-------|----------------|------|
| 1 | Windows 基盤 (WSL2 + Docker + buildx) | (本 repo `setup-homelab.ps1`) | ✅ 完了 |
| 2 | Kerberos ID 統合 + MFA | kerberos | 🚧 要件定義中 |
| 2.x | WireGuard Road Warrior トンネル | wireguard | 🚧 要件定義中 |
| 3 | PXE / ネットブート OS 復元 | pxe | 🚧 要件定義中 |
| 4 | 自動更新ポリシー | autoupdate | 🚧 要件定義中 |
| 5 | 監視 / Web SSO / バックアップ高度化 | (未モジュール化) | 未着手 |
| 6 | HA / セカンダリ KDC / オフサイトバックアップ | (未モジュール化) | 未着手 |

---

## バージョン管理

各モジュールのリリースタグ / コンテナイメージタグは [`versions.yml`](../versions.yml) で集中 pin。
Renovate により PR ベースで更新提案を受ける運用 (詳細は autoupdate モジュール)。

---

## グローバル設計パラメータ

各モジュール共通の命名 / ネットワーク設計は本書に集約し、モジュール側からは参照する。

| 項目 | 暫定値 | TBD |
|------|-------|-----|
| Kerberos Realm | `HOME.LAB` | ✓ |
| DNS Domain | `home.lab` | ✓ |
| NetBIOS Name | `HOMELAB` | ✓ |
| LAN サブネット | TBD | ✓ |
| KDC ホスト名 | `kdc01.home.lab` | ✓ |
| WG エンドポイント | TBD (ルータ or TS-233) | ✓ |
| WG UDP ポート | 51820 | |
| PXE next-server | TS-233 (`kdc01.home.lab`) | |

> 各モジュールの「設計パラメータ」セクションはこの表を参照し、モジュール固有の値のみ定義する。

---

## ルートディレクトリ構成

```
homelab-setup/
├── README.md                  # Phase 1 セットアップ (既存)
├── setup-homelab.ps1          # Phase 1 (既存)
├── add-neovim.ps1             # 既存
├── versions.yml               # 各モジュールのタグ pin
├── docs/
│   └── overview.md            # 本書
└── modules/
    ├── kerberos/
    ├── wireguard/
    ├── pxe/
    └── autoupdate/
```
