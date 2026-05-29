# homelab-pxe

iPXE による OS ネットブート基盤。Fedora CoreOS / Windows をネットワーク経由で配信し、
Kerberos 自動 join 込みで「壊れたら 5〜10 分で復活」を実現する。

- 詳細要件: [`docs/requirements.md`](./docs/requirements.md)
- 全体像: [`../../docs/overview.md`](../../docs/overview.md)

## 想定構成 (将来)

```
modules/pxe/
├── README.md
├── docs/
│   └── requirements.md
├── compose/
│   └── pxe-stack.yml          # dnsmasq + tftpd + nginx
├── ipxe/
│   ├── menu.ipxe              # ブートメニュー
│   └── boot/                  # iPXE バイナリ
├── images/
│   ├── fedora-coreos/         # Live PXE kernel/initramfs/squashfs
│   └── windows/               # boot.wim, install.wim, wimboot
├── ignition/
│   └── fcos-base.bu           # Butane 入力 (KDC ホスト名 + CA 証明書埋込)
└── unattend/
    └── windows-autounattend.xml
```

## 状態

要件定義中 (v0.1)。実装未着手。
