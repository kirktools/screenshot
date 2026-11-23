import Foundation
import Network

@MainActor final class ChatGPTLoopback {
    static let path = "/auth/callback"

    private var pending: CheckedContinuation<URLComponents, Error>?
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    func wait(state: String, openBrowser: @escaping (String) throws -> Void) async throws -> URLComponents {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        defer {
            listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
            self.listener = nil
        }

        let timeout = Task {
            try await Task.sleep(for: .seconds(180))
            finish(.failure(ChatGPTPlan.Failure.signInTimedOut))
        }
        defer { timeout.cancel() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                listener.stateUpdateHandler = { [weak self, weak listener] status in
                    MainActor.assumeIsolated {
                        switch status {
                        case .ready:
                            guard let port = listener?.port else {
                                self?.finish(.failure(ChatGPTPlan.Failure.invalidAuthorization))
                                return
                            }
                            do { try openBrowser("http://127.0.0.1:\(port.rawValue)" + Self.path) }
                            catch { self?.finish(.failure(error)) }
                        case .failed(let error):
                            self?.finish(.failure(error))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated {
                        guard let self, self.pending != nil, self.connections.count < 8 else {
                            connection.cancel()
                            return
                        }
                        self.connections.append(connection)
                        connection.start(queue: .main)
                        self.receive(connection, data: Data(), state: state)
                    }
                }
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }

    private func receive(_ connection: NWConnection, data: Data, state: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var request = data
                request.append(chunk ?? Data())
                if request.count > 16_384 || error != nil {
                    self.close(connection)
                } else if request.range(of: Data([13, 10, 13, 10])) != nil {
                    let callback = Self.callback(request, state: state)
                    let response = callback == nil ? "400 Bad Request" : "200 OK"
                    let message = callback == nil ? "Invalid sign-in callback." : "Return to Screenshot to finish signing in."
                    let body = "HTTP/1.1 \(response)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(message.utf8.count)\r\n\r\n\(message)"
                    connection.send(content: Data(body.utf8), completion: .contentProcessed { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.close(connection)
                            if let callback { self?.finish(.success(callback)) }
                        }
                    })
                } else if done {
                    self.close(connection)
                } else {
                    self.receive(connection, data: request, state: state)
                }
            }
        }
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }

    static func callback(_ data: Data, state: String) -> URLComponents? {
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix(Self.path + "?"),
              let url = URLComponents(string: String(parts[1])),
              let items = url.queryItems, items.filter({ $0.name == "state" }).map(\.value) == [state]
        else { return nil }
        return url
    }
}
