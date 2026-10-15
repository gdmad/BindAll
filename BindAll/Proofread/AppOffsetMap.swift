import Foundation

/// Translates offsets between a field's value and the app's own text, for apps whose two disagree.
/// Slack's value has a newline after every list item, soft line break and emoji, but its own string
/// -- the one `AXStringForRange`, `AXBoundsForRange` and the selection are indexed by -- drops those,
/// while keeping the ones between paragraphs, quotes and code blocks. The two are lined up
/// character by character: the app's string must be the value with some newlines left out.
struct AppOffsetMap: Equatable {
    /// For each UTF-16 offset of the value (and one past the end), the matching offset in the app's
    /// string. A dropped newline maps to where the next kept character is.
    private let toApp: [Int]

    /// Nil when `app` is not `value` minus some newlines -- the caller then keeps its old behavior.
    init?(value: String, app: String) {
        let v = Array((value as NSString).utf16Array)
        let a = Array((app as NSString).utf16Array)
        var map: [Int] = []
        map.reserveCapacity(v.count + 1)
        var j = 0
        for unit in v {
            map.append(j)
            if j < a.count, a[j] == unit {
                j += 1
            } else if unit != 0x0A {
                return nil
            }
        }
        guard j == a.count else { return nil }
        map.append(j)
        toApp = map
    }

    /// True when the two texts are the same, so no translation is needed.
    var isIdentity: Bool { toApp.enumerated().allSatisfy { $0.offset == $0.element } }

    func appRange(_ range: NSRange) -> NSRange? {
        guard range.location >= 0, NSMaxRange(range) < toApp.count else { return nil }
        let start = toApp[range.location]
        return NSRange(location: start, length: toApp[NSMaxRange(range)] - start)
    }

    /// The value offset of an app offset: the first value offset that maps onto it.
    func valueOffset(_ appOffset: Int) -> Int {
        var low = 0, high = toApp.count - 1
        while low < high {
            let mid = (low + high) / 2
            if toApp[mid] < appOffset { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

private extension NSString {
    var utf16Array: [unichar] { (0..<length).map { character(at: $0) } }
}
