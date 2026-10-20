import Foundation

/// Converts the bounded activity DTO into an original artwork pose without inspecting
/// tool arguments, results, or session content.
public enum PetPosePlanner {
    /// Returns a stable preferred pose. Only `.tool` events are interpreted using the
    /// tool name; a lingering tool name during ordinary work is not treated as live work.
    public static func preferredPose(
        for status: PetActivityStatus,
        toolName: String?,
        hint: PetActivityHint? = nil
    ) -> String {
        // Waiting for the user is the most urgent state: a confirmation outranks even
        // a real error, because the run cannot continue until the user acts.
        if hint == .confirming { return "asking" }
        // A real error is the existing short feedback and outranks the other hints.
        if status == .error { return "oops" }
        if let hint {
            switch hint {
            case .confirming: return "asking"
            case .compacting: return "compact"
            case .interrupted: return "surprised"
            }
        }
        switch status {
        case .idle:
            return "idle"
        case .working:
            return "thinking"
        case .tool:
            return preferredToolPose(for: toolName) ?? "busy_left"
        case .success:
            return "happy"
        case .error:
            return "oops"
        }
    }

    /// Whether this tool maps to a concrete semantic pose. Ambient moods (dense-tool
    /// swamped, fatigue) must never cover these actions.
    public static func isSemanticToolName(_ toolName: String?) -> Bool {
        guard let pose = preferredToolPose(for: toolName) else { return false }
        return semanticPoses.contains(pose)
    }

    private static let semanticPoses: Set<String> = [
        "reading", "writing", "searching", "running", "delegating", "drawing",
    ]

    /// Resolves the ordinary-work rhythm poses for one character, using only catalog-listed
    /// artwork. `busy_left`/`busy_right` are generic work poses, and the third stage uses the
    /// character's own thinking variant (never another character's artwork). Semantic poses
    /// such as `writing` are never used as decoration.
    public static func workPoseSet(characterID: String, availablePoseNames: [String]) -> PetWorkPoseSet? {
        guard !availablePoseNames.isEmpty else { return nil }
        let available = Set(availablePoseNames)
        let thinking = resolvedPose(preferred: "thinking", availablePoseNames: availablePoseNames)
        let variant = available.contains(workThinkingVariant(for: characterID))
            ? workThinkingVariant(for: characterID)
            : thinking
        let set = PetWorkPoseSet(
            thinking: thinking,
            busyLeft: available.contains("busy_left") ? "busy_left" : thinking,
            thinkingVariant: variant,
            busyRight: available.contains("busy_right") ? "busy_right" : thinking
        )
        return set.supportsRhythm ? set : nil
    }

    /// The ordinary-work rhythm while at least two unbound conversations are working.
    /// It swaps the thinking stages for the existing swamped artwork, so only ordinary
    /// thinking changes; tool actions, hints, errors and drawing holds are untouched.
    public static func swampedWorkPoseSet(
        characterID: String,
        availablePoseNames: [String]
    ) -> PetWorkPoseSet? {
        guard let normal = workPoseSet(characterID: characterID, availablePoseNames: availablePoseNames) else {
            return nil
        }
        let left = PetPoseMood.resolvedPose(
            for: .swampedLeft,
            workPose: normal.thinking,
            availablePoseNames: availablePoseNames
        )
        let right = PetPoseMood.resolvedPose(
            for: .swampedRight,
            workPose: normal.thinking,
            availablePoseNames: availablePoseNames
        )
        let set = PetWorkPoseSet(
            thinking: left,
            busyLeft: left,
            thinkingVariant: right,
            busyRight: right
        )
        return set.supportsRhythm ? set : normal
    }

    /// The one thinking-variant a character may use in its own work rhythm.
    public static func workThinkingVariant(for characterID: String) -> String {
        switch characterID {
        case "claude": return "thinking-2"
        case "deepseek", "deepseek-hoodie": return "deepthink"
        default: return "thinking"
        }
    }

    /// Resolves a preferred pose against one character's catalog-listed pose names.
    /// The returned value is always present in a non-empty catalog list; valid catalogs
    /// require `idle`, which is the final fallback. A malformed list without `idle`
    /// falls back to its first entry rather than selecting a missing asset.
    public static func resolvedPose(preferred: String, availablePoseNames: [String]) -> String {
        guard !availablePoseNames.isEmpty else { return "idle" }
        let available = Set(availablePoseNames)

        for candidate in candidatePoses(for: preferred) where available.contains(candidate) {
            return candidate
        }
        if available.contains("idle") { return "idle" }
        return availablePoseNames[0]
    }

    private static func preferredToolPose(for toolName: String?) -> String? {
        guard let toolName,
              toolName.count <= 80,
              let parsedName = normalizedToolName(toolName) else { return nil }
        let (namespace, leaf) = parsedName

        if readingTools.contains(leaf) { return "reading" }
        if writingTools.contains(leaf) { return "writing" }
        if genericReadingTools.contains(leaf), isBareOrFunctionsNamespace(namespace) { return "reading" }
        if genericWritingTools.contains(leaf), isBareOrFunctionsNamespace(namespace) { return "writing" }
        if searchingTools.contains(leaf) { return "searching" }
        if runningTools.contains(leaf) { return "running" }
        if delegatingTools.contains(leaf) { return "delegating" }
        if drawingTools.contains(leaf) { return "drawing" }
        return nil
    }

    private static func isBareOrFunctionsNamespace(_ namespace: String) -> Bool {
        namespace.isEmpty || namespace == "functions"
    }

    /// Namespaces are separated only by explicit namespace delimiters. Matching the
    /// final component avoids substring guesses such as `not_read_file_backup`.
    /// A numeric/version suffix is accepted for versioned tool names (`read_file_v2`).
    private static func normalizedToolName(_ name: String) -> (namespace: String, leaf: String)? {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty,
              lowered.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 97 && scalar.value <= 122) ||
                  (scalar.value >= 48 && scalar.value <= 57) ||
                  scalar.value == 95 || scalar.value == 45 ||
                  scalar.value == 46 || scalar.value == 58 || scalar.value == 47
              }) else { return nil }

        let normalizedNamespaces = lowered.replacingOccurrences(of: "::", with: ".")
        let namespaceParts = normalizedNamespaces.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "." || $0 == ":" || $0 == "/" }
        )
        guard namespaceParts.allSatisfy({ !$0.isEmpty }) else { return nil }

        var nameParts: [String] = []
        for part in namespaceParts {
            let components = part.split(separator: "__", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty }) else { return nil }
            nameParts += components.map(String.init)
        }
        guard let rawLeaf = nameParts.popLast() else { return nil }
        let namespace = nameParts.joined(separator: ".")

        guard let delimiter = rawLeaf.lastIndex(where: { $0 == "_" || $0 == "-" }), delimiter != rawLeaf.startIndex else {
            return (namespace, rawLeaf)
        }
        var suffix = rawLeaf[rawLeaf.index(after: delimiter)...]
        if suffix.first == "v" { suffix = suffix.dropFirst() }
        guard !suffix.isEmpty, suffix.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return (namespace, rawLeaf)
        }
        return (namespace, String(rawLeaf[..<delimiter]))
    }

    private static func candidatePoses(for preferred: String) -> [String] {
        var candidates = [preferred]
        let bases = ["idle", "thinking", "busy_left", "busy_right", "reading", "writing", "searching", "running", "delegating", "drawing", "happy", "oops"]

        if let base = bases.first(where: { preferred == $0 }) {
            candidates += ["\(base)-2", "\(base)-3"]
        } else if let base = bases.first(where: { preferred == "\($0)-2" || preferred == "\($0)-3" }) {
            candidates.append(base)
        }

        let canonical = bases.first(where: { preferred == $0 || preferred == "\($0)-2" || preferred == "\($0)-3" }) ?? preferred
        switch canonical {
        case "asking":
            candidates += ["listening", "thinking", "idle"]
        case "compact":
            candidates += ["thinking", "busy_left", "idle"]
        case "surprised":
            candidates += ["oops", "idle"]
        case "idle":
            candidates += ["idle-blink", "idle-2", "idle-3"]
        case "idle-blink":
            candidates += ["idle", "idle-2", "idle-3"]
        case "thinking":
            candidates += ["busy_left", "busy_right", "idle", "idle-2", "idle-3"]
        case "busy_left":
            candidates += ["busy_right", "thinking", "thinking-2", "idle", "idle-2", "idle-3"]
        case "busy_right":
            candidates += ["busy_left", "thinking", "thinking-2", "idle", "idle-2", "idle-3"]
        case "reading", "writing", "searching":
            candidates += ["thinking", "thinking-2", "busy_left", "busy_right", "idle", "idle-2", "idle-3"]
        case "running":
            candidates += ["busy_left", "busy_right", "thinking", "thinking-2", "idle", "idle-2", "idle-3"]
        case "delegating":
            candidates += ["busy_right", "busy_left", "running", "thinking", "thinking-2", "idle", "idle-2", "idle-3"]
        case "drawing":
            candidates += ["thinking", "thinking-2", "busy_left", "busy_right", "idle", "idle-2", "idle-3"]
        case "happy":
            candidates += ["happy-2", "proud", "idle", "idle-2", "idle-3"]
        case "oops":
            candidates += ["sorry", "surprised", "idle", "idle-2", "idle-3"]
        default:
            break
        }
        return unique(candidates)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static let readingTools: Set<String> = [
        "read_file", "readfile", "file_read", "read_text_file", "read_document", "open_file", "get_file_contents", "web_fetch",
        "current_status",
    ]
    private static let writingTools: Set<String> = [
        "write_file", "writefile", "file_write", "edit_file", "editfile", "append_file", "replace_file", "patch_file",
        "todo_write",
    ]
    private static let genericReadingTools: Set<String> = ["read", "ls"]
    private static let genericWritingTools: Set<String> = ["write", "edit"]
    private static let searchingTools: Set<String> = [
        "search", "web_search", "search_web", "search_files", "search_code", "code_search", "grep", "find", "find_files", "ripgrep", "rg",
        "tool_search", "tool_help", "browser", "search_memory",
    ]
    private static let runningTools: Set<String> = [
        "exec", "execute", "shell", "terminal", "bash", "zsh", "run_command", "execute_command", "exec_command", "run_shell_command",
        "write_stdin",
    ]
    private static let delegatingTools: Set<String> = [
        "delegate", "delegate_task", "subagent", "spawn_agent", "spawn_subagent", "create_agent", "subagent_reply", "subagent_message",
        "subagent_close", "session",
    ]
    private static let drawingTools: Set<String> = [
        "image_gen", "image_generation", "generate_image", "create_image", "draw_image", "text_to_image", "media_generate-image",
    ]
}
