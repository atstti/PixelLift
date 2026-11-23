# PixelLift AI for Windows

Windows 11 x64 向けのアプリです。日本語の画面で、画像をドラッグして 2・4・8 倍に拡大し、前後を比較できます。初期設定はローカル補間（Mock）です。画像を PC 内で処理します。

## インストールと使い方

1. リリースの **PixelLiftAI-Windows-x64-Setup.exe** をダウンロードして起動します。実行環境も同梱しています。 [Windows プレビュー](https://github.com/atstti/PixelLift/releases/tag/v1.0.0-windows-preview)
2. スタートメニューから **PixelLift AI** を開き、PNG・JPEG・TIFF・WebP 画像を追加します。複数ページ・アニメーション画像は先頭を使います。
3. 倍率を選んで **一括処理を開始** を押します。選んだ画像だけ処理する場合は、右の **選択画像を処理** を押します。
4. スライダーで前後を比較し、保存先を選んで PNG、JPEG または TIFF に保存します。名前には倍率が付き、既存ファイルと同名なら連番を追加します。
5. Replicate を使う場合は、プロバイダーを切り替え、API キーを設定します。処理前に画像の送信と利用料金を確認します。キーは Windows の現在のユーザーに紐付けて暗号化します。

Windows 向けインストーラーは未署名のため、初回に Windows が確認を表示することがあります。一時結果は終了時に削除します。残したい画像は終了前に書き出してください。出力上限は長辺 16,384 px、3,200 万画素です。

## ソースからビルド

.NET 10 SDK がある Windows で実行します。

```powershell
dotnet publish Windows/PixelLift.Windows/PixelLift.Windows.csproj -c Release -r win-x64 --self-contained true -o publish/windows
```

GitHub Actions は Windows 上でインストーラーを作り、インストール後のアプリで画像形式、倍率、EXIF の向き、前後比較の画面、複数画像処理・保存、API キーの暗号化、Replicate のスタブを使った処理を検証します。
