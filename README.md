# vMixrInterface

vMixr仮想音声ドライバと組み合わせるmacOS用音声ルーティング／ミキサーアプリ。
通常オーディオデバイスでのみ利用する場合も動作する。

- ミキサー: 入力4ch/出力4ch（メイン、Aux 1〜3）/バス4系統、チャネル単位のデバイス選択
- 設定ファイル（plist）の読み書き、AppleScriptインタフェース、メニューバー常駐（詳細はdocs/）
- ストリーミング: Icecast 2 / SHOUTcast v1 / RTMP（Phase 3）

## 要件

- macOS 26以降（arm64）
- 想定ワークフローでは[vMixr](https://github.com/ktam72/vMixr)ドライバの導入が前提

## Quick Start

1. vMixrドライバをインストールする

   - [vMixr](https://github.com/ktam72/vMixr)リポジトリを取得する
   - `vMixr.driver`を`/Library/Audio/Plug-Ins/HAL/`へコピーする
   - `coreaudiod`を再起動（`sudo killall coreaudiod`）するか再起動し、デバイスを表示する

2. アプリをビルドする

   xcodebuild -project vMixrInterface.xcodeproj -scheme vMixrInterface -configuration Release -derivedDataPath build

3. アプリを実行する

   open build/Build/Products/Release/vMixrInterface.app

   - 初回起動時はマイク使用の権限を付与する
   - 起動時にウィンドウは自動表示されず、「ウインドウ」メニュー（ミキサー）から開く

## ドキュメント

docs/（Concept.md / Specification.md / Design.md / ChangeRequest.md）

## License

[Apache License 2.0](LICENSE)
