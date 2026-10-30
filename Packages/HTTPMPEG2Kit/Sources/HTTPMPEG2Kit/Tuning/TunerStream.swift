import Foundation

/// One upstream connection the broker owns: one GET, so one tuner. `HDHomeRunStreamClient` is the real one; tests
/// supply fakes.
public nonisolated protocol TunerStream: AnyObject, Sendable {
    /// The MPEG-TS body. Ends when the device closes the stream or after `cancel()`.
    var chunks: AsyncThrowingStream<Data, any Error> { get }
    /// Sends the request and returns once the device accepted it, or throws its error (805 and so on).
    func open() async throws(HDHomeRunClientError) -> StreamOpenInfo
    /// Closes the connection at once, which frees the tuner. Safe to call repeatedly.
    func cancel()
}

extension HDHomeRunStreamClient: TunerStream {}
