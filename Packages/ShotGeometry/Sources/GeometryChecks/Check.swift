import Foundation

/// Minimal assertion collector. Command Line Tools ship neither XCTest nor Swift Testing, so the
/// suite is an executable. Each `check` records a pass or a failure with its message.
struct CheckRunner {
    var passed = 0
    var failures: [String] = []
    var current = ""

    mutating func suite(_ name: String) { current = name; print("— \(name)") }

    mutating func check(_ cond: Bool, _ msg: @autoclosure () -> String) {
        if cond { passed += 1 } else { let m = "[\(current)] \(msg())"; failures.append(m); print("  FAIL \(m)") }
    }

    mutating func near(_ a: Double, _ b: Double, tol: Double, _ label: String) {
        let ok = a.isFinite && b.isFinite && abs(a - b) <= tol
        check(ok, "\(label): got \(fmt(a)), want \(fmt(b)) ± \(fmt(tol))")
    }

    func finish() -> Int32 {
        print("\n\(passed) checks passed, \(failures.count) failed")
        return failures.isEmpty ? 0 : 1
    }
}

func fmt(_ x: Double, _ d: Int = 4) -> String { String(format: "%.\(d)f", x) }
