# Homelab 要件定義書 (Phase 2: Kerberos による ID 統合)

最終更新: 2026-05-29
ステータス: ドラフト v0.1 (議論用たたき台)

---

## 1. 背景と目的

### 1.1 背景
- Phase 1 で Windows ホストに WSL2 + Docker Desktop + buildx (multi-arch) を導入済み (`setup-homelab.ps1`)。
- ホームラボには複数の OS / マシンが混在する見込み:
  - Windows (デスクトップ / WSL2)
  - QNAP TS-233 (ARM64, Linux)
  - Fedora Atomic (将来のサーバ / コンテナホスト)
- それぞれにローカルユーザを個別作成 → パスワードや UID/GID 管理が分散しており、運用負荷とセキュリティリスクが高い。

### 1.2 目的
- **シングルサインオン基盤 (Kerberos KDC) を中心に、Windows / Linux のユーザ認証を一元化する**。
- 各マシンへのログオン、ファイル共有、SSH などで **同一のユーザ名 / パスワード** を利用可能にする。
- 将来的に Web サービス (Nextcloud, Grafana 等) も同じ ID に統合できる素地を作る。

### 1.3 認証方式の要件
本ホームラボでサポートする認証手段は以下の **3 種類**。利用者は環境に応じて使い分けでき、可能な範囲で組み合わせ (MFA) も可能とする。

| # | 方式 | 主な利用シーン | Kerberos との結合方式 |
|---|------|---------------|-----------------------|
| 1 | **パスワード** | リモート SSH、サーバ初期セットアップ、フォールバック | 標準 Kerberos preauth (ENC-TIMESTAMP) |
| 2 | **指紋** | デスクトップ / ノート PC のロック解除 | ローカル PAM (Windows Hello / fprintd) が TPM 上のキャッシュ済み TGT or 保護されたパスワードをアンロック → PAM 経由で `kinit` |
| 3 | **YubiKey** | 高セキュリティ用途、リモートからの強い認証 | PIV アプレットの X.509 証明書を用いた **PKINIT** (Kerberos 標準)。WebAuthn 用途は Web サービス向けに別途 |

> ⚠ 重要な前提: 指紋は **本人ローカルでのアンロック手段** であり、ネットワーク越しに指紋データを送信するわけではない。Kerberos プロトコル自体は指紋を理解しないため、「指紋でローカル PAM → PAM が裏で kinit」という構図になる。

### 1.4 非目的 (今フェーズではやらないこと)
- インターネットへの一般公開 SSO (Keycloak 等の OIDC 連携)。
- マルチサイト / 高可用 (HA) 構成。
- メールサーバ等の追加アプリケーション統合 (将来検討)。
- 指紋データの集中管理 / ネットワーク経由での指紋認証 (技術的にも非推奨)。

---

## 2. スコープ

### 2.1 In Scope
| # | 項目 | 内容 |
|---|------|------|
| S1 | KDC 構築 | Kerberos の Key Distribution Center を 1 台構築 |
| S2 | LDAP | UID/GID, homeDir, ログインシェル等の POSIX 属性管理 |
| S3 | DNS | Kerberos が要求する正引き / 逆引き / SRV レコード整備 |
| S4 | 時刻同期 | NTP / chrony による全ノード時刻同期 (スキュー ≤ 5 分) |
| S5 | Linux クライアント統合 | SSSD で Linux (Fedora Atomic / Ubuntu on WSL / QNAP) を join |
| S6 | Windows クライアント統合 | Windows をドメイン参加 (または kinit ベースの限定統合) |
| S7 | バックアップ | KDC データベース / LDAP / krb5.keytab の定期バックアップ |
| S8 | ドキュメント | 構築手順 / 運用 Runbook / 障害復旧手順 |
| S9 | **PKI 基盤** | YubiKey PIV 証明書を発行する CA (KDC 証明書 + クライアント証明書) |
| S10 | **PKINIT 設定** | KDC 側で証明書認証 (PKINIT) を有効化、YubiKey からのチケット取得を許可 |
| S11 | **指紋連携** | Windows Hello / Linux fprintd で PAM 経由 kinit を実現 (各クライアントローカル設定) |
| S12 | **MFA ポリシー** | 管理者アカウント等、特定ユーザに YubiKey 必須を強制可能にする |

### 2.2 Out of Scope
- マルチ KDC / レプリカ (将来 Phase 3 で検討)。
- Windows AD との双方向トラスト。
- スマートカード / FIDO2 等のハードウェア多要素 (将来検討)。

---

## 3. 採用方式の選択肢 (TBD)

3 つの代表的アプローチを **MFA / YubiKey 観点も含めて** 比較。本ドキュメント承認時に **A / B / C を 1 つ確定** する。

| 観点 | A. **Samba AD DC** | B. **FreeIPA** | C. **MIT Kerberos + OpenLDAP** |
|------|-------------------|---------------|--------------------------------|
| 提供物 | Kerberos + LDAP + DNS + AD 互換 | Kerberos + 389-DS + DNS + 内蔵 CA + sudo/HBAC + OTP | Kerberos のみ (LDAP / CA は別途) |
| Windows 統合 | ◎ ネイティブにドメイン参加可能 | △ AD トラスト経由 | △ kinit + ksetup の手動運用 |
| Linux 統合 | ○ SSSD で参加可能 | ◎ SSSD ネイティブ統合 | ○ SSSD 設定が必要 |
| **PKINIT (YubiKey)** | ○ Samba AD は PKINIT 対応 / CA は自前で準備 | ◎ **内蔵 Dogtag CA で証明書発行 → PKINIT 標準サポート** | ○ MIT Kerberos は PKINIT 対応 / CA は自前 |
| **指紋 (PAM 連携)** | ○ Windows Hello / fprintd はクライアント側設定で対応 | ○ 同左 | ○ 同左 |
| **OTP (HOTP/TOTP)** | △ Azure MFA 等の外部連携が必要 | ◎ **内蔵 OTP トークン管理** | △ pam_oath 等で別途構築 |
| ARM64 (TS-233) 対応 | ○ パッケージあり | △ x86_64 中心、ARM64 は要検証 | ◎ 軽量 |
| RAM 消費 | 中 (~500MB) | 大 (~1.5GB, TS-233 では厳しい) | 小 (~100MB) |
| 学習コスト | 中 | 高 | 高 (構成要素を自分で組む) |
| 推奨度 | **◎ (Windows 中心、CA は別建てでも可)** | ○ (MFA 機能は最強だが TS-233 不可、別ホスト要) | ○ (学習目的) |

### 暫定推奨: **A. Samba AD DC + 別建ての軽量 CA (step-ca or smallstep)**
- Windows をシームレスにドメイン参加できる点が決定的。
- TS-233 の 2GB RAM でも Samba AD DC 単体なら現実的。
- YubiKey の PKINIT 用には **step-ca** (Go 製、ARM64 対応、~50MB) を別コンテナで併設し、ACME / SCEP で証明書を YubiKey PIV に書き込む運用とする。
- 指紋は各クライアントローカルの PAM 設定 (Windows Hello / fprintd) で対応、KDC 側は関与しない。

### 代替案: **B. FreeIPA を別ホスト (x86_64 ミニ PC) で稼働**
- TS-233 の RAM 制約上、FreeIPA を稼働させるには別途 4GB 以上の Linux ホストが必要。
- 採用するなら Phase 2 と同時に「FreeIPA 用ホスト調達」がスコープに入る。

> ⚠ TBD-1: 採用方式 (A / B / C) の最終確定。MFA 要件が強い場合 B も再評価対象。

---

## 4. 想定アーキテクチャ (Samba AD DC 採用案)

```
                    ┌─────────────────────────────┐
                    │  Cloudflare / Internet      │  (今フェーズではアクセスしない)
                    └─────────────────────────────┘
                                  │
   ┌──────────────────────────────┴─────────────────────────────┐
   │                       家庭 LAN (192.168.x.0/24)              │
   │                                                              │
   │  ┌────────────────────┐     ┌────────────────────┐          │
   │  │ Windows Host       │     │ QNAP TS-233 (ARM64)│          │
   │  │ - WSL2 / Docker    │     │ - Samba AD DC      │  ← KDC   │
   │  │ - ドメイン参加     │◀───▶│ - DNS (AD 統合)    │          │
   │  └────────────────────┘     │ - LDAP             │          │
   │                              │ - chrony (NTP)     │          │
   │  ┌────────────────────┐     └────────────────────┘          │
   │  │ Fedora Atomic Host │              ▲                       │
   │  │ - SSSD で AD join  │──────────────┘                       │
   │  │ - Container 基盤   │                                      │
   │  └────────────────────┘                                      │
   └──────────────────────────────────────────────────────────────┘
```

### 主要ノード
| ホスト | 役割 | OS | 認証クライアント |
|--------|------|----|-----------------|
| TS-233 | KDC / DNS / LDAP (プライマリ) | QNAP (Container Station 上の Debian/Ubuntu ARM64) | — |
| Windows Host | デスクトップ | Windows 10/11 | ネイティブ AD 参加 |
| Fedora Atomic Host | コンテナサーバ | Fedora CoreOS / Silverblue | SSSD + realm join |
| WSL2 (Ubuntu-24.04) | 開発環境 | Linux | SSSD (オプション) |

---

## 5. 機能要件

| ID | 要件 | 受け入れ基準 |
|----|------|--------------|
| FR-01 | 単一ユーザ ID で Windows にログオン可能 | ドメインユーザ `alice@HOME.LAB` で Windows サインイン成功 |
| FR-02 | 単一ユーザ ID で Linux に SSH 可能 | `ssh alice@fedora.home.lab` がパスワードで成功し、`id` で AD の UID/GID が見える |
| FR-03 | パスワード変更が全ノードに即時反映 | `kpasswd` または Windows の Ctrl+Alt+Del からの変更が他ノードに反映 |
| FR-04 | パスワードポリシー設定可能 | 最小長 / 履歴 / 有効期限を AD ポリシーで強制 |
| FR-05 | ユーザ追加が CLI / GUI から可能 | `samba-tool user add` および RSAT からの追加に成功 |
| FR-06 | サービスチケットによるパスワードレス SSH (GSSAPI) | `kinit` 後の `ssh -K` が成功 |
| FR-07 | ホームディレクトリの自動マウント (任意) | autofs または mkhomedir で初回ログイン時に作成 |
| FR-08 | **YubiKey でログオン (Windows)** | YubiKey 挿入 + PIN で Windows サインイン成功 (PIV スマートカードログオン) |
| FR-09 | **YubiKey で kinit (Linux)** | `kinit -X X509_user_identity=PKCS11:...` で TGT 取得成功 |
| FR-10 | **指紋で Windows サインイン** | Windows Hello 登録後、指紋でアンロック → 裏で TGT が取得される |
| FR-11 | **指紋で Linux ログオン** | fprintd 登録後、指紋でログオン → PAM 経由 kinit が走り TGT 取得 |
| FR-12 | **管理者は YubiKey 必須** | `admin@HOME.LAB` はパスワードのみでは TGT 取得不可。証明書認証必須 |
| FR-13 | YubiKey 紛失時のリボーク手順 | CA で証明書失効 → CRL/OCSP 反映、対象 YubiKey が KDC から拒否される |

---

## 6. 非機能要件

| ID | カテゴリ | 要件 |
|----|---------|------|
| NFR-01 | 可用性 | KDC 停止時は新規ログオン不可を許容 (HA は Phase 3)。既ログオンセッションは継続可能 |
| NFR-02 | 性能 | 認証応答 ≤ 500ms (LAN 内) |
| NFR-03 | 時刻精度 | 全ノード間スキュー ≤ 5 分 (Kerberos の要件) |
| NFR-04 | バックアップ | 日次で DB / keytab / 設定をスナップショット、世代保存 7 日 |
| NFR-05 | 復旧 | バックアップから 1 時間以内に KDC を再構築可能 (Runbook 整備) |
| NFR-06 | セキュリティ | 暗号化方式は AES256-CTS-HMAC-SHA1-96 を最低限有効化、RC4 / DES は無効 |
| NFR-07 | 監査 | ログオン成功 / 失敗を最低 30 日保存 |
| NFR-08 | 運用 | 全設定を Git 管理 (本 repo)、再構築は IaC (Ansible / シェルスクリプト) から再現可能 |
| NFR-09 | PKI | KDC 証明書 / クライアント証明書の有効期間: KDC=1 年、ユーザ=90 日 (短命) |
| NFR-10 | YubiKey | PIV PIN は 8 桁以上、PUK は別管理。3 回失敗でロック |
| NFR-11 | 指紋 | 指紋テンプレートはローカル TPM / Secure Enclave 内に閉じ、ネットワーク送信しない |
| NFR-12 | リボーク | 紛失報告から ≤ 1 時間で対象証明書を失効可能 (CRL 配布間隔 = 30 分) |

---

## 7. 命名 / 設計パラメータ (TBD)

| 項目 | 暫定値 | 備考 |
|------|--------|------|
| Kerberos Realm | `HOME.LAB` | 全大文字。実在 TLD を避ける |
| DNS Domain | `home.lab` | 内部 DNS のみで解決 |
| NetBIOS Name | `HOMELAB` | 15 文字以内 |
| KDC ホスト名 | `kdc01.home.lab` | TS-233 を指す |
| LAN サブネット | TBD | 例: `192.168.10.0/24` |
| 管理者 UPN | `admin@HOME.LAB` | |
| 初期ユーザ | TBD | 例: 家族メンバーごと |

> ⚠ TBD-2: Realm 名 / DNS ドメインの確定 (`.lab` か `.internal` か等)。
> ⚠ TBD-3: 既存 LAN サブネットの確認。
> ⚠ TBD-4: 初期ユーザ一覧。

---

## 7.5 認証フロー (シーケンス概要)

### 7.5.1 パスワード認証 (フォールバック)
```
User ──(username/pw)──> Client PAM ──(AS-REQ + PA-ENC-TIMESTAMP)──> KDC
                                  <──(TGT 暗号化されたもの)─────────
```

### 7.5.2 指紋認証 (Windows Hello / fprintd)
```
User ──(指紋)──> ローカル TPM/Secure Enclave
                       │
                       └──> 保護されたパスワード or キャッシュ鍵を解放
                                  │
                                  └──> PAM が裏で AS-REQ → TGT 取得
```
※ 指紋データは絶対にネットワークに出ない。あくまでローカルのアンロック。

### 7.5.3 YubiKey 認証 (PKINIT)
```
User ──(YubiKey 挿入 + PIN)──> Client (PKCS#11)
        │
        └──> PIV スロット 9a の秘密鍵で署名
                  │
                  └──> AS-REQ (PA-PK-AS-REQ, クライアント証明書同梱) ──> KDC
                                                                          │
                          KDC が CA 信頼 + CRL 確認 ──> TGT を発行 ◀──┘
```

---

## 8. 制約と前提

- **TS-233 の RAM は 2GB** のため、AD DC は単体運用 (重い追加サービスは別ホスト)。
- TS-233 上では QNAP Container Station 上の Debian/Ubuntu ARM64 コンテナとして Samba AD DC を稼働させる方針 (QTS 直接インストールは避ける)。
- DNS は Samba AD DC 内蔵 (BIND9_DLZ ではなく内蔵 DNS を使用、運用簡素化)。
- Fedora Atomic ホストは未調達 / 未構築の前提。実装は Windows + TS-233 から開始。
- 家庭 LAN 内部のみで完結し、外部公開はしない。

---

## 9. リスクと対策

| # | リスク | 対策 |
|---|--------|------|
| R1 | KDC 単一障害点 | 日次バックアップ + Runbook 整備。Phase 3 でセカンダリ DC を追加 |
| R2 | 時刻ずれによる認証失敗 | 全ノード chrony 必須、KDC は上位 NTP に同期 |
| R3 | DNS 設定ミスで Kerberos 解決不能 | 構築前に dig での SRV レコード確認手順をチェックリスト化 |
| R4 | Windows のドメイン参加でローカルプロファイル消失 | 事前にローカルプロファイルのバックアップ / 移行手順を整備 |
| R5 | QNAP Container Station のネットワーク制約 | host ネットワーク or macvlan で固定 IP 化、検証必須 |
| R6 | ARM64 向け Samba AD DC パッケージの動作不確実性 | 初期構築前に PoC で smoke test (`samba-tool domain join` 等) |
| R7 | YubiKey 紛失 → 締め出し | バックアップ YubiKey を 1 本必ず用意。リカバリ用パスワードは紙で金庫保管 |
| R8 | CA 秘密鍵漏洩 | step-ca の root key は HSM or オフラインメディア保管、intermediate のみオンライン |
| R9 | 指紋センサ故障 | パスワード or YubiKey でログオン可能なフォールバックを常に維持 |
| R10 | PKINIT 設定ミスで全員ロックアウト | 管理者用パスワード認証のローカル経路を残す (`kadmin.local`) |
| R11 | Windows のスマートカードログオン要件 (ドメインの CA 証明 NTAuth ストア登録) | 構築手順に AD への CA 証明書配布 (`certutil -dspublish`) を必須化 |

---

## 10. フェーズ計画

| Phase | 内容 | 完了条件 | 状態 |
|-------|------|----------|------|
| 1 | Windows ホスト基盤 (WSL2 + Docker + buildx) | `setup-homelab.ps1` 完走 | ✅ 完了 |
| **2** | **Kerberos ID 統合 (本ドキュメント)** | FR-01 〜 FR-06 達成 | 🚧 要件定義中 |
| 2.1 | PoC: TS-233 上 Samba AD DC コンテナ起動 | `samba-tool domain provision` 成功 | 未着手 |
| 2.2 | Windows ドメイン参加 | ドメインユーザでサインイン成功 | 未着手 |
| 2.3 | Linux クライアント参加 (WSL2 → Fedora) | `realm join` 成功、SSH 通る | 未着手 |
| 2.4 | **CA 構築 (step-ca) + PKINIT 有効化** | KDC 証明書発行 + Linux からの PKINIT 成功 | 未着手 |
| 2.5 | **YubiKey プロビジョニング** | PIV スロット 9a に証明書書き込み、Win/Linux 双方でログオン成功 | 未着手 |
| 2.6 | **指紋連携 (各クライアント)** | Windows Hello / fprintd でログオン → TGT 取得確認 | 未着手 |
| 2.7 | バックアップ / Runbook 整備 | 復旧演習 1 回成功 + YubiKey 紛失リカバリ演習 | 未着手 |
| 3 | HA 化 / 監視 / Web サービス統合 | 別途定義 | 未着手 |

---

## 11. 成果物 (Phase 2 完了時)

- `docs/requirements.md` (本書、確定版)
- `docs/architecture.md` (構成図 / シーケンス)
- `docs/runbook-kdc.md` (運用 / 障害対応)
- `kdc/` ディレクトリ
  - `compose.yml` (Samba AD DC コンテナ定義)
  - `provision.sh` (初期プロビジョニングスクリプト)
  - `backup.sh` (日次バックアップ)
- `clients/windows/join-domain.ps1`
- `clients/windows/enable-smartcard-logon.ps1` (YubiKey PIV)
- `clients/linux/realm-join.sh`
- `clients/linux/setup-fprintd.sh` (指紋)
- `clients/yubikey/provision.sh` (PIV プロビジョニング)
- `ca/` ディレクトリ
  - `compose.yml` (step-ca コンテナ)
  - `provision-ca.sh`
  - `issue-user-cert.sh`

---

## 12. オープン事項 (TBD まとめ)

| # | 内容 | 期限 |
|---|------|------|
| TBD-1 | 採用方式 (Samba AD DC / FreeIPA / MIT 素) の最終決定 | Phase 2 着手前 |
| TBD-2 | Realm 名 / DNS ドメイン名の確定 | Phase 2 着手前 |
| TBD-3 | LAN サブネット / KDC の固定 IP | PoC 開始前 |
| TBD-4 | 初期ユーザ一覧 | クライアント参加前 |
| TBD-5 | バックアップ保管先 (TS-233 内 / 外付け USB / クラウド) | バックアップ実装前 |
| TBD-6 | WSL2 を AD に参加させるか (利便性 vs 複雑性) | クライアント参加時 |
| TBD-7 | YubiKey の型番 (5C NFC / 5 Bio / Security Key 等) | 調達前 |
| TBD-8 | YubiKey の本数 (1 人あたりプライマリ + バックアップ = 2 本想定) | 調達前 |
| TBD-9 | CA を AD DC と同居させるか別ホスト (TS-233 内 / Windows ホスト) | PoC 中 |
| TBD-10 | パスワード認証を完全廃止するか (MFA 強制) / フォールバックとして残すか | Phase 2.4 まで |

---

## 13. Kerberos 統合候補 (拡張機能)

KDC を立てた後、**「同じ ID で透過的に使える」** ようになる機能を一覧化。
Phase 2.x or Phase 3 で順次取り込み。

### 13.1 ◎ 標準的に Kerberize できる (推奨)
| # | 機能 | Kerberos 統合方式 | 嬉しさ |
|---|------|------------------|--------|
| K-01 | **SSH (GSSAPI)** | `GSSAPIAuthentication yes` + 各サーバの host keytab | `kinit` 1 回で全 Linux に **パスワードレス SSH**。鍵配布不要 |
| K-02 | **NFSv4 (krb5p)** | `sec=krb5p` で完全暗号化 | LAN 内ファイル共有を **盗聴・改ざん耐性付きで提供**。NFS の弱点解消 |
| K-03 | **SMB/CIFS** | Samba AD が標準サポート | Windows / macOS / Linux 全てから同一資格でファイル共有 |
| K-04 | **HTTP / Web SSO (SPNEGO)** | Apache `mod_auth_gssapi` / nginx `spnego-http-auth` | Grafana, Gitea, Jenkins 等で **ブラウザがチケットを送り自動ログイン** (Edge/Chrome/Firefox 標準対応) |
| K-05 | **PostgreSQL / MariaDB** | `gss` 認証メソッド | DB クライアントから **パスワードレス接続**。pgAdmin 等も対応 |
| K-06 | **LDAP** | Samba AD 内蔵、GSSAPI で bind | アプリ側 (Nextcloud, GitLab) の認証バックエンドにも流用 |
| K-07 | **sudo (HBAC ライク)** | SSSD + AD グループで `sudoers` を集中管理 | 全 Linux ホストの sudo ルールを 1 箇所で管理 |
| K-08 | **WinRM / PowerShell Remoting** | Kerberos auth が既定 | Windows ホスト間の **パスワードレス管理**、Ansible WinRM も |
| K-09 | **RDP (NLA)** | ドメイン参加で自動 Kerberos | Windows リモートデスクトップが SSO 化 |
| K-10 | **CIFS / SMB マウント (Linux)** | `mount.cifs sec=krb5` | Linux 側で Samba 共有を自動マウント、認証透過 |
| K-11 | **DNS 動的更新 (GSS-TSIG)** | Samba AD 内蔵 DNS | 各クライアントが起動時に自分の A レコードを安全に登録 |

### 13.2 ○ 半 Kerberize / SSO 化できる
| # | 機能 | 統合方式 | 備考 |
|---|------|---------|------|
| K-20 | **Gitea / GitLab / Jenkins / Grafana / Nextcloud / Vaultwarden** | LDAP バックエンド + SPNEGO ブラウザ SSO | Web UI は SPNEGO、CLI は LDAP パスワード or トークン |
| K-21 | **Jupyter / VS Code Server** | SSH GSSAPI 越し or リバプロで SPNEGO | リモート開発が透過的 |
| K-22 | **CUPS (印刷)** | Kerberos 認証可 | 家庭用ではオーバーキル |
| K-23 | **IMAP / SMTP** | GSSAPI SASL | 家庭メール立てるなら |
| K-24 | **Kubernetes (kubectl)** | OIDC 経由が現実的 (KDC + Keycloak) | k3s 入れた時に検討 |
| K-25 | **Container Registry (Harbor 等)** | LDAP バックエンド | dev/CI 基盤と相性良 |

### 13.3 △ 直接の Kerberos 統合は **不可** (ご質問の WireGuard 含む)

| # | 機能 | なぜ統合できないか | 代替・回避策 |
|---|------|------------------|-------------|
| K-30 | **WireGuard** | プロトコル設計上、認証は **Curve25519 の静的公開鍵ペアのみ**。ユーザ概念・パスワード・チケットを扱わない | (a) **公開鍵を AD/LDAP 属性に格納** し、ピア構成を生成するスクリプトを Kerberos 認証付きで配布。(b) **wg-easy / wg-portal** に SPNEGO リバプロを被せ、ブラウザ SSO でピア発行 |
| K-31 | **Tailscale** | 独自 ID プロバイダ。OIDC は使えるが Kerberos 不可 | OIDC で Keycloak → Kerberos バックエンド (Phase 3) |
| K-32 | **DNSSEC / 一般 NTP** | プロトコル外 | Kerberos の前提として NTP は別途必須 (chrony) |

### 13.4 ◎ Kerberos と相性の良い代替 VPN (もし「VPN を Kerberize したい」なら)
| # | 製品 | 認証方式 |
|---|------|---------|
| V-01 | **strongSwan (IKEv2) + EAP-GSSAPI** | Kerberos チケットで VPN 接続。Windows 標準クライアント可 |
| V-02 | **OpenVPN + openvpn-auth-pam (krb5)** | パスワード認証経路を Kerberos に投げる |
| V-03 | **OpenSSH ベース VPN (sshuttle, ssh -w)** | GSSAPI SSH そのもの。シンプル |

### 13.5 WireGuard と Kerberos の現実的な組み合わせ案

WireGuard を **「LAN を超えた経路の暗号化 / 外出先からの帰宅トンネル」** に使い、その上の各サービスを Kerberize する **二層構成** が実用的。

#### 想定トポロジ (Road Warrior + Full Tunnel)
```
[外出先 PC] ── 公衆 Wi-Fi (untrusted) ── Internet
     │                                       │
     │  ① WireGuard tunnel (UDP 51820)        │
     │     AllowedIPs = 0.0.0.0/0             │
     │     (=全トラフィックをトンネル経由)    │
     ▼                                       ▼
        ┌────────────────────────────────────────┐
        │  自宅ルータ or TS-233 (WG サーバ)       │
        │  - WireGuard endpoint                  │
        │  - NAT で LAN / Internet にルーティング │
        └────────────────────────────────────────┘
                          │
                          ▼
        ┌────────────────────────────────────────┐
        │  自宅 LAN (Kerberos / NFS / SMB / DNS)  │
        │  ② サービスは全て Kerberos 認証         │
        └────────────────────────────────────────┘
```

#### 効果
| 効果 | 内容 |
|------|------|
| 通信路の暗号化 | 公衆 Wi-Fi 上の盗聴 / MITM を防止 |
| 内部リソースへのアクセス | 外出先から KDC / NFS / SMB / Web SSO に LAN 同等で接続 |
| DNS 統一 | 自宅 DNS (Samba AD 内蔵) を全クライアントで使用 → 内部名 (`kdc01.home.lab`) が解決可能 |
| 送信元 IP 固定 | 外向き通信が自宅 IP になるため、地理制約サービス / 自宅前提のフィルタにも適合 |
| Kerberos 前提条件の確保 | KDC との通信が必須なので、外出先からも TGT 取得が可能になる |

#### 鍵管理
- WireGuard の鍵は AD の `pwdLastSet` 連動などはできないため、**LDAP 属性 `wireguardPublicKey` を独自スキーマで追加** し、admin スクリプトでピア構成を生成・配布する運用が現実解。
- 「Kerberos でログオン → そのチケットで WireGuard 構成 (ピア鍵) を pull → wg-quick up」というラッパースクリプトを `clients/linux/wg-pull.sh` として提供することは可能。
- Windows クライアントは公式 WireGuard クライアントを使い、ピア構成は管理者が `*.conf` を配布 (or QR コード / wg-easy)。

#### 設計パラメータ (TBD)
| 項目 | 暫定 | 備考 |
|------|------|------|
| WG エンドポイント | TBD | 自宅ルータ or TS-233。ルータが対応していれば終端負荷を分離 |
| Public IP / DDNS | TBD | 固定 IP がなければ DDNS (no-ip, duckdns, Cloudflare DDNS) |
| UDP ポート | 51820 | 必要なら別ポートに |
| トンネル方針 | Full tunnel (`0.0.0.0/0`) | Split tunnel (自宅 LAN のみ) も選択可 |
| ピア数想定 | TBD | 利用するデバイス数 |

> ⚠ TBD-13: WG エンドポイントを自宅ルータか TS-233 か。
> ⚠ TBD-14: 動的 IP 環境なら DDNS の選定。

### 13.6 統合スコープの推奨優先度 (Phase 2.x 内に取り込むもの)
1. **K-01 SSH GSSAPI** (即時、コスト極小、利便性最大)
2. **K-03 SMB/CIFS** (Samba AD なので自動で得られる)
3. **K-11 DNS 動的更新** (同上、自動)
4. **K-07 sudo 集中管理** (SSSD 設定追加だけ)
5. **K-02 NFSv4 krb5p** (ファイル共有を NFS で立てるなら)

Phase 3 候補: K-04 (Web SSO), K-20 (各 Web アプリ統合), V-01 (VPN Kerberize)

> ⚠ TBD-11: 上記 13.6 のうちどこまでを Phase 2 のスコープに含めるか。
> ⚠ TBD-12: WireGuard を導入するか / どの代替 VPN を採用するか。

---

## 14. Phase 3: PXE / ネットブートによる OS 復元基盤

### 14.1 目的
- マシン故障 / OS 破損 / 新規プロビジョニング時に、**ネットワーク経由で OS をブートし、自動で再構築** できるようにする。
- 「壊れたら 5〜10 分で復活」を実現し、状態の所在を **「マシン」ではなく「KDC + PXE サーバ」** に寄せる。
- Kerberos / SSSD の自動 join まで含めて自動化し、再構築直後から既存ユーザでログイン可能にする。

### 14.2 スコープ
| ID | 項目 | 内容 |
|----|------|------|
| P-01 | DHCP | next-server / PXE オプション (option 66/67) を配布 |
| P-02 | TFTP | iPXE バイナリ (`undionly.kpxe`, `ipxe.efi`, `snponly.efi`) を配信 |
| P-03 | HTTP | カーネル / initramfs / squashfs / Ignition / unattend.xml を高速配信 |
| P-04 | iPXE メニュー | Windows / Fedora CoreOS / メモリ診断 / ローカルディスクブート を選択 |
| P-05 | **Fedora CoreOS PXE** | Live PXE で起動 → Ignition で初期化 → Kerberos join 済み状態で完成 |
| P-06 | **Windows PXE** | WDS or iPXE + wimboot で WIM 配信、unattend.xml でドメイン参加自動化 |
| P-07 | UEFI / Secure Boot 対応 | shim 経由 or 自前署名 |
| P-08 | 認証 / 制限 | LAN セグメント限定。VLAN 分離推奨 |

### 14.3 採用方式
| 観点 | A. **netboot.xyz + 独自カスタム** | B. **MAAS (Canonical)** | C. **Foreman / Cobbler** |
|------|----------------------------------|------------------------|--------------------------|
| 軽量さ | ◎ コンテナ 1 つ | △ x86_64 中心、TS-233 不可 | △ 重い |
| Windows 配信 | ○ iPXE + wimboot | △ Linux 中心 | ○ |
| Fedora CoreOS | ◎ Live PXE 標準 | ○ | ○ |
| ARM64 (TS-233) | ◎ | × | △ |
| 学習コスト | 低 | 中 | 高 |
| 推奨 | **◎** | × | △ |

### 14.4 暫定推奨: **A. iPXE + netboot.xyz ベース + 独自メニュー**
- TS-233 上のコンテナ (`dnsmasq` + `nginx` + `tftpd-hpa`) で軽量に構築可能。
- Fedora CoreOS は公式の **Live PXE images** を `nginx` で配信し、Ignition は KDC のホスト名や CA 証明書を埋め込んだものを動的生成。
- Windows は **iPXE → wimboot → boot.wim** 経由でセットアップ起動。`autounattend.xml` でドメイン参加と Hello 登録を自動化。

### 14.5 アーキテクチャ
```
                 [新規 / 故障マシン]
                       │ PXE Boot (Network Boot 起動)
                       ▼
   ┌─────────────────────────────────────────────┐
   │  TS-233 (Container Station)                  │
   │  ┌────────────┐  ┌────────────┐ ┌──────────┐│
   │  │ dnsmasq    │  │ tftpd      │ │ nginx    ││
   │  │ (DHCP proxy│  │ (iPXE 配信)│ │ (HTTP    ││
   │  │  or 主 DHCP│  └────────────┘ │  カーネル││
   │  └────────────┘                 │  WIM 等)││
   │                                  └──────────┘│
   │  ┌─────────────────────────────────────────┐│
   │  │ Ignition / Unattend テンプレート生成    ││
   │  │  (KDC ホスト名, CA 証明書を埋め込み)    ││
   │  └─────────────────────────────────────────┘│
   └─────────────────────────────────────────────┘
                       │
                       ▼
            [Kerberos KDC = 同 TS-233 上]
            (初回ブート時に realm join / smartcard 登録)
```

### 14.6 機能要件
| ID | 要件 | 受け入れ基準 |
|----|------|--------------|
| FR-P-01 | 新規 PC を PXE ブートしメニューが出る | iPXE メニューが 30 秒以内に表示 |
| FR-P-02 | Fedora CoreOS が無人インストール完了 | 起動後 SSH で `alice@` でログイン可能 (Kerberos 認証) |
| FR-P-03 | Windows が無人インストール完了 | 起動後ドメインユーザでサインイン可能 |
| FR-P-04 | 復元後の Kerberos join が自動 | Ignition / unattend に組み込まれ手動操作ゼロ |
| FR-P-05 | UEFI Secure Boot マシンで起動可 | shim 経由で起動成功 |
| FR-P-06 | 既存 DHCP との競合回避 | dnsmasq の `dhcp-range` を proxyDHCP モードで併用可 |

### 14.7 リスク
| # | リスク | 対策 |
|---|--------|------|
| R-P-1 | 家庭ルータの DHCP と衝突 | proxyDHCP モード (option 66 のみ追加配布) で共存 |
| R-P-2 | TS-233 1 台障害で復元基盤も失う | iPXE バイナリと CoreOS イメージは外付け USB にもミラー |
| R-P-3 | Secure Boot 鍵管理 | 自前 MOK enroll 手順を Runbook 化 |
| R-P-4 | Ignition に CA 秘密鍵等の機微情報を含めない | 公開鍵 / 信頼 CA 証明書のみ。秘密鍵は初回ブート後に取得 |

---

## 15. Phase 4: 自動更新ポリシー (リリース追従)

### 15.1 目的
- 各 OS が **常に最新のリリースに自動追従** し、人手によるメンテナンスを最小化する。
- セキュリティパッチの遅延をゼロに近づける。
- ロールバック可能性を確保し、自動更新による障害リスクを軽減。

### 15.2 OS 別方針
| OS | 更新メカニズム | 自動化方式 | ロールバック |
|----|---------------|-----------|------------|
| **Fedora CoreOS** | rpm-ostree + **zincati** (標準搭載) | リリースストリーム購読、再起動戦略を `update strategy` で制御 | ostree で前世代に rollback (`rpm-ostree rollback`) |
| **Fedora Silverblue** | rpm-ostree + systemd timer | `rpm-ostree upgrade` を週次実行 | 同上 |
| **QNAP (TS-233)** | QTS Auto Update | QTS GUI 設定で自動有効化 | スナップショット (RAID 構成依存) |
| **Windows** | Windows Update for Business | グループポリシー / Intune で「自動ダウンロード + アクティブ時間外再起動」 | 「以前のビルドに戻す」(10 日以内) |
| **コンテナ (Samba / step-ca 等)** | Watchtower / Renovate | タグ pin + Renovate で PR 自動作成、merge で適用 | Compose の image タグを前版に戻す |

### 15.3 Fedora CoreOS 自動更新 (詳細)
- **zincati** が標準搭載のため、`Type=automatic` で稼働させるだけで以下が動く:
  - リリースストリーム (`stable` / `testing` / `next`) を購読
  - 新リリース検出 → ローカルダウンロード → 再起動戦略に従い再起動
- **再起動戦略 (`/etc/zincati/config.d/`)**:
  - `immediate`: 即時再起動 (検証マシン向け)
  - `periodic`: 指定曜日 / 時間帯のみ再起動 (本番向け、推奨)
  - `fleet_lock`: 複数台で互いに排他制御 (HA 構成時)
- **想定設定** (homelab 用):
  ```toml
  [updates]
  strategy = "periodic"
  [[updates.periodic.window]]
  days = [ "Sun" ]
  start_time = "03:00"
  length_minutes = 60
  ```
- **失敗時の rollback**:
  - 起動失敗を検知すると ostree が自動で前世代を選択
  - 手動: `rpm-ostree rollback && systemctl reboot`

### 15.4 機能要件
| ID | 要件 | 受け入れ基準 |
|----|------|--------------|
| FR-U-01 | Fedora CoreOS が自動でメジャー / マイナー追従 | 設定後、リリース公開から ≤ 7 日以内に適用される |
| FR-U-02 | 更新は週次の指定時間帯のみ再起動 | 平日昼間に再起動しない |
| FR-U-03 | 起動失敗時に自動 rollback | カーネルパニック等で前世代が選択される |
| FR-U-04 | Windows は業務時間外に再起動 | アクティブ時間 9:00-22:00 を尊重 |
| FR-U-05 | コンテナイメージは tag pin + 通知ベース更新 | 自動適用ではなく PR ベースで承認制 (誤更新防止) |
| FR-U-06 | KDC は自動更新前に DB バックアップ | systemd 経由で zincati pre-reboot hook 実行 |

### 15.5 非機能要件
| ID | 内容 |
|----|------|
| NFR-U-01 | 更新失敗の通知: メール / Webhook / Grafana アラート |
| NFR-U-02 | KDC は更新ウィンドウをクライアントとずらす (循環停止回避) |
| NFR-U-03 | 更新ログを 90 日保存 |

### 15.6 リスク
| # | リスク | 対策 |
|---|--------|------|
| R-U-1 | 自動更新で互換性破壊 (Samba メジャー版アップ等) | コンテナは tag pin、OS は `stable` ストリームのみ追従 |
| R-U-2 | 全ノードが同時再起動 → 認証断 | KDC とクライアントで更新ウィンドウをずらす |
| R-U-3 | rollback できない更新 (ファームウェア等) | ファームは手動承認制とする |

---

## 16. 改訂されたフェーズ計画

| Phase | テーマ | 主要成果 | 状態 |
|-------|-------|---------|------|
| 1 | Windows 基盤 (WSL2 + Docker + buildx) | `setup-homelab.ps1` 完走 | ✅ 完了 |
| 2 | Kerberos ID 統合 + MFA (パスワード / 指紋 / YubiKey) | KDC 構築 + Win/Linux クライアント join + PKINIT + バックアップ | 🚧 要件定義中 |
| **2.x** | **WireGuard Road Warrior トンネル** | 外出先 → 自宅 WG → LAN + KDC 透過アクセス | 新規追加 |
| 3 | **PXE / ネットブート OS 復元基盤** | iPXE + Fedora CoreOS Live + Windows WIM 配信 + Ignition/unattend 自動 join | 新規追加 |
| 4 | **自動更新ポリシー (zincati / WUfB)** | Fedora CoreOS は週次自動再起動、Windows は WUfB、コンテナは Renovate PR ベース | 新規追加 |
| 5 | 監視 / Web SSO / バックアップ高度化 | Prometheus + Grafana + Loki、SPNEGO で各 Web アプリ統合 | 未着手 |
| 6 | HA / セカンダリ KDC / オフサイトバックアップ | 別ホスト or クラウドでレプリカ | 未着手 |

---

## 17. レビュー履歴

| 日付 | 版 | 変更点 | レビュア |
|------|----|--------|---------|
| 2026-05-29 | v0.1 | 初版ドラフト | — |
| 2026-05-29 | v0.2 | 認証方式 (パスワード/指紋/YubiKey) と MFA 要件を追加。CA / PKINIT を盛り込み | — |
| 2026-05-29 | v0.3 | §13 Kerberos 統合候補 (SSH/NFS/SMB/Web SSO/sudo/WireGuard 等) を追加 | — |
| 2026-05-29 | v0.4 | WireGuard Road Warrior 構成を明文化、§14 PXE 基盤 / §15 自動更新ポリシー (zincati 中心) を Phase 3/4 として追加 | — |
