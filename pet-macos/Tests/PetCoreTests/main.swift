import Foundation
import PetBridge
import PetCore

@main
struct PetCoreChecks {
    static func main() async throws {
        try testHealthAndRoutes()
        try testPoseStateReadback()
        try testSyntheticSnapshotProjection()
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
        try testHTTPParserLimits()
        try await testLoopbackServerRoundTrip()
        print("All 16 PetCore checks passed.")
    }

    private static func testHealthAndRoutes() throws {
        let api = PetAPI(store: PetStateStore())
        let health = api.handle(request("GET", "/v3/hello"))
        let body = try json(health.body)
        expect(health.statusCode == 200, "health returns 200")
        expect(body["service"] as? String == "hana-desktop-pet", "health reports service marker")
        expect(body["protocolVersion"] as? Int == 3, "health reports protocol version")
        expect(api.handle(request("GET", "/v1/hello")).statusCode == 404, "v1 peer route is retired")
        expect(api.handle(request("GET", "/v2/hello")).statusCode == 404, "v2 peer route is retired fail-closed")
        expect(api.handle(request("GET", "/v3/admin")).statusCode == 404, "unknown route is rejected")
        expect(api.handle(request("DELETE", "/v3/selection")).statusCode == 405, "unknown method is rejected")
        print("PASS health and route allowlist")
    }

    private static func testPoseStateReadback() throws {
        let stateStore = PetStateStore()
        let poseStore = PetPoseReadbackStore(characterId: "claude", pose: "idle", since: 100)
        let api = PetAPI(store: stateStore, poseReadback: poseStore)

        func readState() throws -> [String: Any] {
            try json(api.handle(request("GET", "/v3/state")).body)
        }

        let initial = try readState()
        expect(initial["schemaVersion"] as? Int == 3, "pose readback uses schema v3")
        expect(initial["characterId"] as? String == "claude" && initial["pose"] as? String == "idle", "pose endpoint exposes the renderer's initial state")
        expect(Set(initial.keys) == Set(["schemaVersion", "characterId", "pose", "fallback", "since", "revision"]), "pose response contains only the strict DTO fields")
        expect(api.handle(PetHTTPRequest(method: "GET", path: "/v3/state", headers: [:], body: Data("{}".utf8))).statusCode == 400, "state read rejects a request body")
        expect(api.handle(request("POST", "/v3/state")).statusCode == 405, "state endpoint is read-only")

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

        let errorPreferred = PetPosePlanner.preferredPose(for: .error, toolName: nil, hint: .confirming)
        let errorResolved = PetPosePlanner.resolvedPose(preferred: errorPreferred, availablePoseNames: ["oops", "idle"])
        poseStore.update(characterId: "gpt", pose: errorResolved, fallback: errorResolved != errorPreferred, now: 500)
        state = try readState()
        expect(state["pose"] as? String == "oops" && state["fallback"] as? Bool == false, "short error feedback outranks hints and reads back oops")
        let revision = state["revision"] as? Int ?? -1
        poseStore.update(characterId: "gpt", pose: "surprised", fallback: false, now: 501)
        state = try readState()
        expect((state["revision"] as? Int ?? -1) > revision && (state["since"] as? Int ?? 0) >= 501, "state revision increases and pose since advances across transitions")
        print("PASS strict v3 final-pose readback, fallback, mood/hint resolution and revision")
    }

    private static func testSyntheticSnapshotProjection() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let body: [String: Any] = [
            "schemaVersion": 3,
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
            ],
        ]
        let response = api.handle(jsonRequest("POST", "/v3/snapshot", body))
        let responseBody = try json(response.body)
        let state = store.viewState()
        expect(response.statusCode == 200 && responseBody["accepted"] as? Bool == true, "synthetic snapshot accepted")
        expect(state.appConnected, "snapshot marks app connected")
        expect(state.activity.title == "合成联调", "activity title projected")
        expect(state.activity.status == .tool, "tool state projected")
        expect(state.activity.hint == nil, "missing optional hint remains backward-compatible")
        expect(state.roles == PetRole.builtIns, "canonical seven-character directory projected")
        expect(state.selection.characterId == "claude" && state.selection.revision == 0, "snapshot cannot change pet choice")
        print("PASS synthetic snapshot projection")
    }

    private static func testStrictUnknownFieldRejection() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let body: [String: Any] = [
            "schemaVersion": 3,
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
        let response = api.handle(jsonRequest("POST", "/v3/snapshot", body))
        let responseText = String(data: response.body, encoding: .utf8) ?? ""
        expect(response.statusCode == 400, "nested unknown field rejected")
        expect(store.viewState().activity.title == nil, "rejected payload does not mutate state")
        expect(!responseText.contains("must-not-be-accepted"), "error response does not echo request content")
        var rootExtra = body
        rootExtra["unexpected"] = "extra"
        expect(api.handle(jsonRequest("POST", "/v3/snapshot", rootExtra)).statusCode == 400, "root unknown field rejected")
        var nonCanonical = body
        nonCanonical["characters"] = [["id": "stranger", "name": "替换角色"]]
        expect(api.handle(jsonRequest("POST", "/v3/snapshot", nonCanonical)).statusCode == 400, "remote cannot replace the local character catalog")
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
            return api.handle(jsonRequest("POST", "/v3/snapshot", [
                "schemaVersion": 3,
                "revision": revision,
                "characters": PetRole.builtIns.map { ["id": $0.id, "name": $0.name] },
                "activity": activity,
            ]))
        }

        for (index, hint) in PetActivityHint.allCases.enumerated() {
            expect(send(index + 1, includeHint: true, hintValue: hint.rawValue).statusCode == 200, "v3 accepts hint \(hint.rawValue)")
            expect(store.viewState().activity.hint == hint, "v3 stores only the validated \(hint.rawValue) enum")
        }
        expect(send(10, includeHint: false).statusCode == 200, "missing optional hint remains accepted")
        expect(store.viewState().activity.hint == nil, "missing optional hint projects as nil")
        expect(send(11, includeHint: true, hintValue: NSNull()).statusCode == 200, "explicit null hint is accepted")
        expect(store.viewState().activity.hint == nil, "explicit null hint projects as nil")
        expect(send(12, includeHint: true, hintValue: "Confirming").statusCode == 400, "hint enum matching is case-sensitive")
        expect(send(13, includeHint: true, hintValue: "unknown").statusCode == 400, "unknown hint value is rejected")
        expect(send(14, includeHint: true, hintValue: 1).statusCode == 400, "non-string hint value is rejected")
        expect(store.viewState().activity.hint == nil, "invalid hint never mutates the accepted snapshot")
        print("PASS protocol v3 optional hint allowlist and strict values")
    }

    private static func testSelectionRevisionAndConflict() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let write = api.handle(jsonRequest("POST", "/v3/selection", [
            "schemaVersion": 3,
            "characterId": "deepseek-hoodie",
            "expectedRevision": 0,
            "updatedAt": 100,
        ]))
        let writtenBody = try json(write.body)
        let written = writtenBody["selection"] as? [String: Any] ?? [:]
        expect(write.statusCode == 200, "expected revision selection write accepted")
        expect(written["characterId"] as? String == "deepseek-hoodie", "skin selection is stored")
        expect(written["schemaVersion"] as? Int == 3, "selection response uses the v3 schema")
        expect(written["revision"] as? Int == 1, "selection revision increments")

        let current = try json(api.handle(request("GET", "/v3/selection")).body)
        expect(current["characterId"] as? String == "deepseek-hoodie", "pet choice can be read back")
        expect(current["revision"] as? Int == 1, "pet revision is returned")

        let conflict = api.handle(jsonRequest("POST", "/v3/selection", [
            "schemaVersion": 3,
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
        let snapshot = api.handle(jsonRequest("POST", "/v3/snapshot", [
            "schemaVersion": 3,
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
        let selected = try json(api.handle(request("GET", "/v3/selection")).body)
        expect(selected["characterId"] as? String == "glm", "activity never overwrites pet choice")
        expect(selected["revision"] as? Int == 1, "pet selection revision remains independent")
        expect(store.viewState().activity.status == .success, "activity state still updates")
        print("PASS event state and manual choice remain independent")
    }

    private static func testSnapshotRevisionAndConnectionTimeout() throws {
        let store = PetStateStore()
        let api = PetAPI(store: store)
        let payload: [String: Any] = [
            "schemaVersion": 3,
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
        expect(api.handle(jsonRequest("POST", "/v3/snapshot", payload)).statusCode == 200, "new snapshot revision accepted")
        let receivedAt = PetStateStore.nowMilliseconds()
        expect(store.viewState(now: receivedAt).appConnected, "recent heartbeat is connected")
        var stale = payload
        stale["revision"] = 9
        expect(api.handle(jsonRequest("POST", "/v3/snapshot", stale)).statusCode == 409, "older activity revision rejected")
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
        let current = try json(api.handle(request("GET", "/v3/selection")).body)
        let health = try json(api.handle(request("GET", "/v3/hello")).body)
        expect(current["schemaVersion"] as? Int == 3 && current["characterId"] as? String == "claude", "legacy requests leave the new manual choice unchanged")
        expect(store.viewState().roles == PetRole.builtIns && store.viewState().activity.status == .idle, "legacy snapshot cannot replace the canonical catalog or activity")
        expect(api.handle(request("GET", "/v1/hello")).statusCode == 404 &&
               api.handle(request("GET", "/v2/hello")).statusCode == 404 &&
               health["protocolVersion"] as? Int == 3, "v1 and v2 Hana peers fail closed")
        print("PASS v1/v2 peers fail closed without overwriting v3 roles or choice")
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

        expect(PetArtworkPoseMapper.poseName(for: .idle, animationStep: 0) == "idle", "idle state uses idle art")
        expect(PetArtworkPoseMapper.poseName(for: .idle, animationStep: 8) == "idle-blink", "idle state uses the listed blink pose")
        expect(PetArtworkPoseMapper.poseName(for: .working, animationStep: 0) == "thinking", "working maps to thinking")
        expect(PetArtworkPoseMapper.poseName(for: .working, animationStep: 1) == "writing", "working cycles to writing")
        expect(PetArtworkPoseMapper.poseName(for: .tool, animationStep: 0) == "busy_left" && PetArtworkPoseMapper.poseName(for: .tool, animationStep: 1) == "busy_right", "tool state alternates the listed busy poses")
        expect(PetArtworkPoseMapper.poseName(for: .success, animationStep: 0) == "happy", "success maps to happy")
        expect(PetArtworkPoseMapper.poseName(for: .error, animationStep: 0) == "oops", "error maps to oops")
        print("PASS \(decodedCount) WebP decodes, 7-role alpha hit masks, pose mapping and idle fallbacks")
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

    private static func testHTTPParserLimits() throws {
        let prefix = Data("POST /v3/selection HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{".utf8)
        let partialRequest = try PetHTTPCodec.parse(prefix)
        expect(partialRequest == nil, "parser waits for incomplete body")
        var complete = prefix
        complete.append(Data("}".utf8))
        let parsed = try require(PetHTTPCodec.parse(complete), "complete request parsed")
        expect(parsed.method == "POST" && parsed.path == "/v3/selection", "method and route parsed")
        expect(String(data: parsed.body, encoding: .utf8) == "{}", "body length respected")

        let tooLarge = Data("POST /v3/snapshot HTTP/1.1\r\nContent-Length: 16385\r\n\r\n".utf8)
        expectThrows(.bodyTooLarge, { try PetHTTPCodec.parse(tooLarge) }, "oversize body rejected")
        let chunked = Data("POST /v3/snapshot HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8)
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
                health = try await send(session, url: baseURL.appendingPathComponent("v3/hello"), method: "GET")
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
        let (poseData, poseStatus) = try await send(session, url: baseURL.appendingPathComponent("v3/state"), method: "GET")
        let poseResponse = try json(poseData)
        expect(poseStatus == 200 && poseResponse["schemaVersion"] as? Int == 3, "loopback exposes the read-only pose route")
        expect(poseResponse["characterId"] as? String == "gpt" && poseResponse["pose"] as? String == "thinking" && poseResponse["fallback"] as? Bool == true, "loopback state returns the stored final pose and fallback flag")

        let snapshot: [String: Any] = [
            "schemaVersion": 3,
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
            url: baseURL.appendingPathComponent("v3/snapshot"),
            method: "POST",
            body: snapshot
        )
        let snapshotResponse = try json(snapshotData)
        expect(snapshotStatus == 200 && snapshotResponse["accepted"] as? Bool == true, "loopback activity snapshot accepted")
        expect(store.viewState().activity.title == "本机合成快照", "loopback activity reaches state store")

        let (selectionData, selectionStatus) = try await send(
            session,
            url: baseURL.appendingPathComponent("v3/selection"),
            method: "POST",
            body: ["schemaVersion": 3, "characterId": "deepseek", "expectedRevision": 0, "updatedAt": PetStateStore.nowMilliseconds()]
        )
        let selectionResponse = try json(selectionData)["selection"] as? [String: Any] ?? [:]
        expect(selectionStatus == 200, "loopback role selection write accepted")
        expect(selectionResponse["characterId"] as? String == "deepseek", "loopback returns current selection")
        let (_, readStatus) = try await send(session, url: baseURL.appendingPathComponent("v3/selection"), method: "GET")
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
