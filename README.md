# homelab-setup

QNAP TS-233(ARM64)+ Windows + Fedora Atomic を見据えた自宅 homelab のフェーズ 1 セットアップ用 PowerShell スクリプト。Windows ホストに **WSL2 / Ubuntu-24.04 / Docker Desktop / buildx(multi-arch:linux/arm64 + linux/amd64)** を 1 行で導入します。

## ワンライナー(管理者 PowerShell)

PowerShell を **管理者として実行** で開き、次を貼り付けて Enter:

```powershell
iex (irm https://raw.githubusercontent.com/nagata1634/homelab-setup/main/setup-homelab.ps1)
```

実行中、自動で **2 回再起動** します(stage1 → stage2 → stage3)。再起動後は Task Scheduler 経由でログイン時に自動再開します。所要時間はネット速度次第で **20〜40 分** 程度。

## 何が起こるか

| stage | 主な処理 | 再起動 |
|---|---|---|
| stage1 | VirtualMachinePlatform / WSL / HypervisorPlatform を有効化、`wsl --install --no-distribution` | あり |
| stage2 | Ubuntu-24.04 を `--no-launch` で登録、Docker Desktop をサイレントインストール | あり |
| stage3 | Docker engine 起動待ち、`hello-world`、`tonistiigi/binfmt --install all`、`docker buildx create --name multi --use --bootstrap`、`linux/arm64` 検証 | なし(完了) |

完了後、デスクトップに `homelab-docs\` フォルダと `homelab-setup-result.txt`(最終サマリ)が置かれます。

## 中断・再開

- 各 stage の状態は `C:\ProgramData\homelab-setup\state.json` に保存されます(`stage1` / `stage2` / `stage3` / `done` / `stageN_failed`)。
- エラーで止まった場合は **同じワンライナーをもう一度実行** すれば、中断したステージから再開します(スクリプトは idempotent)。
- 手動再開タスクを削除したい場合: 管理者 PowerShell で `Unregister-ScheduledTask -TaskName HomelabSetupResume -Confirm:$false`

## ログ

- 実行ログ: `C:\ProgramData\homelab-setup\setup.log`
- PowerShell トランスクリプト: `C:\ProgramData\homelab-setup\transcript.log`

## 既知の制約

- Docker Desktop は `--accept-license --quiet` でサイレント導入しますが、**初回起動時にバージョンによっては「Use recommended settings」ダイアログが出る** ことがあります。出た場合は OK を 1 回押してください(scriptはそのまま engine 起動を待ちます)。
- `wsl --install -d Ubuntu-24.04 --no-launch` でディストロは登録のみ。Ubuntu 内のユーザ作成は Docker Desktop の WSL integration 経由なら不要ですが、Ubuntu を独立に使うなら別途 `wsl -d Ubuntu-24.04` で初期化してください。
- 対象 OS: Windows 10 21H2(build 19044)以上 / Windows 11。Home エディションでも WSL2 + Docker Desktop は動作します。

## セキュリティの注意 ⚠️

`iex (irm ...)` 形式(いわゆる curl-pipe)は **取得した内容をそのまま管理者で実行** します。実行前に必ず GitHub 上で [`setup-homelab.ps1`](./setup-homelab.ps1) を目視確認することを **強く推奨** します。フォークして自分の repo の raw URL を使う運用が最も安全です(フォークしたら `setup-homelab.ps1` 冒頭の `$Script:SelfUrl` を自 repo の raw URL に書き換えてください)。

## ライセンス

MIT — [LICENSE](./LICENSE) 参照。
