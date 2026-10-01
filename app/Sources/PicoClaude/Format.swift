import Foundation
import SwiftUI

/// Same wording as the Pico firmware (device/cc/fmt.py), so both views agree.
enum Format {
    static func tokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        for (limit, div, suffix) in [(1_000_000, 1000.0, "k"), (1_000_000_000, 1_000_000.0, "M"),
                                     (Int.max, 1_000_000_000.0, "B")] where n < limit {
            let v = Double(n) / div
            if v < 9.95 { return String(format: "%.1f%@", v, suffix) }
            if v < 999.5 { return "\(Int(v + 0.5))\(suffix)" }
        }
        return "\(n)"
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "<1m" }
        let m = seconds / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return String(format: "%dh %02dm", h, m % 60) }
        return "\(h / 24)d \(h % 24)h"
    }
}

enum Palette {
    static let background = Color(red: 20 / 255, green: 19 / 255, blue: 17 / 255)
    static let track = Color(red: 48 / 255, green: 45 / 255, blue: 40 / 255)
    static let rule = Color(red: 60 / 255, green: 57 / 255, blue: 52 / 255)
    static let text = Color(red: 240 / 255, green: 238 / 255, blue: 230 / 255)
    static let dim = Color(red: 150 / 255, green: 145 / 255, blue: 135 / 255)
    static let orange = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let amber = Color(red: 235 / 255, green: 175 / 255, blue: 60 / 255)
    static let red = Color(red: 226 / 255, green: 78 / 255, blue: 66 / 255)

    /// Orange below 70%, amber to 90%, red beyond - as on the Pico.
    static func level(_ pct: Double?) -> Color {
        guard let pct, pct >= 70 else { return orange }
        return pct < 90 ? amber : red
    }
}
