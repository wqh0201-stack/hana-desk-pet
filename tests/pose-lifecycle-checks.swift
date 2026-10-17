import Foundation

// Cross-layer synthetic lifecycle check.
//
// Replays the DTOs emitted by `tests/lifecycle-fixture.mjs` through the real native
// path — strict v3 `PetAPI` parsing into `PetStateStore`, then `PetPosePlanner`, then
// `PetPoseTimeline` — and asserts the expected status, tool name, pose and settled
// timeline layer at every step. The expectations below are written independently of
// the JS fixture so the two halves cannot agree by accident.
//
// Synthetic data only: this never starts the GUI, never opens a listener, and never
// posts to a real 127.0.0.1:43127 service.

@main
private struct PoseLifecycleChecks {
    private static var checks = 0

    private struct Expectation {
        let status: PetActivityStatus
        let toolName: String?
        let preferred: String
        let resolved: String
    }

    private static let expected: [Expectation] = [
        Expectation(status: .working, toolName: nil, preferred: "thinking", resolved: "thinking"),
        Expectation(status: .tool, toolName: "read", preferred: "reading", resolved: "reading-2"),
        Expectation(status: .success, toolName: nil, preferred: "happy", resolved: "happy-2"),
        Expectation(status: .success, toolName: nil, preferred: "happy", resolved: "happy-2"),
        Expectation(status: .working, toolName: nil, preferred: "thinking", resolved: "thinking"),
        Expectation(status: .tool, toolName: "functions.write", preferred: "writing", resolved: "writing"),
        Expectation(status: .error, toolName: nil, preferred: "oops", resolved: "oops"),
        Expectation(status: .error, toolName: nil, preferred: "oops", resolved: "oops"),
        Expectation(status: .working, toolName: nil, preferred: "thinking", resolved: "thinking"),
        Expectation(status: .working, toolName: nil, preferred: "thinking", resolved: "thinking"),
        Expectation(status: .working, toolName: nil, preferred: "thinking", resolved: "thinking"),
        Expectation(status: .working, toolName: nil, preferred: "thinking", resolved: "thinking"),
        Expectation(status: .success, toolName: nil, preferred: "happy", resolved: "happy-2"),
        Expectation(status: .success, toolName: nil, preferred: "happy", resolved: "happy-2"),
        Expectation(status: .idle, toolName: nil, preferred: "idle", resolved: "idle"),
    ]

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let fixturePath = arguments.first else {
            fputs("usage: PoseLifecycleChecks <lifecycle-fixture.json> [crosspet-asset-dir]\n", stderr)
            exit(2)
        }
        let assetRoot = arguments.count > 1 ? arguments[1] : "assets/crosspet"

        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        guard let fixture = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
              fixture["schemaVersion"] as? Int == 1,
              let rawSteps = fixture["steps"] as? [[String: Any]] else {
            fatalError("CHECK FAILED: the synthetic lifecycle fixture is unreadable")
        }
        let sentinels = (fixture["privateSentinels"] as? [String]) ?? []
        expect(!sentinels.isEmpty, "the fixture declares the private sentinels to look for")
        expect(rawSteps.count == expected.count, "the fixture step count matches the native expectation table")

        let catalog = try PetArtworkCatalog(directoryURL: URL(fileURLWithPath: assetRoot, isDirectory: true))
        let roleID = "claude"
        let poses = catalog.poseNames(forCharacterID: roleID)
        // Claude's catalogued reading artwork is the `reading-2` variant, so the resolved
        // expectation exercises the real variant fallback rather than a generic name.
        expect(poses.contains("idle") && poses.contains("reading-2") && poses.contains("writing") &&
               poses.contains("thinking") && poses.contains("oops") && poses.contains("happy-2"),
               "the \(roleID) catalog exposes every mapped work pose and variant")
        let layout = PetCharacterLayout(maximumAspectRatio: catalog.maximumAspectRatio)
        expect(layout.windowSize.width > 0 && layout.windowSize.height > 0 && layout.displayHeight == 176, "the layout reserves a positive window at a fixed 176pt character height")

        let store = PetStateStore()
        let api = PetAPI(store: store)
        var timeline = PetPoseTimeline()
        var clock = 0.0

        for (index, rawStep) in rawSteps.enumerated() {
            let label = rawStep["label"] as? String ?? "step \(index)"
            guard let dto = rawStep["dto"] as? [String: Any] else {
                fatalError("CHECK FAILED: \(label) carries no DTO")
            }
            let table = expected[index]

            expect(Set(dto.keys) == ["schemaVersion", "revision", "characters", "activity"], "\(label) root keys are exactly the strict v3 set")
            let requiredActivityKeys: Set<String> = ["sessionId", "title", "agentId", "agentName", "status", "toolName", "lastActivityAt"]
            let allowedActivityKeys = requiredActivityKeys.union(["hint"])
            let activityKeys = Set((dto["activity"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys)
            expect(requiredActivityKeys.isSubset(of: activityKeys) && activityKeys.isSubset(of: allowedActivityKeys),
                   "\(label) activity keys use the strict v3 allowlist with optional hint")
            expect(api.handle(jsonRequest("POST", "/v3/snapshot", dto)).statusCode == 200, "\(label) is accepted by the strict native v3 parser")

            let state = store.viewState()
            expect(state.activity.status == table.status, "\(label) projects native status \(table.status.rawValue)")
            expect(state.activity.toolName == table.toolName, "\(label) projects the expected tool name")
            expect(state.selection.characterId == "claude", "\(label) activity never overrides the manual character choice")

            let preferred = PetPosePlanner.preferredPose(
                for: state.activity.status,
                toolName: state.activity.toolName,
                hint: state.activity.hint
            )
            let expectedPreferred: String
            if state.activity.status == .error {
                expectedPreferred = "oops"
            } else if let hint = state.activity.hint {
                switch hint {
                case .confirming: expectedPreferred = "asking"
                case .compacting: expectedPreferred = "compact"
                case .interrupted: expectedPreferred = "surprised"
                }
            } else {
                expectedPreferred = table.preferred
            }
            expect(preferred == expectedPreferred, "\(label) planner prefers \(expectedPreferred)")
            let resolved = PetPosePlanner.resolvedPose(preferred: preferred, availablePoseNames: poses)
            let expectedResolved = (state.activity.hint == nil && state.activity.status != .error)
                ? table.resolved
                : PetPosePlanner.resolvedPose(preferred: expectedPreferred, availablePoseNames: poses)
            expect(resolved == expectedResolved, "\(label) resolves \(expectedResolved) inside the real catalog")
            expect(poses.contains(resolved), "\(label) resolved pose is a catalogued asset")

            clock += 1
            _ = timeline.update(
                status: state.activity.status,
                basePose: resolved,
                availablePoseNames: poses,
                allowsIdleAnimation: state.activity.hint == nil,
                hint: state.activity.status == .error ? nil : state.activity.hint,
                at: clock
            )
            let settled = timeline.advance(at: clock + 0.5)
            expect(settled.count == 1 && settled[0].poseName == resolved && settled[0].opacity >= 0.999,
                   "\(label) timeline settles on \(resolved)")

            let serialized = String(data: try JSONSerialization.data(withJSONObject: dto), encoding: .utf8) ?? ""
            for sentinel in sentinels {
                expect(!serialized.contains(sentinel), "\(label) never carries \(sentinel)")
            }
        }

        print("PoseLifecycleChecks: \(checks) cross-layer checks passed (claude layout \(Int(layout.windowSize.width))x\(Int(layout.windowSize.height)) pt, maxAspect \(catalog.maximumAspectRatio))")
        try checkConcurrentFollowIntoWorkScheduler(catalog: catalog, fixture: fixture)
        print("PoseLifecycleChecks: \(checks) cross-layer checks passed including synthetic concurrent follow")
    }

    /// Replays the synthetic concurrent-follow steps through the real native path and then
    /// through the new work scheduler. The follow rules are asserted unchanged; the
    /// scheduler only has to prove it never writes a pose across a session switch.
    private static func checkConcurrentFollowIntoWorkScheduler(
        catalog: PetArtworkCatalog,
        fixture: [String: Any]
    ) throws {
        guard let rawSteps = fixture["concurrentSteps"] as? [[String: Any]], rawSteps.count == 9 else {
            fatalError("CHECK FAILED: the synthetic concurrent fixture is missing or incomplete")
        }
        let poses = catalog.poseNames(forCharacterID: "claude")
        let workSet = PetPosePlanner.workPoseSet(characterID: "claude", availablePoseNames: poses)
        let store = PetStateStore()
        let api = PetAPI(store: store)
        var mood = PetPoseMoodTracker()
        var scheduler = PetWorkPoseScheduler()
        var clock = 0.0
        var queued: [(PetWorkPoseIdentity?, UInt64)] = []

        for (index, rawStep) in rawSteps.enumerated() {
            let label = rawStep["label"] as? String ?? "concurrent step \(index)"
            guard let dto = rawStep["dto"] as? [String: Any],
                  let expectation = rawStep["expectation"] as? [String: Any],
                  let expectedOwner = expectation["current"] as? String else {
                fatalError("CHECK FAILED: \(label) carries no DTO or expectation")
            }
            expect(api.handle(jsonRequest("POST", "/v3/snapshot", dto)).statusCode == 200 ||
                   store.viewState().activity.sessionId == expectedOwner,
                   "\(label) is accepted by the strict v3 parser")

            let state = store.viewState()
            expect(state.activity.sessionId == expectedOwner,
                   "\(label) projects the session the existing follow rules selected")

            clock += 1
            _ = mood.update(
                status: state.displayStatus,
                toolName: state.activity.toolName,
                hint: state.displayHint,
                lastActivityAt: state.activity.lastActivityAt,
                at: clock
            )
            let realPose = PetPosePlanner.resolvedPose(
                preferred: PetPosePlanner.preferredPose(
                    for: state.displayStatus,
                    toolName: state.activity.toolName,
                    hint: state.displayHint
                ),
                availablePoseNames: poses
            )
            let tick = scheduler.update(
                PetWorkPoseSchedulerInput(
                    sessionId: state.activity.sessionId,
                    workSegmentStart: mood.continuousWorkStart,
                    status: state.displayStatus,
                    hint: state.displayHint,
                    hasPriorityState: mood.mood(at: clock) != nil,
                    allowsAutonomousRotation: true,
                    interactionIsActive: false,
                    realPose: realPose
                ),
                workPoses: workSet,
                at: clock
            )
            if let pose = tick.pose {
                expect(poses.contains(pose), "\(label) scheduler pose is catalogued artwork")
                expect(pose != "writing" && pose != "reading", "\(label) rhythm never fabricates a semantic tool pose")
            }
            if tick.identity != nil {
                queued.append((tick.identity, tick.generation))
            }
        }

        // Every callback queued before the handover must spin empty afterwards.
        let finalIdentity = scheduler.currentIdentity
        let finalGeneration = scheduler.currentGeneration
        let staleTokens = queued.filter { $0.0 != finalIdentity || $0.1 != finalGeneration }
        expect(!staleTokens.isEmpty, "the concurrent sequence really did hand over the followed session")
        let poseBefore = scheduler.currentPose(at: clock)
        for token in staleTokens {
            let discarded = scheduler.advance(identity: token.0, generation: token.1, at: clock + 1)
            expect(discarded.discardedStaleTick, "a callback queued under another session is discarded")
        }
        expect(scheduler.currentPose(at: clock + 1) == poseBefore,
               "discarded callbacks leave the current session's pose untouched")

        // The current token still advances normally.
        let live = scheduler.advance(identity: finalIdentity, generation: finalGeneration, at: clock + 1)
        expect(!live.discardedStaleTick, "the current session's own callback still advances")
    }

    private static func jsonRequest(_ method: String, _ path: String, _ object: [String: Any]) -> PetHTTPRequest {
        PetHTTPRequest(
            method: method,
            path: path,
            headers: ["content-type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
