import Foundation

public struct PetHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct PetHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public enum HTTPParseError: Error, Equatable, Sendable {
    case malformed
    case headerTooLarge
    case bodyTooLarge
    case unsupportedTransferEncoding
    case unexpectedTrailingBytes

    public var statusCode: Int {
        switch self {
        case .bodyTooLarge, .headerTooLarge: 413
        case .unsupportedTransferEncoding: 400
        case .malformed, .unexpectedTrailingBytes: 400
        }
    }
}

public enum PetHTTPCodec {
    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 16 * 1024

    /// Returns nil until the complete Content-Length-delimited request is available.
    public static func parse(_ data: Data) throws -> PetHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: delimiter) else {
            if data.count > maxHeaderBytes { throw HTTPParseError.headerTooLarge }
            return nil
        }
        let headerLength = data.distance(from: data.startIndex, to: range.lowerBound)
        guard headerLength <= maxHeaderBytes else { throw HTTPParseError.headerTooLarge }
        guard let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            throw HTTPParseError.malformed
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPParseError.malformed }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3,
              let method = String(parts[0]).nilIfEmpty,
              let path = String(parts[1]).nilIfEmpty,
              path.count <= 1_024,
              parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1" else {
            throw HTTPParseError.malformed
        }

        var headers: [String: String] = [:]
        guard lines.count <= 65 else { throw HTTPParseError.headerTooLarge }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.contains("\r"), !value.contains("\n"), headers[name] == nil else {
                throw HTTPParseError.malformed
            }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { throw HTTPParseError.unsupportedTransferEncoding }

        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else { throw HTTPParseError.malformed }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maxBodyBytes else { throw HTTPParseError.bodyTooLarge }
        let bodyStart = range.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }
        guard available == contentLength else { throw HTTPParseError.unexpectedTrailingBytes }
        return PetHTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: data.subdata(in: bodyStart..<data.endIndex)
        )
    }

    public static func encode(_ response: PetHTTPResponse) -> Data {
        let reason: String
        switch response.statusCode {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        case 415: reason = "Unsupported Media Type"
        default: reason = "Internal Server Error"
        }
        let header = "HTTP/1.1 \(response.statusCode) \(reason)\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(response.body)
        return data
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
