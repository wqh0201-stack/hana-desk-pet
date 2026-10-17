import Foundation
import ImageIO

@main
private struct PosePlannerChecks {
    private static var checks = 0

    static func main() throws {
        try checkStatusMapping()
        try checkToolNameClassification()
        try checkPoseResolution()
        try checkWorkRhythmCandidates()
        try checkBundledCatalog()
        print("PosePlannerChecks: \(checks) checks passed")
    }

    private static func checkStatusMapping() throws {
        expect(PetPosePlanner.preferredPose(for: .idle, toolName: "read_file") == "idle", "idle ignores tool name")
        expect(PetPosePlanner.preferredPose(for: .working, toolName: "write_file") == "thinking", "working does not infer a live tool")
        expect(PetPosePlanner.preferredPose(for: .tool, toolName: nil) == "busy_left", "tool without a safe name stays generic")
        expect(PetPosePlanner.preferredPose(for: .success, toolName: nil) == "happy", "success uses happy")
        expect(PetPosePlanner.preferredPose(for: .error, toolName: nil) == "oops", "error uses oops")
        let hintPoses: [(PetActivityHint, String)] = [
            (.confirming, "asking"), (.compacting, "compact"), (.interrupted, "surprised"),
        ]
        for (hint, expected) in hintPoses {
            expect(PetPosePlanner.preferredPose(for: .working, toolName: nil, hint: hint) == expected, "\(hint.rawValue) maps to \(expected)")
            expect(PetPosePlanner.preferredPose(for: .error, toolName: nil, hint: hint) == "oops", "error short feedback outranks \(hint.rawValue)")
        }
    }

    private static func checkToolNameClassification() throws {
        let cases: [(String, String)] = [
            ("read", "reading"),
            ("functions.read", "reading"),
            ("ls", "reading"),
            ("functions.ls", "reading"),
            ("web_fetch", "reading"),
            ("functions.web_fetch", "reading"),
            ("read_file", "reading"),
            ("MCP__filesystem__READ_FILE", "reading"),
            ("filesystem.read_file_v2", "reading"),
            ("write", "writing"),
            ("functions.write", "writing"),
            ("edit", "writing"),
            ("functions.edit", "writing"),
            ("fs:write_file-2", "writing"),
            ("mcp__editor__EDIT_FILE", "writing"),
            ("web.search", "searching"),
            ("MCP__search__WEB_SEARCH_v3", "searching"),
            ("shell.run_command", "running"),
            ("exec_command", "running"),
            ("delegate:spawn_agent", "delegating"),
            ("subagent_reply", "delegating"),
            ("functions.subagent_message", "delegating"),
            ("subagent_close", "delegating"),
            ("session", "delegating"),
            ("functions.session", "delegating"),
            ("write_stdin", "running"),
            ("functions.write_stdin_v2", "running"),
            ("MCP__tools__TOOL_HELP-2", "searching"),
            ("todo_write", "writing"),
            ("tool_search", "searching"),
            ("tool_help", "searching"),
            ("current_status", "reading"),
            ("browser", "searching"),
            ("search_memory", "searching"),
            ("image.generate_image", "drawing"),
            ("media_generate-image", "drawing"),
        ]
        for (name, expected) in cases {
            expect(PetPosePlanner.preferredPose(for: .tool, toolName: name) == expected, "tool \(name) -> \(expected)")
        }

        for ambiguousOrUnknown in [
            "filesystem.read", "session.read", "tool_call", "file", "functions.unknown_session",
            "media_resize-image", "functions.read#hash", "read-abc", "my_read_file_backup", "not_read_file_backup", "search_or_run", "unknown_tool", "",
        ] {
            expect(PetPosePlanner.preferredPose(for: .tool, toolName: ambiguousOrUnknown) == "busy_left", "\(ambiguousOrUnknown) is not inferred")
        }
        expect(PetPosePlanner.preferredPose(for: .tool, toolName: "read_file with arguments") == "busy_left", "tool names with unsafe text are rejected")
    }

    private static func checkPoseResolution() throws {
        expect(PetPosePlanner.resolvedPose(preferred: "reading", availablePoseNames: ["idle", "reading-2"]) == "reading-2", "reading-2 is selected when base artwork is absent")
        expect(PetPosePlanner.resolvedPose(preferred: "searching", availablePoseNames: ["idle", "searching-3"]) == "searching-3", "-3 pose variant is supported")
        expect(PetPosePlanner.resolvedPose(preferred: "happy", availablePoseNames: ["idle", "happy-2"]) == "happy-2", "Claude happy-2 artwork resolves")
        expect(PetPosePlanner.resolvedPose(preferred: "idle-blink", availablePoseNames: ["idle", "idle-2"]) == "idle", "missing Gemini blink falls back to idle")
        let catalog = try PetArtworkCatalog(directoryURL: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/crosspet", isDirectory: true))
        let claudePoses = catalog.poseNames(forCharacterID: "claude")
        let otherRolesKeepDrawing = PetRole.builtIns.filter { $0.id != "claude" }.allSatisfy { role in
            let poses = catalog.poseNames(forCharacterID: role.id)
            return poses.contains("drawing") && PetPosePlanner.resolvedPose(preferred: "drawing", availablePoseNames: poses) == "drawing"
        }
        expect(PetPosePlanner.resolvedPose(preferred: "drawing", availablePoseNames: ["idle", "thinking", "busy_left"]) == "thinking" &&
               PetPosePlanner.resolvedPose(preferred: "drawing", availablePoseNames: claudePoses) == "drawing" &&
               otherRolesKeepDrawing,
               "drawing keeps the thinking fallback when missing, while Claude and the other six roles resolve to drawing")
        expect(PetPosePlanner.resolvedPose(preferred: "writing", availablePoseNames: ["idle", "busy_left"]) == "busy_left", "busy fallback is used before idle")
        expect(PetPosePlanner.resolvedPose(preferred: "unknown", availablePoseNames: ["idle", "idle-2"]) == "idle", "unknown preferred pose ends at idle")
        expect(PetPosePlanner.resolvedPose(preferred: "reading", availablePoseNames: ["busy_right"]) == "busy_right", "malformed list still resolves to an available pose")
        expect(PetPosePlanner.resolvedPose(preferred: "reading", availablePoseNames: []) == "idle", "empty list has deterministic idle fallback")
    }

    private static func checkBundledCatalog() throws {
        let root = CommandLine.arguments.dropFirst().first ?? "assets/crosspet"
        let catalog = try PetArtworkCatalog(directoryURL: URL(fileURLWithPath: root, isDirectory: true))
        expect(catalog.maximumAspectRatio.isFinite && catalog.maximumAspectRatio > 0, "maximum aspect ratio is computed from catalog image headers")
        var expectedMaximumAspectRatio = 0.0
        for role in PetRole.builtIns {
            for poseName in catalog.poseNames(forCharacterID: role.id) {
                let imageURL = URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(role.id, isDirectory: true)
                    .appendingPathComponent("\(poseName).webp", isDirectory: false)
                if let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
                   let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                   let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                   width > 0, height > 0 {
                    expectedMaximumAspectRatio = max(expectedMaximumAspectRatio, width / height)
                }
            }
        }
        expect(abs(catalog.maximumAspectRatio - expectedMaximumAspectRatio) < 0.000_001, "maximum aspect ratio matches source image headers")

        let samples: [(PetActivityStatus, String?)] = [
            (.idle, nil), (.working, nil), (.tool, "read_file"), (.tool, "write_file"),
            (.tool, "web_search"), (.tool, "run_command"), (.tool, "spawn_agent"),
            (.tool, "generate_image"), (.tool, "unclassified"), (.success, nil), (.error, nil),
        ]
        for role in PetRole.builtIns {
            let available = catalog.poseNames(forCharacterID: role.id)
            expect(available.contains("idle"), "\(role.id) catalog includes idle")
            for (status, toolName) in samples {
                let preferred = PetPosePlanner.preferredPose(for: status, toolName: toolName)
                let resolved = PetPosePlanner.resolvedPose(preferred: preferred, availablePoseNames: available)
                expect(available.contains(resolved), "\(role.id): \(preferred) resolves to its listed artwork")
            }
            checkMoodPoseResolution(for: role.id, available: available)
            checkHintPoseResolution(for: role.id, available: available)
        }

        let claude = catalog.poseNames(forCharacterID: "claude")
        expect(PetPosePlanner.resolvedPose(preferred: "happy", availablePoseNames: claude) == "happy-2", "Claude's actual catalog resolves happy-2")
        let gemini = catalog.poseNames(forCharacterID: "gemini")
        expect(gemini.contains("idle-blink") && PetPosePlanner.resolvedPose(preferred: "idle-blink", availablePoseNames: gemini) == "idle-blink", "Gemini's generated blink pose resolves to idle-blink")
        let hoodie = catalog.poseNames(forCharacterID: "deepseek-hoodie")
        expect(hoodie.contains("idle-2") && hoodie.contains("idle-3") &&
               PetPosePlanner.resolvedPose(preferred: "idle-2", availablePoseNames: hoodie) == "idle-2" &&
               PetPosePlanner.resolvedPose(preferred: "idle-3", availablePoseNames: hoodie) == "idle-3",
               "DeepSeek hoodie idle variants resolve to idle-2 and idle-3")
    }

    private static func checkHintPoseResolution(for roleID: String, available: [String]) {
        let cases: [(PetActivityHint, String, [String])] = [
            (.confirming, "asking", ["asking", "listening", "thinking", "idle"]),
            (.compacting, "compact", ["compact", "thinking", "busy_left", "idle"]),
            (.interrupted, "surprised", ["surprised", "oops", "idle"]),
        ]
        for (hint, preferred, fallbackChain) in cases {
            expect(PetPosePlanner.preferredPose(for: .working, toolName: nil, hint: hint) == preferred, "\(roleID): \(hint.rawValue) requests \(preferred)")
            let resolved = PetPosePlanner.resolvedPose(preferred: preferred, availablePoseNames: available)
            let expected = fallbackChain.first(where: { available.contains($0) }) ?? available.first ?? "idle"
            expect(resolved == expected, "\(roleID): \(hint.rawValue) follows its available catalog fallback chain")
            expect(available.contains(resolved), "\(roleID): \(hint.rawValue) never selects outside its catalog")

            let withoutPreferred = available.filter { $0 != preferred }
            let forcedFallback = PetPosePlanner.resolvedPose(preferred: preferred, availablePoseNames: withoutPreferred)
            let expectedFallback = fallbackChain.dropFirst().first(where: { withoutPreferred.contains($0) }) ?? withoutPreferred.first ?? "idle"
            expect(forcedFallback == expectedFallback, "\(roleID): missing \(preferred) advances to the next available hint fallback")
            expect(withoutPreferred.contains(forcedFallback), "\(roleID): missing \(preferred) still resolves inside its catalog")
        }
    }

    private static func checkMoodPoseResolution(for roleID: String, available: [String]) {
        let workPose = PetPosePlanner.resolvedPose(preferred: "thinking", availablePoseNames: available)
        let moodCases: [(PetPoseMood, String, [String])] = [
            (.sleeping, available.contains("sleeping") ? "sleeping" : "sleeping-2", ["sleeping", "sleeping-2"]),
            (.tired, "tired", ["tired", "tired-2"]),
            (.swampedLeft, "swamped_left", ["swamped_left", "swamped_right"]),
            (.swampedRight, "swamped_right", ["swamped_right", "swamped_left"]),
            (.proud, "proud", ["proud", "proud-2"]),
        ]
        for (mood, preferred, moodAssets) in moodCases {
            let resolved = PetPoseMood.resolvedPose(for: mood, workPose: workPose, availablePoseNames: available)
            let expected = available.contains(preferred) ? preferred :
                (mood == .sleeping && available.contains("sleeping-2") ? "sleeping-2" :
                    (mood == .proud && available.contains("happy") ? "happy" :
                        (mood == .proud && available.contains("happy-2") ? "happy-2" :
                            (mood == .tired ? workPose :
                                (mood == .swampedLeft ? (available.contains("busy_left") ? "busy_left" : "idle") :
                                    (mood == .swampedRight ? (available.contains("busy_right") ? "busy_right" : "idle") : "idle"))))))
            expect(resolved == expected, "\(roleID): \(mood.rawValue) uses its listed pose or intended fallback")
            expect(available.contains(resolved), "\(roleID): \(mood.rawValue) never selects outside its own catalog")

            let withoutMoodArt = available.filter { name in !moodAssets.contains(name) }
            let fallback = PetPoseMood.resolvedPose(for: mood, workPose: workPose, availablePoseNames: withoutMoodArt)
            let expectedFallback: String
            switch mood {
            case .sleeping: expectedFallback = "idle"
            case .tired: expectedFallback = workPose
            case .swampedLeft: expectedFallback = withoutMoodArt.contains("busy_left") ? "busy_left" : "idle"
            case .swampedRight: expectedFallback = withoutMoodArt.contains("busy_right") ? "busy_right" : "idle"
            case .proud: expectedFallback = PetPosePlanner.resolvedPose(preferred: "happy", availablePoseNames: withoutMoodArt)
            }
            expect(fallback == expectedFallback, "\(roleID): missing \(mood.rawValue) art follows its safe fallback chain")
            expect(withoutMoodArt.contains(fallback), "\(roleID): missing \(mood.rawValue) art still resolves within its own catalog")
        }
    }

    private static func checkWorkRhythmCandidates() throws {
        let root = CommandLine.arguments.dropFirst().first ?? "assets/crosspet"
        let catalog = try PetArtworkCatalog(directoryURL: URL(fileURLWithPath: root, isDirectory: true))
        let expectedVariant = [
            "claude": "thinking-2",
            "gpt": "thinking",
            "deepseek": "deepthink",
            "gemini": "thinking",
            "glm": "thinking",
            "deepseek-hoodie": "deepthink",
            "gpt-onesie": "thinking",
        ]
        for role in PetRole.builtIns {
            let poses = catalog.poseNames(forCharacterID: role.id)
            guard let set = PetPosePlanner.workPoseSet(characterID: role.id, availablePoseNames: poses) else {
                fatalError("CHECK FAILED: \(role.id) has no ordinary-work candidates")
            }
            expect(set.thinking == "thinking" && set.busyLeft == "busy_left" && set.busyRight == "busy_right",
                   "\(role.id) uses the generic work poses")
            expect(set.thinkingVariant == expectedVariant[role.id], "\(role.id) uses its own thinking variant")
            expect(set.distinctPoses.allSatisfy { poses.contains($0) }, "\(role.id) candidates stay inside its catalog")
            expect(PetWorkPoseScheduler.phases(for: set).count == 4, "\(role.id) has four distinct rhythm stages")
        }

        // Missing-artwork branches never fall outside the character's own list.
        expect(PetPosePlanner.workPoseSet(characterID: "claude", availablePoseNames: []) == nil,
               "an empty catalog yields no rhythm")
        expect(PetPosePlanner.workPoseSet(characterID: "claude", availablePoseNames: ["idle", "thinking"]) == nil,
               "one usable work pose yields no rhythm")
        let variantless = PetPosePlanner.workPoseSet(
            characterID: "claude",
            availablePoseNames: ["idle", "thinking", "busy_left", "busy_right"]
        )
        expect(variantless?.thinkingVariant == "thinking", "a missing variant falls back to base thinking")
        expect(Set(PetWorkPoseScheduler.phases(for: variantless!).map(\.pose)) == ["thinking", "busy_left", "busy_right"],
               "a variant that would repeat base thinking does not create a duplicate stage")
        let partial = PetPosePlanner.workPoseSet(characterID: "deepseek", availablePoseNames: ["idle", "thinking", "busy_right"])
        expect(partial?.busyLeft == "thinking" && partial?.supportsRhythm == true,
               "a partial catalog collapses missing stages onto base thinking instead of borrowing another role")
        expect(PetPosePlanner.workThinkingVariant(for: "claude") == "thinking-2" &&
               PetPosePlanner.workThinkingVariant(for: "deepseek") == "deepthink",
               "variant mapping is per character and never cross-character")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
