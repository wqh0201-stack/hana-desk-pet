import Foundation
import Network
import PetCore

public final class LocalHTTPServer: @unchecked Sendable {
    public static let defaultPortValue: UInt16 = 43127

    public var onStateChange: (() -> Void)?
    public var onListenerState: ((String) -> Void)?

    public let portValue: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hana.desktop-pet.loopback", qos: .utility)
    private let api: PetAPI

    public var endpointURL: URL {
        URL(string: "http://127.0.0.1:\(portValue)")!
    }

    public init(store: PetStateStore, portValue: UInt16 = defaultPortValue) throws {
        guard portValue > 0 else { throw LocalHTTPServerError.invalidPort }
        self.portValue = portValue
        let port = NWEndpoint.Port(rawValue: portValue)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        listener = try NWListener(using: parameters)
        api = PetAPI(store: store)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onListenerState?("listening")
            case .failed:
                self?.onListenerState?("error")
            case .cancelled:
                self?.onListenerState?("stopped")
            default:
                self?.onListenerState?("starting")
            }
        }
    }

    public func start() {
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PetHTTPCodec.maxHeaderBytes + PetHTTPCodec.maxBodyBytes) {
            [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var bytes = accumulated
            if let data { bytes.append(data) }

            do {
                if let request = try PetHTTPCodec.parse(bytes) {
                    let response = self.api.handle(request)
                    if response.statusCode == 200 &&
                        ((request.method == "POST" && request.path == "/v3/snapshot") ||
                         (request.method == "POST" && request.path == "/v3/selection")) {
                        DispatchQueue.main.async { self.onStateChange?() }
                    }
                    self.send(response, over: connection)
                } else if error != nil {
                    connection.cancel()
                } else if complete {
                    self.send(self.jsonError(400), over: connection)
                } else {
                    self.receive(connection, accumulated: bytes)
                }
            } catch let parseError as HTTPParseError {
                self.send(self.jsonError(parseError.statusCode), over: connection)
            } catch {
                self.send(self.jsonError(400), over: connection)
            }
        }
    }

    private func send(_ response: PetHTTPResponse, over connection: NWConnection) {
        connection.send(content: PetHTTPCodec.encode(response), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func jsonError(_ status: Int) -> PetHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": "invalid_request"])) ?? Data("{}".utf8)
        return PetHTTPResponse(statusCode: status, body: data)
    }
}

private enum LocalHTTPServerError: Error {
    case invalidPort
}
