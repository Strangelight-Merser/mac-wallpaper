import Foundation
import Security
import XCTest
@testable import WESteam

final class AuthTests: XCTestCase {
    func testJWTAndCookies() throws {
        let tokens = try testTokens(), claims = try SteamJWT(tokens.refreshToken)
        XCTAssertEqual(claims.sub, String(testSteamID)); XCTAssertEqual(claims.aud, ["client"])
        XCTAssertGreaterThan(claims.exp, Date())
        XCTAssertThrowsError(try SteamJWT("invalid"))
        let cookies = webCookies(tokens)
        XCTAssertEqual(cookies.count, 4)
        for cookie in cookies {
            XCTAssertTrue(cookie.isSecure); XCTAssertEqual(cookie.path, "/")
            if cookie.name == "steamLoginSecure" {
                XCTAssertTrue(cookie.value.hasPrefix(String(testSteamID) + "%7C%7C"))
                XCTAssertTrue(cookie.isHTTPOnly)
            } else {
                XCTAssertEqual(cookie.value.count, 24)
                XCTAssertTrue(cookie.value.allSatisfy { $0.isHexDigit })
            }
        }
        let headers = HTTPCookie.requestHeaderFields(with: cookies.filter { $0.domain.contains("steamcommunity") })
        XCTAssertTrue(headers["Cookie"]?.contains("%7C%7C") == true)
        var missing = tokens; missing.accessToken = nil
        XCTAssertTrue(webCookies(missing).isEmpty)
    }
    func testFormEncodingAndFallback() async throws {
        XCTAssertEqual(SteamHTTP.form(["x": "a+b /="]), "x=a%2Bb%20%2F%3D")
        let queue = HTTPQueue([("{}", 400, [:]), (#"{"response":{"client_id":"7"}}"#, 200, [:])])
        var p = ProtoWriter(); p.string(1, "offline")
        let response = try await queue.http.auth("BeginAuthSessionViaQR", fields: ["device_friendly_name": "offline"], protobuf: p.data)
        XCTAssertEqual(response["client_id"].uint, 7)
        let requests = await queue.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(String(decoding: requests[1].httpBody!, as: UTF8.self).hasPrefix("input_protobuf_encoded="))
        let rejected = HTTPQueue([("{}", 200, ["x-eresult": "5"])])
        do { _ = try await rejected.http.auth("x", fields: [:], protobuf: Data()); XCTFail("expected rejection") }
        catch { XCTAssertEqual(error as? SteamError, .result(5)) }
        let count = await rejected.requests.count
        XCTAssertEqual(count, 1)
    }
    func testQRRotationScannedAndSuccess() async throws {
        let token = try jwt()
        let queue = HTTPQueue([
            (#"{"response":{"client_id":"12","request_id":"+/8=","interval":0.001,"challenge_url":"https://s.team/q/1/12"}}"#, 200, [:]),
            (#"{"response":{"new_client_id":"13","new_challenge_url":"https://s.team/q/1/13","had_remote_interaction":true}}"#, 200, [:]),
            ("{\"response\":{\"refresh_token\":\"\(token)\",\"access_token\":\"\(token)\",\"account_name\":\"offline\"}}", 200, [:]),
        ])
        var challenges = 0, scanned = 0, succeeded = false
        for try await event in SteamQRLogin(deviceName: "offline", http: queue.http).events() {
            switch event {
            case .challenge: challenges += 1
            case .scanned: scanned += 1
            case .succeeded(let tokens): succeeded = tokens.steamID == testSteamID
            }
        }
        XCTAssertEqual(challenges, 2); XCTAssertEqual(scanned, 1); XCTAssertTrue(succeeded)
        let requests = await queue.requests
        let form = String(decoding: requests[2].httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("client_id=12")); XCTAssertTrue(form.contains("request_id=%2B%2F8%3D"))
    }
    func testAccessRenewalAndNoOp() async throws {
        let valid = try testTokens(), queue = HTTPQueue([])
        let unchanged = try await renew(valid, http: queue.http)
        XCTAssertTrue(unchanged == valid)
        var expired = valid; expired.accessToken = try jwt(expires: 1)
        let access = try jwt(), refresh = try jwt(expires: Date().timeIntervalSince1970 + 10000)
        let renewal = HTTPQueue([("{\"response\":{\"access_token\":\"\(access)\",\"refresh_token\":\"\(refresh)\"}}", 200, [:])])
        let updated = try await renew(expired, http: renewal.http)
        XCTAssertTrue(updated.accessToken == access); XCTAssertTrue(updated.refreshToken == refresh)
    }
    func testRSAEncryption() throws {
        // Generated offline with system OpenSSL; avoids Security's Keychain-backed CDSA key generation.
        let privateDER = Data(base64Encoded: "MIIEpAIBAAKCAQEAu4nYBdVpByR+JnaVBhtRRP4MplhYdYCEWZo/BwTzsguzyilDi55VBpPrfo9p6yBsHqAcHD4KKdTnHUClQQKjLuWDlhhfP6Wt/xbh7mrfT/sJk9qRXzzDi8zLGVZvqKr8V1P1pZycU+W1aEhGBFV4ZtTOqU87Y8b7XMIGyleHBClxs7OGfFq3a8wHC9Xt95/hqymIZj47S+0XodaFPAUIxRzG9a3W8KgnGcoT8BgutXLfMPIVTr+RE9180yWuget9ZPNAA2d1ZxKKp4T1EuYqdG+b4BCaLy1RxG7eZDkIT84uKn9KggvsW8QDzdP5QKf08Rert71xWVhYJOXTzI+cjwIDAQABAoIBAB3YPnITN88krhS161pY75KAsYepaI5ugOF3jA80aQnNFfQWpAKslFBjKudtsEf0VXB8P2z5LInisVL07jeN0WVNriatQz8wQSPmwta72ET0qN4IOvlChMYTNcEXAdcAOv80w9NyvGgXlsp9MfNPnMUUmbzU+JkU2fy1ffomerydDAtsQcsZavllJQqF7LfCqRd5smSVXGlrit9cvSFogJmK466IbGyN5/In3mGqRfkOHjRTgZO/Jj6Yuirx86U+O/3i2QgbwZ4MZyMIF7/KcDYeSLEp/j9JzwYrm8mJJv0rrgEJeSvKKyoWOYpxIC3Go1DsdajVfn95gVQg+ifaADECgYEA40hVLZNEDdmS47CXt6Uk8mQ4/RB2DjuOv4ADFpqySVFl1FBM2Dbp5g1v5BxV4sDEUflU1M32uyJOCrGwyALAQCl/REvRTZkb0yso253i0jy9z89D9fDlopq1TLmfUCVHJw2g2SAL8phfgWVLikbSmG7swNVM5ntuh3l9pTqWlnECgYEA0zvzdR36vWJbJdf8Q5vy20skY14iL3mMWR3F632nrQ3J5EOcTHNDosBKHubs553vVXNdobj9Hk+L91LzQn1ObppjQeHcC0M7CQppp3HkInYBCRZwu26fG8pvWx9HvGeUtS+cM3jRshugBHjje6f9d4UCGItyF8wOZKPwAtvA4v8CgYBM+c5/ZQUDe9DX9JMty2y7+12ht9WD9H/gM8bX/QSs+Dh4s8mS4OZO1/YxV7du2MKk0MD+YdNShcfQr2WkF+ps0KEdzF/S3CwkVNW9q7eKZLAUlan6vd/INoV4utVOG5IBlAgKAWSKgTi3ZkszRdFFdywQEy28UcmZcHgxYapmwQKBgQDHLf+qTsORcr4p2BjaE6IToC5GuIuZoo5xtb5cCNdkOd1GrW4jNIjxXUpHC08WM/lq5ObESS/8NdvwMbqJ1qhvaIrxo6yevh1bsALiTmVlDUp6rDtOsce8J82K6dr1z+IMW0F505I/1Qa1UNyITGaYHcZVKKBDyjlEMsVtnJOsNwKBgQDUxC5lTo6urKGxf5KuY4TwdIx2OfavHIZ3pFcsyBCXzkV1YOvEhKk9M/qUbbQCM+vB1X/GXT6/pNTa76XtH1jr65k9CtyZ5C3OZ2iQ3t02EIYXslt1+AXfrn+SdPvLZHnhZm17DD5Xg5E7Bs33QAMWgEZbD8jzZgoToUKxVl+lww==")!
        let data = Data(base64Encoded: "MIIBCgKCAQEAu4nYBdVpByR+JnaVBhtRRP4MplhYdYCEWZo/BwTzsguzyilDi55VBpPrfo9p6yBsHqAcHD4KKdTnHUClQQKjLuWDlhhfP6Wt/xbh7mrfT/sJk9qRXzzDi8zLGVZvqKr8V1P1pZycU+W1aEhGBFV4ZtTOqU87Y8b7XMIGyleHBClxs7OGfFq3a8wHC9Xt95/hqymIZj47S+0XodaFPAUIxRzG9a3W8KgnGcoT8BgutXLfMPIVTr+RE9180yWuget9ZPNAA2d1ZxKKp4T1EuYqdG+b4BCaLy1RxG7eZDkIT84uKn9KggvsW8QDzdP5QKf08Rert71xWVhYJOXTzI+cjwIDAQAB")!
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        let privateKey = try XCTUnwrap(SecKeyCreateWithData(privateDER as CFData, attributes as CFDictionary, nil))
        var cursor = ByteCursor(data)
        func readDER(_ cursor: inout ByteCursor, tag: UInt8) throws -> Data {
            XCTAssertEqual(try cursor.integer(UInt8.self), tag)
            let first = try cursor.integer(UInt8.self)
            var length = Int(first)
            if first & 128 != 0 {
                length = 0
                for _ in 0..<(first & 127) { length = length << 8 | Int(try cursor.integer(UInt8.self)) }
            }
            return try cursor.read(length)
        }
        var sequence = try ByteCursor(readDER(&cursor, tag: 0x30))
        let modulus = try readDER(&sequence, tag: 2), exponent = try readDER(&sequence, tag: 2)
        let encrypted = try encryptPassword("offline-test", modulus: modulus.hex, exponent: exponent.hex)
        let ciphertext = try XCTUnwrap(Data(base64Encoded: encrypted))
        let plain = try XCTUnwrap(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, ciphertext as CFData, nil)) as Data
        XCTAssertTrue(plain == Data("offline-test".utf8))
    }
    func testSubscriptionHTMLRequiresLogin() throws {
        let html = #"var g_steamID = "76561198000000001"; <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=123">x</a>"#
        XCTAssertEqual(try SteamWorkshop.subscriptionPage(html, steamID: testSteamID), [123])
        XCTAssertThrowsError(try SteamWorkshop.subscriptionPage(html, steamID: testSteamID + 1))
        XCTAssertThrowsError(try SteamWorkshop.subscriptionPage(#"<a href="/profiles/76561198000000001">profile</a>"#, steamID: testSteamID))
    }
    func testBinaryAuthResponseAndPollExpiryCancellation() async throws {
        var p = ProtoWriter(); p.uint(1, 12); p.string(2, "https://s.team/q/1/12")
        p.bytes(3, Data([1, 2])); p.fixed32(4, Float(0.1).bitPattern)
        let bytes = p.data
        let http = SteamHTTP { request in response(request, bytes, headers: ["x-eresult": "1"]) }
        let parsed = try await http.auth("BeginAuthSessionViaQR", fields: [:], protobuf: Data())
        XCTAssertEqual(parsed["client_id"].uint, 12)
        XCTAssertEqual(parsed["interval"].double, 0.1, accuracy: 0.00001)
        let session = try AuthSession(parsed), empty = HTTPQueue([])
        do {
            _ = try await poll(session, http: empty.http, timeout: .milliseconds(1)) { _ in }
            XCTFail("expected expiry")
        } catch { XCTAssertEqual(error as? SteamError, .expired) }
        let cancelled = Task { try await poll(session, http: empty.http) { _ in } }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testPasswordLoginEmailCode() async throws {
        let token = try jwt(), modulus = String(repeating: "a1", count: 256)
        let queue = HTTPQueue([
            ("{\"response\":{\"publickey_mod\":\"\(modulus)\",\"publickey_exp\":\"010001\",\"timestamp\":\"123\"}}", 200, [:]),
            (#"{"response":{"client_id":"12","request_id":"AQI=","interval":0.001,"steamid":"76561198000000001","allowed_confirmations":[{"confirmation_type":2}]}}"#, 200, [:]),
            (#"{"response":{}}"#, 200, [:]),
            ("{\"response\":{\"refresh_token\":\"\(token)\",\"access_token\":\"\(token)\",\"account_name\":\"offline\"}}", 200, [:]),
        ])
        let tokens = try await SteamPasswordLogin(deviceName: "offline", http: queue.http)
            .login(account: "offline", password: "offline-password") { choices in
                XCTAssertEqual(choices.map(\.kind), [.emailCode])
                return (.emailCode, "123456")
            }
        XCTAssertEqual(tokens.steamID, testSteamID)
        let requests = await queue.requests
        XCTAssertEqual(requests[0].httpMethod, "GET")
        let begin = String(decoding: requests[1].httpBody!, as: UTF8.self)
        XCTAssertFalse(begin.contains("offline-password"))
        XCTAssertTrue(begin.contains("persistence=1")); XCTAssertTrue(begin.contains("platform_type=1"))
        let update = String(decoding: requests[2].httpBody!, as: UTF8.self)
        XCTAssertTrue(update.contains("code_type=2")); XCTAssertTrue(update.contains("client_id=12"))
    }
    func testKeychainUniqueService() throws {
        let service = "dev.macwallpaper.steam.tests." + UUID().uuidString
        var tokens = try testTokens()
        do { try SteamKeychain.save(tokens, service: service) }
        catch let SteamError.keychain(status) { throw XCTSkip("Keychain unavailable in this environment (status \(status))") }
        defer {
            try? SteamKeychain.delete(account: tokens.accountName, service: service)
            try? SteamKeychain.delete(account: "second-offline-account", service: service)
        }
        XCTAssertTrue(try SteamKeychain.load(account: tokens.accountName, service: service) == tokens)
        tokens.accessToken = nil
        try SteamKeychain.save(tokens, service: service)
        XCTAssertTrue(try SteamKeychain.load(account: nil, service: service) == tokens)
        var second = tokens; second.accountName = "second-offline-account"
        try SteamKeychain.save(second, service: service)
        XCTAssertEqual(try SteamKeychain.entries(service: service).count, 2)
        XCTAssertEqual(try SteamKeychain.load(account: nil, service: service)?.accountName, second.accountName)
        try SteamKeychain.delete(account: tokens.accountName, service: service)
        XCTAssertNil(try SteamKeychain.load(account: tokens.accountName, service: service))
    }
}
