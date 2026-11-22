# テスト結果

## 実行した確認

環境は Linux x86_64、Swift 6.1.2 です。実際の Replicate リクエストは 0 件です。

| 確認対象 | 結果 |
| --- | --- |
| Swift Package ビルド | 成功 |
| API と URLSession のスタブテスト | 8 件成功。スキーマ、認証エラー、429、5xx、タイムアウト、キャンセル、送信上限、認証情報の送信先を確認 |
| キューとキャッシュ | 5 件成功。同時実行上限、処理待ちと実行中のキャンセル、再試行、容量上限、キャッシュ削除、起動時の残留データ削除を確認 |
| Swift ソースの構文 | アプリ・パッケージ・テストを構文解析 |
| Xcode プロジェクト構成 | OpenStep plist と共有スキームを解析。プロジェクト参照、アセット、アプリの entitlements を確認 |

## macOS で実行するテスト

`swift test --package-path Packages/PixelLiftCore` で、上記 13 件に加えて次の 5 件を実行できます。Linux ではこれらの macOS 専用テストは対象外でした。

| テスト | 対象 |
| --- | --- |
| `testPNGJPEGAndTIFFInputWithFileSignatureDetection` | 拡張子に依存しない画像形式判定と不正ファイル |
| `testWebPInputAndCloudPreparation` | WebP の読み込みと送信用 PNG の生成 |
| `testEXIFOrientationsAndMetadataRemoval` | EXIF 1〜8 の寸法、送信画像の向きと GPS 情報除去 |
| `testMockAndSaveAllFormatsWithoutOverwriting` | Mock の実寸、PNG・JPEG・TIFF の再読込、既存ファイル保護 |
| `testLargePreviewAndResizeMemory` | 3,000 × 2,000 px の縮小表示と 24 MP 結果の書き出し、XCTest のメモリ計測 |

## macOS での確認項目

- Xcode で Debug と Release をビルドし、Apple Silicon の Mac で起動する。Release の `.app` に対してファイル容量とバイナリのアーキテクチャを計測する。
- Finder ドロップと複数選択、書き出し先の再起動後の復元、Keychain の保存・削除を確認する。Mock ではネットワーク接続がない状態も確認する。
- Retina で 100% を検証し、200%・400% で左右の位置が揃うことを確認する。キューの同時実行とキャンセル、一括書き出し後のキャッシュ削除も確認する。
- Replicate 実環境の送信と画質・所要時間・請求の測定には、実課金を伴うテストへの明示的な許可が必要です。
