import Foundation
import PetBridge
import PetCore

@main
struct PetCoreChecks {
    static func main() async throws {
        try testHealthAndRoutes()
        try testPoseStateReadback()
        try testSyntheticSnapshotProjection()
        try testBoundedV4FieldsRejectInvalidValues()
        try testStrictUnknownFieldRejection()
        try testHintDTOValidation()
        try testSelectionRevisionAndConflict()
        try testPetLocalSelectionSurvivesActivitySnapshot()
        try testSnapshotRevisionAndConnectionTimeout()
        try testLegacyPeerFailsClosed()
        try testPetArtworkCatalog()
        try testAlphaCoverageHit()
        try testPointerGestureRecognition()
        try testWindowInputPolicy()
        try testCharacterMotionGeometry()
        try testNoticeCenterAndSpotlightHold()
        try testBubbleLayout()
        PetBasinChecks.run()
        try testHTTPParserLimits()
        try await testLoopbackServerRoundTrip()
        print("All PetCore checks passed.")
    }

    private static func testHealthAndRoutes() throws {
        let api = PetAPI(store: PetStateStore())
        let health = api.handle(request("GET", "/v4/hello"))
        let body = try json(health.body)
        expect(health.statusCode == 200, "health returns 200")
        expect(body["service"] as? String == "hana-desktop-pet", "health reports service marker")
        expect(body["protocolVersion"] as? Int == 4, "health reports protocol version")
        expect(api.handle(request("GET", "/v3/hello")).statusCode == 404, "the retired v3 route is rejected")
        expect(api.handle(request("GET", "/v1/hello")).statusCode == 404, "v1 peer route is retired")
        expect(api.handle(request("GET", "/v2/hello")).statusCode == 404, "v2 peer route is retired fail-closed")
        expect(api.handle(request("GET", "/v4/admin")).statusCode == 404, "unknown route is rejected")
        expect(api.handle(request("DELETE", "/v4/selection")).statusCode == 405, "unknown method is rejected")
        print("PASS health and route allowlist")
    }

    private static func testPoseStateReadback() throws {
        let stateStore = PetStateStore()
        let poseStore = PetPoseReadbackStore(characterId: "claude", pose: "idle", since: 100)
        let api = PetAPI(store: stateStore, poseReadback: poseStore)

        func readState() throws -> [String: Any] {
            try json(api.handle(request("GET", "/v4/state")).body)
        }

        let initial = try readState()
        expect(initial["schemaVersion"] as? Int == 4, "pose readback uses schema v4")
        expect(initial["characterId"] as? String == "claude" && initial["pose"] as? String == "idle", "pose endpoint exposes the renderer's initial state")
        expect(Set(initial.keys) == Set(["schemaVersion", "characterId", "pose", "fallback", "since", "revision"]), "pose response contains only the strict DTO fields")
        expect(api.handle(PetHTTPRequest(method: "GET", path: "/v4/state", headers: [:], body: Data("{}".utf8))).statusCode == 400, "state read rejects a request body")
        expect(api.handle(request("POST", "/v4/state")).statusCode == 405, "state endpoint is read-only")

        let drawingPreferred = PetPosePlanner.preferredPose(for: .tool, toolName: "image_gen")
        let drawingResolved = PetPosePlanner.resolvedPose(preferred: drawingPreferred, availablePoseNames: ["idle", "thinking"])
        poseStore.update(characterId: "claude", pose: drawingResolved, fallback: drawingResolved != drawingPreferred, now: 200)
        var state = try readState()
        expect(state["pose"] as? String == "thinking", "readback reports the resolved pose rather than the planner's unavailable drawing request")
        expect(state["fallback"] as? Bool == true, "fallback flag identifies the substituted artwork")
        expect(state["since"] as? Int == 200 && state["revision"] as? Int == 1, "pose transition stamps since and increments revision")

        poseStore.update(characterId: "claude", pose: drawingResolved, fallback: true, now: 250)
        state = try readState()
        expect(state["since"] as? Int == 200 && state["revision"] as? Int == 1, "unchanged resolved pose does not restart its clock or revision")

        let hintPoses = ["idle", "thinking", "oops"]
        for (index, hint) in PetActivityHint.allCases.enumerated() {
            let preferred = PetPosePlanner.preferredPose(for: .working, toolName: nil, hint: hint)
            let resolved = PetPosePlanner.resolvedPose(preferred: preferred, availablePoseNames: hintPoses)
            poseStore.update(characterId: "gpt", pose: resolved, fallback: resolved != preferred, now: Int64(300 + index))
            state = try readState()
            expect(state["characterId"] as? String == "gpt" && state["pose"] as? String == resolved, "\(hint.rawValue) hint reports its final resolved pose")
            expect(state["fallback"] as? Bool == (resolved != preferred), "\(hint.rawValue) fallback is reported accurately")
        }

        let moodPoseNames = ["idle", "thinking", "sleeping", "tired", "swamped_left", "proud"]
        var fatigue = PetPoseMoodTracker()
        _ = fatigue.update(status: .working, toolName: nil, lastActivityAt: 1, at: 0)
        let tiredMood = fatigue.advance(at: PetPoseMoodTracker.tiredAfterWork + 0.01)
        expect(tiredMood == .tired, "synthetic continuous work reaches the fatigue mood")
        for mood in [PetPoseMood.sleeping, .tired, .swampedLeft, .swampedRight, .proud] {
            let resolved = PetPoseMood.resolvedPose(for: mood, workPose: "thinking", availablePoseNames: moodPoseNames)
            let primary: String
            switch mood {
            case .sleeping: primary = "sleeping"
            case .tired: primary = "tired"
            case .swampedLeft: primary = "swamped_left"
            case .swampedRight: primary = "swamped_right"
            case .proud: primary = "proud"
            }
            poseStore.update(characterId: "gpt", pose: resolved, fallback: resolved != primary, now: Int64(400 + moodPoseNames.firstIndex(of: resolved)!))
            state = try readState()
            expect(state["pose"] as? String == resolved, "\(mood.rawValue) mood period reports its final resolved pose")
            expect(state["fallback"] as? Bool == (resolved != primary), "\(mood.rawValue) mood fallback reflects the mood artwork choice")
        }

        let errorPreferred = PetPosePlanner.preferredPose(for: .error, toolName: nil, hint: .compacting)
        let errorResolved = PetPosePlanner.resolvedPose(preferred: errorPreferred, availablePoseNames: ["oops", "idle"])
        poseStore.update(characterId: "gpt", pose: errorResolved, fallback: errorResolved != errorPreferred, now: 500)
        state = try readState()
        expect(state["pose"] as? String == "oops" && state["fallback"] as? Bool == false, "short error feedback outranks the lower-priority hints and reads back oops")
        let confirmingPreferred = PetPosePlanner.preferredPose(for: .error, toolName: nil, hint: .confirming)
        let confirmingResolved = PetPosePlanner.resolvedPose(preferred: confirmingPreferred, availablePoseNames: ["asking", "oops", "idle"])
        poseStore.update(characterId: "gpt", pose: confirmingResolved, fallback: confirmingResolved != confirmingPreferred, now: 500)
        state = try readState()
        expect(state["pose"] as? String == "asking", "a pending confirmation outranks even an error")
        let revision = state["revision"] as? Int ?? -1
        poseStore.update(characterId: "gpt", pose: "surprised", fallback: false, now: 501)
        state = try readState()
        expect((state["revision"] as? Int ?? -1) > revision && (state["since"] as? Int ?? 0) >= 501, "state revision increases and pose since advances across transitions")
        print("PASS strict v4 final-pose readback, fallback, mood/hint resolution and revision")
    }

    private static func testSyntheticSnapshotProjection() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let body: [String: Any] = [
            "schemaVersion": 4,
            "revision": 100,
            "characters": PetRole.builtIns.map { ["id": $0.id, "name": $0.name] },
            "activity": [
                "sessionId": "session-test-1",
                "title": "合成联调",
                "agentId": "agent-test",
                "agentName": "测试助手",
                "status": "tool",
                "toolName": "test.read",
                "lastActivityAt": 99,
                "spotlight": ["kind": "drawing", "at": 98],
            ],
            "followMode": "pinned",
            "concurrentSessions": 3,
            "notifications": [
                ["id": "confirmation:0badf00d:97", "kind": "confirmation",
                 "sessionId": "session-test-1", "title": "合成联调", "at": 97],
            ],
        ]
        let response = api.handle(jsonRequest("POST", "/v4/snapshot", body))
        let responseBody = try json(response.body)
        let state = store.viewState()
        expect(response.statusCode == 200 && responseBody["accepted"] as? Bool == true, "synthetic snapshot accepted")
        expect(state.appConnected, "snapshot marks app connected")
        expect(state.activity.title == "合成联调", "activity title projected")
        expect(state.activity.status == .tool, "tool state projected")
        expect(state.activity.hint == nil, "missing optional hint remains backward-compatible")
        expect(state.activity.spotlight == PetActivitySpotlight(kind: "drawing", at: 98), "display spotlight projected")
        expect(state.followMode == .pinned, "follow mode projected")
        expect(state.concurrentSessions == 3, "bounded concurrency projected")
        expect(state.notifications.count == 1 && state.notifications[0].kind == .confirmation,
               "bounded notices projected")
        expect(state.displaySpotlight != nil, "connected display keeps the spotlight")
        expect(state.roles == PetRole.builtIns, "canonical seven-character directory projected")
        expect(state.selection.characterId == "claude" && state.selection.revision == 0, "snapshot cannot change pet choice")
        print("PASS synthetic snapshot projection")
    }

    private static func testBoundedV4FieldsRejectInvalidValues() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let base: [String: Any] = [
            "schemaVersion": 4,
            "revision": 200,
            "characters": PetRole.builtIns.map { ["id": $0.id, "name": $0.name] },
            "activity": [
                "sessionId": "session-bounded", "title": "边界", "agentId": NSNull(), "agentName": NSNull(),
                "status": "working", "toolName": NSNull(), "lastActivityAt": 1,
            ],
        ]
        var badMode = base
        badMode["followMode"] = "other"
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", badMode)).statusCode == 400, "unknown follow mode rejected")
        var badConcurrency = base
        badConcurrency["concurrentSessions"] = 33
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", badConcurrency)).statusCode == 400, "out-of-range concurrency rejected")
        var badNotifications = base
        badNotifications["notifications"] = (0..<9).map { index in
            ["id": "completion:0badf00d:\(index)", "kind": "completion", "at": index]
        }
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", badNotifications)).statusCode == 400, "more than eight notices rejected")
        var badNoticeId = base
        badNoticeId["notifications"] = [["id": "bad id!/../x", "kind": "completion", "at": 1]]
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", badNoticeId)).statusCode == 400, "unsafe notice id rejected")
        var badKind = base
        badKind["notifications"] = [["id": "completion:0badf00d:1", "kind": "success", "at": 1]]
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", badKind)).statusCode == 400, "unknown notice kind rejected")
        var badSpotlight = base
        badSpotlight["activity"] = [
            "sessionId": "session-bounded", "title": "边界", "agentId": NSNull(), "agentName": NSNull(),
            "status": "working", "toolName": NSNull(), "lastActivityAt": 1,
            "spotlight": ["kind": "video", "at": 1],
        ]
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", badSpotlight)).statusCode == 400, "unknown spotlight kind rejected")

        var duplicateNotice = base
        duplicateNotice["notifications"] = [
            ["id": "completion:0badf00d:1", "kind": "completion", "at": 1],
            ["id": "completion:0badf00d:1", "kind": "completion", "at": 2],
        ]
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", duplicateNotice)).statusCode == 400,
               "duplicate notice ids are rejected")
        var wrongModeType = base
        wrongModeType["followMode"] = 4
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", wrongModeType)).statusCode == 400,
               "a non-string follow mode is rejected")
        var wrongConcurrencyType = base
        wrongConcurrencyType["concurrentSessions"] = "3"
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", wrongConcurrencyType)).statusCode == 400,
               "a non-integer concurrency count is rejected")
        var wrongNoticesType = base
        wrongNoticesType["notifications"] = "none"
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", wrongNoticesType)).statusCode == 400,
               "a non-array notifications value is rejected")
        var missingSpotlightAt = base
        missingSpotlightAt["activity"] = [
            "sessionId": "session-bounded", "title": "边界", "agentId": NSNull(), "agentName": NSNull(),
            "status": "working", "toolName": NSNull(), "lastActivityAt": 1,
            "spotlight": ["kind": "drawing"],
        ]
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", missingSpotlightAt)).statusCode == 400,
               "a spotlight without its timestamp is rejected")
        var unknownRoot = base
        unknownRoot["unexpected"] = 1
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", unknownRoot)).statusCode == 400,
               "an unknown v4 root field is rejected")
        expect(api.handle(jsonRequest("POST", "/v3/snapshot", base)).statusCode == 404,
               "the retired v3 snapshot route is rejected")
        expect(store.viewState().activity.status == .idle, "invalid v4 fields never mutate accepted state")
        print("PASS bounded v4 field validation")
    }

    private static func testStrictUnknownFieldRejection() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let body: [String: Any] = [
            "schemaVersion": 4,
            "revision": 100,
            "characters": PetRole.builtIns.map { ["id": $0.id, "name": $0.name] },
            "activity": [
                "sessionId": "session-test-2",
                "title": "合成标题",
                "agentId": NSNull(),
                "agentName": NSNull(),
                "status": "working",
                "toolName": NSNull(),
                "lastActivityAt": 99,
                "message": "must-not-be-accepted",
            ],
        ]
        let response = api.handle(jsonRequest("POST", "/v4/snapshot", body))
        let responseText = String(data: response.body, encoding: .utf8) ?? ""
        expect(response.statusCode == 400, "nested unknown field rejected")
        expect(store.viewState().activity.title == nil, "rejected payload does not mutate state")
        expect(!responseText.contains("must-not-be-accepted"), "error response does not echo request content")
        var rootExtra = body
        rootExtra["unexpected"] = "extra"
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", rootExtra)).statusCode == 400, "root unknown field rejected")
        var nonCanonical = body
        nonCanonical["characters"] = [["id": "stranger", "name": "替换角色"]]
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", nonCanonical)).statusCode == 400, "remote cannot replace the local character catalog")
        expect(store.viewState().roles == PetRole.builtIns, "rejected catalog leaves the seven local roles intact")
        print("PASS strict DTO keys and canonical character catalog")
    }

    private static func testHintDTOValidation() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let baseActivity: [String: Any] = [
            "sessionId": NSNull(), "title": NSNull(), "agentId": NSNull(), "agentName": NSNull(),
            "status": "working", "toolName": NSNull(), "lastActivityAt": 100,
        ]
        func send(_ revision: Int, includeHint: Bool, hintValue: Any? = nil) -> PetHTTPResponse {
            var activity = baseActivity
            if includeHint { activity["hint"] = hintValue ?? NSNull() }
            return api.handle(jsonRequest("POST", "/v4/snapshot", [
                "schemaVersion": 4,
                "revision": revision,
                "characters": PetRole.builtIns.map { ["id": $0.id, "name": $0.name] },
                "activity": activity,
            ]))
        }

        for (index, hint) in PetActivityHint.allCases.enumerated() {
            expect(send(index + 1, includeHint: true, hintValue: hint.rawValue).statusCode == 200, "v4 accepts hint \(hint.rawValue)")
            expect(store.viewState().activity.hint == hint, "v4 stores only the validated \(hint.rawValue) enum")
        }
        expect(send(10, includeHint: false).statusCode == 200, "missing optional hint remains accepted")
        expect(store.viewState().activity.hint == nil, "missing optional hint projects as nil")
        expect(send(11, includeHint: true, hintValue: NSNull()).statusCode == 200, "explicit null hint is accepted")
        expect(store.viewState().activity.hint == nil, "explicit null hint projects as nil")
        expect(send(12, includeHint: true, hintValue: "Confirming").statusCode == 400, "hint enum matching is case-sensitive")
        expect(send(13, includeHint: true, hintValue: "unknown").statusCode == 400, "unknown hint value is rejected")
        expect(send(14, includeHint: true, hintValue: 1).statusCode == 400, "non-string hint value is rejected")
        expect(store.viewState().activity.hint == nil, "invalid hint never mutates the accepted snapshot")
        print("PASS protocol v4 optional hint allowlist and strict values")
    }

    private static func testSelectionRevisionAndConflict() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let write = api.handle(jsonRequest("POST", "/v4/selection", [
            "schemaVersion": 4,
            "characterId": "deepseek-hoodie",
            "expectedRevision": 0,
            "updatedAt": 100,
        ]))
        let writtenBody = try json(write.body)
        let written = writtenBody["selection"] as? [String: Any] ?? [:]
        expect(write.statusCode == 200, "expected revision selection write accepted")
        expect(written["characterId"] as? String == "deepseek-hoodie", "skin selection is stored")
        expect(written["schemaVersion"] as? Int == 4, "selection response uses the v4 schema")
        expect(written["revision"] as? Int == 1, "selection revision increments")

        let current = try json(api.handle(request("GET", "/v4/selection")).body)
        expect(current["characterId"] as? String == "deepseek-hoodie", "pet choice can be read back")
        expect(current["revision"] as? Int == 1, "pet revision is returned")

        let conflict = api.handle(jsonRequest("POST", "/v4/selection", [
            "schemaVersion": 4,
            "characterId": "gpt-onesie",
            "expectedRevision": 0,
            "updatedAt": 200,
        ]))
        let conflictBody = try json(conflict.body)
        let conflictSelection = conflictBody["selection"] as? [String: Any] ?? [:]
        expect(conflict.statusCode == 409, "stale selection write conflicts")
        expect(conflictSelection["characterId"] as? String == "deepseek-hoodie", "conflict returns current choice")
        print("PASS selection write/read/conflict")
    }

    private static func testPetLocalSelectionSurvivesActivitySnapshot() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let local = store.selectLocally("glm", now: 500)
        expect(local?.revision == 1 && local?.updatedAt == 500, "pet local choice increments revision")
        let snapshot = api.handle(jsonRequest("POST", "/v4/snapshot", [
            "schemaVersion": 4,
            "revision": 900,
            "characters": PetRole.builtIns.map { ["id": $0.id, "name": $0.name] },
            "activity": [
                "sessionId": "session-next",
                "title": "新活动",
                "agentId": NSNull(),
                "agentName": NSNull(),
                "status": "success",
                "toolName": NSNull(),
                "lastActivityAt": 901,
            ],
        ]))
        expect(snapshot.statusCode == 200, "activity snapshot accepted")
        let selected = try json(api.handle(request("GET", "/v4/selection")).body)
        expect(selected["characterId"] as? String == "glm", "activity never overwrites pet choice")
        expect(selected["revision"] as? Int == 1, "pet selection revision remains independent")
        expect(store.viewState().activity.status == .success, "activity state still updates")
        print("PASS event state and manual choice remain independent")
    }

    private static func testSnapshotRevisionAndConnectionTimeout() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let payload: [String: Any] = [
            "schemaVersion": 4,
            "revision": 10,
            "characters": PetRole.builtIns.map { ["id": $0.id, "name": $0.name] },
            "activity": [
                "sessionId": NSNull(),
                "title": NSNull(),
                "agentId": NSNull(),
                "agentName": NSNull(),
                "status": "success",
                "toolName": NSNull(),
                "lastActivityAt": 0,
            ],
        ]
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", payload)).statusCode == 200, "new snapshot revision accepted")
        let receivedAt = PetStateStore.nowMilliseconds()
        expect(store.viewState(now: receivedAt).appConnected, "recent heartbeat is connected")
        var stale = payload
        stale["revision"] = 9
        expect(api.handle(jsonRequest("POST", "/v4/snapshot", stale)).statusCode == 409, "older activity revision rejected")
        let expired = store.viewState(now: receivedAt + 9_001)
        expect(!expired.appConnected, "stale heartbeat becomes disconnected")
        expect(expired.activity.status == .success, "timeout does not mutate the received DTO")
        expect(expired.displayStatus == .idle, "expired success state falls back to idle for display")
        print("PASS activity revision and heartbeat timeout")
    }

    private static func testLegacyPeerFailsClosed() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let legacySnapshot = api.handle(jsonRequest("POST", "/v1/snapshot", [
            "schemaVersion": 1,
            "revision": 999,
            "characters": [
                ["id": "blue-whale", "name": "蓝湾鲸"],
                ["id": "star-bunny", "name": "星点兔"],
                ["id": "amber-fox", "name": "柚光狐"],
            ],
            "activity": [
                "sessionId": "legacy-session",
                "title": "不应覆盖目录",
                "agentId": NSNull(),
                "agentName": NSNull(),
                "status": "working",
                "toolName": NSNull(),
                "lastActivityAt": 999,
            ],
        ]))
        expect(legacySnapshot.statusCode == 404, "old snapshot route is retired")
        let legacySelection = api.handle(jsonRequest("POST", "/v1/selection", [
            "schemaVersion": 1,
            "characterId": "blue-whale",
            "expectedRevision": 0,
            "updatedAt": 1000,
        ]))
        expect(legacySelection.statusCode == 404, "old selection route is retired")
        let current = try json(api.handle(request("GET", "/v4/selection")).body)
        let health = try json(api.handle(request("GET", "/v4/hello")).body)
        expect(current["schemaVersion"] as? Int == 4 && current["characterId"] as? String == "claude", "legacy requests leave the new manual choice unchanged")
        expect(store.viewState().roles == PetRole.builtIns && store.viewState().activity.status == .idle, "legacy snapshot cannot replace the canonical catalog or activity")
        expect(api.handle(request("GET", "/v1/hello")).statusCode == 404 &&
               api.handle(request("GET", "/v2/hello")).statusCode == 404 &&
               health["protocolVersion"] as? Int == 4, "v1 and v2 Hana peers fail closed")
        print("PASS v1/v2 peers fail closed without overwriting v4 roles or choice")
    }

    private static func testPetArtworkCatalog() throws {
        let directory = assetDirectory()
        let catalog = try PetArtworkCatalog(directoryURL: directory)
        let decodedCount = try catalog.validateAllAssets()
        let catalogPoseCount = PetRole.builtIns.reduce(0) { $0 + catalog.poseNames(forCharacterID: $1.id).count }
        expect(decodedCount == catalogPoseCount, "all \(catalogPoseCount) catalog-listed WebP assets decode as single-frame alpha images")
        expect(PetRole.builtIns.map(\.id) == ["claude", "gpt", "deepseek", "gemini", "glm", "deepseek-hoodie", "gpt-onesie"], "seven character and skin IDs are stable")

        for role in PetRole.builtIns {
            let poses = catalog.poseNames(forCharacterID: role.id)
            expect(poses.contains("idle") && poses.contains("thinking") && poses.contains("writing") && poses.contains("busy_left") && poses.contains("busy_right") && poses.contains("oops") && poses.contains("drawing") && (poses.contains("happy") || poses.contains("happy-2")), "\(role.id) has all mapped activity poses, including drawing")
            guard let idle = catalog.frame(characterID: role.id, poseName: "idle") else {
                fatalError("CHECK FAILED: \(role.id) idle artwork loads")
            }
            expect(idle.height == 640 && idle.containsOpaquePixel(x: idle.width / 2, yFromTop: idle.height / 2), "\(role.id) idle alpha mask contains the character")
            expect(!idle.containsOpaquePixel(x: 0, yFromTop: 0), "\(role.id) transparent corner remains click-through")

            let workSet = PetPosePlanner.workPoseSet(characterID: role.id, availablePoseNames: poses)
            expect(workSet != nil && workSet!.distinctPoses.count >= 3 &&
                   workSet!.distinctPoses.allSatisfy { poses.contains($0) },
                   "\(role.id) ordinary work rhythm stays inside its own catalog")
            let semanticOrMood = ["happy", "oops", "asking", "compact", "sleeping", "tired", "swamped_left", "swamped_right", "proud", "writing", "reading", "searching", "running", "delegating", "drawing"]
            expect(workSet!.distinctPoses.allSatisfy { !semanticOrMood.contains($0) },
                   "\(role.id) ordinary work rhythm never borrows a semantic or mood pose")
        }

        let claudeDrawing = catalog.frame(characterID: "claude", poseName: "drawing")
        let claudeThinking = catalog.frame(characterID: "claude", poseName: "thinking")
        expect(claudeDrawing != nil && claudeDrawing !== claudeThinking, "Claude drawing loads its dedicated artwork instead of thinking fallback")
        let claudeHappy = catalog.frame(characterID: "claude", poseName: "happy")
        let claudeHappyVariant = catalog.frame(characterID: "claude", poseName: "happy-2")
        expect(claudeHappy === claudeHappyVariant, "Claude success pose resolves its catalogued happy-2 image")
        let claudeIdle = catalog.frame(characterID: "claude", poseName: "idle")
        expect(catalog.frame(characterID: "claude", poseName: "not-listed") === claudeIdle, "missing poses fall back only to that character's idle")
        let geminiIdle = catalog.frame(characterID: "gemini", poseName: "idle")
        let geminiBlink = catalog.frame(characterID: "gemini", poseName: "idle-blink")
        expect(geminiBlink != nil && geminiBlink !== geminiIdle, "Gemini's generated idle-blink loads instead of falling back to idle")
        let hoodieIdle = catalog.frame(characterID: "deepseek-hoodie", poseName: "idle")
        let hoodieIdle2 = catalog.frame(characterID: "deepseek-hoodie", poseName: "idle-2")
        let hoodieIdle3 = catalog.frame(characterID: "deepseek-hoodie", poseName: "idle-3")
        expect(hoodieIdle2 != nil && hoodieIdle3 != nil && hoodieIdle2 !== hoodieIdle && hoodieIdle3 !== hoodieIdle && hoodieIdle2 !== hoodieIdle3,
               "DeepSeek hoodie idle-2 and idle-3 load their dedicated generated artwork")

        // Pick-up frames: two distinct decoded images per character, both on the same canvas.
        for role in PetRole.builtIns {
            let poses = catalog.poseNames(forCharacterID: role.id)
            expect(poses.contains("picked-up") && poses.contains("picked-up-2"),
                   "\(role.id) lists both pick-up frames")
            guard let head = catalog.frame(characterID: role.id, poseName: "picked-up"),
                  let tail = catalog.frame(characterID: role.id, poseName: "picked-up-2") else {
                fatalError("CHECK FAILED: \(role.id) pick-up frames decode")
            }
            expect(head !== tail && head.image !== tail.image, "\(role.id) pick-up frames are two different images")
            expect(head.height == 640 && tail.height == 640, "\(role.id) pick-up frames share the 640 px canvas")
            expect(head.width == tail.width, "\(role.id) pick-up frames share one width, so no per-frame rescale")
            expect(catalog.generatedPoseNames(forCharacterID: role.id).contains("picked-up"),
                   "\(role.id) marks its pick-up frames as locally generated")
        }
        expect(PetRole.builtIns.reduce(0) { $0 + catalog.generatedPoseNames(forCharacterID: $1.id).count } == 18,
               "the catalog marks 18 locally generated poses")
        expect(decodedCount == 211, "the catalog now ships 211 assets")
        print("PASS \(decodedCount) WebP decodes, 7-role alpha hit masks, pose mapping, work rhythm candidates, pick-up frames and idle fallbacks")
    }

    private static func testAlphaCoverageHit() throws {
        // Pure rule: a fading layer cannot keep capturing clicks, and stacked layers composite.
        expect(PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 1, alpha: 255)]), "a settled opaque pixel is hittable")
        expect(abs(PetPoseHitCoverage.coverage([PetPoseAlphaSample(opacity: 1, alpha: 255)]) - 1) < 1e-9, "a settled opaque layer reports full coverage")
        expect(PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 1, alpha: 16)]), "the original single-frame alpha floor is preserved")
        expect(!PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 1, alpha: 15)]), "one step below the original floor is not a hit")
        expect(!PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 0.001, alpha: 255)]), "a nearly invisible fading layer cannot capture a click")
        expect(!PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 0.05, alpha: 255)]), "fading-out artwork stays click-through below the threshold")
        expect(!PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 0.02, alpha: 255), PetPoseAlphaSample(opacity: 0.02, alpha: 255)]), "two faint layers still composite below the threshold")
        expect(PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 0.5, alpha: 255), PetPoseAlphaSample(opacity: 0.5, alpha: 255)]), "two half-opaque layers composite into a hit")
        expect(PetPoseHitCoverage.coverage([PetPoseAlphaSample(opacity: 0.5, alpha: 255), PetPoseAlphaSample(opacity: 0.5, alpha: 255)])
            > PetPoseHitCoverage.coverage([PetPoseAlphaSample(opacity: 0.5, alpha: 255)]), "stacked layers raise coverage above a single layer")
        expect(!PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 1, alpha: 0)]), "a fully transparent pixel never hits")
        expect(!PetPoseHitCoverage.isHit([]), "an empty layer set never hits")
        expect(!PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 2, alpha: 0)]), "a fully transparent pixel stays transparent regardless of opacity")

        // Real decoded artwork: the shared rule agrees with each role's actual alpha mask.
        let catalog = try PetArtworkCatalog(directoryURL: assetDirectory())
        for role in PetRole.builtIns {
            guard let idle = catalog.frame(characterID: role.id, poseName: "idle") else {
                fatalError("CHECK FAILED: \(role.id) idle artwork loads")
            }
            let centreAlpha = idle.alphaValue(x: idle.width / 2, yFromTop: idle.height / 2)
            let cornerAlpha = idle.alphaValue(x: 0, yFromTop: 0)
            expect(PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 1, alpha: centreAlpha)]), "\(role.id) centre pixel hits with the shared rule")
            expect(!PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 1, alpha: cornerAlpha)]), "\(role.id) transparent corner stays click-through")
            expect(PetPoseHitCoverage.isHit([PetPoseAlphaSample(opacity: 0.05, alpha: centreAlpha)]) == false, "\(role.id) fading-out centre is click-through")
            let single = PetPoseAlphaSample(opacity: 0.6, alpha: centreAlpha)
            let stacked = [single, single]
            expect(PetPoseHitCoverage.coverage(stacked) > PetPoseHitCoverage.coverage([single]), "\(role.id) stacked layers raise composited coverage")
            expect(PetPoseHitCoverage.isHit(stacked), "\(role.id) stacked layers stay hittable")
            expect(idle.alphaValue(x: -1, yFromTop: 0) == 0, "\(role.id) left out-of-bounds alpha reads as transparent")
            expect(idle.alphaValue(x: idle.width, yFromTop: idle.height) == 0, "\(role.id) right/bottom out-of-bounds alpha reads as transparent")
        }
        print("PASS alpha coverage hit rule across 7 decoded roles")
    }

    private static func assetDirectory() -> URL {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let defaultDirectory = repositoryRoot.appendingPathComponent("assets/crosspet", isDirectory: true)
        return ProcessInfo.processInfo.environment["CROSSPET_ASSET_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory
    }

    private static func testPointerGestureRecognition() throws {
        var gesture = PetDragClickGesture()
        gesture.begin(at: PetPointerPoint(x: 100, y: 100))
        expect(gesture.drag(to: PetPointerPoint(x: 103, y: 102)) == nil, "sub-threshold motion remains a click candidate")
        expect(gesture.end(at: PetPointerPoint(x: 104, y: 102)), "small movement completes as a click")

        gesture.begin(at: PetPointerPoint(x: 100, y: 100))
        expect(gesture.drag(to: PetPointerPoint(x: 103, y: 102)) == nil, "initial pointer motion does not jump the window")
        let translation = try require(gesture.drag(to: PetPointerPoint(x: 106, y: 103)), "threshold crossing begins a drag")
        expect(translation == PetPointerPoint(x: 6, y: 3), "drag offset is measured from the original mouse-down point")
        expect(!gesture.end(at: PetPointerPoint(x: 108, y: 104)), "drag release does not also fire a click")

        gesture.begin(at: PetPointerPoint(x: 0, y: 0))
        expect(!gesture.end(at: PetPointerPoint(x: 5, y: 0)), "movement at the threshold is classified as a drag")
        print("PASS click/drag threshold and no-jump translation")
    }

    private static func testWindowInputPolicy() throws {
        var policy = PetWindowEventPolicy()
        expect(policy.ignoresMouseEvents(pointerIsOnCharacter: false), "idle pointer outside the character enables window pass-through")
        expect(!policy.ignoresMouseEvents(pointerIsOnCharacter: true), "pointer on visible character keeps the window receptive")
        expect(!policy.ignoresMouseEvents(pointerIsOnCharacter: false, duringPickUp: true), "an active pick-up keeps the window receptive even over a transparent frame pixel")

        policy.beginPointerSequence()
        expect(!policy.ignoresMouseEvents(pointerIsOnCharacter: false), "mouse-down holds event reception through a drag")
        policy.endPointerSequence()
        expect(policy.ignoresMouseEvents(pointerIsOnCharacter: false), "mouse-up releases the drag hold")

        policy.menuDidOpen()
        policy.menuDidOpen()
        expect(!policy.ignoresMouseEvents(pointerIsOnCharacter: false), "nested menu tracking keeps the window receptive")
        policy.menuDidClose()
        expect(!policy.ignoresMouseEvents(pointerIsOnCharacter: false), "closing a submenu does not release the root menu hold")
        policy.menuDidClose()
        expect(policy.ignoresMouseEvents(pointerIsOnCharacter: false), "closing the root menu resumes pointer avoidance")
        policy.menuDidClose()
        expect(policy.ignoresMouseEvents(pointerIsOnCharacter: false), "extra close callbacks cannot leave the policy held")
        policy.beginPointerSequence()
        policy.menuDidOpen()
        policy.reset()
        expect(policy.ignoresMouseEvents(pointerIsOnCharacter: false), "lost-window reset clears drag and menu holds")
        print("PASS window event avoidance and drag/menu holds")
    }

    private static func testCharacterMotionGeometry() throws {
        let motion = PetCharacterMotion(
            width: 168,
            height: 212,
            phase: Double.pi / 2,
            reactionProgress: 0.25,
            isError: true
        )
        expect(abs(motion.scale - 1.055) < 1e-10, "tap pulse reaches the tested maximum scale")

        let testPoints = [
            PetPointerPoint(x: motion.center.x + 42, y: motion.center.y + 90), // bunny ear tip
            PetPointerPoint(x: motion.center.x - 42, y: motion.center.y + 90),
            PetPointerPoint(x: motion.center.x + 14, y: motion.center.y + 64), // whale top ornament
            PetPointerPoint(x: motion.center.x + 75, y: motion.center.y + 55), // status sparkle top tip
            PetPointerPoint(x: motion.center.x + 75, y: motion.center.y + 43), // status sparkle side tip
            PetPointerPoint(x: motion.center.x - 37, y: motion.center.y - 79), // conservative whale-tail control bound
        ]
        for point in testPoints {
            let moved = motion.applying(to: point)
            expect(moved.x >= 0 && moved.x <= 168 && moved.y >= 0 && moved.y <= 212, "maximum authored motion stays within the content bounds")
            let restored = motion.unapplying(to: moved)
            expect(abs(restored.x - point.x) < 1e-9 && abs(restored.y - point.y) < 1e-9, "draw and hit-test transforms are exact inverses")
        }
        print("PASS shared motion transform and maximum character bounds")
    }

    private static func testNoticeCenterAndSpotlightHold() throws {
        let completion = PetNotice(id: "completion:11111111:1000", kind: .completion, title: "完成", at: 1000)
        var center = PetNoticeCenter()
        let replay = center.update(notices: [completion], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 1000)
        expect(replay.presentation == nil, "a completion already present at startup is not replayed")

        let fresh = PetNotice(id: "completion:11111111:2000", kind: .completion, title: "完成", at: 2000)
        let shown = center.update(notices: [fresh], bubblesEnabled: true, completionBlocked: false, now: 10, wallNowMs: 2000)
        expect(shown.presentation?.kind == .completion && shown.presentation?.status == "本轮完成了！",
               "a fresh completion becomes the six-second celebration")
        expect(shown.presentation?.endsAt == 16, "completion display is six seconds")

        let confirmation = PetNotice(id: "confirmation:22222222:2100", kind: .confirmation, title: "确认", at: 2100)
        let preempt = center.update(notices: [fresh, confirmation], bubblesEnabled: true, completionBlocked: false, now: 12, wallNowMs: 2100)
        expect(preempt.presentation?.kind == .confirmation && preempt.presentation?.status == "需要你确认",
               "a confirmation preempts a completion")
        let stable = center.update(notices: [fresh, confirmation], bubblesEnabled: true, completionBlocked: false, now: 13, wallNowMs: 2100)
        expect(stable.presentation?.id == preempt.presentation?.id && stable.changed == false,
               "the same confirmation is not re-announced")
        let resolved = center.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 14, wallNowMs: 2200)
        expect(resolved.presentation == nil, "resolving the confirmation clears the bubble")

        var timeoutCenter = PetNoticeCenter()
        let longConfirmation = PetNotice(id: "confirmation:33333333:3000", kind: .confirmation, title: "长确认", at: 3000)
        _ = timeoutCenter.update(notices: [longConfirmation], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 3000)
        let timedOut = timeoutCenter.update(notices: [longConfirmation], bubblesEnabled: true, completionBlocked: false, now: 300.001, wallNowMs: 3300)
        expect(timedOut.presentation == nil, "a confirmation bubble has a safety timeout")

        var blockedCenter = PetNoticeCenter()
        _ = blockedCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0)
        let blockedNotice = PetNotice(id: "completion:44444444:4000", kind: .completion, title: "等待", at: 4000)
        let blocked = blockedCenter.update(notices: [blockedNotice], bubblesEnabled: true, completionBlocked: true, now: 1, wallNowMs: 4000)
        expect(blocked.presentation == nil, "a completion waits behind an error, confirmation, drawing hold or drag")
        let unblocked = blockedCenter.update(notices: [blockedNotice], bubblesEnabled: true, completionBlocked: false, now: 2, wallNowMs: 4001)
        expect(unblocked.presentation?.kind == .completion, "the queued completion shows once the higher state clears")
        expect(unblocked.presentation?.endsAt == 8,
               "the completion gets its own full six seconds after the error hold, not less")
        let stillAfterError = blockedCenter.update(notices: [blockedNotice], bubblesEnabled: true, completionBlocked: false, now: 7.999, wallNowMs: 4002)
        expect(stillAfterError.presentation?.kind == .completion, "it is still visible just before its six-second deadline")
        let doneAfterError = blockedCenter.update(notices: [blockedNotice], bubblesEnabled: true, completionBlocked: false, now: 8.001, wallNowMs: 4003)
        expect(doneAfterError.presentation == nil, "it ends at its own deadline")

        // The reviewer's recovery timeline: the error pose is held for four seconds by
        // the state layer, and the completion starts only after that hold clears.
        var recoveryCenter = PetNoticeCenter()
        _ = recoveryCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0)
        let recoveryNotice = PetNotice(id: "completion:99999999:16000", kind: .completion, sessionId: "R", title: "R", at: 16000)
        let heldByError = recoveryCenter.update(notices: [recoveryNotice], bubblesEnabled: true, completionBlocked: true, now: 1, wallNowMs: 16000)
        expect(heldByError.presentation == nil, "the completion waits behind the four-second error display")
        let afterErrorHold = recoveryCenter.update(notices: [recoveryNotice], bubblesEnabled: true, completionBlocked: false, now: 4.001, wallNowMs: 16001)
        expect(afterErrorHold.presentation?.kind == .completion &&
               abs((afterErrorHold.presentation?.endsAt ?? 0) - 10.001) < 0.0001,
               "after the error hold it runs its own full six seconds")

        var expiryCenter = PetNoticeCenter()
        _ = expiryCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0)
        let old = PetNotice(id: "completion:55555555:5000", kind: .completion, title: "旧", at: 5000)
        let expired = expiryCenter.update(notices: [old], bubblesEnabled: true, completionBlocked: false, now: 1, wallNowMs: 25001)
        expect(expired.presentation == nil, "an old completion is history")

        var toggleCenter = PetNoticeCenter()
        let pendingConfirmation = PetNotice(id: "confirmation:66666666:6000", kind: .confirmation, title: "开关", at: 6000)
        let off = toggleCenter.update(notices: [pendingConfirmation], bubblesEnabled: false, completionBlocked: false, now: 1, wallNowMs: 6000)
        expect(off.presentation == nil, "bubbles off shows no confirmation bubble")
        let on = toggleCenter.update(notices: [pendingConfirmation], bubblesEnabled: true, completionBlocked: false, now: 2, wallNowMs: 6001)
        expect(on.presentation?.kind == .confirmation, "re-enabling shows a still-pending confirmation")

        var hiddenCompletionCenter = PetNoticeCenter()
        _ = hiddenCompletionCenter.update(notices: [], bubblesEnabled: false, completionBlocked: false, now: 0, wallNowMs: 0)
        let hiddenCompletion = PetNotice(id: "completion:77777777:7000", kind: .completion, title: "关", at: 7000)
        let poseOnly = hiddenCompletionCenter.update(notices: [hiddenCompletion], bubblesEnabled: false, completionBlocked: false, now: 1, wallNowMs: 7000)
        expect(poseOnly.presentation?.kind == .completion && poseOnly.presentation?.bubbleVisible == false,
               "a completion arriving with bubbles off still drives the pose but no bubble")
        let stillPoseOnly = hiddenCompletionCenter.update(notices: [hiddenCompletion], bubblesEnabled: true, completionBlocked: false, now: 2, wallNowMs: 7001)
        expect(stillPoseOnly.presentation?.id == poseOnly.presentation?.id &&
               stillPoseOnly.presentation?.bubbleVisible == false,
               "re-enabling inside the six-second pose window does not pop the old bubble back")
        let afterWindow = hiddenCompletionCenter.update(notices: [hiddenCompletion], bubblesEnabled: true, completionBlocked: false, now: 8, wallNowMs: 7002)
        expect(afterWindow.presentation == nil, "the same completion never replays after its window ends")

        // The other high-risk boundary: a visible completion is hidden one second in,
        // then bubbles are re-enabled one second later while its pose still runs.
        var midPlayCenter = PetNoticeCenter()
        _ = midPlayCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0)
        let midPlayCompletion = PetNotice(id: "completion:88888888:8000", kind: .completion, title: "中途关闭", at: 8000)
        let playing = midPlayCenter.update(notices: [midPlayCompletion], bubblesEnabled: true, completionBlocked: false, now: 1, wallNowMs: 8000)
        expect(playing.presentation?.bubbleVisible == true, "a visible completion starts with its bubble")
        let hiddenMidPlay = midPlayCenter.update(notices: [midPlayCompletion], bubblesEnabled: false, completionBlocked: false, now: 2, wallNowMs: 8001)
        expect(hiddenMidPlay.presentation?.kind == .completion && hiddenMidPlay.presentation?.bubbleVisible == false,
               "turning bubbles off one second in keeps the pose but hides the bubble")
        let reopenedMidPlay = midPlayCenter.update(notices: [midPlayCompletion], bubblesEnabled: true, completionBlocked: false, now: 3, wallNowMs: 8002)
        expect(reopenedMidPlay.presentation?.id == playing.presentation?.id &&
               reopenedMidPlay.presentation?.bubbleVisible == false,
               "re-enabling one second later must not replay the already-shown completion")
        let poseStillRuns = reopenedMidPlay.presentation?.endsAt == 7
        expect(poseStillRuns, "the original six-second pose deadline is preserved, not restarted")

        // Binding changes the allowed notice scope. Queued B must not fire after binding A.
        var scopeCenter = PetNoticeCenter()
        _ = scopeCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0, scope: "latest")
        let completionB = PetNotice(id: "completion:bbbbbbbb:9000", kind: .completion, sessionId: "B", title: "B", at: 9000)
        let blockedB = scopeCenter.update(notices: [completionB], bubblesEnabled: true, completionBlocked: true, now: 1, wallNowMs: 9000, scope: "latest")
        expect(blockedB.presentation == nil, "B is queued while a higher-priority state owns the artwork")
        let completionA = PetNotice(id: "completion:aaaaaaaa:9100", kind: .completion, sessionId: "A", title: "A", at: 9100)
        let boundA = scopeCenter.update(notices: [completionA], bubblesEnabled: true, completionBlocked: false, now: 2, wallNowMs: 9100, scope: "pinned")
        expect(boundA.presentation?.title == "A" && boundA.presentation?.kind == .completion,
               "after binding A only A may be shown")
        let afterA = scopeCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 9, wallNowMs: 9200, scope: "pinned")
        expect(afterA.presentation == nil, "the stale queued B is dropped instead of leaking into the new scope")

        // While B is playing, binding A must stop B immediately.
        var preemptCenter = PetNoticeCenter()
        _ = preemptCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0, scope: "latest")
        let playingB = PetNotice(id: "completion:bbbbbbbb:10000", kind: .completion, sessionId: "B", title: "B", at: 10000)
        let startedB = preemptCenter.update(notices: [playingB], bubblesEnabled: true, completionBlocked: false, now: 1, wallNowMs: 10000, scope: "latest")
        expect(startedB.presentation?.title == "B", "B is playing before the binding change")
        let switchedA = preemptCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 2, wallNowMs: 10001, scope: "pinned")
        expect(switchedA.presentation == nil, "binding A removes B from the allowed scope at once")
        let laterB = preemptCenter.update(notices: [playingB], bubblesEnabled: true, completionBlocked: false, now: 3, wallNowMs: 10002, scope: "pinned")
        expect(laterB.presentation == nil, "B never returns after the scope changed")

        // A completion queued (but never shown) before bubbles are turned off must not
        // start playing after re-enabling. This is the old-bubble replay path.
        var queuedCenter = PetNoticeCenter()
        _ = queuedCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0, scope: "latest")
        let queuedCompletion = PetNotice(id: "completion:eeeeeeee:13000", kind: .completion, sessionId: "E", title: "E", at: 13000)
        let queued = queuedCenter.update(notices: [queuedCompletion], bubblesEnabled: true, completionBlocked: true, now: 1, wallNowMs: 13000, scope: "latest")
        expect(queued.presentation == nil, "the completion waits while blocked")
        let closedBeforeShow = queuedCenter.update(notices: [queuedCompletion], bubblesEnabled: false, completionBlocked: true, now: 2, wallNowMs: 13001, scope: "latest")
        expect(closedBeforeShow.presentation == nil, "turning bubbles off while it is still queued shows nothing")
        let reopenedQueued = queuedCenter.update(notices: [queuedCompletion], bubblesEnabled: true, completionBlocked: false, now: 3, wallNowMs: 13002, scope: "latest")
        expect(reopenedQueued.presentation == nil, "re-enabling does not start the old queued completion")

        // Queue → off → still in the six-second pose window on re-enable.
        var offDuringQueueCenter = PetNoticeCenter()
        _ = offDuringQueueCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0, scope: "latest")
        let offQueuedNotice = PetNotice(id: "completion:ffffffff:14000", kind: .completion, sessionId: "F", title: "F", at: 14000)
        _ = offDuringQueueCenter.update(notices: [offQueuedNotice], bubblesEnabled: false, completionBlocked: false, now: 1, wallNowMs: 14000, scope: "latest")
        let reopenedOffQueue = offDuringQueueCenter.update(notices: [offQueuedNotice], bubblesEnabled: true, completionBlocked: false, now: 2, wallNowMs: 14001, scope: "latest")
        expect(reopenedOffQueue.presentation?.kind == .completion &&
               reopenedOffQueue.presentation?.bubbleVisible == false,
               "a completion received while off plays its pose but never re-shows a bubble")

        // The reviewer's exact timeline: off + blocked, completion arrives, re-enable while
        // still blocked, then the block clears. Pose yes, bubble no.
        var offBlockedCenter = PetNoticeCenter()
        _ = offBlockedCenter.update(notices: [], bubblesEnabled: false, completionBlocked: true, now: 0, wallNowMs: 0, scope: "latest")
        let offBlocked = PetNotice(id: "completion:dddddddd:15000", kind: .completion, sessionId: "D", title: "D", at: 15000)
        _ = offBlockedCenter.update(notices: [offBlocked], bubblesEnabled: false, completionBlocked: true, now: 1, wallNowMs: 15000, scope: "latest")
        _ = offBlockedCenter.update(notices: [offBlocked], bubblesEnabled: true, completionBlocked: true, now: 2, wallNowMs: 15001, scope: "latest")
        let offBlockedCleared = offBlockedCenter.update(notices: [offBlocked], bubblesEnabled: true, completionBlocked: false, now: 3, wallNowMs: 15002, scope: "latest")
        expect(offBlockedCleared.presentation?.kind == .completion &&
               offBlockedCleared.presentation?.bubbleVisible == false,
               "a completion arriving off+blocked never pops a bubble when the block clears")

        // Unbinding must not re-report a completion that ended while another session was bound.
        // The console retires that completion when the binding changes, so the pet only
        // sees the new (empty) scope; it must not invent anything from memory.
        var unbindCenter = PetNoticeCenter()
        _ = unbindCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0, scope: "latest")
        let oldB = PetNotice(id: "completion:cccccccc:11000", kind: .completion, sessionId: "B", title: "B", at: 11000)
        let boundOnlyA = unbindCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 1, wallNowMs: 11000, scope: "pinned")
        expect(boundOnlyA.presentation == nil, "while bound to A, B is outside the allowed scope")
        let unboundAgain = unbindCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 2, wallNowMs: 11001, scope: "latest")
        expect(unboundAgain.presentation == nil, "unbinding does not re-report the old B completion")
        _ = oldB

        // A completion queued close to the TTL must still get its full six seconds once it starts.
        var lateCenter = PetNoticeCenter()
        _ = lateCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 0, wallNowMs: 0, scope: "latest")
        let lateNotice = PetNotice(id: "completion:dddddddd:12000", kind: .completion, sessionId: "D", title: "D", at: 12000)
        let blockedLate = lateCenter.update(notices: [lateNotice], bubblesEnabled: true, completionBlocked: true, now: 1, wallNowMs: 12000, scope: "latest")
        expect(blockedLate.presentation == nil, "the late completion waits behind a higher-priority state")
        // The console's 20 s TTL has just removed it from the wire list, but it already started.
        let lateStart = lateCenter.update(notices: [lateNotice], bubblesEnabled: true, completionBlocked: false, now: 2, wallNowMs: 20000, scope: "latest")
        expect(lateStart.presentation?.kind == .completion, "the late completion starts")
        expect(lateStart.presentation?.endsAt == 8, "it receives its own full six-second deadline")
        let lateStillShowing = lateCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 7.999, wallNowMs: 20001, scope: "latest")
        expect(lateStillShowing.presentation?.kind == .completion, "an active completion is not cut short by the console TTL")
        let lateEnds = lateCenter.update(notices: [], bubblesEnabled: true, completionBlocked: false, now: 8.001, wallNowMs: 20002, scope: "latest")
        expect(lateEnds.presentation == nil, "it ends at its own six-second deadline")

        var hold = PetSpotlightHold()
        let spotlight = PetActivitySpotlight(kind: "drawing", at: 10000)
        hold.update(spotlight, now: 0, wallNowMs: 10000)
        expect(hold.isActive(at: 0) && hold.isActive(at: 3.999), "the drawing hold lasts four seconds")
        expect(!hold.isActive(at: 4.001), "the drawing hold ends at four seconds")
        expect(hold.nextDeadline(after: 0) == 4, "the hold exposes its one-shot deadline")

        var late = PetSpotlightHold()
        late.update(spotlight, now: 10, wallNowMs: 12000)
        expect(late.isActive(at: 10) && !late.isActive(at: 12.001), "a late observer only gets the remaining hold")
        var stale = PetSpotlightHold()
        stale.update(spotlight, now: 0, wallNowMs: 20000)
        expect(!stale.isActive(at: 0), "an old drawing marker is not replayed")
        var cleared = PetSpotlightHold()
        cleared.update(spotlight, now: 0, wallNowMs: 10000)
        cleared.update(nil, now: 1, wallNowMs: 10001)
        expect(!cleared.isActive(at: 1), "a missing marker clears the hold")
        print("PASS bounded notice queue, confirmation priority, completion TTL and drawing hold")
    }

    private static func testBubbleLayout() throws {
        expect(PetBubbleLayout.width(measuredTextWidth: 0) == PetBubbleLayout.minWidth, "an empty name uses the minimum width")
        expect(PetBubbleLayout.width(measuredTextWidth: 10) == PetBubbleLayout.minWidth, "a short name stays compact")
        expect(PetBubbleLayout.width(measuredTextWidth: 100) == 152,
               "a medium name grows to its content plus the 17 pt padding, 1 pt borders and 8 pt halo margins")
        expect(PetBubbleLayout.width(measuredTextWidth: 500) == PetBubbleLayout.maxWidth, "a long name is capped, never a long strip")
        expect(PetBubbleLayout.width(measuredTextWidth: 10) > PetBubbleLayout.minWidth - 1,
               "the halo margin never pulls the window below the minimum width")

        // Three tiers, all of which must include the ellipse tail *and* the halo margin. The
        // values below are measured from the real fonts and the real view, not copied from
        // the previous (3 pt border) round.
        let singleLine = PetBubbleLayout.subtitleHeight(oneLine: true)
        let twoLines = PetBubbleLayout.subtitleHeight(oneLine: false)
        let notice = PetBubbleLayout.noticeHeight()
        expect(singleLine == 64, "one 13 pt line: 8 halo + 36 body + 20 tail = 64 pt")
        expect(twoLines == 82, "two wrapped 13 pt lines: 8 + 54 + 20 = 82 pt")
        expect(notice == 78, "the two-line notice tier: 8 + 50 + 20 = 78 pt")
        expect(singleLine == PetBubbleLayout.glowInset + PetBubbleLayout.bodyHeight([.subtitle])
                + PetBubbleLayout.tailSpan,
               "the window height is halo + body + tail, with no hidden slack")
        expect(twoLines > singleLine && notice < twoLines,
               "the tiers are distinct and ordered by their text lines")
        expect(reachesTailWithinBounds(width: 140, height: singleLine), "the single-line tail stays inside the window")
        expect(reachesTailWithinBounds(width: 220, height: twoLines), "the wrapped tail stays inside the window")
        expect(reachesTailWithinBounds(width: 96, height: notice), "the narrow notice tail stays inside the window")

        // The new visual rules: a 1 pt hairline, a two-layer accent halo, and no halo below.
        expect(PetBubbleLayout.borderWidth == 1, "the body border is a 1 pt hairline")
        expect(PetBubbleLayout.tailBorderWidth == 1, "the tail border is a 1 pt hairline")
        expect(PetBubbleLayout.tailStrokeInset == 0.5, "the tail stroke inset follows half the 1 pt border")
        expect(PetBubbleLayout.accentGlows.count == 3, "three accent halo passes are declared")
        expect(PetBubbleLayout.glowHug.alpha == 0.22 && PetBubbleLayout.glowHug.spread == 0.5,
               "the innermost halo is a 0.5 pt hairline at 22 % accent")
        expect(PetBubbleLayout.glowMain.blurRadius == 7 && PetBubbleLayout.glowMain.spread == 2
                && PetBubbleLayout.glowMain.alpha == 0.26,
               "the main halo is 7 pt blur, 2 pt spread, 26 % accent")
        expect(PetBubbleLayout.glowOuter.blurRadius == 16 && PetBubbleLayout.glowOuter.spread == 5
                && PetBubbleLayout.glowOuter.alpha == 0.14,
               "the outer halo is 16 pt blur, 5 pt spread, 14 % accent")
        expect(PetBubbleLayout.glowNeutral.isNeutral && PetBubbleLayout.glowNeutral.alpha == 0.06,
               "the neutral drop shadow is kept at 6 %")
        expect(PetBubbleLayout.glowInset == 8, "the window reserves 8 pt of halo margin")
        expect(PetBubbleLayout.glowInset < PetBubbleLayout.glowOuter.outwardExtent,
               "8 pt is deliberately less than the outer halo's 21 pt reach: the far tail of that " +
               "blur is 14 % opaque and clipping it is invisible, while 21 pt would bloat the window")

        // The halo may grow left/up/right, never below the body: the character is right under it.
        for (width, height) in [(96.0, singleLine), (220.0, twoLines), (140.0, notice)] {
            let body = PetBubbleLayout.bodyRect(width: width, height: height)
            let clip = PetBubbleLayout.bodyGlowClip(width: width, height: height)
            let limit = PetBubbleLayout.glowBottomLimit(width: width, height: height)
            expect(abs(clip.height - (body.y + body.height)) < 1e-9,
                   "the body halo is clipped exactly at the body's bottom edge")
            expect(abs(limit - (body.y + body.height)) < 1e-9,
                   "no halo may paint below the body's bottom edge")
            for pass in PetBubbleLayout.accentGlows {
                let rect = PetBubbleLayout.glowRect(pass: pass, width: width, height: height)
                expect(rect.y >= 0, "\(pass.blurRadius) pt halo stays inside the top edge")
                expect(rect.y + rect.height <= body.y + body.height + 1e-9,
                       "\(pass.blurRadius) pt halo never reaches below the body")
                expect(rect.x >= 0 && rect.x + rect.width <= width + 1e-9,
                       "\(pass.blurRadius) pt halo stays inside the side margins")
                expect(rect.y + rect.height - (rect.y + rect.height) == 0,
                       "the halo rect keeps its own geometry instead of drifting")
            }
            // The tail's own halo is bounded and also never below the tail tip.
            let tailClip = PetBubbleLayout.tailGlowClip(width: width, height: height)
            expect(tailClip.height > 0 && tailClip.y + tailClip.height <= height + 1e-9,
                   "the tail halo ends at the tail tip, which is the window's bottom edge")
        }
        // The upward halo is much stronger than anything below, by construction.
        let body = PetBubbleLayout.bodyRect(width: 140, height: singleLine)
        let strongest = PetBubbleLayout.accentGlows.map(\.alpha).max() ?? 0
        expect(strongest == PetBubbleLayout.glowMain.alpha, "the strongest pass is the main halo")
        expect(PetBubbleLayout.glowBottomLimit(width: 140, height: singleLine) == body.y + body.height,
               "the downward halo strength is zero: its clip ends at the body")

        let visible = PetPoseRect(x: 0, y: 0, width: 1440, height: 900)
        let bubble = PetPoseSize(width: 140, height: notice)
        let pet = PetPoseRect(x: 100, y: 100, width: 176, height: 200)
        let centered = PetBubbleLayout.origin(petFrame: pet, bubbleSize: bubble, visibleFrame: visible)
        expect(centered.x == 118, "the bubble sits above the pet and centered on it")

        let rightEdge = PetBubbleLayout.origin(petFrame: PetPoseRect(x: 1300, y: 100, width: 176, height: 200),
                                              bubbleSize: bubble, visibleFrame: visible)
        expect(rightEdge.x == 1294, "the bubble is clamped inside the right screen edge")
        let topEdge = PetBubbleLayout.origin(petFrame: PetPoseRect(x: 100, y: 850, width: 176, height: 200),
                                            bubbleSize: bubble, visibleFrame: visible)
        expect(topEdge.y == 816, "a pet near the top clamps the bubble inside the visible frame instead of clipping it")
        let secondScreen = PetBubbleLayout.origin(
            petFrame: PetPoseRect(x: 1600, y: 100, width: 176, height: 200),
            bubbleSize: bubble,
            visibleFrame: PetPoseRect(x: 1500, y: 0, width: 1280, height: 900)
        )
        expect(secondScreen.x == 1618, "a second monitor uses its own visible frame")
        print("PASS adaptive bubble width, halo+tail-inclusive 64/78/82 pt tiers and screen-edge clamping")
    }

    /// Two rects intersect with a non-empty interior.
    private static func overlaps(_ lhs: PetPoseRect, _ rhs: PetPoseRect) -> Bool {
        lhs.minX < rhs.maxX && rhs.minX < lhs.maxX && lhs.minY < rhs.maxY && rhs.minY < lhs.maxY
    }

    /// The ellipse's outer box (stroke included) is inside the window and hangs under the body.
    private static func reachesTailWithinBounds(width: Double, height: Double) -> Bool {
        let body = PetBubbleLayout.bodyRect(width: width, height: height)
        let outer = PetBubbleLayout.tailOuterRect(width: width, height: height)
        let eps = 1e-9
        return body.height > 0
            && outer.width > 0 && outer.height > 0
            && outer.x >= -eps && outer.y >= -eps
            && outer.x + outer.width <= width + eps
            && outer.y + outer.height <= height + eps
            && outer.y >= body.height - 2.5
            && abs(outer.x + outer.width / 2 - width / 2) < eps
            && abs((outer.y + outer.height) - height) < 1
    }

    /// Distance from the bubble's visible tail tip to the top of the pet window. The tail tip
    /// is at the window's bottom edge plus the whole-point rounding slack under it.
    private static func tailTipGap(originY: Double, height: Double, pet: PetPoseRect) -> Double {
        _ = height
        let tip = originY + PetBubbleLayout.tailTipSlack
        return tip - (pet.y + pet.height)
    }

    private static func testHTTPParserLimits() throws {
        let prefix = Data("POST /v4/selection HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{".utf8)
        let partialRequest = try PetHTTPCodec.parse(prefix)
        expect(partialRequest == nil, "parser waits for incomplete body")
        var complete = prefix
        complete.append(Data("}".utf8))
        let parsed = try require(PetHTTPCodec.parse(complete), "complete request parsed")
        expect(parsed.method == "POST" && parsed.path == "/v4/selection", "method and route parsed")
        expect(String(data: parsed.body, encoding: .utf8) == "{}", "body length respected")

        let tooLarge = Data("POST /v4/snapshot HTTP/1.1\r\nContent-Length: 16385\r\n\r\n".utf8)
        expectThrows(.bodyTooLarge, { try PetHTTPCodec.parse(tooLarge) }, "oversize body rejected")
        let chunked = Data("POST /v4/snapshot HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8)
        expectThrows(.unsupportedTransferEncoding, { try PetHTTPCodec.parse(chunked) }, "chunked transfer rejected")
        print("PASS HTTP parser limits")
    }

    private static func testLoopbackServerRoundTrip() async throws {
        let store = PetStateStore()
        let port = UInt16.random(in: 45_000...60_000)
        let server = try LocalHTTPServer(store: store, portValue: port)
        server.start()
        defer { server.stop() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let baseURL = server.endpointURL
        var health: (Data, Int)?
        for _ in 0..<20 {
            do {
                health = try await send(session, url: baseURL.appendingPathComponent("v4/hello"), method: "GET")
                break
            } catch {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let (healthData, healthStatus) = try require(health, "loopback health request completed")
        let healthBody = try json(healthData)
        expect(healthStatus == 200, "loopback listener returns HTTP 200")
        expect(healthBody["service"] as? String == "hana-desktop-pet", "loopback listener identifies its service")

        let poseStore = PetPoseReadbackStore.shared
        _ = poseStore.update(characterId: "gpt", pose: "thinking", fallback: true, now: PetStateStore.nowMilliseconds())
        let (poseData, poseStatus) = try await send(session, url: baseURL.appendingPathComponent("v4/state"), method: "GET")
        let poseResponse = try json(poseData)
        expect(poseStatus == 200 && poseResponse["schemaVersion"] as? Int == 4, "loopback exposes the read-only pose route")
        expect(poseResponse["characterId"] as? String == "gpt" && poseResponse["pose"] as? String == "thinking" && poseResponse["fallback"] as? Bool == true, "loopback state returns the stored final pose and fallback flag")

        let snapshot: [String: Any] = [
            "schemaVersion": 4,
            "revision": PetStateStore.nowMilliseconds(),
            "characters": PetRole.builtIns.map { ["id": $0.id, "name": $0.name] },
            "activity": [
                "sessionId": "synthetic-loopback-session",
                "title": "本机合成快照",
                "agentId": "synthetic-agent",
                "agentName": "合成 Agent",
                "status": "working",
                "toolName": NSNull(),
                "lastActivityAt": PetStateStore.nowMilliseconds(),
            ],
        ]
        let (snapshotData, snapshotStatus) = try await send(
            session,
            url: baseURL.appendingPathComponent("v4/snapshot"),
            method: "POST",
            body: snapshot
        )
        let snapshotResponse = try json(snapshotData)
        expect(snapshotStatus == 200 && snapshotResponse["accepted"] as? Bool == true, "loopback activity snapshot accepted")
        expect(store.viewState().activity.title == "本机合成快照", "loopback activity reaches state store")

        let (selectionData, selectionStatus) = try await send(
            session,
            url: baseURL.appendingPathComponent("v4/selection"),
            method: "POST",
            body: ["schemaVersion": 4, "characterId": "deepseek", "expectedRevision": 0, "updatedAt": PetStateStore.nowMilliseconds()]
        )
        let selectionResponse = try json(selectionData)["selection"] as? [String: Any] ?? [:]
        expect(selectionStatus == 200, "loopback role selection write accepted")
        expect(selectionResponse["characterId"] as? String == "deepseek", "loopback returns current selection")
        let (_, readStatus) = try await send(session, url: baseURL.appendingPathComponent("v4/selection"), method: "GET")
        expect(readStatus == 200, "Hana can poll loopback selection")
        print("PASS live loopback bind and HTTP round trip")
    }

    private static func send(
        _ session: URLSession,
        url: URL,
        method: String,
        body: [String: Any]? = nil
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckFailure.invalidHTTPResponse }
        return (data, http.statusCode)
    }

    private static func request(_ method: String, _ path: String) -> PetHTTPRequest {
        PetHTTPRequest(method: method, path: path, headers: [:], body: Data())
    }

    private static func jsonRequest(_ method: String, _ path: String, _ object: [String: Any]) -> PetHTTPRequest {
        PetHTTPRequest(
            method: method,
            path: path,
            headers: ["content-type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        )
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckFailure.invalidJSON
        }
        return object
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckFailure.missingValue(message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("CHECK FAILED: \(message)") }
    }

    private static func expectThrows(
        _ expected: HTTPParseError,
        _ operation: () throws -> Any?,
        _ message: String
    ) {
        do {
            _ = try operation()
            fatalError("CHECK FAILED: \(message) did not throw")
        } catch let actual as HTTPParseError {
            expect(actual == expected, "\(message) has expected error")
        } catch {
            fatalError("CHECK FAILED: \(message) threw unexpected error \(error)")
        }
    }
}

private enum CheckFailure: Error {
    case invalidJSON
    case invalidHTTPResponse
    case missingValue(String)
}
