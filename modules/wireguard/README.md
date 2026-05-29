# homelab-wireguard

外出先 PC から自宅 LAN への暗号化トンネル (Road Warrior + Full Tunnel)。
公衆 Wi-Fi 上の盗聴対策、および自宅 KDC / NFS / SMB への透過アクセスを実現する。

- 詳細要件: [`docs/requirements.md`](./docs/requirements.md)
- 全体像: [`../../docs/overview.md`](../../docs/overview.md)

## 想定構成 (将来)

```
modules/wireguard/
├── README.md
├── docs/
│   └── requirements.md
├── compose/
│   └── wg-server.yml
├── provision/
│   ├── generate-peer.sh
│   └── publish-peer-config.sh
└── clients/
    ├── windows/
    │   └── install-wg-client.ps1
    └── linux/
        ├── wg-pull.sh           # Kerberos TGT で構成 pull
        └── wg-quick-up.sh
```

## 状態

要件定義中 (v0.1)。実装未着手。
