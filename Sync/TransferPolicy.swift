// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Sync/TransferPolicy.swift
// Description: Policies of the 2.0 transfer engine that do not depend on the network: retry delays (exponential back-off with jitter), priorities (what a person asked for goes before background work), and the power state of the machine (battery, Low Power Mode) with what it allows.
import Foundation
#if os(macOS)
import IOKit.ps
#endif

/// Delay before trying again: grows by `factor` at each failure up to `cap`, and is spread by ±`jitter` so that
/// many transfers (or many devices) that failed together do not come back together.
public struct RetryPolicy: Sendable, Equatable {
    public var base: Double
    public var factor: Double
    public var cap: Double
    /// Fraction of the delay that is randomised on each side (0.25 = between 75 % and 125 %).
    public var jitter: Double
    public init(base: Double, factor: Double = 2, cap: Double, jitter: Double = 0.25) { self.base = base; self.factor = factor; self.cap = cap; self.jitter = min(max(jitter, 0), 1) }
    /// Transfers: 2 s, 4 s, 8 s … 10 min.
    public static let transfers = RetryPolicy(base: 2, cap: 600)
    /// Event stream reconnection: 1 s … 60 s (contract §3).
    public static let reconnect = RetryPolicy(base: 1, cap: 60, jitter: 0.3)
    /// Delay without jitter for the nth consecutive failure (1 = first).
    public func nominal(attempt: Int) -> Double { min(cap, base * pow(factor, Double(min(max(attempt, 1), 40) - 1))) }
    /// - Parameter unit: a number in 0…1 that places the delay inside its jitter band (random by default; fixed in tests).
    public func delay(attempt: Int, unit: Double = .random(in: 0...1)) -> Double {
        let n = nominal(attempt: attempt), spread = n * jitter
        return min(cap, max(0, n - spread + 2 * spread * min(max(unit, 0), 1)))
    }
}

/// Priorities of the transfer queue. Higher runs first; among equals, first queued first served.
public enum TransferPriority {
    /// Work nobody is waiting for (pre-fetching, housekeeping). Deferred in Low Power Mode and on a nearly empty battery.
    public static let background = 0
    /// Something the person just asked for: an upload they dropped, a download they clicked.
    public static let userInitiated = 10
    /// "Send this one first", chosen in the transfer centre.
    public static let urgent = 20
}

/// What the machine's power situation is right now.
public struct PowerState: Sendable, Equatable {
    public var onBattery: Bool
    public var lowPowerMode: Bool
    /// Charge between 0 and 1; nil on a Mac without a battery.
    public var level: Double?
    public init(onBattery: Bool = false, lowPowerMode: Bool = false, level: Double? = nil) { self.onBattery = onBattery; self.lowPowerMode = lowPowerMode; self.level = level }
    public static let unconstrained = PowerState()
    /// On battery with 10 % or less.
    public var isCritical: Bool { onBattery && (level ?? 1) <= 0.10 }
    /// On battery with 20 % or less.
    public var isLow: Bool { onBattery && (level ?? 1) <= 0.20 }
    /// Background transfers wait; what the person asked for still runs.
    public var defersBackground: Bool { lowPowerMode || isCritical }
    /// Upper bound on simultaneous transfers imposed by power alone.
    public var concurrencyCap: Int { defersBackground ? 1 : (isLow ? 2 : Int.max) }
}

public protocol PowerSource: Sendable { var state: PowerState { get } }

/// A power source with a fixed, settable state (tests, and Macs where nothing can be read).
public final class FixedPowerSource: PowerSource, @unchecked Sendable {
    private let lock = NSLock(); private var value: PowerState
    public init(_ state: PowerState = .unconstrained) { value = state }
    public var state: PowerState { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

/// Reads Low Power Mode from ProcessInfo and, on macOS, the battery from IOKit power sources. Cheap enough to be read at each queue tick (every 2 s).
public final class SystemPowerSource: PowerSource {
    public init() {}
    public var state: PowerState {
        var s = PowerState(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        #if os(macOS)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return s }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any], (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            s.onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            if let cur = d[kIOPSCurrentCapacityKey] as? Double, let max = d[kIOPSMaxCapacityKey] as? Double, max > 0 { s.level = cur / max }
            else if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 { s.level = Double(cur) / Double(max) }
        }
        #endif
        return s
    }
}
