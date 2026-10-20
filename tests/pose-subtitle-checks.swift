import Foundation

/// Pure-logic checks for the status subtitle layer: pose→state normalisation, the minimum
/// dwell merge, self-retiring vs persistent states, deterministic non-repeating line
/// choice, and the notice / pick-up / switch priorities.
@main
struct PetSubtitleChecks {
    private static var checkCount = 0

    static func main() throws {
        let catalog = try loadCatalog()
        try testCatalogCoversEveryCatalogPose(catalog)
        testStateNormalisation(catalog)
        testDeterministicChoiceAndNoImmediateRepeat(catalog)
        testMinimumDwellQueuesAndMerges(catalog)
        testPersistentStateStaysAndRetiredDoesNotReturn(catalog)
        testTransientStateRetiresOnTime(catalog)
        testNoticePreemptsSubtitleAtOnce(catalog)
        testPickUpPreemptsEverything(catalog)
        testDisabledSwitchHidesWithoutTouchingState(catalog)
        testRoleSwitchNeverCrossesCharacters(catalog)
        testBubbleThemeAccents()
        testTiersIncludeTail(catalog)
        print("PetSubtitleChecks: \(checkCount) checks passed.")
    }

    // MARK: - Fixtures

    private static func loadCatalog() throws -> PetSubtitleCatalog {
        try makeCatalog()
    }

    private static func makeCatalog() throws -> PetSubtitleCatalog {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try PetSubtitleCatalog(directoryURL: root.appendingPathComponent("assets/crosspet"))
    }

    // MARK: - Checks

    /// The normalisation table must be exhaustive: every pose in the bundled catalog
    /// resolves to a state that has two lines, and no numbered variant loses its line.
    private static func testCatalogCoversEveryCatalogPose(_ catalog: PetSubtitleCatalog) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("assets/crosspet/catalog.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let characters = json?["characters"] as? [[String: Any]] ?? []
        expect(!characters.isEmpty, "the bundled catalog lists characters")

        var seen = Set<String>()
        for character in characters {
            let roleId = character["id"] as? String ?? ""
            for file in character["poseFiles"] as? [String] ?? [] {
                let pose = String(file.dropLast(".webp".count))
                seen.insert(pose)
                guard let state = catalog.stateKey(forPose: pose) else {
                    fatalError("CHECK FAILED: pose \(pose) has no logical state")
                }
                expect(catalog.stateOrder.contains(state), "\(pose) maps to a known state key")
                expect(catalog.hasLines(roleId: roleId, state: state), "\(roleId)/\(pose) -> \(state) has lines")
            }
        }
        expect(seen.count >= 30, "the catalog's distinct pose names were enumerated")
        // The explicit variant cases named by the task must all land on their base state.
        for (pose, state) in [
            ("thinking-2", "thinking"), ("idle-2", "idle"), ("idle-3", "idle"),
            ("idle-blink", "idle"), ("busy_left", "busy"), ("busy_right", "busy"),
            ("swamped_left", "swamped"), ("swamped_right", "swamped"), ("sleeping-2", "sleeping"),
            ("happy-2", "happy"), ("reading-2", "reading"), ("deepthink", "thinking"),
            ("picked-up-2", "picked-up"), ("sorry", "oops"), ("listening", "asking"),
            ("surprised", "interrupted"),
        ] {
            expect(catalog.stateKey(forPose: pose) == state, "\(pose) normalises to \(state)")
        }
        // An unknown pose must not invent a line: it falls back to idle's wording, and a
        // catalog with no idle would report nil instead of guessing.
        expect(catalog.stateKey(forPose: "no-such-pose") == "idle", "an unknown pose falls back to idle")
        expect(catalog.stateKey(forPose: "") == "idle", "an empty pose name falls back to idle")
        print("PASS every catalog pose normalises to a state that has lines")
    }

    private static func testStateNormalisation(_ catalog: PetSubtitleCatalog) {
        let fallbackStates = Set(catalog.poseStates.values)
        expect(!fallbackStates.contains("notice"), "no artwork pose maps to the notice pseudo-state")
        expect(catalog.dwellSeconds(forState: "pat") == 4,
               "an unreachable state keeps its reviewed dwell entry")
        expect(catalog.unreachableStates == ["pat"],
               "only `pat` has no reachable pose, and that is recorded rather than silently dropped")
        print("PASS state table is complete and records the unreachable state")
    }

    /// Two candidates per state, so "never the same sentence twice in a row" is provable:
    /// whichever seed is used, entry N and N+1 must differ.
    private static func testDeterministicChoiceAndNoImmediateRepeat(_ catalog: PetSubtitleCatalog) {
        for seed in UInt64(1)...32 {
            var selector = PetSubtitleSelector(catalog: catalog, seed: seed)
            var previous: String?
            var time = 0.0
            for round in 0..<12 {
                // Alternate away and back so the state is genuinely re-entered each time.
                _ = selector.update(pose: "oops", roleId: "gpt", notice: nil, isPickUp: false, enabled: true, at: time)
                let first = selector.currentContent?.status
                time += 3
                _ = selector.update(pose: "idle", roleId: "gpt", notice: nil, isPickUp: false, enabled: true, at: time)
                time += 3
                guard let first else { fatalError("CHECK FAILED: re-entering a state produced a line") }
                if let previous { expect(previous != first, "seed \(seed) round \(round) never repeats the previous line") }
                previous = first
            }
        }
        // Same seed, same inputs, same words: the clock-independent choice is reproducible.
        var left = PetSubtitleSelector(catalog: catalog, seed: 7)
        var right = PetSubtitleSelector(catalog: catalog, seed: 7)
        for step in 0..<6 {
            let a = left.update(pose: "thinking", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: Double(step) * 4)
            let b = right.update(pose: "thinking", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: Double(step) * 4)
            expect(a.content == b.content, "identical seeds and inputs produce identical words")
        }
        // A different seed must actually reach a different choice at some point.
        var picks = Set<String>()
        for seed in UInt64(1)...16 {
            var selector = PetSubtitleSelector(catalog: catalog, seed: seed)
            if let line = selector.update(pose: "happy", roleId: "glm", notice: nil, isPickUp: false, enabled: true, at: 0).content?.status {
                picks.insert(line)
            }
        }
        expect(picks.count == 2, "both candidate lines of a two-candidate state are reachable from some seed")
        print("PASS deterministic seeded choice with no immediate repeat")
    }

    /// A state arriving inside the previous subtitle's 2.5 s window is queued, and only the
    /// last arrival survives.
    private static func testMinimumDwellQueuesAndMerges(_ catalog: PetSubtitleCatalog) {
        var selector = PetSubtitleSelector(catalog: catalog, seed: 3)
        let first = selector.update(pose: "idle", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 0)
        let shown = expectValue(first.content, "the first subtitle shows at once")
        expect(selector.minDwellSeconds == 2.5, "the reviewed minimum dwell is 2.5 s")
        expect(first.nextDeadline == 6, "a self-retiring state schedules its own deadline")

        // 1.0 s in: still inside the dwell, so the newcomer waits.
        let queued = selector.update(pose: "searching", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 1.0)
        expect(queued.content == shown, "a new state inside the 2.5 s window does not cut the current line")
        expect(queued.changed == false, "the queued line reports no visible change yet")
        expect(queued.nextDeadline == 2.5, "the queued line becomes visible at the dwell boundary")

        // Two more arrivals inside the same window: only the last one may win.
        _ = selector.update(pose: "writing", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 1.4)
        let merged = selector.update(pose: "running", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 1.8)
        expect(merged.content == shown, "queued arrivals keep merging without showing")
        let flushed = selector.update(pose: "running", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 2.5)
        let runningLine = expectValue(flushed.content, "the merged line shows at the dwell boundary")
        expect(flushed.changed, "the flushed line is reported as a visible change")
        expect(!(catalog.lines(roleId: "claude", state: "writing").contains(runningLine.status)),
               "the dropped intermediate state never shows")
        expect(catalog.lines(roleId: "claude", state: "running").contains(runningLine.status),
               "only the last queued state is shown")
        expect(flushed.nextDeadline == nil, "a persistent state schedules no retire deadline")
        print("PASS minimum dwell queues and merges into the last state")
    }

    private static func testPersistentStateStaysAndRetiredDoesNotReturn(_ catalog: PetSubtitleCatalog) {
        var selector = PetSubtitleSelector(catalog: catalog, seed: 11)
        let shown = selector.update(pose: "thinking", roleId: "deepseek", notice: nil, isPickUp: false, enabled: true, at: 0)
        let line = expectValue(shown.content, "a persistent state shows a line")
        expect(shown.nextDeadline == nil, "`thinking` has a null dwell entry, so nothing is scheduled")
        // Ten minutes later, unchanged pose: still the same words, no timer.
        let later = selector.update(pose: "thinking", roleId: "deepseek", notice: nil, isPickUp: false, enabled: true, at: 600)
        expect(later.content == line, "a persistent state stays on screen")
        expect(later.nextDeadline == nil, "a persistent state never schedules a retire")

        // A variant pose inside the same state keeps the same words (no flicker).
        let variant = selector.update(pose: "thinking-2", roleId: "deepseek", notice: nil, isPickUp: false, enabled: true, at: 601)
        expect(variant.content == line, "`thinking-2` keeps the `thinking` line instead of re-drawing")

        // A self-retiring state, once retired, must not pop back while its pose stays.
        var retiring = PetSubtitleSelector(catalog: catalog, seed: 5)
        let happy = retiring.update(pose: "happy", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 0)
        expect(happy.nextDeadline == 5, "`happy` retires after the reviewed five seconds")
        let expired = retiring.update(pose: "happy", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 5.1)
        expect(expired.content == nil && expired.changed, "a transient state clears the bubble at its deadline")
        let staysEmpty = retiring.update(pose: "happy-2", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 9)
        expect(staysEmpty.content == nil, "the same state does not reappear while its pose persists")
        // Leaving and coming back is a real re-entry and speaks again.
        _ = retiring.update(pose: "idle", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 10)
        let returned = retiring.update(pose: "happy", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 12)
        expect(returned.content != nil, "re-entering the state after another state speaks again")
        print("PASS persistent states stay, transient states retire and never pop back")
    }

    private static func testTransientStateRetiresOnTime(_ catalog: PetSubtitleCatalog) {
        for (pose, state) in [("happy", "happy"), ("proud", "proud"), ("oops", "oops"), ("idle", "idle"),
                              ("drawing", "drawing"), ("surprised", "interrupted")] {
            guard let dwell = catalog.dwellSeconds(forState: state) else {
                fatalError("CHECK FAILED: \(state) should have a reviewed dwell")
            }
            var selector = PetSubtitleSelector(catalog: catalog, seed: 9)
            let start = selector.update(pose: pose, roleId: "gemini", notice: nil, isPickUp: false, enabled: true, at: 1)
            expect(start.content != nil, "\(state) shows at once")
            expect(start.nextDeadline == 1 + dwell, "\(state) retires exactly \(dwell) s after it appeared")
            let stillThere = selector.update(pose: pose, roleId: "gemini", notice: nil, isPickUp: false, enabled: true, at: 1 + dwell - 0.01)
            expect(stillThere.content != nil, "\(state) is still visible just before its deadline")
            let gone = selector.update(pose: pose, roleId: "gemini", notice: nil, isPickUp: false, enabled: true, at: 1 + dwell)
            expect(gone.content == nil, "\(state) clears at its deadline")
        }
        for state in ["thinking", "reading", "writing", "searching", "running", "delegating",
                      "busy", "asking", "compact", "tired", "sleeping", "swamped", "picked-up"] {
            expect(catalog.dwellSeconds(forState: state) == nil, "\(state) is a persistent (null dwell) state")
        }
        print("PASS transient states retire exactly on time and null states persist")
    }

    private static func testNoticePreemptsSubtitleAtOnce(_ catalog: PetSubtitleCatalog) {
        let confirmation = PetNoticePresentation(
            id: "confirmation:abcd:1", kind: .confirmation, title: "合成会话", status: "需要你确认",
            startedAt: 0, endsAt: 300
        )
        var selector = PetSubtitleSelector(catalog: catalog, seed: 2)
        let subtitle = selector.update(pose: "idle", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 0)
        expect(subtitle.content?.style == .subtitle, "a subtitle is showing before the notice")
        // 0.2 s later — well inside the 2.5 s dwell — the confirmation must still appear at once.
        let notice = selector.update(pose: "idle", roleId: "claude", notice: confirmation, isPickUp: false, enabled: true, at: 0.2)
        expect(notice.changed, "the confirmation is an immediate visible change")
        expect(notice.content?.style == .notice, "a notice takes the bubble over as a notice")
        expect(notice.content?.title == "合成会话" && notice.content?.status == "需要你确认",
               "the two-line notice format is unchanged")
        expect(notice.nextDeadline == 300, "the notice keeps its own 300 s safety deadline")
        let same = selector.update(pose: "idle", roleId: "claude", notice: confirmation, isPickUp: false, enabled: true, at: 1)
        expect(same.content == notice.content && !same.changed, "the same confirmation is not re-announced")

        let completion = PetNoticePresentation(
            id: "completion:abcd:2", kind: .completion, title: "合成会话", status: "本轮完成了！",
            startedAt: 2, endsAt: 8
        )
        let completed = selector.update(pose: "idle", roleId: "claude", notice: completion, isPickUp: false, enabled: true, at: 2)
        expect(completed.content?.style == .notice && completed.content?.status == "本轮完成了！",
               "a completion also uses the unchanged two-line format")
        expect(completed.nextDeadline == 8, "the completion keeps its own six-second deadline")
        // After the notice ends, the pose's own line returns.
        let after = selector.update(pose: "idle", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 8.1)
        expect(after.content?.style == .subtitle, "the subtitle returns once the notice ends")
        // A notice that must not show (bubbleVisible == false) never takes the surface.
        let hidden = PetNoticePresentation(
            id: "completion:ffff:3", kind: .completion, title: "隐藏", status: "本轮完成了！",
            startedAt: 0, endsAt: 6, bubbleVisible: false
        )
        var hiddenSelector = PetSubtitleSelector(catalog: catalog, seed: 4)
        _ = hiddenSelector.update(pose: "idle", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 0)
        let hiddenResult = hiddenSelector.update(pose: "idle", roleId: "claude", notice: hidden, isPickUp: false, enabled: true, at: 1)
        expect(hiddenResult.content?.style == .subtitle, "an invisible notice does not replace the subtitle")
        print("PASS notices preempt subtitles at once and keep their own deadlines")
    }

    private static func testPickUpPreemptsEverything(_ catalog: PetSubtitleCatalog) {
        let confirmation = PetNoticePresentation(
            id: "confirmation:1234:1", kind: .confirmation, title: "拎起", status: "需要你确认",
            startedAt: 0, endsAt: 300
        )
        var selector = PetSubtitleSelector(catalog: catalog, seed: 6)
        _ = selector.update(pose: "idle", roleId: "deepseek", notice: confirmation, isPickUp: false, enabled: true, at: 0)
        let picked = selector.update(pose: "picked-up", roleId: "deepseek", notice: confirmation, isPickUp: true, enabled: true, at: 0.1)
        expect(picked.content?.style == .subtitle, "the pick-up line replaces even a confirmation")
        expect(picked.changed, "the pick-up line is an immediate change")
        expect(catalog.lines(roleId: "deepseek", state: "picked-up").contains(picked.content?.status ?? ""),
               "the pick-up line comes from the picked-up group")
        // The pick-up line is not delayed by dwell: a second pick-up pose is the same state.
        let second = selector.update(pose: "picked-up-2", roleId: "deepseek", notice: confirmation, isPickUp: true, enabled: true, at: 0.2)
        expect(second.content == picked.content, "switching pick-up frames keeps one line")
        // Released: the notice comes straight back.
        let released = selector.update(pose: "asking", roleId: "deepseek", notice: confirmation, isPickUp: false, enabled: true, at: 0.3)
        expect(released.content?.style == .notice, "releasing the character restores the confirmation")
        // Picked up again after release is a fresh entry and may pick another line.
        let again = selector.update(pose: "picked-up", roleId: "deepseek", notice: confirmation, isPickUp: true, enabled: true, at: 5)
        expect(again.content?.style == .subtitle, "picking up again shows the pick-up line")
        print("PASS the pick-up line outranks a confirmation and is not dwell-delayed")
    }

    private static func testDisabledSwitchHidesWithoutTouchingState(_ catalog: PetSubtitleCatalog) {
        var selector = PetSubtitleSelector(catalog: catalog, seed: 8)
        let visible = selector.update(pose: "thinking", roleId: "glm", notice: nil, isPickUp: false, enabled: true, at: 0)
        expect(visible.content != nil, "the subtitle shows while the switch is on")
        let off = selector.update(pose: "thinking", roleId: "glm", notice: nil, isPickUp: false, enabled: false, at: 1)
        expect(off.content == nil && off.changed, "turning the switch off hides the bubble")
        expect(off.nextDeadline == nil, "a hidden bubble schedules no wake")
        // While off, states still pass through the selector; nothing may pop when re-enabled.
        let stillOff = selector.update(pose: "happy", roleId: "glm", notice: nil, isPickUp: false, enabled: false, at: 2)
        expect(stillOff.content == nil, "no line appears while the switch is off")
        let backOn = selector.update(pose: "happy", roleId: "glm", notice: nil, isPickUp: false, enabled: true, at: 3)
        expect(backOn.content != nil, "the current state speaks again after re-enabling")
        // The pose is never part of this layer's inputs: the selector returns words only.
        expect(backOn.content?.style == .subtitle, "re-enabling resumes subtitles, not a replay of a stale notice")
        print("PASS the single switch hides every bubble without touching the activity state")
    }

    private static func testRoleSwitchNeverCrossesCharacters(_ catalog: PetSubtitleCatalog) {
        for role in catalog.roles {
            for state in catalog.stateOrder {
                let lines = catalog.lines(roleId: role, state: state)
                expect(lines.count >= 1, "\(role)/\(state) has at least one line")
                expect(lines.count <= 2, "\(role)/\(state) has at most two candidates here")
                expect(Set(lines).count == lines.count, "\(role)/\(state) has no duplicate candidate")
                expect(lines.allSatisfy { $0.count <= PetSubtitleCatalog.maximumLineCharacters },
                       "\(role)/\(state) lines fit the bounded length")
            }
        }
        var selector = PetSubtitleSelector(catalog: catalog, seed: 1)
        let claude = selector.update(pose: "idle", roleId: "claude", notice: nil, isPickUp: false, enabled: true, at: 0)
        let gpt = selector.update(pose: "idle", roleId: "gpt", notice: nil, isPickUp: false, enabled: true, at: 1)
        expect(catalog.lines(roleId: "claude", state: "idle").contains(claude.content?.status ?? ""),
               "the line belongs to the selected character")
        expect(catalog.lines(roleId: "gpt", state: "idle").contains(gpt.content?.status ?? ""),
               "switching characters re-draws from the new character's own table")
        expect(claude.content?.status != gpt.content?.status, "two characters do not share one line here")
        print("PASS every role/state pair has bounded lines and never borrows another character's")
    }

    private static func testBubbleThemeAccents() {
        let expected: [String: String] = [
            "claude": "#e8a33d",
            "gpt": "#7a8fa8",
            "deepseek": "#3b5bb5",
            "gemini": "#7b5cd6",
            "glm": "#4b5a8a",
            "deepseek-hoodie": "#e0b48a",
            "gpt-onesie": "#e0b48a",
        ]
        for (role, hex) in expected {
            expect(PetBubbleTheme.accent(forRoleId: role).hex == hex, "\(role) uses the reviewed accent \(hex)")
        }
        expect(PetBubbleTheme.accent(forRoleId: "unknown-role").hex == "#e0b48a",
               "an unknown role id falls back to the neutral accent")
        expect(Set(expected.keys) == Set(PetBubbleTheme.knownRoleIds),
               "the theme table covers exactly the seven built-in roles")
        print("PASS seven role accents plus the unknown-id fallback")
    }

    private static func testTiersIncludeTail(_ catalog: PetSubtitleCatalog) {
        _ = catalog
        // Measured against the real fonts and the real view after the halo/hairline change.
        expect(PetBubbleLayout.subtitleHeight(oneLine: true) == 64, "the one-line tier is 64 pt tall")
        expect(PetBubbleLayout.subtitleHeight(oneLine: false) == 82, "the two-line subtitle tier is 82 pt tall")
        expect(PetBubbleLayout.noticeHeight() == 78, "the notice tier is 78 pt tall")
        for width in [PetBubbleLayout.minWidth, 140.0, PetBubbleLayout.maxWidth] {
            for height in [PetBubbleLayout.subtitleHeight(oneLine: true),
                           PetBubbleLayout.subtitleHeight(oneLine: false),
                           PetBubbleLayout.noticeHeight()] {
                let body = PetBubbleLayout.bodyRect(width: width, height: height)
                let outer = PetBubbleLayout.tailOuterRect(width: width, height: height)
                expect(body.x >= PetBubbleLayout.glowInset, "the body starts after the halo margin")
                expect(body.x + body.width <= width - PetBubbleLayout.glowInset + 1e-9,
                       "the body ends before the halo margin")
                expect(outer.x >= 0 && outer.y >= 0, "the tail stays inside the left/top edge")
                expect(outer.x + outer.width <= width + 1e-9, "the tail stays inside the right edge")
                expect(outer.y + outer.height <= height + 1e-9, "the tail stays inside the bottom edge")
                expect(outer.y >= body.y + body.height, "the tail hangs below the body, not over the text")
                expect(abs(outer.x + outer.width / 2 - (body.x + body.width / 2)) < 1e-9,
                       "the tail is centred on the body")
                expect(abs((outer.y + outer.height) - height) <= 1,
                       "the window bottom is essentially the tail's outer tip")
            }
        }
        print("PASS all three tiers include the halo margin and the tail, and neither leaves the window")
    }

    // MARK: - Helpers

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checkCount += 1
        guard condition() else { fatalError("CHECK FAILED: \(message)") }
    }

    private static func expectValue<T>(_ value: T?, _ message: String) -> T {
        guard let value else { fatalError("CHECK FAILED: \(message)") }
        return value
    }
}
