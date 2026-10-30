import Foundation
#if !STANDALONE_TESTS
import XCTest
#endif
@testable import StitchCore

final class CrossPlatformVectorsTests: XCTestCase {
    struct Frame: Decodable {
        let width: Int, height: Int, sourceWidth: Int
        let pixels: String
        var frame: GrayFrame { GrayFrame(width: width, height: height, pixels: Array(Data(base64Encoded: pixels)!), sourceWidth: sourceWidth) }
    }
    struct Vector: Decodable { let name: String, previous: Frame, next: Frame, expected: String }
    func testSharedWindowsVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/stitch-vectors.json")))
        for vector in vectors {
            let result = StitchMatcher().match(previous: vector.previous.frame, next: vector.next.frame)
            let actual: String
            switch result {
            case .append(let rows): actual = "append:\(rows)"
            case .duplicate: actual = "duplicate"
            case .reverse: actual = "reverse"
            case .incompatibleSize: actual = "incompatibleSize"
            case .insufficientOverlap: actual = "insufficientOverlap"
            case .ambiguous: actual = "ambiguous"
            case .changedContent: actual = "changedContent"
            }
            XCTAssertEqual(actual, vector.expected, vector.name)
        }
    }
}
