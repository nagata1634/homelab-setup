# homelab-kerberos

QNAP TS-233 (ARM64) 上に Samba AD DC を構築し、Windows / Linux のユーザ認証を統一する。
パスワード / 指紋 / YubiKey (PKINIT) の 3 方式をサポート。

- 詳細要件: [`docs/requirements.md`](./docs/requirements.md)
- 全体像: [`../../docs/overview.md`](../../docs/overview.md)

## 想定構成 (将来)

```
modules/kerberos/
├── README.md
├── docs/
│   └── requirements.md
├── compose/
│   ├── samba-ad-dc.yml
│   └── step-ca.yml
├── provision/
│   ├── provision-domain.sh
│   ├── issue-host-cert.sh
│   └── enable-pkinit.sh
└── clients/
    ├── windows/
    │   ├── join-domain.ps1
    │   └── enable-smartcard-logon.ps1
    ├── linux/
    │   ├── realm-join.sh
    │   ├── setup-fprintd.sh
    │   └── ssh-gssapi.sh
    └── yubikey/
        └── provision-piv.sh
```

## 状態

要件定義中 (v0.4)。実装未着手。
