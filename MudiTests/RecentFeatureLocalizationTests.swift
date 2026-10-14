import Foundation
import XCTest
@testable import Mudi

@MainActor
final class RecentFeatureLocalizationTests: XCTestCase {
    func testEnglishAndChineseResourcesCoverRecentFeatureCopy() throws {
        let englishPath = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let chinesePath = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: englishPath))
        let chinese = try XCTUnwrap(Bundle(path: chinesePath))
        XCTAssertEqual(MudiL10n.text("拇指快捷弧", bundle: english), "Thumb Arc")
        XCTAssertEqual(MudiL10n.text("快捷模型", bundle: english), "Quick models")
        XCTAssertEqual(MudiL10n.text("发送 + Enter", bundle: english), "Send + Enter")
        XCTAssertEqual(MudiL10n.text("取消", bundle: english), "Cancel")
        XCTAssertEqual(MudiL10n.text("拇指快捷弧", bundle: chinese), "拇指快捷弧")
        XCTAssertEqual(MudiL10n.text("当前预设：", bundle: chinese), "当前预设：")
        let englishFile = try XCTUnwrap(NSDictionary(contentsOfFile: englishPath + "/Localizable.strings") as? [String: String])
        let chineseFile = try XCTUnwrap(NSDictionary(contentsOfFile: chinesePath + "/Localizable.strings") as? [String: String])
        XCTAssertEqual(Set(englishFile.keys), Set(chineseFile.keys))
        for (key, value) in englishFile {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertNil(value.range(of: "[\\p{Han}]", options: .regularExpression), "English resource still contains Chinese: " + key)
        }
    }
    func testLocalizationKeepsCommandsAndConfiguredModelDataUnchanged() {
        let suite = "l10n-model-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuickModelStore(defaults: defaults)
        let model = QuickModel(name: "模型甲", command: "/model magpie/office/group/cheap", scopes: ["pi"])
        store.models = [model]
        XCTAssertEqual(QuickModelStore(defaults: defaults).models, [model])
        XCTAssertEqual(MudiL10n.text("/model magpie/office/group/cheap"), "/model magpie/office/group/cheap")
    }
}
