# homelab-autoupdate

各 OS / コンテナの自動更新ポリシー。Fedora CoreOS の zincati、Windows Update for Business、
コンテナの Renovate ベース PR 更新を統合管理する。

- 詳細要件: [`docs/requirements.md`](./docs/requirements.md)
- 全体像: [`../../docs/overview.md`](../../docs/overview.md)

## 想定構成 (将来)

```
modules/autoupdate/
├── README.md
├── docs/
│   └── requirements.md
├── fcos/
│   ├── zincati-config.toml         # periodic 戦略テンプレ
│   └── pre-reboot-hook.sh          # KDC バックアップ等
├── windows/
│   └── WUfB-policy.admx            # グループポリシー / Intune 設定
├── containers/
│   └── renovate.json5              # Renovate 設定
└── monitoring/
    └── update-alert.yml            # 更新失敗アラート
```

## 状態

要件定義中 (v0.1)。実装未着手。
