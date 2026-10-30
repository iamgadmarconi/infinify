import CoreGraphics

/// Magnetic polarity, experimental (Settings › Windows › "Magnetic polarity"): every window is + or −.
/// Like poles repel, which is the push `Magnetism` always did; opposite poles attract — the one in hand
/// pulls the other in — and on contact they bond into a group that moves as one (`Grouping`,
/// `Magnetism.Body`). Widgets have no pole: they're pushed and push as before, and never bond.
enum Polarity: String, Codable, Sendable {
    case plus, minus

    var flipped: Polarity { self == .plus ? .minus : .plus }

    /// The mark on a window's label.
    var glyph: String { self == .plus ? "⊕" : "⊖" }

    /// What two windows do to each other. Either without a pole (a widget, or polarity off): neutral,
    /// the push as it always was.
    enum Relation { case repel, attract, neutral }

    static func relation(_ a: Polarity?, _ b: Polarity?) -> Relation {
        guard let a, let b else { return .neutral }
        return a == b ? .repel : .attract
    }

    /// How near, on screen, an opposite pole has to come before the pull starts: a little further than
    /// the alignment guides' `CanvasView.snapDistance`, so the two don't compete at one radius. Divided
    /// by the zoom for the world, like the guides, so it feels the same however far out you are.
    static let attractDistance: CGFloat = 16
}

/// Which windows have bonded into groups, by window ID. A value type, so undo keeps a copy. A window in
/// no group is a group of itself. A group may be left with one member (a restore that hasn't seen the
/// second yet, a member closed) and is then inert: nothing treats it differently from a free window.
struct Grouping: Equatable {
    private var groupOf: [CGWindowID: Int] = [:]
    private var next = 0

    var isEmpty: Bool { groupOf.isEmpty }

    func group(of id: CGWindowID) -> Int? { groupOf[id] }

    /// Whether the window has a bonded partner.
    func isGrouped(_ id: CGWindowID) -> Bool { members(of: id).count > 1 }

    /// The window and everyone bonded to it, the window first and the rest in ID order; just the window
    /// when it's free. An ID never seen is free.
    func members(of id: CGWindowID) -> [CGWindowID] {
        guard let g = groupOf[id] else { return [id] }
        return [id] + groupOf.compactMap { $0.value == g && $0.key != id ? $0.key : nil }.sorted()
    }

    /// Two windows bond: their groups become one.
    mutating func merge(_ a: CGWindowID, _ b: CGWindowID) {
        guard a != b else { return }
        switch (groupOf[a], groupOf[b]) {
        case (nil, nil):
            groupOf[a] = next
            groupOf[b] = next
            next += 1
        case (let g?, nil):
            groupOf[b] = g
        case (nil, let g?):
            groupOf[a] = g
        case (let ga?, let gb?):
            guard ga != gb else { return }
            for (id, g) in groupOf where g == gb { groupOf[id] = ga }
        }
    }

    /// The window leaves its group; the others stay as they were.
    mutating func remove(_ id: CGWindowID) {
        groupOf[id] = nil
    }

    /// The window leaves its group, and the rest is re-split into the pieces that still sit together
    /// (`split`): a window flipped or dragged out of the middle doesn't leave a rigid pair with a hole
    /// in it. `rects` are the members' places (a member without one stays with the first piece).
    mutating func remove(_ id: CGWindowID, rects: [CGWindowID: CGRect], gap: CGFloat) {
        guard let g = groupOf[id] else { return }
        let rest = members(of: id).dropFirst()
        groupOf[id] = nil
        let pieces = Grouping.split(Array(rest), rects: rects, gap: gap)
        for (i, piece) in pieces.enumerated() {
            if piece.count < 2 {
                for member in piece { groupOf[member] = nil }
            } else if i > 0 {
                for member in piece { groupOf[member] = next }
                next += 1
            } else {
                for member in piece { groupOf[member] = g }
            }
        }
    }

    /// The whole group goes free.
    mutating func dissolve(groupOf id: CGWindowID) {
        guard let g = groupOf[id] else { return }
        groupOf = groupOf.filter { $0.value != g }
    }

    /// For writing down: a group number, from 0, for each of `ids` that has a partner among them.
    func saved(for ids: [CGWindowID]) -> [CGWindowID: Int] {
        var numbers: [Int: Int] = [:]
        var result: [CGWindowID: Int] = [:]
        let present = Set(ids)
        for id in ids {
            guard let g = groupOf[id], groupOf.contains(where: { $0.value == g && $0.key != id && present.contains($0.key) })
            else { continue }
            if numbers[g] == nil { numbers[g] = numbers.count }
            result[id] = numbers[g]
        }
        return result
    }

    /// Reading back: the window joins the group that stood under `saved` in the file. The first time a
    /// saved number is seen it gets a fresh group here, and `remap` remembers which, so members arriving
    /// one at a time over a restore end up together.
    mutating func adopt(saved: Int, for id: CGWindowID, remap: inout [Int: Int]) {
        let g: Int
        if let known = remap[saved] {
            g = known
        } else {
            g = next
            next += 1
            remap[saved] = g
        }
        groupOf[id] = g
    }

    /// `ids` in the pieces that sit together: each piece is connected by windows side by side, no more
    /// than `gap` apart (`Magnetism.adjacent`). Pieces come in the order their first member had in
    /// `ids`; an ID without a rect goes in the first piece.
    static func split(_ ids: [CGWindowID], rects: [CGWindowID: CGRect], gap: CGFloat) -> [[CGWindowID]] {
        var pieces: [[CGWindowID]] = []
        var seen = Set<CGWindowID>()
        var homeless: [CGWindowID] = []
        for start in ids where !seen.contains(start) {
            guard let r0 = rects[start] else {
                seen.insert(start)
                homeless.append(start)
                continue
            }
            var piece = [start]
            var queue = [r0]
            seen.insert(start)
            while let r = queue.popLast() {
                for other in ids where !seen.contains(other) {
                    guard let o = rects[other], Magnetism.adjacent(r, o, within: gap) else { continue }
                    seen.insert(other)
                    piece.append(other)
                    queue.append(o)
                }
            }
            pieces.append(piece)
        }
        if !homeless.isEmpty {
            if pieces.isEmpty { pieces = [homeless] } else { pieces[0] += homeless }
        }
        return pieces
    }
}
