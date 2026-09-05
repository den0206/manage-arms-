import Foundation
import Testing
@testable import ManageArmsCore

/// 設置場所ガードの分類ロジック。
/// 「促す / 促さない」の線引きをここで固定する。促しすぎると開発中に毎回ダイアログが出て、
/// 促さなすぎると DMG から起動したまま使われる。
@Suite("設置場所の判定")
struct InstallLocationTests {

    private let applications = ["/Applications", "/Users/tester/Applications"]

    private func classify(
        _ path: String,
        readOnly: Bool = false,
        removable: Bool = false
    ) -> InstallLocation {
        InstallLocationClassifier.classify(
            bundlePath: path,
            applicationsPaths: applications,
            volumeIsReadOnly: readOnly,
            volumeIsRemovable: removable
        )
    }

    // MARK: - 正規の設置場所

    @Test func システムのアプリケーションフォルダ() {
        #expect(classify("/Applications/ManageArms.app") == .applications)
    }

    @Test func ユーザーのアプリケーションフォルダ() {
        #expect(classify("/Users/tester/Applications/ManageArms.app") == .applications)
    }

    @Test func アプリケーションフォルダ配下のサブフォルダ() {
        #expect(classify("/Applications/Utilities/ManageArms.app") == .applications)
    }

    /// 前方一致の誤爆防止。`/ApplicationsBackup` は Applications ではない。
    @Test func 名前が似ているだけのフォルダは対象外() {
        #expect(classify("/ApplicationsBackup/ManageArms.app") == .elsewhere)
    }

    // MARK: - 促すべき設置場所

    @Test func マウント中のディスクイメージ() {
        #expect(classify("/Volumes/ManageArms/ManageArms.app", readOnly: true) == .readOnlyVolume)
    }

    @Test func 外付けディスク() {
        #expect(classify("/Volumes/USB/ManageArms.app", removable: true) == .removableVolume)
    }

    /// 移動保護下のパスも読み取り専用に見えるので、ボリューム属性より先に判定する。
    @Test func 移動保護は読み取り専用より優先する() {
        let path = "/private/var/folders/ab/xyz/d/AppTranslocation/1234-5678/d/ManageArms.app"
        #expect(classify(path, readOnly: true) == .translocated)
    }

    // MARK: - 促さない設置場所

    @Test func ダウンロードフォルダは促さない() {
        #expect(classify("/Users/tester/Downloads/ManageArms.app") == .elsewhere)
    }

    /// 開発ビルドの置き場。ここで促すと F5 のたびにダイアログが出て邪魔になる。
    @Test func 開発ビルドのパスは促さない() {
        #expect(classify("/Users/tester/manage-arms/.build/arm64-apple-macosx/debug/ManageArms Debug.app")
                == .elsewhere)
    }

    // MARK: - 促す / 促さないの線引き

    @Test func 促すのはボリュームと移動保護の場合だけ() {
        #expect(InstallLocation.readOnlyVolume.shouldPromptToMove)
        #expect(InstallLocation.removableVolume.shouldPromptToMove)
        #expect(InstallLocation.translocated.shouldPromptToMove)
        #expect(!InstallLocation.applications.shouldPromptToMove)
        #expect(!InstallLocation.elsewhere.shouldPromptToMove)
    }

    /// Applications 配下なら、ボリューム属性がどうであれ促さない。
    @Test func アプリケーションフォルダはボリューム属性より優先する() {
        #expect(classify("/Applications/ManageArms.app", readOnly: true, removable: true) == .applications)
    }
}
