import Foundation
import Dispatch

// MARK: - Trace Types

extension CallSessionController {
    struct TraceClock {
        let t0Ns: UInt64

        init() {
            self.t0Ns = DispatchTime.now().uptimeNanoseconds
        }

        func nowNs() -> UInt64 {
            DispatchTime.now().uptimeNanoseconds
        }

        func msSinceT0(_ tNs: UInt64) -> Double {
            Double(tNs &- t0Ns) / 1_000_000.0
        }

        func deltaMs(_ a: UInt64, _ b: UInt64) -> Double {
            Double(b &- a) / 1_000_000.0
        }
    }
}
