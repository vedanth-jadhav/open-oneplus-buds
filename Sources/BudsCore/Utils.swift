import Foundation

extension Duration {
    var timeInterval: TimeInterval {
        switch self.components {
        case let (seconds, attoseconds):
            return TimeInterval(seconds) + TimeInterval(attoseconds) / 1_000_000_000_000_000_000
        }
    }
}

extension Array {
    subscript(safe idx: Int) -> Element? {
        guard idx >= 0 && idx < count else { return nil }
        return self[idx]
    }
}

