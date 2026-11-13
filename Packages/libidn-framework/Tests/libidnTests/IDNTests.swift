import XCTest
import libidn

final class IDNTests: XCTestCase {
    func testNode() {
        XCTAssertEqual(NSString.idn_prepNode("L.Karpov"), "l.karpov")
        XCTAssertEqual(NSString.idn_prepNode("Иван"), "иван")
        XCTAssertEqual(NSString.idn_prepNode("Straße"), "strasse")
        XCTAssertEqual(NSString.idn_prepNode("a\u{00AD}b"), "ab")
        for bad in ["a b", "a@b", "a/b", "a:b", "a&b", "a'b", "a\"b", "a<b", "a>b", "a\u{0}b", "a\u{7F}b", "a\u{00A0}b"] {
            XCTAssertNil(NSString.idn_prepNode(bad), bad)
        }
    }

    func testDomain() {
        XCTAssertEqual(NSString.idn_prepDomain("XMPP.Example.ORG"), "xmpp.example.org")
        XCTAssertNil(NSString.idn_prepDomain("a\u{2028}b"))
    }

    func testResourceKeepsCaseAndSpaces() {
        XCTAssertEqual(NSString.idn_prepResource("Psi+ Mobile"), "Psi+ Mobile")
        XCTAssertNil(NSString.idn_prepResource("a\u{1}b"))
        // NFKC превращает неразрывный пробел в обычный, а он в Resourceprep разрешён.
        XCTAssertEqual(NSString.idn_prepResource("a\u{00A0}b"), "a b")
    }

    func testPassword() {
        // RFC 4013, раздел 3.
        XCTAssertEqual(NSString.idn_prepPassword("I\u{00AD}X"), "IX")
        XCTAssertEqual(NSString.idn_prepPassword("user"), "user")
        XCTAssertEqual(NSString.idn_prepPassword("USER"), "USER")
        XCTAssertEqual(NSString.idn_prepPassword("\u{00AA}"), "a")
        XCTAssertEqual(NSString.idn_prepPassword("\u{2168}"), "IX")
        XCTAssertEqual(NSString.idn_prepPassword("a\u{00A0}b"), "a b")
        XCTAssertEqual(NSString.idn_prepPassword("a\u{200B}b"), "a b")
        XCTAssertNil(NSString.idn_prepPassword("\u{7}"))
        XCTAssertNil(NSString.idn_prepPassword("\u{0627}\u{0031}"))
    }

    func testBidi() {
        XCTAssertNotNil(NSString.idn_prepNode("\u{05D0}\u{05D1}"))
        XCTAssertNotNil(NSString.idn_prepNode("\u{05D0}\u{0301}\u{05D1}"))
        XCTAssertNil(NSString.idn_prepNode("\u{05D0}a"))
        XCTAssertNil(NSString.idn_prepNode("a\u{05D0}"))
    }

    /// В libidn-framework строка от 1024 байт оставляла буфер без завершающего нуля.
    func testLongInputIsRejected() {
        XCTAssertEqual(NSString.idn_prepNode(String(repeating: "a", count: 1023))?.utf8.count, 1023)
        for length in [1024, 1025, 100_000] {
            let long = String(repeating: "a", count: length)
            XCTAssertNil(NSString.idn_prepNode(long))
            XCTAssertNil(NSString.idn_prepDomain(long))
            XCTAssertNil(NSString.idn_prepResource(long))
            XCTAssertNil(NSString.idn_prepPassword(long))
        }
    }

    func testEmptyInput() {
        XCTAssertEqual(NSString.idn_prepNode(""), "")
        XCTAssertEqual(NSString.idn_prepPassword(""), "")
    }
}
