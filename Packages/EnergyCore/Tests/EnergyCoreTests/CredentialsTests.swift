import Foundation
import Testing
@testable import EnergyCore

// All values below are made up; they only mimic the observed shapes (15 digits / 32 hex).
private let fakeId = "202600000000001"
private let fakeSecret = "0123456789abcdef0123456789abcdef"

@Suite("DeyeAppCredentialsParser")
struct DeyeAppCredentialsParserTests {
    @Test("Labelled values in various formats", arguments: [
        "App ID: \(fakeId)\napp secret: \(fakeSecret)",
        "AppId=\(fakeId)\nAppSecret=\(fakeSecret)",
        #"{"appId": "\#(fakeId)", "appSecret": "\#(fakeSecret)"}"#,
        "DEYE_APP_ID = \(fakeId)\nDEYE_APP_SECRET = \(fakeSecret)",
        "AppSecret\n\(fakeSecret)\nAppId\n\(fakeId)",
        "app_id \(fakeId) secret key \(fakeSecret)",
    ])
    func labelled(_ text: String) {
        let r = DeyeAppCredentialsParser.parse(text)
        #expect(r.appId == fakeId)
        #expect(r.appSecret == fakeSecret)
        #expect(r.isComplete)
    }

    @Test("Unlabelled values are recognized by shape")
    func shapes() {
        let r = DeyeAppCredentialsParser.parse("ключі: \(fakeSecret) та \(fakeId)")
        #expect(r.appId == fakeId)
        #expect(r.appSecret == fakeSecret)
    }

    @Test("Partial or unrelated text")
    func partial() {
        #expect(DeyeAppCredentialsParser.parse("AppId: \(fakeId)") == .init(appId: fakeId, appSecret: nil))
        #expect(DeyeAppCredentialsParser.parse("привіт, це не ключі") == .init(appId: nil, appSecret: nil))
        #expect(!DeyeAppCredentialsParser.parse("").isComplete)
    }

    @Test("Plausibility check rejects obviously wrong input")
    func plausible() {
        #expect(DeyeAppCredentials(appId: " \(fakeId) ", appSecret: fakeSecret).isPlausible)
        #expect(DeyeAppCredentials(appId: fakeId, appSecret: fakeSecret).appId == fakeId)
        #expect(!DeyeAppCredentials(appId: "", appSecret: fakeSecret).isPlausible)
        #expect(!DeyeAppCredentials(appId: fakeId, appSecret: "short").isPlausible)
        #expect(!DeyeAppCredentials(appId: "has space", appSecret: fakeSecret).isPlausible)
    }
}

@Suite("Remembered vs not remembered password")
struct RememberPasswordTests {
    let app = DeyeAppCredentials(appId: fakeId, appSecret: fakeSecret)

    @Test("Account without a stored password keeps using a valid token, even near expiry")
    func usesTokenWithoutPassword() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Expires in 1 hour: with a password this would be renewed; without one it is still used.
        let store = InMemoryDeyeTokenStore(DeyeToken(accessToken: "T", expiresAt: now.addingTimeInterval(3600)))
        let (session, id) = StubURLProtocol.session { _, _, _ in (200, DeyeCloudClientTests.fixture("pinned_latest_grid_on"), [:]) }
        let creds = DeyeCloudCredentials(app: app, account: DeyeAccount(email: "u@example.com", passwordSHA256: nil))
        let client = DeyeCloudClient(region: .eu, credentials: creds, tokenStore: store, session: session, limiter: .unlimited, now: { now })
        _ = try await client.latest([InverterID("sn")])
        #expect(StubURLProtocol.requests(id).map(\.path) == ["device/latest"])
        #expect(StubURLProtocol.requests(id).first?.auth == "bearer T")
    }

    @Test("Expired token without a stored password asks the user to log in")
    func loginRequired() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryDeyeTokenStore(DeyeToken(accessToken: "T", expiresAt: now.addingTimeInterval(-1)))
        let (session, id) = StubURLProtocol.session { _, _, _ in (500, Data(), [:]) }
        let creds = DeyeCloudCredentials(app: app, account: DeyeAccount(email: "u@example.com", passwordSHA256: nil))
        let client = DeyeCloudClient(region: .eu, credentials: creds, tokenStore: store, session: session, limiter: .unlimited, now: { now })
        await #expect(throws: DataSourceError.loginRequired) { try await client.latest([InverterID("sn")]) }
        #expect(StubURLProtocol.requests(id).isEmpty)
    }

    @Test("Revoked token without a stored password asks the user to log in")
    func revokedWithoutPassword() async {
        let store = InMemoryDeyeTokenStore(DeyeToken(accessToken: "T", expiresAt: .distantFuture))
        let (session, _) = StubURLProtocol.session { _, _, _ in (200, DeyeCloudClientTests.invalidToken, [:]) }
        let creds = DeyeCloudCredentials(app: app, account: DeyeAccount(email: "u@example.com", passwordSHA256: nil))
        let client = DeyeCloudClient(region: .eu, credentials: creds, tokenStore: store, session: session, limiter: .unlimited)
        await #expect(throws: DataSourceError.loginRequired) { try await client.latest([InverterID("sn")]) }
    }

    @Test("Account combines with app keys; password only as SHA-256")
    func combine() {
        let account = DeyeAccount(email: " u@example.com ", passwordSHA256: DeyeAccount.hash("pw"))
        let creds = DeyeCloudCredentials(app: app, account: account)
        #expect(creds.email == "u@example.com")
        #expect(creds.passwordSHA256 == "30c952fab122c3f9759f02a6d95c3758b246b4fee239957b2d4fee46e26170c4")
        #expect(creds.app == app)
        #expect(account.remembersPassword)
        #expect(RefreshService.describe(DataSourceError.loginRequired) == "Сесія Deye Cloud завершилась, увійдіть знову")
    }
}

@Suite("Strict import for Shortcuts")
struct DeyeAppCredentialsImportTests {
    @Test("Page text with both keys")
    func success() throws {
        let page = "Deye Cloud Developer\nMy app\nApp ID\n\(fakeId)\nApp Secret\n\(fakeSecret)\nCreated 2026-11-25"
        let keys = try DeyeAppCredentialsParser.credentials(from: page)
        #expect(keys == DeyeAppCredentials(appId: fakeId, appSecret: fakeSecret))
    }

    @Test("Errors say what is missing")
    func errors() {
        #expect(throws: DeyeAppCredentialsParser.ImportError.emptyInput) {
            try DeyeAppCredentialsParser.credentials(from: "  \n ")
        }
        #expect(throws: DeyeAppCredentialsParser.ImportError.missingAppSecret) {
            try DeyeAppCredentialsParser.credentials(from: "AppId: \(fakeId)")
        }
        #expect(throws: DeyeAppCredentialsParser.ImportError.missingAppId) {
            try DeyeAppCredentialsParser.credentials(from: "AppSecret: \(fakeSecret)")
        }
        #expect(throws: DeyeAppCredentialsParser.ImportError.missingAppId) {
            try DeyeAppCredentialsParser.credentials(from: "Увійдіть у свій акаунт")
        }
    }
}
