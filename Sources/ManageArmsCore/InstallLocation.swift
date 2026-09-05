import Foundation

/// 実行中バンドルの設置場所。
///
/// DMG を開いてそのまま起動されることが実際に起きる。その状態でスキルを有効化すると、
/// ユーザーは「入れた」つもりなのに、ディスクイメージを取り出した瞬間にアプリが消える。
/// 実体（`~/.agents/skills`）と symlink は残るので**壊れはしない**が、
/// 管理する手段だけが無くなるという分かりにくい状態になる。それを起動時に潰す。
public enum InstallLocation: Sendable, Equatable {
    /// `/Applications` または `~/Applications` 配下（正規の設置場所）。
    case applications
    /// 読み取り専用ボリューム = マウント中の DMG から直接起動している。
    case readOnlyVolume
    /// リムーバブル / 外付けボリューム。
    case removableVolume
    /// Gatekeeper のアプリ移動保護（App Translocation）下の一時パス。
    case translocated
    /// 内蔵ディスク上だが Applications 外（`~/Downloads`・開発ビルドなど）。
    case elsewhere

    /// 「アプリケーションフォルダへ移動」を促すべきか。
    ///
    /// `elsewhere` は促さない。ユーザーが意図してそこに置いている場合があり、
    /// 開発ビルド（`.build/…`）まで毎回ダイアログが出るのを避けるため。
    public var shouldPromptToMove: Bool {
        switch self {
        case .readOnlyVolume, .removableVolume, .translocated: true
        case .applications, .elsewhere:                        false
        }
    }
}

/// 設置場所の判定（純粋関数）。
///
/// ボリューム属性はファイルシステムを触る呼び出し側が渡す。こうしておくと
/// 判定そのものはモック不要でテストできる（DESIGN.md 10.1）。
public enum InstallLocationClassifier {
    public static func classify(
        bundlePath: String,
        applicationsPaths: [String],
        volumeIsReadOnly: Bool,
        volumeIsRemovable: Bool
    ) -> InstallLocation {
        // 移動保護下のパスも読み取り専用ボリュームに見えるため、先に判定する。
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        // 前方一致だけだと `/ApplicationsBackup` を拾う。区切りまで見る。
        if applicationsPaths.contains(where: { bundlePath.hasPrefix($0 + "/") }) { return .applications }
        if volumeIsReadOnly { return .readOnlyVolume }
        if volumeIsRemovable { return .removableVolume }
        return .elsewhere
    }
}
