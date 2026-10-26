import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Development-only observation, never an audio callback dependency.
/// A nil recorder is the production default. This file performs no file/network I/O.
public enum EfficiencyRole: String, Codable, Sendable {
    case warmup, measured_trial, overhead_check
}

public enum EfficiencyEvidenceKind: String, Codable, Sendable {
    case synthetic_self_test, exported_measurement_claim
}

public enum EfficiencyEvent: String, Codable, Sendable {
    case observation_started, observation_finished
    case load_submission_requested, load_queue_started, model_context_reused
    case load_work_drained
    case decode_submission_requested, decode_queue_started
    case decode_result_created, decode_work_drained
    case unload_submission_requested, unload_queue_started, unload_work_drained
}

public enum EfficiencyOutcome: String, Codable, Sendable {
    case ok, failed, cancelled, invalid, right_censored
}

public enum EfficiencyReason: String, Codable, Sendable {
    case cancelled, inference_failed, harness_stopped
    case sleep_wake_clock_uncertain, route_changed, thermal_changed, power_changed
    case competing_work_changed, counter_regressed, clock_regressed, milestone_capacity_exceeded
}

public enum EfficiencyCounterState: String, Codable, Sendable {
    case valid, unsupported, api_failed, malformed, insufficient_returned_count
}

public enum EfficiencyCounterAPI: String, Codable, Sendable {
    case getrusage_self_user_seconds, getrusage_self_system_seconds
    case task_vm_info_resident_size_bytes, task_vm_info_phys_footprint_bytes
    case synthetic, unavailable
}

/// A value is null unless status=valid. Brackets are acquisition times, not phase boundaries.
public struct EfficiencyCounter<Value: Codable & Sendable>: Codable, Sendable {
    public let value: Value?
    public let status: EfficiencyCounterState
    public let api: EfficiencyCounterAPI
    public let read_started_ns: UInt64
    public let read_ended_ns: UInt64
    public let error_number: Int32?

    enum CodingKeys: String, CodingKey {
        case value, status, api, read_started_ns, read_ended_ns, error_number
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(status, forKey: .status)
        try c.encode(api, forKey: .api)
        try c.encode(read_started_ns, forKey: .read_started_ns)
        try c.encode(read_ended_ns, forKey: .read_ended_ns)
        try c.encode(error_number, forKey: .error_number)
    }
}

public struct EfficiencyCPUReading: Codable, Sendable {
    public let user_seconds: EfficiencyCounter<Double>
    public let system_seconds: EfficiencyCounter<Double>
}

public struct EfficiencyMemoryReading: Codable, Sendable {
    public let rss_bytes: EfficiencyCounter<UInt64>
    public let phys_footprint_bytes: EfficiencyCounter<UInt64>
}

public protocol EfficiencyClock: Sendable {
    func nowNS() -> UInt64
}

public struct EfficiencyUptimeClock: EfficiencyClock {
    public init() {}
    public func nowNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Called only in the recorder's serial, non-realtime ownership domain.
public protocol EfficiencyCounterProvider: AnyObject {
    func readCPU() -> EfficiencyCPUReading
    func readMemory() -> EfficiencyMemoryReading
}

public struct EfficiencyIdentity: Encodable, Sendable {
    public let attempt_id: UUID
    public let observation_id: UUID
    public let run_role: EfficiencyRole
    public let evidence_kind: EfficiencyEvidenceKind
    public let source_inventory_sha256: String
    public let executable_sha256: String
    /// Digest of an independently retained, content-free experiment manifest.
    /// The recorder does not verify its bytes or certify its claims.
    public let experiment_manifest_sha256: String

    public init(attemptID: UUID, observationID: UUID, role: EfficiencyRole,
                evidenceKind: EfficiencyEvidenceKind,
                sourceInventorySHA256: String, executableSHA256: String,
                experimentManifestSHA256: String) throws {
        for digest in [sourceInventorySHA256, executableSHA256, experimentManifestSHA256] {
            guard digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw EfficiencyRecorderError.invalid_identity }
        }
        attempt_id = attemptID; observation_id = observationID; run_role = role
        evidence_kind = evidenceKind
        source_inventory_sha256 = sourceInventorySHA256
        executable_sha256 = executableSHA256
        experiment_manifest_sha256 = experimentManifestSHA256
    }
}

public struct EfficiencyConfiguration: Encodable, Sendable {
    /// Aggregate provider.readMemory invocations, including failed readings.
    /// Reserve start + finish + all 32 milestones; unused reservations are not borrowed.
    public static let vmAcquisitionCeiling = 1_202
    public let maximum_vm_acquisitions: Int
    public let sampling_interval_ns: UInt64
    public let periodic_window_ns: UInt64
    public let maximum_periodic_samples: Int
    public let maximum_milestones: Int

    public init(samplingIntervalNS: UInt64 = 100_000_000,
                periodicWindowNS: UInt64 = 120_000_000_000,
                maximumPeriodicSamples: Int = 1_168,
                maximumMilestones: Int = 32) throws {
        guard (100_000_000...1_000_000_000).contains(samplingIntervalNS),
              periodicWindowNS >= samplingIntervalNS,
              periodicWindowNS <= 120_000_000_000,
              (1...1_168).contains(maximumPeriodicSamples),
              (1...32).contains(maximumMilestones),
              maximumPeriodicSamples + maximumMilestones + 2 <= Self.vmAcquisitionCeiling
        else { throw EfficiencyRecorderError.invalid_configuration }
        maximum_vm_acquisitions = Self.vmAcquisitionCeiling
        sampling_interval_ns = samplingIntervalNS; periodic_window_ns = periodicWindowNS
        maximum_periodic_samples = maximumPeriodicSamples; maximum_milestones = maximumMilestones
    }
}

public struct EfficiencyBoundary: Codable, Sendable {
    public let event: EfficiencyEvent
    /// Call-site timestamp; acquisition below can be later due to queue/sampler delay.
    public let timestamp_ns: UInt64
    public let recording_started_ns: UInt64
    public let recording_ended_ns: UInt64
    public let cpu: EfficiencyCPUReading
    public let memory: EfficiencyMemoryReading
}

public struct EfficiencyMemorySample: Codable, Sendable {
    public let tick_started_ns: UInt64
    public let tick_ended_ns: UInt64
    public let memory: EfficiencyMemoryReading
}

public struct EfficiencyTrace: Encodable, Sendable {
    public let schema_version: String
    public let clock: String
    public let identity: EfficiencyIdentity
    public let configuration: EfficiencyConfiguration
    public let outcome: EfficiencyOutcome
    public let reason: EfficiencyReason?
    public let started: EfficiencyBoundary
    public let finished: EfficiencyBoundary
    public let completed_end_ns: UInt64?
    public let observation_end_ns: UInt64
    public let milestones: [EfficiencyBoundary]
    public let memory_samples: [EfficiencyMemorySample]
    public let periodic_sampling_truncated: Bool
    public let milestone_overflow: Bool
    public let energy_status: String
    public let energy_joules: Double?

    enum CodingKeys: String, CodingKey {
        case schema_version, clock, identity, configuration, outcome, reason
        case started, finished, completed_end_ns, observation_end_ns, milestones
        case memory_samples, periodic_sampling_truncated, milestone_overflow
        case energy_status, energy_joules
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema_version, forKey: .schema_version)
        try c.encode(clock, forKey: .clock)
        try c.encode(identity, forKey: .identity)
        try c.encode(configuration, forKey: .configuration)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(reason, forKey: .reason)
        try c.encode(started, forKey: .started)
        try c.encode(finished, forKey: .finished)
        try c.encode(completed_end_ns, forKey: .completed_end_ns)
        try c.encode(observation_end_ns, forKey: .observation_end_ns)
        try c.encode(milestones, forKey: .milestones)
        try c.encode(memory_samples, forKey: .memory_samples)
        try c.encode(periodic_sampling_truncated, forKey: .periodic_sampling_truncated)
        try c.encode(milestone_overflow, forKey: .milestone_overflow)
        try c.encode(energy_status, forKey: .energy_status)
        try c.encode(energy_joules, forKey: .energy_joules)
    }
}

public enum EfficiencyRecorderError: Error {
    case invalid_identity, invalid_configuration, already_active, not_active
    case missing_completion_event, ambiguous_completion_event, invalid_completion_event
    case missing_reason, unexpected_success_reason, stale_ticket, synthetic_evidence_required
}

/// Ticket generation binds both events and terminalization to one observation.
/// Retaining a ticket intentionally retains its recorder; it does not grant a new workload admission.
public struct EfficiencyTicket: Sendable {
    fileprivate let recorder: EfficiencyRecorder
    fileprivate let generation: UUID
    public let observationID: UUID

    /// Call only after the actual inference queue barrier, or explicitly right-censor.
    /// `ok` is a caller-reported workload result, not proof of quality or lifecycle completion.
    public func finish(outcome: EfficiencyOutcome, completedBy: EfficiencyEvent? = nil,
                       reason: EfficiencyReason? = nil) throws -> EfficiencyTrace {
        try recorder.finish(generation: generation, outcome: outcome,
                            completedBy: completedBy, reason: reason)
    }

    @discardableResult public func mark(_ event: EfficiencyEvent) -> Bool {
        recorder.mark(event, generation: generation)
    }
}

/// The only lock/queue ownership domain is non-realtime. Never call from the tap.
/// A sample/window limit stops observation sampling, not capture or inference.
public final class EfficiencyRecorder: @unchecked Sendable {
    private final class Active {
        let generation = UUID()
        let identity: EfficiencyIdentity
        let started: EfficiencyBoundary
        var milestones: [EfficiencyBoundary] = []
        var samples: [EfficiencyMemorySample] = []
        var samplingTruncated = false
        var milestoneOverflow = false
        init(identity: EfficiencyIdentity, started: EfficiencyBoundary,
             configuration: EfficiencyConfiguration) {
            self.identity = identity; self.started = started
            milestones.reserveCapacity(configuration.maximum_milestones)
            samples.reserveCapacity(configuration.maximum_periodic_samples)
        }
    }
    private let queue = DispatchQueue(label: "org.clavune.efficiency-observer", qos: .utility)
    private let clock: any EfficiencyClock
    private let provider: any EfficiencyCounterProvider
    private let configuration: EfficiencyConfiguration
    private let automaticallySchedule: Bool
    private let syntheticProvidersOnly: Bool
    private var active: Active?
    private var timer: DispatchSourceTimer?

    public convenience init(configuration: EfficiencyConfiguration) {
        let clock = EfficiencyUptimeClock()
        self.init(configuration: configuration, clock: clock,
                  provider: EfficiencyDarwinCounters(clock: clock), automaticallySchedule: true,
                  syntheticProvidersOnly: false)
    }

    /// Injected adapter/manual scheduler is for deterministic observer tests, not product data.
    convenience init(configuration: EfficiencyConfiguration, clock: any EfficiencyClock,
                     provider: any EfficiencyCounterProvider, automaticallySchedule: Bool) {
        self.init(configuration: configuration, clock: clock, provider: provider,
                  automaticallySchedule: automaticallySchedule, syntheticProvidersOnly: true)
    }

    private init(configuration: EfficiencyConfiguration, clock: any EfficiencyClock,
                 provider: any EfficiencyCounterProvider, automaticallySchedule: Bool,
                 syntheticProvidersOnly: Bool) {
        self.configuration = configuration; self.clock = clock; self.provider = provider
        self.automaticallySchedule = automaticallySchedule
        self.syntheticProvidersOnly = syntheticProvidersOnly
    }

    deinit { timer?.setEventHandler {}; timer?.cancel() }

    @discardableResult public func begin(_ identity: EfficiencyIdentity) throws -> EfficiencyTicket {
        try queue.sync {
            guard active == nil else { throw EfficiencyRecorderError.already_active }
            guard !syntheticProvidersOnly || identity.evidence_kind == .synthetic_self_test else {
                throw EfficiencyRecorderError.synthetic_evidence_required
            }
            let start = boundary(.observation_started, at: clock.nowNS())
            let state = Active(identity: identity, started: start, configuration: configuration)
            active = state
            if automaticallySchedule {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .nanoseconds(Int(configuration.sampling_interval_ns)),
                               repeating: .nanoseconds(Int(configuration.sampling_interval_ns)),
                               leeway: .milliseconds(5))
                let generation = state.generation
                timer.setEventHandler { [weak self] in self?.sampleOnQueue(generation: generation) }
                self.timer = timer; timer.resume()
            }
            return EfficiencyTicket(recorder: self, generation: state.generation,
                                    observationID: state.identity.observation_id)
        }
    }

    public func ticket() -> EfficiencyTicket? {
        queue.sync { active.map {
            EfficiencyTicket(recorder: self, generation: $0.generation,
                             observationID: $0.identity.observation_id)
        } }
    }

    fileprivate func mark(_ event: EfficiencyEvent, generation: UUID) -> Bool {
        // Timestamp before serial handoff. This is still forbidden on the RT callback.
        let timestamp = clock.nowNS()
        return queue.sync {
            guard let state = active, state.generation == generation else { return false }
            guard event != .observation_started, event != .observation_finished else { return false }
            guard state.milestones.count < configuration.maximum_milestones else {
                state.milestoneOverflow = true
                return false
            }
            state.milestones.append(boundary(event, at: timestamp))
            return true
        }
    }

    /// Call only after the workload's actual drain barrier, or explicitly right-censor it.
    /// A returned/failed/cancelled continuation alone does not establish native result cleanup.
    fileprivate func finish(generation: UUID, outcome: EfficiencyOutcome,
                            completedBy: EfficiencyEvent?, reason: EfficiencyReason?) throws -> EfficiencyTrace {
        try queue.sync {
            guard let state = active else { throw EfficiencyRecorderError.not_active }
            // Reject before any clock/provider read, timer cancellation, or active-state mutation.
            guard state.generation == generation else { throw EfficiencyRecorderError.stale_ticket }
            guard outcome != .ok || reason == nil else {
                throw EfficiencyRecorderError.unexpected_success_reason
            }
            let completed: UInt64?
            if outcome == .ok && !state.milestoneOverflow {
                guard let event = completedBy else { throw EfficiencyRecorderError.missing_completion_event }
                guard event == .decode_work_drained || event == .load_work_drained ||
                      event == .unload_work_drained else {
                    throw EfficiencyRecorderError.invalid_completion_event
                }
                let matches = state.milestones.lazy.filter { $0.event == event }
                guard let completion = matches.first else { throw EfficiencyRecorderError.missing_completion_event }
                guard matches.count == 1 else { throw EfficiencyRecorderError.ambiguous_completion_event }
                completed = completion.timestamp_ns
            } else if outcome != .ok {
                guard reason != nil else { throw EfficiencyRecorderError.missing_reason }
                completed = nil
            } else {
                completed = nil
            }
            cancelTimerOnQueue()
            let end = boundary(.observation_finished, at: clock.nowNS())
            let exceedsWindow = end.timestamp_ns < state.started.timestamp_ns ||
                end.timestamp_ns - state.started.timestamp_ns > configuration.periodic_window_ns
            let clockRegressed = end.timestamp_ns < state.started.timestamp_ns ||
                end.recording_ended_ns < end.timestamp_ns ||
                state.milestones.contains {
                    $0.timestamp_ns < state.started.timestamp_ns || $0.timestamp_ns > end.timestamp_ns
                }
            let effectiveOutcome: EfficiencyOutcome = state.milestoneOverflow || clockRegressed ? .invalid : outcome
            let trace = EfficiencyTrace(schema_version: "clavune.efficiency.raw.v1",
                clock: "dispatch_uptime_ns_excludes_sleep", identity: state.identity,
                configuration: configuration, outcome: effectiveOutcome,
                reason: clockRegressed ? .clock_regressed :
                    state.milestoneOverflow ? .milestone_capacity_exceeded : reason,
                started: state.started, finished: end,
                completed_end_ns: effectiveOutcome == .ok ? completed : nil,
                observation_end_ns: end.recording_ended_ns,
                milestones: state.milestones, memory_samples: state.samples,
                periodic_sampling_truncated: state.samplingTruncated || exceedsWindow,
                milestone_overflow: state.milestoneOverflow,
                energy_status: "not_measured", energy_joules: nil)
            active = nil
            return trace
        }
    }

    /// Memory only on periodic ticks; CPU is sampled at bounded event boundaries.
    /// Every accepted provider acquisition is retained, including failures. Rejected ticks do not read.
    /// 1,168 periodic + 32 milestone + start/finish = at most 1,202 VM acquisitions.
    private func sampleOnQueue(generation: UUID) {
        guard let state = active, state.generation == generation else { return }
        let now = clock.nowNS()
        guard now >= state.started.timestamp_ns,
              now - state.started.timestamp_ns <= configuration.periodic_window_ns,
              state.samples.count < configuration.maximum_periodic_samples else {
            state.samplingTruncated = true
            cancelTimerOnQueue()
            return
        }
        let reading = provider.readMemory()
        state.samples.append(EfficiencyMemorySample(tick_started_ns: now,
            tick_ended_ns: clock.nowNS(), memory: reading))
        if state.samples.count == configuration.maximum_periodic_samples ||
           now - state.started.timestamp_ns == configuration.periodic_window_ns {
            state.samplingTruncated = true
            cancelTimerOnQueue()
        }
    }

    private func boundary(_ event: EfficiencyEvent, at timestamp: UInt64) -> EfficiencyBoundary {
        let begin = clock.nowNS()
        let cpu = provider.readCPU()
        let memory = provider.readMemory()
        return EfficiencyBoundary(event: event, timestamp_ns: timestamp,
            recording_started_ns: begin, recording_ended_ns: clock.nowNS(),
            cpu: cpu, memory: memory)
    }

    private func cancelTimerOnQueue() {
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
    }

    var timerScheduledForTesting: Bool { queue.sync { timer != nil } }

    // Tests deliberately execute the same sample path without a real timer or real resources.
    func sampleForTesting(_ ticket: EfficiencyTicket? = nil) {
        queue.sync {
            guard let generation = ticket?.generation ?? active?.generation else { return }
            sampleOnQueue(generation: generation)
        }
    }
}

/// SDK-bound adapter. Own process only. No sysctl, credentials, devices or host identity.
/// Must compile and run against the target macOS SDK before any source promotion.
public final class EfficiencyDarwinCounters: EfficiencyCounterProvider {
    private let clock: any EfficiencyClock
    public init(clock: any EfficiencyClock = EfficiencyUptimeClock()) { self.clock = clock }

    static func normalizedSeconds(seconds: Int64, microseconds: Int64) -> Double? {
        guard seconds >= 0, (0..<1_000_000).contains(microseconds) else { return nil }
        let result = Double(seconds) + Double(microseconds) / 1_000_000
        return result.isFinite ? result : nil
    }

    public func readCPU() -> EfficiencyCPUReading {
        let begin = clock.nowNS()
        #if canImport(Darwin)
        var usage = rusage()
        let rc = getrusage(RUSAGE_SELF, &usage)
        let error = rc == 0 ? nil : Int32(errno)
        let end = clock.nowNS()
        func value(_ time: timeval, api: EfficiencyCounterAPI) -> EfficiencyCounter<Double> {
            let seconds = Self.normalizedSeconds(seconds: Int64(time.tv_sec), microseconds: Int64(time.tv_usec))
            let valid = rc == 0 && seconds != nil
            return EfficiencyCounter(value: valid ? seconds : nil,
                status: rc != 0 ? .api_failed : valid ? .valid : .malformed,
                api: api, read_started_ns: begin, read_ended_ns: end, error_number: error)
        }
        return EfficiencyCPUReading(
            user_seconds: value(usage.ru_utime, api: .getrusage_self_user_seconds),
            system_seconds: value(usage.ru_stime, api: .getrusage_self_system_seconds))
        #else
        let end = clock.nowNS()
        let empty = EfficiencyCounter<Double>(value: nil, status: .unsupported, api: .unavailable,
            read_started_ns: begin, read_ended_ns: end, error_number: nil)
        return EfficiencyCPUReading(user_seconds: empty, system_seconds: empty)
        #endif
    }

    public func readMemory() -> EfficiencyMemoryReading {
        let begin = clock.nowNS()
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let rc: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let end = clock.nowNS()
        let returnedBytes = Int(count) * MemoryLayout<integer_t>.size
        func field(_ value: UInt64, offset: Int?, api: EfficiencyCounterAPI) -> EfficiencyCounter<UInt64> {
            let covered = offset.map { returnedBytes >= $0 + MemoryLayout<UInt64>.size } ?? false
            let valid = rc == KERN_SUCCESS && covered && count <= mach_msg_type_number_t(capacity)
            return EfficiencyCounter(value: valid ? value : nil,
                status: rc != KERN_SUCCESS ? .api_failed : valid ? .valid : .insufficient_returned_count,
                api: api, read_started_ns: begin, read_ended_ns: end,
                error_number: rc == KERN_SUCCESS ? nil : Int32(rc))
        }
        return EfficiencyMemoryReading(
            rss_bytes: field(UInt64(info.resident_size),
                offset: MemoryLayout<task_vm_info_data_t>.offset(of: \.resident_size),
                api: .task_vm_info_resident_size_bytes),
            phys_footprint_bytes: field(UInt64(info.phys_footprint),
                offset: MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint),
                api: .task_vm_info_phys_footprint_bytes))
        #else
        let end = clock.nowNS()
        let empty = EfficiencyCounter<UInt64>(value: nil, status: .unsupported, api: .unavailable,
            read_started_ns: begin, read_ended_ns: end, error_number: nil)
        return EfficiencyMemoryReading(rss_bytes: empty, phys_footprint_bytes: empty)
        #endif
    }
}
