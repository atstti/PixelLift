import Foundation
import PixelLiftCore
import SwiftUI

struct UserMessage: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let text: String
}

extension PixelLiftError {
    var userText: String {
        switch self {
        case .sourceChanged: return String(localized: "追加後に元画像が変更されました。一覧から外して追加し直してください。")
        case .invalidImage: return String(localized: "対応する画像を読み込めませんでした。")
        case .dimensionsTooLarge: return String(localized: "画像の辺が16,384 px、または面積が3,200万画素の上限を超えます。倍率を下げてください。")
        case .inputTooLarge: return String(localized: "入力画像が容量上限を超えました。")
        case .outputTooLarge: return String(localized: "処理結果が128 MiBの上限を超えました。")
        case .encodingFailed: return String(localized: "画像を書き出せませんでした。")
        case .cacheFull: return String(localized: "結果キャッシュの空きが足りません。必要な結果を保存してから、不要な結果を削除してください。")
        case .cacheBusy: return String(localized: "処理または保存が完了してからキャッシュを操作してください。")
        case .missingToken: return String(localized: "設定でReplicateのAPIキーを保存してください。")
        case .invalidToken: return String(localized: "APIキーに空白または無効な文字が含まれています。")
        case .invalidResponse: return String(localized: "Replicateから読み取れない応答が返りました。")
        case .replicateResponse(let stage):
            switch stage {
            case .uploading: return String(localized: "Replicateの画像アップロード応答を読み取れませんでした。")
            case .processing: return String(localized: "Replicateの処理状況を読み取れませんでした。ダッシュボードで結果を確認してください。")
            case .downloading: return String(localized: "Replicateの結果を受信できませんでした。ダッシュボードで処理結果を確認してください。")
            case .preparing, .starting: return String(localized: "Replicateから読み取れない応答が返りました。")
            }
        case .uploadResponse(let status, let bytes, let problem):
            let detail: String
            switch problem {
            case .empty: detail = String(localized: "応答が空です。")
            case .tooLarge: detail = String(localized: "応答が大きすぎます。")
            case .missingID: detail = String(localized: "応答にファイルIDがありません。")
            case .invalidID: detail = String(localized: "ファイルIDの形式を読み取れません。")
            case .html: detail = String(localized: "APIの応答がHTMLでした。")
            case .unreadable: detail = String(localized: "応答をJSONとして読み取れません。")
            }
            return String(localized: "Replicateのアップロード応答（HTTP \(status.formatted(.number.grouping(.never)))、\(bytes.formatted())バイト）。\(detail)")
        case .predictionOutputUnavailable:
            return String(localized: "Replicateで処理は完了しましたが、結果の画像URLを取得できませんでした。ダッシュボードで処理結果を確認してください。")
        case .unsafeURL: return String(localized: "Replicateの許可ドメイン以外のURLが返りました。")
        case .unauthorized: return String(localized: "Replicateで認証できませんでした。APIキーを確認してください。")
        case .rateLimited: return String(localized: "Replicateのレート制限に達しました。時間をおいて再試行してください。")
        case .timedOut: return String(localized: "処理がタイムアウトしました。")
        case .connection: return String(localized: "ネットワークに接続できませんでした。")
        case .ambiguousSubmission: return String(localized: "送信結果が不明です。重複課金を避けるため、Replicateのダッシュボードで実行状況を確認してから再試行してください。")
        case .http(let status): return String(localized: "ReplicateがHTTP \(status.formatted(.number.grouping(.never)))を返しました。")
        case .predictionFailed: return String(localized: "Replicateで画像処理が失敗しました。詳細はReplicateのダッシュボードで確認できます。")
        case .predictionCanceled: return String(localized: "Replicateで処理がキャンセルされました。")
        case .cloudCancellationUnconfirmed: return String(localized: "クラウド側の停止を確認できませんでした。Replicateのダッシュボードで処理状況を確認してください。")
        case .wrongOutputDimensions: return String(localized: "結果の解像度が指定倍率と一致しませんでした。")
        case .fileOperation: return String(localized: "ファイルを操作できませんでした。アクセス権と空き容量を確認してください。")
        }
    }
}

func userText(_ error: Error) -> String {
    if let error = error as? KeychainFailure, let message = error.errorDescription { return message }
    return (error as? PixelLiftError ?? .fileOperation).userText
}

extension UpscaleMode {
    var title: LocalizedStringKey {
        switch self {
        case .standard: return "高画質化"
        case .preserveFaces: return "顔の再現性優先"
        case .enhanceFaces: return "顔を補正（GFPGAN）"
        }
    }
}

extension UpscaleStage {
    var title: LocalizedStringKey {
        switch self {
        case .preparing: return "画像を準備中"
        case .uploading: return "アップロード中"
        case .starting: return "クラウドに処理を要求中"
        case .processing: return "画像を処理中"
        case .downloading: return "結果をダウンロード中"
        }
    }
}
