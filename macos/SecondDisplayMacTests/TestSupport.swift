import Foundation
import XCTest

enum TestSupport {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func vector(_ relativePath: String) throws -> Data {
        let url = repositoryRoot.appendingPathComponent("shared/test-vectors/\(relativePath)")
        return try Data(contentsOf: url)
    }

    static func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else {
            throw NSError(domain: "TestSupport", code: 1)
        }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw NSError(domain: "TestSupport", code: 2)
            }
            result.append(byte)
            index = next
        }
        return result
    }
}

