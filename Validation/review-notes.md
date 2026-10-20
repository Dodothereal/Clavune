# Initial focused review

Two read-only reviewers inspected audio/endpoint and app/model/inference lifecycle code. They ran no builds, microphone capture or benchmarks.

Findings addressed before the source checkpoint:

- An already-running worker could convert frames after a cutoff sampled before its stop action reached the queue. The stop action now fails closed if any already-converted native interval extends past cutoff. The new synthetic backlog fixture verifies that this is an endpoint error. It does not claim hardware endpoint validation or attempt an unsafe trim of contaminated resampler state.
- Cancellation could release the app's admission gate before capture closure completed, allowing a stale “microphone closed” status over another session. Capture closure now holds a separate gate and generation-checks completion updates.
- A late first-sample callback could replace a stopping/error status. It now requires the still-current preparing phase before reporting recording.
- Source model size was checked before an unbounded copy. Import now performs bounded chunked copying, detects growth/truncation, checks cancellation during copying/hashing, and verifies the private copy before activation.
- Import completion checked cancellation before an awaited unload but not after. It now checks cancellation and generation on both sides.

No context or cancellation-token use-after-free was identified by the lifecycle reviewer in the serial inference path. That is a review observation, not a memory-sanitizer or real-model test result.

Still open: real devices, model inference/cancellation, targeted Thread Sanitizer or concurrent ring stress tests, real UI cancellation fixtures, model selection restoration, complete effective-parameter logging, and approved real insertion adapters. A future endpoint optimization should reduce false endpoint errors using measured timestamp/clock/priming behavior, preserving the batch reference.
