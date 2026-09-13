import XCTest
@testable import RAPPShotCore

final class DetectorTests: XCTestCase {
    func testAnchoredRulesAndObservedHomoglyphs() throws {
        let detector = try CredentialDetector()
        let cases: [(String, String)] = [
            ("fixture.user@example.test", "email"),
            ("gh" + "p_9zQ7LmN4bV2cD8fH1jKЗpR5sT6uW0xY2aB", "github token"),
            ("sk" + "-abcdefghijklmnopqrstuvwx" + "×" + "0123", "openai-style key"),
            ("AK" + "IA" + "IOSFODNN7" + "EXAMPLE", "aws access key"),
            ("sk_" + "live_" + "51H8xKfL2mNpQrStUvWxYz01", "stripe-style key"),
            ("xoxb" + "-123456789012-1234567890123-" + "AbCdEfGhIjKlMnOpQrStUvWx", "slack token"),
            ("postgres://admin:" + "s3cr3tP" + "assw0rd@db.example.com:5432/prod", "credentials in a connection URL"),
            ("-----" + "BEGIN RSA PRIVATE KEY" + "-----", "private key block"),
            (["4111", "1111", "1111", "1111"].joined(separator: " "), "card-like number"),
            (["123", "45", "6789"].joined(separator: "-"), "ssn-like")
        ]
        for (text, expected) in cases {
            XCTAssertTrue(detector.find(text).contains { $0.label == expected }, "Expected \(expected)")
        }
        XCTAssertEqual(CredentialDetector.normalize("АВЕКМНОРСТХЗб α × Ø | １２3 e\u{301}"), "ABEKMHOPCTX36 α x 0 l 123 e")
    }

    func testOriginalCredentialRegressionCases() throws {
        let hex = String(repeating: "0123456789abcdef", count: 2)
        let b64 = "aHVudGVyMmh1bnRlcjJodW50ZXJ5b3VjYW50c2VlbWU="
        let fixtures = [
            "TWILIO_AUTH_" + "TOKEN=" + hex,
            "AWS_SECRET_ACCESS_" + "KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "key: " + hex,
            #"{"client_secret": ""# + hex + #""}"#,
            "https://api.example.com/v1/x?access_" + "token=" + hex,
            String(repeating: "a3f5", count: 10).uppercased(),
            "DefaultEndpointsProtocol=https;AccountName=x;AccountKey=" + b64 + ";",
            "/var/run/secrets/" + hex,
            "AZURE_CLIENT_" + "SECRET=" + "8Q~" + String(hex.prefix(31)),
            "AWS_SECRET rotated to Xk7Qz2Rw9Tb4Vn5Lm",
            "AWS_SECRET rotated to xk7qz2rw9tb4vn5lmz8p",
            "Xk7Qz2Rw9Tb4Vn5Lm8Pj3Cd",
            #""SecretAccessKey": "wJalrXUtnFEMI/M3ucXiI8+bPxRfiCYEXAMPLEKEY","#,
            "LICENCE EKSK-N1DB-9R5W-DCRS-UCDZ",
            "device 1307eefeae7c33c3-08bd5af86e4d683b",
            "password 3PYNCR-YQ4YS1-NJBAP7",
            #""AccountKey": ""# + "Xy9/kL2mNpQrStUvWxYz01+aB3cD4eF5gH6=" + #"""#,
            "//registry.npmjs.org/:_authToken=npm_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5",
            #"{"AccountKey": "Tq7vNs2wLd9xRb"}"#,
            "P/wMLKlKjLRw2C+//LP/SROxR1i9STV7qFCSXR//",
            "hmMGxvAhN9WV3ljp/EzYb+sRlOElzCBohSvWnfpT",
            "n8rXWGTg7G+d80ZG/o80FKkvbJE2YFWOxOt+ijmj",
            // Keep the inherited Round-6 synthetic regression value exact, without a credential-shaped literal.
            #""SecretAccessKey": ""# + [
                "rLIeMKxj",
                "X5LF69bv",
                "uzU/o7mt",
                "8zLj3c/Z",
                "LTUsjeAc",
            ].joined() + #"","#,
            "AbcDefGhiJklMnoPqrStuVwxYzAbcDefGhiJklMn",
            "SecretKeyRef AbcDefGhiJklMnoPqrStuVwxYzAbcDefGhiJklMn",
            "token: aB3×9zQØLm4bV2cD8fH1jK5pR",
            "api_key: aB3x9zQ|Lm4bV2cD8fH1jK5pRs"
        ]
        let detector = try CredentialDetector()
        for (index, fixture) in fixtures.enumerated() {
            XCTAssertFalse(detector.find(fixture).isEmpty, "Original credential regression \(index) was missed")
        }
    }

    func testOriginalBenignRegressionCasesAndDigestPolicy() throws {
        let benign = [
            "2026-07-26T01:20:31Z INFO  boot: loading configuration",
            "2026-07-26 01:20:33.481 WARN  db: retrying connection",
            "2026-07-26T01:20:35.123456Z ERROR api: order 88214 failed",
            "/var/folders/kx/8vv6qk1n0dq2rb_3xyzq7c400000gn/T/build.log",
            "/Users/someone/Library/Application Support/Example/cache",
            "~/Documents/GitHub/rapp-tower/work/2026-07-18-tower-blindspot-r2/HANDOFF.md",
            "/Users/x/Library/Containers/3f2504e0-4f89-11d3-9a0c-0305e82c3301/Data",
            "/opt/homebrew/Cellar/python@3.14/3.14.4_1/Frameworks/Python.framework",
            "run id 3f2504e0-4f89-11d3-9a0c-0305e82c3301 is not a secret",
            "com.example.internal.service.AuthenticationTokenProvider",
            "org.apache.commons.configuration2.PropertiesConfiguration",
            "kubectl get pods -n production --field-selector=status.phase=Running",
            "docker compose -f docker-compose.production.yml up --detach",
            "the quarterly report is attached and the pricing review is Thursday",
            "https://github.com/kody-w/rapp-shot/blob/main/README.md",
            "npm install --save-dev @typescript-eslint/eslint-plugin",
            "summary: 3 warnings, 1 error, deploy blocked",
            "git checkout -b feature/redaction-false-positives",
            #""resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz","#,
            "index 7a3f2b1..9c4d8e6 100644",
            "    at com.example.svc.OrderValidator.validate(OrderValidator.java:142)",
            "SELECT id, created_at FROM orders WHERE status = 'pending' LIMIT 100;",
            ".btn-primary:hover{background-color:#0f9d74;border-radius:.5rem}",
            "export const useStore=e=>{const t=useContext(StoreCtx);return t[e]}",
            "CompileSwift normal arm64 /Users/x/Proj/Sources/AppDelegate.swift",
            #""engines": { "node": ">=18.17.0", "npm": ">=9.6.7" },"#,
            #"ProcessInfo.processInfo.environment["DYLD_FRAMEWORK_PATH"]"#,
            "Deployment/Production/us-east-1/order-service/2026-07-26",
            "https://example.com/blog/2026/07/why-we-rewrote-the-scheduler",
            "brew install ffmpeg whisper-cpp hammerspoon --quiet --no-quarantine",
            "inet6 fe80::1c3d:8a2f:9b7e:4d61%en0 prefixlen 64 scopeid 0xe",
            "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
            "ether a4:83:e7:2b:9c:1f",
            "Physical Address. . . . . . . . . : A4-83-E7-2B-9C-1F",
            "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7"
        ]
        let detector = try CredentialDetector()
        for (index, line) in benign.enumerated() {
            XCTAssertTrue(detector.find(line).isEmpty, "Benign regression \(index) was over-redacted")
        }
        XCTAssertFalse(detector.find("sha256:" + String(repeating: "0123456789abcdef", count: 4)).isEmpty)
    }

    func testCustomRulesRejectInvalidRulesAndSupportComments() throws {
        let detector = try CredentialDetector(patternText: "# fixture only\n\nINTERNAL-[0-9]{4}\n")
        XCTAssertTrue(detector.find("ticket INTERNAL-7788 is closed").contains { $0.label == "custom" })
        XCTAssertThrowsError(try CredentialDetector(patternText: "# comment\n[")) {
            guard case ShotError.invalidPattern(2, _) = $0 else { return XCTFail("Wrong pattern error: \($0)") }
        }
    }

    func testSurvivorsAreNormalizedAndPartialLongRunsStillCount() {
        let token = "gh" + "p_9zQ3LmN4bV2cD8fH1jK3pR5sT6uW0xY2aB"
        let mangled = token.replacingOccurrences(of: "3", with: "З")
        XCTAssertTrue(CredentialDetector.stillPresent(token, in: "noise \(mangled) noise"))
        XCTAssertTrue(CredentialDetector.stillPresent(token, in: String(token.prefix(24))))
        XCTAssertFalse(CredentialDetector.stillPresent(token, in: "noise opaque rectangle noise"))
        XCTAssertFalse(CredentialDetector.stillPresent("", in: "anything"))
    }

    func testExplicitPerLineLimitationAndEntropy() throws {
        let detector = try CredentialDetector()
        XCTAssertTrue(detector.find("gh" + "p_A1b2C3d4").isEmpty)
        XCTAssertTrue(detector.find("E5f6G7h8I9j0").isEmpty)
        XCTAssertFalse(detector.find("gh" + "p_A1b2C3d4E5f6G7h8I9j0").isEmpty)
        XCTAssertEqual(CredentialDetector.entropy("abcd"), 2, accuracy: 0.0001)
        XCTAssertEqual(CredentialDetector.entropy(""), 0)
    }
}
