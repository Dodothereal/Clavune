# Architecture

Clavune is a macOS-only SwiftUI/AppKit application with a minimal C++ bridge to one
pinned whisper.cpp backend. Presentation is separate from capture, inference and
resource ownership. The current source is experimental; this map is not a runtime
verification result.

## Application and ownership

`ClavuneApp` and `AppCoordinator` own the native window/review workflow. A main-actor
coordinator admits operations, rejects stale results and waits for admitted work to
drain after cancellation. Capture, model setup, transcription, file operations and
statistics export have explicit ownership boundaries. Cancellation is a request,
not proof that a decoder, file operation or delegate has already released resources.

`CoordinatorEnvironment`, `AppLaunchConfiguration` and `FunctionalQAContext` provide
injected system boundaries and isolated synthetic QA. The normal development bundle
uses `org.clavune.development`. The fixed comparison identifier intentionally enters
synthetic QA; the two must not be confused during packaging or acceptance.

## Audio pipeline

Live input is captured at its negotiated native rate. The realtime callback performs
a bounded copy/publication into a preallocated single-producer/single-consumer C++
ring. Worker-side checks handle continuity/loss and continuous conversion to 16-kHz
mono PCM. A fixed stop cutoff and bounded drain prevent later samples from silently
entering the accepted prefix. Overflow or an unconfirmed endpoint fails closed.

The development live limit is 120 seconds. Explicit audio import uses read-only,
bounded native decoding into the same batch pipeline, rejects overlong input and
does not open microphone capture. Synthetic timeline tests do not establish actual
device closure or Bluetooth endpoint behavior.

## Models and inference

`ModelStore` and `ModelDownloadService` accept only manifest-matching size/hash
identities. Imports create verified managed copies. Explicit HTTPS downloads use
pinned revisions, bounded streaming, restricted redirects and validated ETag resume.
Pre-request setup must finish before creating a delegate-retaining session. Failed
or cancelled setup must not release resources still owned by active work.

The explicitly selected installed model is reverified on relaunch; inference weights
load on demand. A serialized inference service can retain verified weights for warm
reuse, while decoder state and cancellation ownership remain per request. There is
one active inference job, no preview streaming and no promoted default model. Hash
identity does not establish quality, conversion provenance or runtime compatibility.

## Review, files and clipboard

Native transcript editing keeps raw recognition separate from edited text. Explicit
copy uses a current-host clipboard operation; external automatic paste/AX mutation
is not enabled. Open/Save use bounded UTF-8 document handling and atomic save staging.
Save, Quit and editor composition need byte/selection/Undo preservation, not merely
matching high-level strings. Real Open cancellation/read-failure and IME workflows
remain acceptance gaps.

## Local metrics

`LocalMetricsJournal` writes bounded, content-free, append-only local records when
private storage and writer ownership are available. The snapshot reader and
statistics model feed the presentation and explicit JSON export. Metrics are enabled
by default without a user-facing off switch; no transcript/audio/path fields or
remote metrics upload are intended. See [Privacy](../PRIVACY.md).

## Build and verification boundaries

The dependency archive and downstream patches are hash-locked. Packaging separates
source/build identity from ad-hoc signing, resource/license checks and final artifact
publication. Portable Python tests inspect contracts and synthetic tools. Native
Swift/AppKit, real capture/model behavior, supported OS coverage and a notarized
binary require additional evidence; see [validation status](VALIDATION.md).
