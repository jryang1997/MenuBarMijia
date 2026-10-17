import Foundation
import Testing
@testable import MijiaCore

/// 方案 v1 第 1 步：检查更新（读 GitHub Releases 最新版本）。
struct UpdateCheckerTests {
    @Test("Versions compare numerically, ignoring a leading v")
    func versionCompare() {
        #expect(AppVersion("v1.10.0")! > AppVersion("1.9.3")!)
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
        #expect(AppVersion("2.0.0-beta")! > AppVersion("1.9")!)
        #expect(AppVersion("abc") == nil)
    }

    static func checker(status: Int, body: String) -> UpdateChecker {
        UpdateChecker(currentVersion: "1.0.0", transport: { request in
            #expect(request.url?.absoluteString == "https://api.github.com/repos/jryang1997/MenuBarMijia/releases/latest")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
    }

    @Test("A newer release is reported with its download page")
    func newerRelease() async throws {
        let json = #"{"tag_name":"v1.1.0","html_url":"https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.1.0","body":"新功能"}"#
        let result = try await Self.checker(status: 200, body: json).check()
        #expect(result == .available(version: "1.1.0", url: URL(string: "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.1.0")!, notes: "新功能"))
    }

    @Test("Same version or no releases yet means up to date")
    func upToDate() async throws {
        let same = #"{"tag_name":"v1.0.0","html_url":"https://github.com/x"}"#
        #expect(try await Self.checker(status: 200, body: same).check() == .upToDate)
        #expect(try await Self.checker(status: 404, body: "{}").check() == .upToDate)
    }

    @Test("Server errors surface as a thrown error")
    func serverError() async {
        await #expect(throws: UpdateChecker.CheckError.self) {
            _ = try await Self.checker(status: 500, body: "").check()
        }
    }
}
