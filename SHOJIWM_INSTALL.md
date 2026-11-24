# ShojiWM + shoji-bar-4 NixOS 導入マニュアル

新しい PC（NixOS / Flakes 環境）で、ShojiWM コンポジターと公式デスクトップシェル `shoji-bar-4` を再現性よく一括導入するための手順書です。

---

## 1. ファイル構成と役割

| ファイル | 役割 |
|---|---|
| `flake.nix` | `shojiwm` flake input の登録、`shojiwm.nixosModules.default` の読み込み、`packages.<system>.shoji-bar-4` の公開 |
| `shojiwm.nix` | `shoji-bar-4` の Nix パッケージ定義と NixOS モジュール（シェル本体・依存パッケージ・必須サービス・初期設定の自動補正） |
| `configuration.nix` | `shojiwm.nix` の import と、`programs.shojiwm` / `programs.shojiwmDesktop` の有効化 |

`shojiwm.nix` を有効にすると、以下が自動的に揃います。

- `shoji-bar-4`（Rust でビルドされ、Wayland / Vulkan / OpenGL / Fontconfig / PAM ライブラリをラップ済み）
- ランタイム依存パッケージ: `cliphist`, `wl-clipboard`, `zenity`, `playerctl`, `bibata-cursors`
- システムサービス: `services.upower`, `services.power-profiles-daemon`
- SDDM の ShojiWM セッションで、Wayland 起動後に `shojiwm-session.target` を開始し、終了時に停止（`graphical-session.target` と連携）
- KWallet の PAM ロック解除と Secret ポータルを ShojiWM でも使用（`programs.shojiwmDesktop.enableKWallet = false;` で無効化可能）
- Flatpak アプリの `StartupWMClass` を照合し、Vivaldi などをドックに固定できるように補正
- `~/.config/shojiwm/src/index.tsx` の初回自動補正:
  - `SHELL` を Nix 管理の `shojiwm-desktop-shell` に差し替え（セッション初期化後に `shoji-bar-4` を起動。既存の標準設定も更新）
  - 未導入になりやすい `kitty` / `google-chrome-stable` を既定端末・ブラウザ（既定: `konsole` / `firefox`）に差し替え
  - キーボードレイアウトを JIS（`layout: "jp"`）に設定し、上流既定の Razer キーボード向け US 上書きを除去

---

## 2. 新しい PC への導入手順

既存環境でこの修正を適用した場合は、保存作業を済ませてログアウトし、SDDM から ShojiWM に入り直してください。
ブラウザの認証情報の保存方式は変更せず、既存の KWallet を利用します。
メールの再ログインが再発しないことは、Vivaldi を終了してから OS を再起動して確認してください。

### 前提条件

- NixOS で Flakes が有効化されていること（`nix.settings.experimental-features = [ "nix-command" "flakes" ];`）
- ディスプレイマネージャー（SDDM など）および基本的なデスクトップサービス（`networking.networkmanager`, `services.pipewire`, `hardware.bluetooth`）が有効であること

### 手順 1: `shojiwm.nix` を配置する

このリポジトリの `shojiwm.nix` を、新しい PC の `/etc/nixos/shojiwm.nix` にコピーします。

### 手順 2: `flake.nix` に ShojiWM を追加する

`/etc/nixos/flake.nix` に `shojiwm` input とモジュールを追加します（ホスト名は新しい PC のものに置き換えてください）。

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.shojiwm.url = "github:bea4dev/ShojiWM";
  inputs.shojiwm.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, shojiwm, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system}.shoji-bar-4 = (import ./shojiwm.nix { inherit pkgs; }).package;

      nixosConfigurations.<新しいホスト名> = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          shojiwm.nixosModules.default
          ./configuration.nix
        ];
      };
    };
}
```

> **ポイント**: `inputs.shojiwm.inputs.nixpkgs.follows = "nixpkgs";` を付けることで、システムの `nixpkgs`（グラフィックドライバ・glibc 等）と揃います。

### 手順 3: `configuration.nix` にモジュールと設定を追加する

`/etc/nixos/configuration.nix` の `imports` に `shojiwm.nix` を追加し、`programs.shojiwm` を有効化します。

```nix
{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    (import ./shojiwm.nix { inherit pkgs; }).nixosModule
  ];

  programs.shojiwm = {
    enable = true;
    initConfig = {
      enable = true;
      users = [ "<ユーザー名>" ];
    };
  };

  # 必要に応じて端末やブラウザを変更（省略時の既定値は konsole / firefox）
  # programs.shojiwmDesktop = {
  #   enableShell = true;
  #   terminal = "konsole";
  #   browser = "firefox";
  # };
}
```

> **注意**: `programs.shojiwmDesktop.terminal` や `browser` に指定したコマンド（例: `konsole`, `firefox`）がシステムにインストールされていることを確認してください。KDE Plasma を使わない環境では `environment.systemPackages` に任意の端末（例: `pkgs.kitty` や `pkgs.alacritty`）を追加し、`terminal` に指定します。

### 手順 4: Git 管理下の場合は新規ファイルをステージする

`/etc/nixos` が Git リポジトリの場合、未追跡ファイルは Flake 評価から見えません。`shojiwm.nix` を必ず追加してください。

```sh
sudo git -C /etc/nixos add shojiwm.nix
```

### 手順 5: Flake ロック作成とシステム適用

既存の `nixpkgs` バージョンを変えずに `shojiwm` input だけロックに追加する場合:

```sh
sudo nix flake lock /etc/nixos
```

その後、システムへ適用します（初回は ShojiWM 本体と `shoji-bar-4` の Rust ビルドが走るため、数分〜十数分かかります）。

```sh
sudo nixos-rebuild switch --flake /etc/nixos#<新しいホスト名>
```

> **補足**: 2 回目以降、現在のホスト名と `nixosConfigurations` 名が一致していれば `--flake` ごと省略して `sudo nixos-rebuild switch` だけで適用できます。

### 手順 6: ShojiWM セッションを起動する

- **SDDM（ログイン画面）から**: ログアウト → 画面端のセッション選択から **ShojiWM** を選んでログイン
- **TTY から直接起動**: `Ctrl+Alt+F3` → ログイン → `shoji_wm --tty`

---

## 3. 主要キーバインド（初期設定）

| キー | 動作 |
|---|---|
| `Super`（単押し） / `Super+A` | アプリランチャー（`shoji-bar-4`） |
| `Super+T` | ターミナル起動（既定: `konsole`） |
| `Super+B` | ブラウザ起動（既定: `firefox`） |
| `Super+E` | ファイルマネージャー（`dolphin`） |
| `Super+Q` | フォーカス中ウィンドウを閉じる |
| `Super+Tab` | ウィンドウ切替 |
| `Super+M` / `Super+F` | 最大化 / フルスクリーン切替 |
| `Super` + 左ドラッグ / 右ドラッグ | ウィンドウ内の任意の場所から移動 / リサイズ |
| `Super+N` / `Super+C` / `Super+V` | クイック設定 / カレンダー / クリップボード履歴 |
| `Super+L` | 画面ロック（PAM `login` 認証） |
| `Super+Shift+R` | 設定のホットリロード（CLI: `shoji_wm -r`） |
| `Super+Shift+Q` | ShojiWM を終了（CLI: `shoji_wm -q`） |

ユーザー設定ファイルは `~/.config/shojiwm/src/index.tsx` にあります。

---

## 4. アップデート手順

### ShojiWM 本体だけ更新する

```sh
sudo nix flake update shojiwm --flake /etc/nixos
sudo nixos-rebuild switch --flake /etc/nixos#<ホスト名>
```

### `shoji-bar-4` を更新する

1. 最新のコミットハッシュと SRI ハッシュを取得します。
   ```sh
   nix flake prefetch --json github:bea4dev/shoji-bar-4
   ```
2. 必要に応じて `shoji-bar-4` の `Cargo.lock` 内の `AntiWebUI` コミットハッシュも確認し、同様に取得します。
   ```sh
   nix flake prefetch --json github:bea4dev/AntiWebUI/<AntiWebUIのrev>
   ```
3. `/etc/nixos/shojiwm.nix` の `version` / `rev` / `hash` / `outputHashes` を更新し、ビルド確認後に適用します。
   ```sh
   nix build /etc/nixos#shoji-bar-4 --no-link
   sudo nixos-rebuild switch --flake /etc/nixos#<ホスト名>
   ```

---

## 5. トラブルシューティング

### 画面は映りカーソルも動くが、バーもアプリも何も出ない

- ShojiWM の上流デフォルト設定は `kitty` / `google-chrome-stable` / 手動ビルド版 `~/.config/shoji-bar-4/target/release/shoji-bar-4` を参照します。
- `shojiwm.nix` が import されていれば自動で `shoji-bar-4` / `konsole` / `firefox` に補正されます。未適用なら `nixos-rebuild switch` を実行してください。

### `ReferenceError: SHELL is not defined` が出る

- `~/.config/shojiwm/src/index.tsx` の先頭付近（シェル起動箇所）に `const SHELL = "shoji-bar-4";` が定義されているか確認してください。修正後は `Super+Shift+R` または `shoji_wm -r` で再読み込みできます。

### 設定を直したのに `shoji-bar-4` が自動起動しない

- `index.tsx` の `shell` プロセスは `runPolicy: "once-per-session"` のため、同じセッション内でホットリロードしただけでは再起動しない場合があります。一度ログアウトして ShojiWM に再ログインするか、端末から手動で `shoji-bar-4 &` を起動してください。

### ウィンドウの上部（掴める部分）がトップバーの下に潜り込んで移動できない

- **今すぐ動かす方法**: タイトルバーがバーの下に隠れていても、**`Super`（Windows キー）+ ウィンドウ内のどこでも左ドラッグ**で移動できます（`Super` + 右ドラッグでリサイズ、`Super+M` で最大化切替）。
- **原因**: ShojiWM の初期 `~/.config/shojiwm/src/window-manager.ts` では、フローティングウィンドウの初回中央配置（`centeredFloatingRect`）・ドラッグ終了時（`onFloatingWindowMove`）・バー領域更新時（`refreshUsableAreaLayout`）に上端 `y` が `COMPOSITOR.layer.usableArea(monitor).y` 以上へクランプされません。そのため Vivaldi のように高さの大きいウィンドウや、上方向へドラッグしたウィンドウの上部がトップバーの下に潜り込むことがあります。
- **恒久対策**: `~/.config/shojiwm/src/window-manager.ts` に以下のヘルパー関数を追加し、3 箇所で上端をクランプしたあと `Super+Shift+R`（または `shoji_wm -r`）でリロードします。
  ```ts
  function clampFloatingTopToUsableArea(
    rect: ManagedWindowRect,
    monitor: string,
  ): ManagedWindowRect {
    const usable = COMPOSITOR.layer.usableArea(monitor);
    if (!usable) {
      return rect;
    }
    const y = read(rect.y);
    if (y >= usable.y) {
      return rect;
    }
    return {
      x: read(rect.x),
      y: usable.y,
      width: read(rect.width),
      height: read(rect.height),
    };
  }
  ```
  - `onFloatingWindowMove`（ドラッグ確定の `if (!snapped)` ブロック）: `nextRect` を `clampFloatingTopToUsableArea(nextRect, drag.workspace.monitor)` でクランプして適用する。
  - `Workspace.refreshUsableAreaLayout`: 最大化・フルスクリーン・最小化以外のフローティングウィンドウも `clampFloatingTopToUsableArea(currentRect, this.monitor)` でクランプし、`syncFloatingWindowRect` を呼ぶ。
  - `Workspace.centeredFloatingRect`: `x` / `y` をそれぞれ `Math.max(logicalX, logicalX + (logicalWidth - width) / 2)`、`Math.max(logicalY, logicalY + (logicalHeight - height) / 2)` にする。

### マウスカーソルが白背景で白くなって見えない

- デフォルト設定で指定されている `Bibata-Modern-Ice` が未導入だと、縁なしの白いフォールバックカーソルになります（ログに `failed to load default xcursor theme image` が出ます）。
- `shojiwm.nix` に `bibata-cursors` を含めてあるため、`sudo nixos-rebuild switch` 後に再ログインまたは `Super+Shift+R` を実行すれば黒縁付きの `Bibata-Modern-Ice` が適用されます。黒カーソルが好みの場合は `~/.config/shojiwm/src/index.tsx` の `theme` を `"Bibata-Modern-Classic"` に変更してください。

### キーボードが US 配列として認識される

- ShojiWM は Plasma の X11 設定（`services.xserver.xkb.layout`）とは独立して独自の xkb 設定を持ち、未指定だと US 配列になります。`shojiwm.nix` の補正で `~/.config/shojiwm/src/index.tsx` の `input.global.keyboard` に `layout: "jp"` が入るため、`nixos-rebuild switch` 後に再ログインすれば JIS 配列になります。
- 今すぐ直す場合は `index.tsx` の `keyboard: { ... }` に `layout: "jp",` を追加し、`Super+Shift+R`（または `shoji_wm -r`）でリロードしてください。上流既定にある `input.device["Razer Razer Blade Keyboard"] = { keyboard: { layout: "us" } }` はこの PC には不要なので削除して構いません。

### ログの確認先

- ShojiWM セッションログ: `~/.local/state/shoji_wm/logs/latest.log`

### `shoji-bar-4` 単体でビルド・描画確認したい場合

```sh
nix build /etc/nixos#shoji-bar-4 --no-link --print-out-paths
shoji-bar-4 preview bar /tmp/bar-preview.png
```

### （この PC 向けメモ）手動ビルドの整理

`shojiwm.nix` を適用して `nixos-rebuild switch` すると、`~/.config/shojiwm/src/index.tsx` の `SHELL` が自動的に Nix 版の `shoji-bar-4` に切り替わります。次回再ログイン後にバーが正常表示されることを確認したら、作業中に手動クローンした `~/.config/shoji-bar-4` は削除しても問題ありません。
