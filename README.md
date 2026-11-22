# PixelLift AI

macOS 14 以降向けの画像アップスケールアプリです。SwiftUI で表示し、AI 推論は Replicate で行います。Mac に AI モデルを保存しません。初期設定の Mock では、ローカル補間で画像の比較、キュー、書き出しを確認できます。

## ビルド済みプレビュー

Apple Silicon 搭載の Mac（macOS 14 以降）で試せます。リリースの `PixelLiftAI-macOS-arm64.zip` を展開し、`PixelLift AI.app` を開きます。Xcode のインストールは不要です。プレビューにはアドホック署名を使用しています。 [macOS プレビューのダウンロード](https://github.com/atstti/PixelLift/releases/tag/v1.0.0-macos-preview)

## ソースからのビルド

ソースからビルドするには macOS 14 以降と Xcode 15 以降が必要です。Apple Silicon が対象です。外部 Swift パッケージはありません。

1. `PixelLiftAI.xcodeproj` を Xcode で開きます。
2. スキームに `PixelLiftAI`、実行先に `My Mac` を選びます。
3. ⌘R で起動します。初期状態の Mock は API キーなしで使えます。
4. Finder から複数の画像をドロップするか、⌘O で選択します。倍率を選び、画面下部の「未処理…件を開始」を押します。
5. 完了した画像を選んで比較します。書き出し形式と保存先は ⌘, で開く設定にあります。

ターミナルで Release をビルドし、アプリ本体の実容量と対象アーキテクチャを確認できます。

```sh
xcodebuild -project PixelLiftAI.xcodeproj -scheme PixelLiftAI \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build build
du -sh 'build/Build/Products/Release/PixelLift AI.app'
lipo -archs 'build/Build/Products/Release/PixelLift AI.app/Contents/MacOS/PixelLift AI'
```

プロジェクトの署名設定はローカル実行用のアドホック署名です。一般配布用の `.app` は Developer ID Application で署名し、公証できます。目標サイズは 500 MB 以下です。GitHub Actions で作成した Apple Silicon 用 Release ビルドのディスク使用量は 1,580 KiB でした。プレビュー版の公証は未実施です。

## Replicate の設定

1. Replicate のアカウントで API トークンを発行します。料金や利用条件はアカウント側で確認できます。 [API トークン](https://replicate.com/account/api-tokens) · [料金](https://replicate.com/pricing)
2. PixelLift AI の「設定」でプロバイダーを Replicate に変更します。トークンを貼り付けて「キーチェーンに保存」を押します。設定の「削除」で登録を解除できます。
3. メイン画面で倍率とモードを選び、処理を開始します。送信先・画像件数・料金に関する確認が表示されます。同意したバッチだけを送信します。再試行でも確認します。
4. 設定に表示する件数は、このセッションで作成を試みた予測の数です。利用履歴と請求額は Replicate で確認できます。 [処理履歴](https://replicate.com/predictions) · [請求情報](https://replicate.com/account/billing)

| 項目 | 実装 |
| --- | --- |
| モデル | `nightmareai/real-esrgan` |
| 固定バージョン | `f121d640bd286e1fdc67f9799164c1d5be36ff74576ee11c803ae5b665dd46aa` |
| 倍率 | `scale` に 2・4・8 を指定 |
| 顔の再現性優先 | `face_enhance: false`。顔の補正処理を無効にして Real-ESRGAN で高画質化 |
| 顔を補正 | `face_enhance: true`。Real-ESRGAN と GFPGAN を使用 |
| 画像の受け渡し | Replicate Files の `POST /v1/files` が返す `urls.get` を `image` に指定 |
| 結果 | URI 形式の出力を Replicate の配信用ドメインからダウンロード |

8 倍の予測は 1 回です。画像サイズと処理時間に応じて費用が変わります。ノイズ除去・シャープ化・質感調整の個別設定は、モデルの入力スキーマにありません。処理で目や口元などの特徴が変化する場合は、比較プレビューで元画像と照合できます。 [固定バージョンの入出力仕様](https://replicate.com/nightmareai/real-esrgan/versions/f121d640bd286e1fdc67f9799164c1d5be36ff74576ee11c803ae5b665dd46aa/api) · [HTTP API](https://replicate.com/docs/reference/http) · [Files を含む OpenAPI](https://api.replicate.com/openapi.json)

## 画像とストレージ

- 入力は PNG・JPEG・TIFF・WebP です。ImageIO でファイル形式と EXIF の向きを読み取ります。複数ページ・アニメーション画像は先頭を処理します。
- 元画像は選択されたパスから参照します。送信時は向きを反映した PNG を生成し、元の GPS や撮影情報を除去します。画像に写った情報は送信されます。
- 読み込み上限は 100 MiB です。Replicate への送信は元ファイルと送信用 PNG のそれぞれ 24 MiB 以下に制限します。入力と出力の上限はどちらも長辺 16,384 px、3,200 万画素です。結果ファイルの上限は 128 MiB です。
- 比較プレビューは左右で表示位置を共有します。100・200・400% の表示は Retina の表示倍率を考慮します。比較表示では処理後の画素数を基準に元画像を揃えます。
- PNG・JPEG・TIFF で個別・一括保存できます。既存名は保持し、`photo_4x_2.png` のように衝突時は連番を追加します。JPEG の透明部分は白になります。書き出し先には排他的なリネームをサポートするボリュームを指定してください。
- 作業ファイルと結果の合計上限は 512 MiB です。混雑時は処理結果の保存とキャッシュ削除で空きを確保できます。アプリの終了時に作業領域を削除します。異常終了で残った作業データは次の起動時に削除します。書き出した画像はユーザーが管理します。
- ジョブと画像の履歴はセッション内に保持します。設定と保存先へのアクセス権は残ります。アップロードしたファイルの削除は処理終了時に要求します。ファイルは Replicate の `expires_at` に従い、予測の入出力データと結果 URL は既定で約 1 時間で失効します。 [データ保持](https://replicate.com/docs/topics/predictions/data-retention) · [出力ファイル](https://replicate.com/docs/topics/predictions/output-files)
- キャンセルでは受付済み予測の停止を要求します。予測には 10 分のサーバー側期限があります。送信結果が不明な場合はダッシュボードで状況を確認できます。HTTP 429 と安全に再試行できる操作は指数バックオフを使います。結果が不明な予測作成の POST は自動再送の対象外です。

## 構成とテスト

```text
PixelLiftAI.xcodeproj/              macOS アプリと共有スキーム
App/                               SwiftUI、MVVM、Keychain、日本語リソース
Packages/PixelLiftCore/Sources/      画像処理、プロバイダー、キュー、キャッシュ
Packages/PixelLiftCore/Tests/        API モック、画像、キュー、ストレージのテスト
TESTING.md                         実行結果と macOS での確認項目
```

新しい AI サービスは `CloudUpscaleProvider` に適合させ、`ProviderChoice` と生成処理に追加します。画面の日本語をローカライズの元言語とし、SwiftUI の文字列と `String(localized:)` から Xcode で英語翻訳を追加できます。

```sh
swift test --package-path Packages/PixelLiftCore
```

テストの通信先はスタブです。macOS では ImageIO・Core Image・出力ファイル・メモリ計測のテストも実行対象になります。 [実行結果と確認項目](TESTING.md)

## Git

作業履歴は `main` 上の機能別コミットです。すでに作成した空の GitHub リポジトリを使う場合は、ローカル履歴を確認した後に、そのリポジトリを `origin` に登録できます。
