import Foundation

/// Something playback holds and must give back: a tuner, a security scope, a record-engine session.
///
/// The player session (one per tile in multi-view) owns the lease and releases it on stop, on error, when the
/// engine is replaced, when the window closes, and from `deinit` as a safety net. For HDHomeRun live TV the lease is
/// the `TunerLease` the `.liveTuner` transport carries, so it always covers the subscription the engine reads.
public nonisolated protocol PlaybackLease: Sendable {
    /// Idempotent. Called when playback stops or fails, or when the tile closes.
    func release() async
}
