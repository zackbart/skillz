import Foundation

/// A connection to a Herdr socket.
///
/// Herdr's socket is **one-request-per-connection** for RPC: you open a
/// connection, send one request, read its reply, and the server closes it.
/// Only `events.subscribe` keeps a connection open (to stream events). The
/// transport models exactly that: `request` is a one-shot round-trip, `events`
/// opens a persistent subscription stream. Request/response correlation isn't
/// needed — each request has its own connection, so its reply is unambiguous.
public protocol HerdrTransport: Sendable {
    /// Establish the underlying connection (e.g. the SSH session). Per-request
    /// channels are opened lazily.
    func connect() async throws

    /// One-shot request/response: open a channel, send the request, read the
    /// single reply, and let the server close the channel.
    func request(_ request: RPCRequest) async throws -> RPCResponse

    /// Open a persistent subscription: send `subscribeRequest`, then stream every
    /// pushed message until the channel closes or the stream is cancelled.
    func events(_ subscribeRequest: RPCRequest) -> AsyncStream<IncomingMessage>

    /// Close the connection.
    func disconnect() async
}

public enum HerdrError: Error, Sendable {
    case notConnected
    case transportClosed
    case rpc(RPCError)
    /// A human-readable SSH connection problem — bad credentials, unreachable
    /// host, or a socket bridge that couldn't start. Carries a message safe to
    /// show the user.
    case connectionFailed(String)
}
