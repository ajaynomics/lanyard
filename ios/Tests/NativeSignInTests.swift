import XCTest

/// The phone's sign-in through the browser sheet, as addresses and requests:
/// what the sheet opens, which return the app accepts, and the post that
/// finishes it. Rails checks the same from its side
/// (test/integration/phone_app_sign_in_test.rb).
final class NativeSignInTests: XCTestCase {
    private let base = URL(string: "http://localhost:3000")!
    // RFC 7636, appendix B.
    private let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    func testTheChallengeIsS256OfTheVerifierAsRFC7636Says() {
        XCTAssertEqual(NativeSignInRequest.challenge(of: rfcVerifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(NativeSignInRequest(verifier: rfcVerifier).challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testEachSignInHasItsOwnUnguessableVerifier() {
        let verifiers = (0..<50).map { _ in NativeSignInRequest().verifier }
        XCTAssertEqual(Set(verifiers).count, 50)
        for verifier in verifiers {
            XCTAssertEqual(verifier.count, 43)
            XCTAssertNil(verifier.range(of: "[^A-Za-z0-9_-]", options: .regularExpression), verifier)
        }
    }

    func testTheSheetOpensTheStartPageWithTheChallengeAndNeverTheVerifier() throws {
        let request = NativeSignInRequest(verifier: rfcVerifier)
        let url = request.startURL(base: base)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "localhost")
        XCTAssertEqual(components.port, 3000)
        XCTAssertEqual(components.path, "/native_sign_in/new")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "code_challenge", value: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ])
        XCTAssertFalse(url.absoluteString.contains(rfcVerifier))
    }

    func testOnlyTheWebsOwnStartPageStartsTheSheet() {
        XCTAssertTrue(NativeSignInRequest.isStart(URL(string: "http://localhost:3000/native_sign_in/new")!, base: base))
        XCTAssertFalse(NativeSignInRequest.isStart(URL(string: "http://localhost:3000/sign_in")!, base: base))
        XCTAssertFalse(NativeSignInRequest.isStart(URL(string: "http://localhost:3001/native_sign_in/new")!, base: base))
        XCTAssertFalse(NativeSignInRequest.isStart(URL(string: "https://elsewhere.example/native_sign_in/new")!, base: base))
    }

    func testTheCodeIsTakenOnlyFromTheAppsOwnReturnAddress() {
        let scheme = "org.example.lanyard"
        XCTAssertEqual(NativeSignInRequest.code(from: URL(string: "org.example.lanyard://signed-in?code=abc--def_1")!, scheme: scheme), "abc--def_1")
        XCTAssertEqual(NativeSignInRequest.code(from: URL(string: "ORG.EXAMPLE.LANYARD://signed-in?code=abc")!, scheme: scheme), "abc")
        XCTAssertNil(NativeSignInRequest.code(from: URL(string: "other.app://signed-in?code=abc")!, scheme: scheme))
        XCTAssertNil(NativeSignInRequest.code(from: URL(string: "org.example.lanyard://elsewhere?code=abc")!, scheme: scheme))
        XCTAssertNil(NativeSignInRequest.code(from: URL(string: "org.example.lanyard://signed-in?code=")!, scheme: scheme))
        XCTAssertNil(NativeSignInRequest.code(from: URL(string: "org.example.lanyard://signed-in")!, scheme: scheme))
    }

    func testTheRedemptionPostsTheCodeAndVerifierAsAForm() throws {
        let request = NativeSignInRequest(verifier: rfcVerifier).redemption(base: base, code: "c0de+/=&x")
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:3000/native_sign_in")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(body, "code=c0de%2B%2F%3D%26x&code_verifier=\(rfcVerifier)")
    }
}
