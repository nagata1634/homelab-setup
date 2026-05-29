# WireGuard モジュール 要件定義書

最終更新: 2026-05-29 / ステータス: ドラフト v0.1

> 全体像とグローバル設計パラメータは [`../../../docs/overview.md`](../../../docs/overview.md) を参照。

---

## 1. 目的

- **外出先 PC から自宅 LAN への暗号化トンネル** (Road Warrior + Full Tunnel) を提供する。
- 公衆 Wi-Fi 上の盗聴 / MITM を防止。
- 外出先からも自宅の Kerberos KDC / NFS / SMB / 内部 DNS に LAN 同等でアクセスできるようにする。
- Kerberos モジュールの前提条件 (KDC への到達性) を外出先環境でも満たす。

## 2. 依存

| 種別 | 依存先 | 内容 |
|------|-------|------|
| 提供 | kerberos | 外出先での TGT 取得経路 |
| 受領 | kerberos | LDAP (`wireguardPublicKey` 属性) で鍵を集中管理 (任意) |
| 受領 | autoupdate | WG コンテナの更新 |
| 外部 | DDNS or 固定 IP | 外部からの WG エンドポイント解決 |
| 外部 | 家庭ルータ | UDP 51820 ポートフォワード or DMZ |

## 3. スコープ

### 3.1 In Scope
| ID | 項目 | 内容 |
|----|------|------|
| S1 | WG サーバ構築 | TS-233 上 or 家庭ルータ上で endpoint 終端 |
| S2 | クライアント鍵管理 | LDAP 属性 + admin スクリプトで配布 |
| S3 | Full Tunnel 構成 | `AllowedIPs = 0.0.0.0/0` で全トラフィック経路化 |
| S4 | DNS 引き継ぎ | 接続時に自宅 DNS (Samba AD 内蔵) を使用 |
| S5 | Win/Linux/モバイルクライアント | 公式 WG クライアントで接続 |
| S6 | DDNS 連携 | 動的 IP 環境で WG endpoint を解決可能に |
| S7 | Kill Switch | WG 切断時に素通信を防ぐ (Win/Linux 設定) |

### 3.2 Out of Scope
- Split Tunnel (自宅 LAN のみ経由) を別プロファイルとして提供 (Phase 2.x.1 検討)
- VPN ごと Kerberize する代替案 (strongSwan IKEv2 + EAP-GSSAPI) — 別モジュール化検討
- Site-to-Site VPN
- WireGuard over TCP (難検閲環境向け)

## 4. 採用方式の選択 (TBD)

| 観点 | A. **家庭ルータで終端** | B. **TS-233 (コンテナ)** で終端 |
|------|------------------------|--------------------------------|
| パフォーマンス | ◎ ハードウェアオフロード | ○ ARM64 ソフトウェア処理 |
| 設定の柔軟性 | △ ルータ依存 | ◎ wg-easy 等の管理 UI 利用可 |
| 障害分離 | ○ ルータ別物 | △ TS-233 障害で TGT 取得も不可 |
| 鍵管理の自動化 | △ ルータ UI 経由 | ◎ LDAP 連携スクリプト書ける |
| 推奨 | ルータが WG 対応なら ◎ | 対応しない場合の代替 |

### 暫定推奨: **A (ルータが OpenWrt / VyOS / EdgeRouter / Synology 等で WG サポート時)** → なければ B

> ⚠ TBD-13: WG エンドポイントを自宅ルータ / TS-233 のどちらにするか (ルータ機種次第)。
> ⚠ TBD-14: 動的 IP なら DDNS の選定 (Cloudflare DDNS / duckdns / no-ip)。

## 5. 想定トポロジ

```
[外出先 PC] ── 公衆 Wi-Fi ── Internet
     │
     │  WG tunnel (UDP 51820)
     │  AllowedIPs = 0.0.0.0/0
     ▼
┌──────────────────────────────┐
│  WG 終端 (ルータ or TS-233)   │
│  - peer 認証 (公開鍵ペア)    │
│  - NAT / ルーティング        │
└──────────────────────────────┘
     │
     ▼
[自宅 LAN] → KDC / NFS / SMB / 内部 DNS
```

## 6. 機能要件

| ID | 要件 | 受け入れ基準 |
|----|------|------------|
| FR-01 | 外出先から WG 接続成功 | `wg-quick up home` でハンドシェイク成立 |
| FR-02 | 接続後に内部名解決 | `dig kdc01.home.lab` で内部 IP が返る |
| FR-03 | 接続後に Kerberos TGT 取得 | `kinit alice@HOME.LAB` 成功 |
| FR-04 | 接続後に SMB マウント | `mount -t cifs //fileserver.home.lab/...` 成功 |
| FR-05 | Full Tunnel 動作 | `curl ifconfig.io` が自宅 IP を返す |
| FR-06 | Kill Switch | WG 切断時に物理 NIC からの素通信を遮断 |
| FR-07 | クライアント鍵の追加 | admin スクリプトで peer 追加 + QR コード生成 |
| FR-08 | クライアント鍵の失効 | admin スクリプトで peer 削除、即座に切断 |

## 7. 非機能要件

| ID | 内容 |
|----|------|
| NFR-01 | スループット ≥ 100Mbps (TS-233 終端時、ARM64 制約あり) |
| NFR-02 | ハンドシェイク確立 ≤ 3 秒 |
| NFR-03 | クライアント秘密鍵はクライアント端末から外に出さない (サーバには公開鍵のみ) |
| NFR-04 | サーバ秘密鍵はファイル権限 600、root 所有 |
| NFR-05 | 接続ログを 30 日保存 (peer 公開鍵 / 接続元 IP / 接続時刻) |

## 8. 設計パラメータ

| 項目 | 暫定値 | TBD |
|------|-------|-----|
| WG endpoint | TBD (ルータ or TS-233) | ✓ TBD-13 |
| Public IP / DDNS | TBD | ✓ TBD-14 |
| UDP ポート | 51820 | |
| トンネル方針 | Full Tunnel (`0.0.0.0/0`) | |
| WG サブネット | `10.10.0.0/24` (暫定) | |
| ピア数想定 | TBD | |
| クライアント DNS | `10.0.0.x` (自宅 DNS) | グローバル参照 |

## 9. 鍵管理ポリシー

- WireGuard の鍵は AD パスワード変更等と連動しないため、**LDAP 属性 `wireguardPublicKey` を独自スキーマで追加** し集中管理。
- **生成フロー**:
  1. クライアントで鍵ペア生成 (`wg genkey | tee priv.key | wg pubkey > pub.key`)
  2. 公開鍵を Kerberos 認証付き API スクリプト経由でサーバに登録
  3. サーバ側で peer 構成を生成、QR コード or `*.conf` をクライアントへ返送
- **失効フロー**:
  1. 紛失報告
  2. LDAP から該当 peer の公開鍵を削除
  3. WG サーバ設定を再ロード (`wg syncconf`)
- **オプション**: 「Kerberos でログオン → TGT で WG 構成を pull → `wg-quick up`」を行うラッパー `clients/linux/wg-pull.sh`。

## 10. リスクと対策

| # | リスク | 対策 |
|---|-------|------|
| R1 | ルータ機種が WG 非対応 | TS-233 フォールバック |
| R2 | 動的 IP 変動で接続不可 | DDNS + クライアント側 `Endpoint` をホスト名指定 |
| R3 | TS-233 終端時のスループット不足 | ルータ終端への移行 or 別ホスト |
| R4 | クライアント鍵流出 → なりすまし | 端末ロック必須、紛失時即失効 |
| R5 | Full Tunnel で自宅回線が外出時にボトルネック | Split Tunnel プロファイルも併設 |
| R6 | UDP 51820 を ISP がブロック | TCP 443 ベースの WireGuard over TLS は別検討 |

## 11. 成果物 (Phase 2.x 完了時)

- 本 `docs/requirements.md`
- `compose/wg-server.yml` (TS-233 終端時)
- `provision/generate-peer.sh` (peer 追加)
- `provision/publish-peer-config.sh` (LDAP 登録 + QR 生成)
- `clients/windows/install-wg-client.ps1`
- `clients/linux/wg-pull.sh` (Kerberos 経由 pull)
- ルータ終端時の手順 `docs/router-setup.md` (機種別)

## 12. レビュー履歴

| 日付 | 版 | 変更点 |
|------|----|--------|
| 2026-05-29 | v0.1 | モジュール分離に伴う初版 |
