import Foundation
import Testing
@testable import LemonMusic

@Suite(.serialized)
struct LemonAPIClientTests {
    @Test func loginUsesV1BearerContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        URLProtocolStub.handler = { request in
            #expect(request.url?.path == "/api/v1/auth/login")
            #expect(request.httpMethod == "POST")
            let body = #"{"token":"jwt","user":{"id":"1","username":"admin","displayName":"Admin","role":"admin"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let client = LemonAPIClient(session: session)
        try await client.configure(baseURL: "https://music.example.com", token: nil)
        let login = try await client.login(username: "admin", password: "secret")
        #expect(login.token == "jwt")
        #expect(login.user.role == "admin")
    }

    @Test func loginFallsBackToLegacyPrefixWhenDeployedV1IsProtected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/v1/auth/login" {
                let body = #"{"error":"未登录或登录已过期","code":"UNAUTHORIZED"}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            #expect(request.url?.path == "/api/auth/login")
            let body = #"{"token":"jwt","user":{"id":"1","username":"admin","displayName":"Admin","role":"admin"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let client = LemonAPIClient(session: session)
        try await client.configure(baseURL: "https://music.example.com", token: nil)
        let login = try await client.login(username: "admin", password: "secret")
        #expect(login.token == "jwt")
        #expect(await client.selectedAPIPrefix() == "/api")
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
