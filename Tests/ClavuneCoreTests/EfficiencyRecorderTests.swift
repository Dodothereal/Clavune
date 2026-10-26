import Dispatch
import Foundation
import XCTest
@testable import ClavuneCore

/// These tests use invented counters and manual ticks only. No audio, model or benchmark.
final class EfficiencyRecorderTests: XCTestCase {
    private final class Clock: EfficiencyClock, @unchecked Sendable {
        private let lock = NSLock()
        private var time: UInt64 = 1_000_000_000
        private var reads = 0
        var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
        func nowNS() -> UInt64 { lock.lock(); defer { lock.unlock() }; reads += 1; return time }
        func advance(_ ns: UInt64) { lock.lock(); time += ns; lock.unlock() }
        func set(_ ns: UInt64) { lock.lock(); time = ns; lock.unlock() }
    }

    private final class Counters: EfficiencyCounterProvider {
        let clock: Clock
        var cpuReads = 0
        var memoryReads = 0
        var rssMissing = false
        var footprintMissing = false
        init(_ clock: Clock) { self.clock = clock }
        func readCPU() -> EfficiencyCPUReading {
            cpuReads += 1
            let start = clock.nowNS()
            clock.advance(10)
            let end = clock.nowNS()
            return EfficiencyCPUReading(
                user_seconds: EfficiencyCounter(value: Double(cpuReads), status: .valid,
                    api: .synthetic, read_started_ns: start, read_ended_ns: end, error_number: nil),
                system_seconds: EfficiencyCounter(value: Double(cpuReads) / 2, status: .valid,
                    api: .synthetic, read_started_ns: start, read_ended_ns: end, error_number: nil))
        }
        func readMemory() -> EfficiencyMemoryReading {
            memoryReads += 1
            let start = clock.nowNS()
            clock.advance(20)
            let end = clock.nowNS()
            return EfficiencyMemoryReading(
                rss_bytes: EfficiencyCounter(value: rssMissing ? nil : UInt64(100 + memoryReads),
                    status: rssMissing ? .api_failed : .valid, api: .synthetic,
                    read_started_ns: start, read_ended_ns: end, error_number: rssMissing ? 5 : nil),
                phys_footprint_bytes: EfficiencyCounter(value: footprintMissing ? nil : UInt64(80 + memoryReads),
                    status: footprintMissing ? .unsupported : .valid, api: .synthetic,
                    read_started_ns: start, read_ended_ns: end, error_number: nil))
        }
    }

    private func identity(_ role: EfficiencyRole = .measured_trial) throws -> EfficiencyIdentity {
        try EfficiencyIdentity(attemptID: UUID(), observationID: UUID(), role: role,
            evidenceKind: .synthetic_self_test,
            sourceInventorySHA256: String(repeating: "a", count: 64),
            executableSHA256: String(repeating: "b", count: 64),
            experimentManifestSHA256: String(repeating: "c", count: 64))
    }

    private func recorder(samples: Int = 1_168, milestones: Int = 32)
        throws -> (EfficiencyRecorder, Clock, Counters) {
        let clock = Clock()
        // Keep both provider and call-site timestamps in exactly the same injected domain.
        let sharedCounters = Counters(clock)
        let recorder = EfficiencyRecorder(
            configuration: try EfficiencyConfiguration(maximumPeriodicSamples: samples,
                                                       maximumMilestones: milestones),
            clock: clock, provider: sharedCounters, automaticallySchedule: false)
        return (recorder, clock, sharedCounters)
    }

    func testIdleRecorderDoesNotReadCounters() throws {
        let (r, _, p) = try recorder()
        XCTAssertNil(r.ticket())
        r.sampleForTesting()
        XCTAssertEqual(p.cpuReads, 0); XCTAssertEqual(p.memoryReads, 0)
    }

    func testSuccessKeepsCompletionDistinctFromObservation() throws {
        let (r, clock, _) = try recorder()
        let id = try identity(.measured_trial)
        let ticket = try r.begin(id)
        clock.advance(100)
        XCTAssertTrue(ticket.mark(.decode_work_drained))
        clock.advance(1_000)
        let trace = try ticket.finish(outcome: .ok, completedBy: .decode_work_drained)
        XCTAssertEqual(trace.outcome, .ok)
        XCTAssertEqual(trace.identity.run_role, .measured_trial)
        XCTAssertEqual(trace.completed_end_ns, trace.milestones.last?.timestamp_ns)
        XCTAssertLessThan(try XCTUnwrap(trace.completed_end_ns), trace.observation_end_ns)
        XCTAssertNil(r.ticket())
    }

    func testCounterAcquisitionBracketsArePreserved() throws {
        let (r, _, _) = try recorder()
        let ticket = try r.begin(identity())
        let trace = try ticket.finish(outcome: .right_censored, reason: .harness_stopped)
        let cpu = trace.started.cpu.user_seconds
        XCTAssertEqual(cpu.read_ended_ns - cpu.read_started_ns, 10)
        XCTAssertEqual(trace.started.memory.rss_bytes.read_ended_ns -
                       trace.started.memory.rss_bytes.read_started_ns, 20)
        XCTAssertNotEqual(cpu.read_started_ns, trace.started.memory.rss_bytes.read_started_ns)
    }

    func testFailureDoesNotInventCompletionOrEnergy() throws {
        let (r, _, _) = try recorder()
        let ticket = try r.begin(identity())
        let trace = try ticket.finish(outcome: .failed, reason: .inference_failed)
        XCTAssertNil(trace.completed_end_ns); XCTAssertNil(trace.energy_joules)
        XCTAssertEqual(trace.energy_status, "not_measured")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trace))
                                    as? [String: Any])
        XCTAssertTrue(object["completed_end_ns"] is NSNull)
        XCTAssertTrue(object["energy_joules"] is NSNull)
        XCTAssertEqual(object["reason"] as? String, "inference_failed")
    }

    func testMissingCounterIsNullAndIndependent() throws {
        let (r, clock, p) = try recorder()
        let ticket = try r.begin(identity())
        p.rssMissing = true
        clock.advance(100_000_000); r.sampleForTesting()
        let trace = try ticket.finish(outcome: .cancelled, reason: .cancelled)
        let sample = try XCTUnwrap(trace.memory_samples.first)
        XCTAssertNil(sample.memory.rss_bytes.value)
        XCTAssertEqual(sample.memory.rss_bytes.status, .api_failed)
        XCTAssertEqual(sample.memory.rss_bytes.error_number, 5)
        XCTAssertEqual(sample.memory.phys_footprint_bytes.status, .valid)
        XCTAssertNotNil(sample.memory.phys_footprint_bytes.value)
    }

    func testPeriodicCapacityIsBoundedAndDoesNotDiscardTerminal() throws {
        let (r, clock, _) = try recorder(samples: 2)
        let ticket = try r.begin(identity())
        for _ in 0..<5 { clock.advance(100_000_000); r.sampleForTesting() }
        XCTAssertTrue(ticket.mark(.decode_work_drained))
        let trace = try ticket.finish(outcome: .ok, completedBy: .decode_work_drained)
        XCTAssertEqual(trace.memory_samples.count, 2)
        XCTAssertTrue(trace.periodic_sampling_truncated)
        XCTAssertEqual(trace.outcome, .ok) // Resource coverage, not workload success, is truncated.
        XCTAssertNotNil(trace.completed_end_ns)
    }

    func testPeriodicWindowDoesNotStopWorkOrDiscardLaterDrain() throws {
        let (r, clock, _) = try recorder()
        let ticket = try r.begin(identity())
        clock.advance(121_000_000_000); r.sampleForTesting()
        XCTAssertTrue(ticket.mark(.decode_work_drained))
        let trace = try ticket.finish(outcome: .ok, completedBy: .decode_work_drained)
        XCTAssertTrue(trace.periodic_sampling_truncated)
        XCTAssertEqual(trace.memory_samples.count, 0)
        XCTAssertNotNil(trace.completed_end_ns)
    }

    func testMilestoneOverflowProducesInvalidTraceWithReservedTerminal() throws {
        let (r, _, _) = try recorder(milestones: 1)
        let ticket = try r.begin(identity())
        XCTAssertTrue(ticket.mark(.decode_queue_started))
        XCTAssertFalse(ticket.mark(.decode_work_drained))
        let trace = try ticket.finish(outcome: .ok, completedBy: .decode_work_drained)
        XCTAssertEqual(trace.outcome, .invalid)
        XCTAssertEqual(trace.reason, .milestone_capacity_exceeded)
        XCTAssertNil(trace.completed_end_ns)
        XCTAssertEqual(trace.finished.event, .observation_finished)
        XCTAssertEqual(trace.milestones.count, 1)
    }

    func testOldTicketCannotContaminateNewAttempt() throws {
        let (r, _, p) = try recorder()
        let old = try r.begin(identity())
        _ = try old.finish(outcome: .cancelled, reason: .cancelled)
        let current = try r.begin(identity())
        let before = p.cpuReads
        XCTAssertFalse(old.mark(.decode_work_drained))
        XCTAssertEqual(p.cpuReads, before)
        XCTAssertTrue(current.mark(.decode_work_drained))
        let trace = try current.finish(outcome: .ok, completedBy: .decode_work_drained)
        XCTAssertEqual(trace.milestones.count, 1)
    }

    func testOldScheduledTickCannotContaminateNewAttempt() throws {
        let (r, clock, p) = try recorder()
        let old = try r.begin(identity())
        _ = try old.finish(outcome: .cancelled, reason: .cancelled)
        let current = try r.begin(identity())
        let before = p.memoryReads
        clock.advance(100_000_000)
        r.sampleForTesting(old)
        XCTAssertEqual(p.memoryReads, before)
        r.sampleForTesting(current)
        XCTAssertEqual(p.memoryReads, before + 1)
        let trace = try current.finish(outcome: .right_censored, reason: .harness_stopped)
        XCTAssertEqual(trace.memory_samples.count, 1)
    }

    func testNoReadAfterFinishAndDoubleFinishRejected() throws {
        let (r, clock, p) = try recorder()
        let ticket = try r.begin(identity())
        _ = try ticket.finish(outcome: .right_censored, reason: .harness_stopped)
        let count = p.memoryReads
        clock.advance(100_000_000); r.sampleForTesting()
        XCTAssertFalse(ticket.mark(.decode_work_drained))
        XCTAssertEqual(p.memoryReads, count)
        XCTAssertThrowsError(try ticket.finish(outcome: .cancelled, reason: .cancelled))
    }

    func testNoFabricatedCompletionAndNoConcurrentBegin() throws {
        let (r, _, _) = try recorder()
        let ticket = try r.begin(identity())
        XCTAssertThrowsError(try r.begin(identity()))
        XCTAssertThrowsError(try ticket.finish(outcome: .ok, completedBy: .decode_work_drained))
        XCTAssertThrowsError(try ticket.finish(outcome: .failed))
        _ = try ticket.finish(outcome: .right_censored, reason: .harness_stopped)
    }

    func testRegressedClockIsInvalidNotSuccessfulDuration() throws {
        let (r, clock, _) = try recorder()
        let ticket = try r.begin(identity())
        ticket.mark(.decode_work_drained)
        clock.set(1)
        let trace = try ticket.finish(outcome: .ok, completedBy: .decode_work_drained)
        XCTAssertEqual(trace.outcome, .invalid)
        XCTAssertEqual(trace.reason, .clock_regressed)
        XCTAssertNil(trace.completed_end_ns)
    }

    func testConfigurationAndPrivacyIdentifiersRejectUnboundedInput() throws {
        XCTAssertThrowsError(try EfficiencyConfiguration(samplingIntervalNS: 1))
        XCTAssertThrowsError(try EfficiencyConfiguration(periodicWindowNS: .max))
        XCTAssertThrowsError(try EfficiencyConfiguration(maximumPeriodicSamples: 1_169))
        XCTAssertThrowsError(try EfficiencyConfiguration(maximumMilestones: 33))
        XCTAssertThrowsError(try EfficiencyIdentity(attemptID: UUID(), observationID: UUID(),
            role: .measured_trial, evidenceKind: .synthetic_self_test, sourceInventorySHA256: "/private/path",
            executableSHA256: String(repeating: "a", count: 64),
            experimentManifestSHA256: String(repeating: "b", count: 64)))
    }

    func testCPUTimevalNormalizationAndMalformedValues() {
        XCTAssertEqual(EfficiencyDarwinCounters.normalizedSeconds(seconds: 2, microseconds: 250_000), 2.25)
        XCTAssertEqual(EfficiencyDarwinCounters.normalizedSeconds(seconds: 0, microseconds: 0), 0)
        XCTAssertNil(EfficiencyDarwinCounters.normalizedSeconds(seconds: -1, microseconds: 0))
        XCTAssertNil(EfficiencyDarwinCounters.normalizedSeconds(seconds: 1, microseconds: -1))
        XCTAssertNil(EfficiencyDarwinCounters.normalizedSeconds(seconds: 1, microseconds: 1_000_000))
    }

    func testAggregateCeilingIncludesAllFailedAndSuccessfulAcquisitions() throws {
        let (r, clock, p) = try recorder()
        let ticket = try r.begin(identity())
        p.rssMissing = true
        p.footprintMissing = true
        for _ in 0..<1_168 {
            clock.advance(100_000_000)
            r.sampleForTesting(ticket)
        }
        for _ in 0..<31 { XCTAssertTrue(ticket.mark(.decode_queue_started)) }
        XCTAssertTrue(ticket.mark(.decode_work_drained))
        for _ in 0..<8 { r.sampleForTesting(ticket) }
        let trace = try ticket.finish(outcome: .ok, completedBy: .decode_work_drained)
        XCTAssertEqual(trace.configuration.maximum_vm_acquisitions, 1_202)
        XCTAssertEqual(trace.configuration.maximum_periodic_samples, 1_168)
        XCTAssertEqual(trace.memory_samples.count, 1_168)
        XCTAssertEqual(trace.milestones.count, 32)
        XCTAssertEqual(p.memoryReads, 1_202)
        XCTAssertEqual(p.cpuReads, 34)
        XCTAssertTrue(trace.periodic_sampling_truncated)
        XCTAssertEqual(trace.outcome, .ok)
        XCTAssertEqual(trace.memory_samples.last?.memory.rss_bytes.status, .api_failed)
        XCTAssertEqual(trace.memory_samples.last?.memory.phys_footprint_bytes.status, .unsupported)
    }

    func testUnusedMilestoneReservationsCannotIncreasePeriodicCeiling() throws {
        XCTAssertThrowsError(try EfficiencyConfiguration(maximumPeriodicSamples: 1_169,
                                                        maximumMilestones: 1))
        let config = try EfficiencyConfiguration(maximumMilestones: 1)
        XCTAssertEqual(config.maximum_periodic_samples, 1_168)
        XCTAssertEqual(config.maximum_vm_acquisitions, 1_202)
    }

    func testStaleFinishRejectsBeforeClockCountersAndState() throws {
        let clock = Clock()
        let p = Counters(clock)
        let r = EfficiencyRecorder(configuration: try EfficiencyConfiguration(samplingIntervalNS: 1_000_000_000),
            clock: clock, provider: p, automaticallySchedule: false)
        let old = try r.begin(identity())
        _ = try old.finish(outcome: .right_censored, reason: .harness_stopped)
        let currentIdentity = try identity()
        let current = try r.begin(currentIdentity)
        XCTAssertEqual(current.observationID, currentIdentity.observation_id)
        let cpuBefore = p.cpuReads, memoryBefore = p.memoryReads, clockBefore = clock.readCount
        XCTAssertThrowsError(try old.finish(outcome: .failed, reason: .inference_failed)) {
            guard case EfficiencyRecorderError.stale_ticket = $0 else {
                XCTFail("Expected stale_ticket, got \($0)"); return
            }
        }
        XCTAssertEqual(clock.readCount, clockBefore)
        XCTAssertEqual(p.cpuReads, cpuBefore); XCTAssertEqual(p.memoryReads, memoryBefore)
        XCTAssertEqual(r.ticket()?.observationID, currentIdentity.observation_id)
        XCTAssertTrue(current.mark(.decode_work_drained))
        let trace = try current.finish(outcome: .ok, completedBy: .decode_work_drained)
        XCTAssertEqual(trace.identity.observation_id, currentIdentity.observation_id)
        XCTAssertFalse(r.timerScheduledForTesting)
    }

    func testStaleFinishLeavesCurrentScheduledTimerActive() throws {
        let clock = Clock()
        let p = Counters(clock)
        let r = EfficiencyRecorder(configuration: try EfficiencyConfiguration(samplingIntervalNS: 1_000_000_000),
            clock: clock, provider: p, automaticallySchedule: true)
        let old = try r.begin(identity())
        _ = try old.finish(outcome: .right_censored, reason: .harness_stopped)
        let current = try r.begin(identity())
        XCTAssertTrue(r.timerScheduledForTesting)
        XCTAssertThrowsError(try old.finish(outcome: .failed, reason: .inference_failed))
        XCTAssertTrue(r.timerScheduledForTesting)
        _ = try current.finish(outcome: .cancelled, reason: .cancelled)
        XCTAssertFalse(r.timerScheduledForTesting)
    }

    func testRightCensorThenLateNativeEventsCannotTerminalizeNewObservation() throws {
        let (r, _, p) = try recorder()
        let old = try r.begin(identity())
        _ = try old.finish(outcome: .right_censored, reason: .harness_stopped)
        let current = try r.begin(identity())
        let reads = p.memoryReads
        XCTAssertFalse(old.mark(.decode_result_created))
        XCTAssertFalse(old.mark(.decode_work_drained))
        XCTAssertThrowsError(try old.finish(outcome: .ok, completedBy: .decode_work_drained))
        XCTAssertEqual(p.memoryReads, reads)
        let trace = try current.finish(outcome: .cancelled, reason: .cancelled)
        XCTAssertTrue(trace.milestones.isEmpty)
        XCTAssertNil(trace.completed_end_ns)
        // This recorder-only sequence does not authorize a second live native decode.
    }

    func testDuplicateTerminalizationRejectedWithoutProviderReads() throws {
        let (r, _, p) = try recorder()
        let ticket = try r.begin(identity())
        _ = try ticket.finish(outcome: .cancelled, reason: .cancelled)
        let reads = p.memoryReads
        XCTAssertThrowsError(try ticket.finish(outcome: .cancelled, reason: .cancelled)) {
            guard case EfficiencyRecorderError.not_active = $0 else {
                XCTFail("Expected not_active"); return
            }
        }
        XCTAssertEqual(p.memoryReads, reads)
    }

    func testSuccessRejectsReasonAndUnapprovedCompletionWithoutConsumption() throws {
        let (r, _, p) = try recorder()
        let ticket = try r.begin(identity())
        XCTAssertTrue(ticket.mark(.decode_queue_started))
        let reads = p.memoryReads
        XCTAssertThrowsError(try ticket.finish(outcome: .ok, completedBy: .decode_queue_started))
        XCTAssertThrowsError(try ticket.finish(outcome: .ok, completedBy: .decode_work_drained,
                                               reason: .inference_failed))
        XCTAssertEqual(p.memoryReads, reads)
        XCTAssertEqual(r.ticket()?.observationID, ticket.observationID)
        XCTAssertTrue(ticket.mark(.decode_work_drained))
        let trace = try ticket.finish(outcome: .ok, completedBy: .decode_work_drained)
        XCTAssertNil(trace.reason)
    }

    func testDuplicateCompletionCannotSelectLastOpportunistically() throws {
        let (r, clock, p) = try recorder()
        let ticket = try r.begin(identity())
        XCTAssertTrue(ticket.mark(.decode_work_drained))
        clock.advance(100)
        XCTAssertTrue(ticket.mark(.decode_work_drained))
        let reads = p.memoryReads
        XCTAssertThrowsError(try ticket.finish(outcome: .ok, completedBy: .decode_work_drained)) {
            guard case EfficiencyRecorderError.ambiguous_completion_event = $0 else {
                XCTFail("Expected ambiguous_completion_event"); return
            }
        }
        XCTAssertEqual(p.memoryReads, reads)
        let trace = try ticket.finish(outcome: .invalid, reason: .harness_stopped)
        XCTAssertEqual(trace.milestones.count, 2)
        XCTAssertNil(trace.completed_end_ns)
    }

    func testFailedAndCancelledDrainsNeverBecomeSuccessfulCompletion() throws {
        for outcome in [EfficiencyOutcome.failed, .cancelled] {
            let (r, _, _) = try recorder()
            let ticket = try r.begin(identity())
            XCTAssertTrue(ticket.mark(.decode_submission_requested))
            XCTAssertTrue(ticket.mark(.decode_work_drained))
            let trace = try ticket.finish(outcome: outcome, completedBy: .decode_work_drained,
                reason: outcome == .failed ? .inference_failed : .cancelled)
            XCTAssertEqual(trace.outcome, outcome)
            XCTAssertNil(trace.completed_end_ns)
            XCTAssertEqual(trace.milestones.last?.event, .decode_work_drained)
        }
    }

    func testInjectedProviderCannotClaimExportedMeasurement() throws {
        let (r, clock, p) = try recorder()
        let id = try EfficiencyIdentity(attemptID: UUID(), observationID: UUID(), role: .measured_trial,
            evidenceKind: .exported_measurement_claim,
            sourceInventorySHA256: String(repeating: "a", count: 64),
            executableSHA256: String(repeating: "b", count: 64),
            experimentManifestSHA256: String(repeating: "c", count: 64))
        let before = clock.readCount
        XCTAssertThrowsError(try r.begin(id)) {
            guard case EfficiencyRecorderError.synthetic_evidence_required = $0 else {
                XCTFail("Expected synthetic_evidence_required"); return
            }
        }
        XCTAssertEqual(p.cpuReads, 0); XCTAssertEqual(p.memoryReads, 0)
        XCTAssertEqual(clock.readCount, before)
        XCTAssertNil(r.ticket())
    }

    private final class RaceResult: @unchecked Sendable {
        let lock = NSLock()
        var acceptedMark: Bool?
        var trace: EfficiencyTrace?
        var failure: Error?
        func mark(_ accepted: Bool) { lock.lock(); defer { lock.unlock() }; acceptedMark = accepted }
        func finish(_ result: Result<EfficiencyTrace, Error>) {
            lock.lock(); defer { lock.unlock() }
            switch result { case .success(let value): trace = value; case .failure(let error): failure = error }
        }
    }

    func testConcurrentMarkAndFinishHaveOneSerializedOutcome() throws {
        let (r, _, p) = try recorder()
        let ticket = try r.begin(identity())
        let result = RaceResult()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { result.mark(ticket.mark(.decode_work_drained)); group.leave() }
        group.enter()
        DispatchQueue.global().async {
            result.finish(Result { try ticket.finish(outcome: .right_censored, reason: .harness_stopped) })
            group.leave()
        }
        guard group.wait(timeout: .now() + 2) == .success else {
            XCTFail("Synthetic serialization test timed out"); return
        }
        result.lock.lock()
        let accepted = result.acceptedMark, trace = result.trace, failure = result.failure
        result.lock.unlock()
        XCTAssertNil(failure)
        let completedTrace = try XCTUnwrap(trace)
        XCTAssertEqual(completedTrace.milestones.count, accepted == true ? 1 : 0)
        XCTAssertEqual(p.memoryReads, 2 + completedTrace.milestones.count)
        XCTAssertNil(r.ticket())
        XCTAssertFalse(ticket.mark(.decode_work_drained))
    }

    func testTicketRetainsRecorderUntilReleasedAndTimerDoesNotCycle() throws {
        let clock = Clock()
        let counters = Counters(clock)
        var recorder: EfficiencyRecorder? = EfficiencyRecorder(
            configuration: try EfficiencyConfiguration(samplingIntervalNS: 1_000_000_000),
            clock: clock, provider: counters, automaticallySchedule: true)
        weak var weakRecorder = recorder
        var ticket: EfficiencyTicket? = try recorder?.begin(identity())
        XCTAssertNotNil(ticket)
        recorder = nil
        XCTAssertNotNil(weakRecorder)
        ticket = nil
        XCTAssertNil(weakRecorder)
        // Requires actual Swift/Dispatch execution; source presence is not a runtime result.
    }
}
