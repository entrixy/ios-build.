import XCTest
@testable import Entrixy

final class SystemMessageLocalizationTests: XCTestCase {
    func testCommandUncertaintyAndControllerRefusalUseTheSelectedLanguageWithoutChangingRawStatus() {
        let raw = "Результат Bluetooth-команды неизвестен. Автоматического повтора не будет."
        XCTAssertEqual(ProductText.systemMessage(raw,language:"ru"),raw)
        XCTAssertEqual(ProductText.systemMessage(raw,language:"en"),"Bluetooth command result unknown. It will not be retried automatically.")
        XCTAssertEqual(ProductText.systemMessage("Контроллер отклонил подпись",language:"en"),"Controller rejected the signature")
        for language in ["de","es","fr","pt","zh"] {
            XCTAssertNotEqual(ProductText.systemMessage(raw,language:language),raw,language)
        }
    }
    func testOwnedCompositeErrorsAndPendingCountsTranslateWhileUnknownDetailsRemainVerbatim() {
        XCTAssertEqual(ProductText.systemMessage("Bluetooth-команда не отправлена. Контроллер отклонил подпись",language:"en"),
                       "Bluetooth command not sent. Controller rejected the signature")
        XCTAssertEqual(ProductText.systemMessage("Bluetooth-команда не отправлена. Detail 123",language:"en"),
                       "Bluetooth command not sent. Detail 123")
        let raw = "Привязки перенесены. Ключей, ожидающих защищённую связку от владельца: 2. Они сохранены в разделе «Ключи»."
        XCTAssertEqual(ProductText.systemMessage(raw,language:"en"),
                       "Bindings transferred. Keys awaiting a protected owner bundle: 2. They are saved under Keys.")
    }
    func testUnknownContentAndGenericNamesAreNotTreatedAsSystemOutcomes() {
        for value in ["Анна","Объект","Название","Мои ворота","My personal message","%1$d",""] {
            XCTAssertEqual(ProductText.systemMessage(value,language:"en"),value)
        }
    }
}
