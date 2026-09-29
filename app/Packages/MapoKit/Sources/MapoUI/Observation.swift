import Observation

/// Runs `render` now and again after every change to the observable state it read, re-arming each time
/// (PLAN T0.7 step 7). Changes within one main-actor turn coalesce into one render. Stops when `owner` goes.
public func observeContinuously<Owner: AnyObject & Sendable>(
    _ owner: Owner, _ render: @escaping @MainActor (Owner) -> Void
) {
    withObservationTracking {
        render(owner)
    } onChange: { [weak owner] in
        Task { @MainActor in
            guard let owner else { return }
            observeContinuously(owner, render)
        }
    }
}
