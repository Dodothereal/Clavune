import AppKit
import ApplicationServices
import Foundation

/// A notification revokes the entire attempt rather than updating a snapshot:
/// observed A -> B -> A must never heal the original insertion lease.
/// The lock lets AX/workspace callbacks revoke without an asynchronous actor hop.
final class AXOneShotObservationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var revoked = false
    private var epoch: UInt64

    init(epoch: UInt64) { self.epoch = epoch }

    func arm() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !revoked else { return false }
        armed = true
        return true
    }

    func currentEpoch() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return armed && !revoked ? epoch : nil
    }

    func revoke() {
        lock.lock(); defer { lock.unlock() }
        revoked = true
        armed = false
        epoch &+= 1
    }
}

/// Callback refcon is a monotonically allocated integer, never an unretained
/// object pointer. A callback arriving after teardown finds no entry. IDs are
/// not reused even if an AX observer's CF address is recycled.
private final class AXOneShotCallbackRegistry: @unchecked Sendable {
    static let shared = AXOneShotCallbackRegistry()
    private let lock = NSLock()
    private var nextID: UInt = 1
    private var latches: [UInt: AXOneShotObservationLatch] = [:]

    func insert(_ latch: AXOneShotObservationLatch) -> UInt? {
        lock.lock(); defer { lock.unlock() }
        guard nextID < UInt.max else { return nil }
        let id = nextID
        nextID += 1
        latches[id] = latch
        return id
    }

    func revoke(_ id: UInt) {
        lock.lock()
        let latch = latches[id]
        lock.unlock()
        latch?.revoke()
    }

    func remove(_ id: UInt) {
        lock.lock(); defer { lock.unlock() }
        latches.removeValue(forKey: id)?.revoke()
    }
}

private func axOneShotNotificationCallback(_ observer: AXObserver, _ element: AXUIElement,
                                           _ notification: CFString,
                                           _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    AXOneShotCallbackRegistry.shared.revoke(UInt(bitPattern: refcon))
}

/// The observer is a narrow, fail-closed source-only adapter. Registration
/// success is not a proof that another app emits or delivers events on time:
/// every exact pinned target build needs separate native coverage validation.
final class AXOneShotNotificationLease {
    struct Registration {
        let element: AXUIElement
        let name: String
    }

    let latch: AXOneShotObservationLatch
    private let observer: AXObserver
    private let source: CFRunLoopSource
    private let runLoop: CFRunLoop
    private let callbackID: UInt
    private var registrations: [Registration] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var workspaceCenter: NotificationCenter?
    private var attached = false
    private var stopped = false
    private let stopLock = NSLock()

    private init(latch: AXOneShotObservationLatch, observer: AXObserver,
                 callbackID: UInt, runLoop: CFRunLoop) {
        self.latch = latch
        self.observer = observer
        self.source = AXObserverGetRunLoopSource(observer)
        self.callbackID = callbackID
        self.runLoop = runLoop
    }

    @MainActor static func start(pid: pid_t, application: AXUIElement,
                                 window: AXUIElement, field: AXUIElement) -> AXOneShotNotificationLease? {
        let latch = AXOneShotObservationLatch(epoch: UInt64.random(in: 1..<UInt64.max))
        guard let callbackID = AXOneShotCallbackRegistry.shared.insert(latch) else { return nil }
        var created: AXObserver?
        guard AXObserverCreate(pid, axOneShotNotificationCallback, &created) == .success,
              let observer = created else {
            AXOneShotCallbackRegistry.shared.remove(callbackID)
            return nil
        }
        let lease = AXOneShotNotificationLease(latch: latch, observer: observer,
                                               callbackID: callbackID, runLoop: CFRunLoopGetMain())
        guard lease.install(application: application, window: window, field: field) else {
            lease.stop()
            return nil
        }
        return lease
    }

    @MainActor private func install(application: AXUIElement,
                                    window: AXUIElement, field: AXUIElement) -> Bool {
        CFRunLoopAddSource(runLoop, source, CFRunLoopMode.commonModes)
        attached = CFRunLoopContainsSource(runLoop, source, CFRunLoopMode.commonModes)
        guard attached, CFRunLoopSourceIsValid(source) else { return false }

        // Every registration is mandatory. Unsupported/cannotComplete/duplicate
        // is a failed capture, not permission to omit an invalidation channel.
        let required: [Registration] = [
            .init(element: application, name: kAXFocusedUIElementChangedNotification),
            .init(element: application, name: kAXFocusedWindowChangedNotification),
            .init(element: application, name: kAXApplicationDeactivatedNotification),
            .init(element: field, name: kAXSelectedTextChangedNotification),
            .init(element: field, name: kAXValueChangedNotification),
            .init(element: field, name: kAXUIElementDestroyedNotification),
            .init(element: window, name: kAXUIElementDestroyedNotification)
        ]
        guard Set(required.map(\.name)) == AXOneShotSurfacePolicy.requiredNotificationNames
        else { return false }
        for item in required {
            guard AXUIElementSetMessagingTimeout(item.element, 0.25) == .success,
                  AXObserverAddNotification(observer, item.element,
                                            item.name as CFString,
                                            UnsafeMutableRawPointer(bitPattern: callbackID)) == .success
            else { return false }
            registrations.append(item)
        }

        // Workspace activation can reveal an app A -> B -> A excursion even
        // if the target app fails to post focus changes. Callback is immediate,
        // not Task { @MainActor ... }, so a received event latches revocation.
        let center = NSWorkspace.shared.notificationCenter
        workspaceCenter = center
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: nil) {
                [latch] _ in latch.revoke()
            })
        }
        return latch.arm()
    }

    func stop() {
        // Normal callers own this lease on MainActor. The deinit fallback may
        // run elsewhere, so serialize teardown; no install mutates these arrays
        // after the lease is published. CFRunLoop's C API is used, not NSRunLoop.
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped else { return }
        stopped = true
        latch.revoke() // revoke before any possibly failing teardown step
        AXOneShotCallbackRegistry.shared.remove(callbackID)
        if let center = workspaceCenter {
            for token in workspaceTokens { center.removeObserver(token) }
        }
        workspaceTokens.removeAll()
        workspaceCenter = nil
        for item in registrations.reversed() {
            _ = AXObserverRemoveNotification(observer, item.element, item.name as CFString)
        }
        registrations.removeAll()
        if attached { CFRunLoopRemoveSource(runLoop, source, CFRunLoopMode.commonModes) }
        attached = false
    }

    deinit { stop() }
}
