# 用語集

本 repo で頻出する略語 / 用語の簡易リファレンス。

---

## Kerberos / 認証

| 用語 | 説明 |
|------|------|
| **Kerberos** | チケットベースの認証プロトコル (RFC 4120)。共通鍵を中央 (KDC) に置き、各サービスへの通行手形 (チケット) を発行する方式。 |
| **KDC** (Key Distribution Center) | Kerberos のチケット発行サーバ。AS (認証サーバ) + TGS (チケット付与サーバ) からなる。 |
| **TGT** (Ticket-Granting Ticket) | ユーザがログインした際に最初に発行されるマスターチケット。これを使って各サービスチケットを取得する。 |
| **Realm** | Kerberos の管理単位 (Active Directory のドメインに相当)。慣例として全大文字 (`HOME.LAB`)。 |
| **Principal** | Kerberos 上の主体名。`alice@HOME.LAB` (ユーザ) や `host/server.home.lab@HOME.LAB` (サービス) の形。 |
| **Keytab** | サービスの長期鍵を格納したファイル。サーバ側で `kinit` 相当を非対話で行うために使用。 |
| **PKINIT** | Kerberos の **公開鍵ベース事前認証** (RFC 4556)。スマートカードや YubiKey の PIV を使った TGT 取得を可能にする。 |
| **GSSAPI** | Generic Security Services API。Kerberos を SSH/HTTP/DB に組み込むための標準 API。 |
| **SPNEGO** | HTTP で GSSAPI を使うためのネゴシエーション方式。ブラウザ SSO の正体。 |
| **SSSD** | System Security Services Daemon。Linux を AD / IPA に参加させるためのデーモン。NSS / PAM 統合を提供。 |
| **realm join** | Linux ホストを AD ドメインに参加させるコマンド (`realmd` 経由)。 |

---

## PKI (PIV 採用時)

| 用語 | 説明 |
|------|------|
| **PKI** | Public Key Infrastructure。証明書ベースの信頼インフラ。 |
| **CA** (Certificate Authority) | 証明書を発行する認証局。本 repo では step-ca を採用予定。 |
| **CRL** (Certificate Revocation List) | 失効した証明書のリスト。クライアントが信頼性確認に使う。 |
| **OCSP** | Online Certificate Status Protocol。CRL のオンライン版、リアルタイム失効確認。 |
| **PIV** | Personal Identity Verification (FIPS 201)。スマートカードの標準仕様。YubiKey 5 系などが対応。 |
| **PKCS#11** | 暗号トークン (スマートカード / HSM) を扱う標準 API。 |
| **NTAuth Store** | AD 内のスマートカード用信頼 CA ストア。`certutil -dspublish` で登録。 |

---

## FIDO2 / WebAuthn

| 用語 | 説明 |
|------|------|
| **FIDO2** | パスワードレス認証の標準。FIDO Alliance + W3C による WebAuthn の組み合わせ。 |
| **WebAuthn** | ブラウザでハードウェアキーを使う W3C 標準。 |
| **U2F** | FIDO2 の前身、2 要素目用途のチャレンジ・レスポンス。 |
| **CTAP2** | クライアント (PC / モバイル) と認証器 (YubiKey 等) の通信プロトコル。 |
| **Resident Key** (Discoverable Credential) | 認証器に保存される常駐鍵。ユーザ名なしログイン可。 |
| **pam-u2f** | PAM スタックに FIDO2 認証を組み込む Yubico 製モジュール。 |
| **ssh ed25519-sk** | OpenSSH 8.2+ のハードウェアキー対応鍵タイプ。 |

---

## OS / 自動更新

| 用語 | 説明 |
|------|------|
| **Fedora CoreOS** (FCOS) | コンテナ実行に特化した自動更新型 Linux。ostree ベースのイミュータブル設計。 |
| **Fedora Silverblue** | デスクトップ向けの ostree ベース Fedora。 |
| **ostree** | git ライクな OS ファイルツリーバージョン管理。世代切替によるロールバックが可能。 |
| **rpm-ostree** | RPM パッケージを ostree コミットとして扱うハイブリッド管理ツール。 |
| **Ignition** | FCOS の初回ブート時設定ファイル (JSON)。 |
| **Butane** | Ignition の人間可読入力 (YAML)。`butane → ignition` に変換。 |
| **zincati** | FCOS の自動更新エージェント。リリースストリームを購読し、戦略に従って再起動。 |
| **WUfB** (Windows Update for Business) | Windows の業務向け Update ポリシー機構。GP / Intune で制御。 |

---

## ネットワーク / VPN

| 用語 | 説明 |
|------|------|
| **WireGuard** | UDP ベースの軽量 VPN プロトコル。ChaCha20-Poly1305 で暗号化、静的公開鍵ペア認証。 |
| **Road Warrior** | 外出先からホームネットへの 1 対 1 VPN 接続パターン。 |
| **Full Tunnel** | クライアントの全トラフィックを VPN 経由にする構成 (`AllowedIPs = 0.0.0.0/0`)。 |
| **Split Tunnel** | 特定範囲のみ VPN 経由、それ以外は直接インターネットへ抜ける構成。 |
| **GSS-TSIG** | Kerberos GSSAPI で署名された DNS 動的更新。Samba AD が標準サポート。 |
| **DDNS** | Dynamic DNS。動的 IP 環境で名前解決を維持する仕組み。 |

---

## PXE / プロビジョニング

| 用語 | 説明 |
|------|------|
| **PXE** (Preboot eXecution Environment) | ネットワーク経由で OS をブートする仕組み。 |
| **iPXE** | PXE の高機能実装。HTTP / iSCSI / スクリプト対応。 |
| **TFTP** | Trivial File Transfer Protocol。PXE ブートの初期ステージで使用。 |
| **proxyDHCP** | 既存 DHCP と共存し、PXE オプションのみ追加配布するモード。 |
| **wimboot** | iPXE で Windows の WIM (Windows Imaging Format) を起動するための仕組み。 |
| **Autounattend.xml** | Windows セットアップの無人インストール定義ファイル。 |
| **Secure Boot** | UEFI の起動チェーン検証機構。shim 経由で Linux 起動。 |
| **shim** | Microsoft 署名済みの一次ブートローダ。Secure Boot で Linux を起動する橋渡し。 |
| **MOK** (Machine Owner Key) | ユーザが Secure Boot に追加できる信頼鍵。 |

---

## その他

| 用語 | 説明 |
|------|------|
| **HBAC** (Host-Based Access Control) | ホスト単位のアクセス制御。FreeIPA の機能だが、AD + SSSD でも sudoers ルールで類似実装可。 |
| **ADR** (Architecture Decision Record) | 設計判断を文書化する軽量フォーマット。本 repo では各モジュールの "Open Design Decisions" セクションが該当。 |
| **IaC** (Infrastructure as Code) | インフラ構成をコードで管理する考え方。本 repo の compose / provision スクリプトが該当。 |

---

## 参考リンク (英語の信頼できる一次情報)

- [Kerberos Consortium](https://www.kerberos.org/)
- [Microsoft Kerberos Authentication Overview](https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-authentication-overview)
- [FIDO Alliance](https://fidoalliance.org/)
- [NIST FIPS 201 (PIV)](https://csrc.nist.gov/publications/detail/fips/201/3/final)
