import Foundation
import Synchronization

public enum AXTreeCompactor {
    private static let transparentRoles: Set<String> = [
        "group", "axgroup", "uiview", "_uihostingview", "uilayoutcontainerview",
        "uicontentview", "container", "unknown"
    ]

    private static let leafDisplayRoles: Set<String> = [
        "text", "axstatictext", "uilabel", "image", "aximage", "uiimageview"
    ]

    private static let compositeRoles: Set<String> = [
        "btn", "button", "axbutton", "uibutton", "cell", "row", "axrow", "axcell",
        "tab", "axtab", "switch", "axcheckbox", "uiswitch", "link", "axlink", "menu", "menuitem"
    ]

    public static func formatRef(revision: Int, index: Int) -> String {
        revision > 0 ? "r\(revision)e\(index)" : "e\(index)"
    }

    public static func parseRef(_ raw: String) -> (revision: Int?, index: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("r") {
            let rest = trimmed.dropFirst()
            guard let eIdx = rest.firstIndex(of: "e") else { return nil }
            let revPart = rest[..<eIdx]
            let idxPart = rest[rest.index(after: eIdx)...]
            guard let rev = Int(revPart), rev > 0,
                  let idx = Int(idxPart), idx > 0 else {
                return nil
            }
            return (rev, idx)
        }
        if trimmed.hasPrefix("e") {
            let idxPart = trimmed.dropFirst()
            guard let idx = Int(idxPart), idx > 0 else { return nil }
            return (nil, idx)
        }
        return nil
    }

    public static func compact(
        snapshot: RawUITreeSnapshot,
        query: UISnapshotQuery = UISnapshotQuery(),
        revision: Int = 1
    ) -> CompactedUISnapshot {
        let preparedRoot = prepareNode(
            snapshot.root,
            viewportWidth: snapshot.width,
            viewportHeight: snapshot.height,
            viewportOnly: query.viewportOnly
        )

        var startRoots: [(node: UITreeNode, ancestorSig: String)]
        if query.scopeSemanticKey != nil || query.scopeRef != nil {
            if let scoped = findScopedNode(
                in: preparedRoot,
                scopeSemanticKey: query.scopeSemanticKey,
                scopeRawTarget: query.scopeRef
            ) {
                startRoots = [scoped]
            } else {
                let widthInt = Int(snapshot.width.rounded())
                let heightInt = Int(snapshot.height.rounded())
                let header = "# app=\(snapshot.bundleID) pid=\(snapshot.pid) \(widthInt)x\(heightInt)"
                    + " src=\(snapshot.source.rawValue) rev=\(revision) scopeNotFound=1"
                return CompactedUISnapshot(
                    revision: revision,
                    bundleID: snapshot.bundleID,
                    pid: snapshot.pid,
                    width: snapshot.width,
                    height: snapshot.height,
                    source: snapshot.source,
                    isCanvasOnlyHint: snapshot.isCanvasOnlyHint,
                    nodes: [],
                    text: header,
                    truncatedByLimit: false,
                    scopeNotFound: true
                )
            }
        } else {
            startRoots = preparedRoot.map { ($0, "") }
        }

        if query.roles.isEmpty && query.query == nil && query.interactiveOnly {
            startRoots = startRoots.flatMap { entry in
                pruneNonInteractive(entry.node).map { ($0, entry.ancestorSig) }
            }
        }

        var nextRefIndex = 1
        var collected: [CompactedUINode] = []
        var lines: [String] = []
        var truncatedByLimit = false
        var usedSemanticKeys: [String: Int] = [:]
        let widthInt = Int(snapshot.width.rounded())
        let heightInt = Int(snapshot.height.rounded())
        var header = "# app=\(snapshot.bundleID) pid=\(snapshot.pid) \(widthInt)x\(heightInt)"
        header += " src=\(snapshot.source.rawValue) rev=\(revision)"
        if snapshot.isCanvasOnlyHint {
            header += " canvas=1"
        }
        lines.append(header)

        func emit(
            _ node: UITreeNode,
            depth: Int,
            ancestorSig: String,
            siblingIdx: Int,
            occurrenceIdx: Int
        ) {
            if collected.count >= query.maxNodes {
                truncatedByLimit = true
                return
            }
            if depth > query.maxDepth {
                truncatedByLimit = true
                return
            }

            let shortRole = normalizeRole(node.role)
            let matchesFilters = nodeMatchesQuery(node, shortRole: shortRole, query: query)
            let currentSig = makeCurrentSig(
                shortRole: shortRole,
                node: node,
                ancestorSig: ancestorSig,
                siblingIdx: siblingIdx,
                occurrenceIdx: occurrenceIdx
            )

            var nextDepth = depth
            if matchesFilters {
                let ref = formatRef(revision: revision, index: nextRefIndex)
                nextRefIndex += 1
                let baseSemanticKey = makeSemanticKey(
                    role: shortRole,
                    node: node,
                    ancestorSig: currentSig,
                    siblingIdx: siblingIdx,
                    occurrenceIdx: occurrenceIdx
                )
                let keyCount = usedSemanticKeys[baseSemanticKey, default: 0]
                usedSemanticKeys[baseSemanticKey] = keyCount + 1
                let semanticKey = keyCount == 0 ? baseSemanticKey : "\(baseSemanticKey)|dup=\(keyCount)"

                let line = formatLine(
                    ref: ref,
                    role: shortRole,
                    node: node,
                    depth: depth,
                    bounds: query.bounds
                )
                let compacted = CompactedUINode(
                    ref: ref,
                    rawID: node.id,
                    role: shortRole,
                    label: node.label,
                    value: node.value,
                    identifier: node.identifier,
                    enabled: node.enabled,
                    selected: node.selected,
                    focused: node.focused,
                    frame: node.frame,
                    actions: node.actions,
                    source: snapshot.source,
                    depth: depth,
                    semanticKey: semanticKey,
                    lineText: line
                )
                collected.append(compacted)
                lines.append(line)
                nextDepth = depth + 1
            }

            let children = node.children
            let listCap = (node.isListContainer && query.query == nil && query.roles.isEmpty) ? 20 : children.count
            let visibleChildren = Array(children.prefix(listCap))
            var childSigCounts: [String: Int] = [:]
            for (idx, child) in visibleChildren.enumerated() {
                if collected.count >= query.maxNodes {
                    truncatedByLimit = true
                    break
                }
                let childRole = normalizeRole(child.role)
                let childBase = baseSignaturePart(shortRole: childRole, node: child, siblingIdx: idx)
                let occ = childSigCounts[childBase, default: 0]
                childSigCounts[childBase] = occ + 1
                emit(child, depth: nextDepth, ancestorSig: currentSig, siblingIdx: idx, occurrenceIdx: occ)
            }
            if children.count > listCap {
                truncatedByLimit = true
                let indent = String(repeating: "  ", count: nextDepth)
                let hint = "\(indent)... (+\(children.count - listCap) items; "
                    + "use scopeRef or query to filter)"
                lines.append(hint)
            }
        }

        var rootSigCounts: [String: Int] = [:]
        for (idx, entry) in startRoots.enumerated() {
            let rootRole = normalizeRole(entry.node.role)
            let rootBase = baseSignaturePart(shortRole: rootRole, node: entry.node, siblingIdx: idx)
            let occ = rootSigCounts[rootBase, default: 0]
            rootSigCounts[rootBase] = occ + 1
            emit(entry.node, depth: 0, ancestorSig: entry.ancestorSig, siblingIdx: idx, occurrenceIdx: occ)
        }

        if truncatedByLimit {
            lines.append("# truncated: shown \(collected.count) nodes (maxNodes=\(query.maxNodes))")
        }

        return CompactedUISnapshot(
            revision: revision,
            bundleID: snapshot.bundleID,
            pid: snapshot.pid,
            width: snapshot.width,
            height: snapshot.height,
            source: snapshot.source,
            isCanvasOnlyHint: snapshot.isCanvasOnlyHint,
            nodes: collected,
            text: lines.joined(separator: "\n"),
            truncatedByLimit: truncatedByLimit,
            scopeNotFound: false
        )
    }

    private static func findScopedNode(
        in nodes: [UITreeNode],
        scopeSemanticKey: String?,
        scopeRawTarget: String?
    ) -> (node: UITreeNode, ancestorSig: String)? {
        func search(
            _ levelNodes: [UITreeNode],
            ancestorSig: String
        ) -> (node: UITreeNode, ancestorSig: String)? {
            var sigCounts: [String: Int] = [:]
            for (idx, node) in levelNodes.enumerated() {
                let shortRole = normalizeRole(node.role)
                let base = baseSignaturePart(shortRole: shortRole, node: node, siblingIdx: idx)
                let occ = sigCounts[base, default: 0]
                sigCounts[base] = occ + 1
                let currentSig = makeCurrentSig(
                    shortRole: shortRole,
                    node: node,
                    ancestorSig: ancestorSig,
                    siblingIdx: idx,
                    occurrenceIdx: occ
                )
                let semanticKey = makeSemanticKey(
                    role: shortRole,
                    node: node,
                    ancestorSig: currentSig,
                    siblingIdx: idx,
                    occurrenceIdx: occ
                )

                if let targetKey = scopeSemanticKey {
                    let normalizedTarget = stripDuplicateSuffix(targetKey)
                    if semanticKey == targetKey || semanticKey == normalizedTarget {
                        return (node, ancestorSig)
                    }
                } else if let rawTarget = scopeRawTarget {
                    if semanticKey == rawTarget || node.id == rawTarget {
                        return (node, ancestorSig)
                    }
                }

                if let nested = search(node.children, ancestorSig: currentSig) {
                    return nested
                }
            }
            return nil
        }

        return search(nodes, ancestorSig: "")
    }

    private static func stripDuplicateSuffix(_ key: String) -> String {
        guard let range = key.range(of: "|dup=", options: .backwards) else {
            return key
        }
        return String(key[..<range.lowerBound])
    }

    private static func baseSignaturePart(shortRole: String, node: UITreeNode, siblingIdx: Int) -> String {
        let tag = cleanString(node.identifier) ?? cleanString(node.label) ?? "#\(siblingIdx)"
        return "\(shortRole):\(tag)"
    }

    private static func makeCurrentSig(
        shortRole: String,
        node: UITreeNode,
        ancestorSig: String,
        siblingIdx: Int,
        occurrenceIdx: Int
    ) -> String {
        let base = baseSignaturePart(shortRole: shortRole, node: node, siblingIdx: siblingIdx)
        let sigPart = occurrenceIdx == 0 ? base : "\(base)#\(occurrenceIdx)"
        return ancestorSig.isEmpty ? sigPart : "\(ancestorSig)/\(sigPart)"
    }

    private static func prepareNode(
        _ node: UITreeNode,
        viewportWidth: Double,
        viewportHeight: Double,
        viewportOnly: Bool
    ) -> [UITreeNode] {
        if node.hidden || !node.alpha.isFinite || node.alpha < 0.01 {
            return []
        }

        let shortRole = normalizeRole(node.role)
        let transformedChildren = node.children.flatMap {
            prepareNode(
                $0,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                viewportOnly: viewportOnly
            )
        }

        if viewportOnly && shortRole != "win" && !node.frame.isEmpty {
            if !node.frame.intersects(viewportWidth: viewportWidth, viewportHeight: viewportHeight) {
                if transformedChildren.isEmpty {
                    return []
                }
            }
        }

        // Stage 1: Transparent container collapse
        if isTransparentContainer(node, shortRole: shortRole) {
            return transformedChildren
        }

        // Stage 2: Composite control text merging & decorative child folding
        var mergedLabel = cleanString(node.label)
        var mergedValue = cleanString(node.value)
        var keptChildren: [UITreeNode] = []

        if compositeRoles.contains(shortRole) && !transformedChildren.isEmpty {
            for child in transformedChildren {
                let childRole = normalizeRole(child.role)
                if leafDisplayRoles.contains(childRole) && !child.isInteractive && child.children.isEmpty {
                    if let childText = cleanString(child.label) ?? cleanString(child.value) {
                        if mergedLabel == nil {
                            mergedLabel = childText
                        } else if mergedValue == nil && mergedLabel != childText {
                            mergedValue = childText
                        }
                    }
                    continue
                }
                keptChildren.append(child)
            }
        } else {
            keptChildren = transformedChildren
        }

        let rebuilt = UITreeNode(
            id: node.id,
            role: shortRole,
            subrole: node.subrole,
            label: mergedLabel,
            value: mergedValue,
            hint: cleanString(node.hint),
            identifier: cleanString(node.identifier),
            enabled: node.enabled,
            selected: node.selected,
            focused: node.focused,
            hidden: node.hidden,
            alpha: node.alpha,
            frame: node.frame,
            actions: node.actions,
            isInteractive: node.isInteractive,
            isListContainer: node.isListContainer,
            isCanvas: node.isCanvas,
            children: keptChildren
        )
        return [rebuilt]
    }

    private static func pruneNonInteractive(_ node: UITreeNode) -> [UITreeNode] {
        let keptChildren = node.children.flatMap { pruneNonInteractive($0) }
        let keepSelf = node.isInteractive
            || node.role == "win"
            || node.isListContainer
            || node.isCanvas
            || node.role == "web"
            || node.role == "alert"
            || !keptChildren.isEmpty
        guard keepSelf else { return [] }
        return [UITreeNode(
            id: node.id,
            role: node.role,
            subrole: node.subrole,
            label: node.label,
            value: node.value,
            hint: node.hint,
            identifier: node.identifier,
            enabled: node.enabled,
            selected: node.selected,
            focused: node.focused,
            hidden: node.hidden,
            alpha: node.alpha,
            frame: node.frame,
            actions: node.actions,
            isInteractive: node.isInteractive,
            isListContainer: node.isListContainer,
            isCanvas: node.isCanvas,
            children: keptChildren
        )]
    }

    private static func isTransparentContainer(_ node: UITreeNode, shortRole: String) -> Bool {
        guard transparentRoles.contains(shortRole) else { return false }
        if node.isInteractive || node.isListContainer || node.isCanvas { return false }
        if !node.actions.isEmpty { return false }
        if cleanString(node.label) != nil || cleanString(node.value) != nil { return false }
        if cleanString(node.identifier) != nil { return false }
        return true
    }

    private static func nodeMatchesQuery(_ node: UITreeNode, shortRole: String, query: UISnapshotQuery) -> Bool {
        if !query.roles.isEmpty && !query.roles.contains(shortRole) {
            return false
        }
        if let needle = query.query?.lowercased() {
            let haystack = [
                shortRole,
                node.label ?? "",
                node.value ?? "",
                node.identifier ?? "",
                node.hint ?? ""
            ].joined(separator: " ").lowercased()
            if !haystack.contains(needle) {
                return false
            }
        }
        return true
    }

    private static func formatLine(
        ref: String,
        role: String,
        node: UITreeNode,
        depth: Int,
        bounds: UITreeBoundsMode
    ) -> String {
        let indent = String(repeating: "  ", count: depth)
        var parts: [String] = ["\(indent)[\(ref)] \(role)"]
        if let label = cleanString(node.label) {
            parts.append("\"\(escapeQuoted(label, maxLen: 80))\"")
        } else if let id = cleanString(node.identifier) {
            parts.append("#\(id)")
        }
        if let value = cleanString(node.value) {
            parts.append("val=\"\(escapeQuoted(value, maxLen: 48))\"")
        }
        if node.isListContainer && !node.children.isEmpty {
            parts.append("(\(node.children.count) items)")
        }
        var flags: [String] = []
        if !node.enabled { flags.append("disabled") }
        if node.selected { flags.append("sel") }
        if node.focused { flags.append("focus") }
        if !flags.isEmpty {
            parts.append("[\(flags.joined(separator: ","))]")
        }
        switch bounds {
        case .none:
            break
        case .center:
            parts.append("@(\(Int(node.frame.centerX.rounded())),\(Int(node.frame.centerY.rounded())))")
        case .rect:
            let rx = Int(node.frame.x.rounded())
            let ry = Int(node.frame.y.rounded())
            let rw = Int(node.frame.width.rounded())
            let rh = Int(node.frame.height.rounded())
            parts.append("@(\(rx),\(ry),\(rw)x\(rh))")
        }
        return parts.joined(separator: " ")
    }

    private static func makeSemanticKey(
        role: String,
        node: UITreeNode,
        ancestorSig: String,
        siblingIdx: Int,
        occurrenceIdx: Int
    ) -> String {
        let suffix = occurrenceIdx == 0 ? "" : "|occ=\(occurrenceIdx)"
        if let identifier = cleanString(node.identifier) {
            return "\(role)|id=\(identifier)|\(ancestorSig)\(suffix)"
        }
        if let label = cleanString(node.label) {
            return "\(role)|lbl=\(label)|\(ancestorSig)\(suffix)"
        }
        return "\(role)|idx=\(siblingIdx)|\(ancestorSig)\(suffix)"
    }

    private static func cleanString(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func escapeQuoted(_ value: String, maxLen: Int) -> String {
        let clipped = value.count > maxLen ? String(value.prefix(maxLen - 1)) + "…" : value
        return clipped.replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func normalizeRole(_ raw: String) -> String {
        switch raw.lowercased() {
        case "axapplication", "uiapplication", "app":
            return "app"
        case "axwindow", "uiwindow", "win":
            return "win"
        case "axbutton", "uibutton", "btn":
            return "btn"
        case "axtextfield", "uitextfield", "uitextview", "axtextarea", "input":
            return "input"
        case "axsearchfield", "uisearchbar", "search":
            return "search"
        case "axstatictext", "uilabel", "text":
            return "text"
        case "aximage", "uiimageview", "img", "image":
            return "img"
        case "axcheckbox", "axswitch", "uiswitch", "switch":
            return "switch"
        case "axslider", "uislider", "slider":
            return "slider"
        case "axtab", "axradiobutton", "tab":
            return "tab"
        case "axtabgroup", "uitabbar", "tabs":
            return "tabs"
        case "axlist", "axtable", "axoutline", "uitableview", "uicollectionview", "list":
            return "list"
        case "axrow", "axcell", "uitableviewcell", "uicollectionviewcell", "row":
            return "row"
        case "axscrollarea", "uiscrollview", "scroll":
            return "scroll"
        case "axwebarea", "wkwebview", "web":
            return "web"
        case "axlink", "link":
            return "link"
        case "axsheet", "axdialog", "uialertcontroller", "alert":
            return "alert"
        case "axmenu", "axmenuitem", "menu":
            return "menu"
        case "mtkview", "cametallayer", "canvas":
            return "canvas"
        default:
            return raw.lowercased()
        }
    }
}

public enum UIRefLookupResult: Sendable {
    case found(CompactedUINode)
    case stale(message: String, candidates: [CompactedUINode])
}

public final class UITreeRevisionStore: Sendable {
    private struct BundleHistory: Sendable {
        var nextRevision: Int = 1
        var snapshots: [CompactedUISnapshot] = []
    }

    private let maxHistoryPerApp: Int
    private let state = Mutex<[String: BundleHistory]>([:])

    public init(maxHistoryPerApp: Int = 8) {
        self.maxHistoryPerApp = max(2, maxHistoryPerApp)
    }

    public func record(
        rawSnapshot: RawUITreeSnapshot,
        query: UISnapshotQuery
    ) -> (current: CompactedUISnapshot, previous: CompactedUISnapshot?) {
        state.withLock { storage in
            var history = storage[rawSnapshot.bundleID] ?? BundleHistory()
            let rev = history.nextRevision
            let prev = history.snapshots.last
            let compacted = AXTreeCompactor.compact(snapshot: rawSnapshot, query: query, revision: rev)
            if compacted.scopeNotFound {
                return (compacted, prev)
            }
            history.nextRevision = rev + 1
            history.snapshots.append(compacted)
            if history.snapshots.count > maxHistoryPerApp {
                history.snapshots.removeFirst(history.snapshots.count - maxHistoryPerApp)
            }
            storage[rawSnapshot.bundleID] = history
            return (compacted, prev)
        }
    }

    public func latestSnapshot(for bundleID: String) -> CompactedUISnapshot? {
        state.withLock { $0[bundleID]?.snapshots.last }
    }

    public func snapshot(for bundleID: String, revision: Int) -> CompactedUISnapshot? {
        state.withLock { $0[bundleID]?.snapshots.first(where: { $0.revision == revision }) }
    }

    public func resolveRef(
        bundleID: String,
        ref: String,
        expectedRevision: Int? = nil
    ) -> UIRefLookupResult {
        let snapshots = state.withLock { $0[bundleID]?.snapshots ?? [] }
        guard let latest = snapshots.last else {
            return .stale(message: "STALE_REF \(ref): no snapshot captured yet for \(bundleID)", candidates: [])
        }

        let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = AXTreeCompactor.parseRef(trimmedRef) else {
            return .stale(
                message: "STALE_REF \(trimmedRef): invalid ref format (expected r\(latest.revision)e<N>)",
                candidates: Array(latest.nodes.prefix(3))
            )
        }

        if let refRev = parsed.revision {
            if let expectedRevision, expectedRevision != refRev {
                return .stale(
                    message: "STALE_REF \(trimmedRef): ref revision \(refRev) != requested rev \(expectedRevision)",
                    candidates: Array(latest.nodes.prefix(3))
                )
            }
            if refRev == latest.revision, let exact = latest.node(forRef: trimmedRef) {
                return .found(exact)
            }
            let priorNode = snapshots.first(where: { $0.revision == refRev })?.node(forRef: trimmedRef)
            return makeStaleResult(
                ref: trimmedRef,
                prior: priorNode,
                priorRev: refRev,
                latest: latest
            )
        }

        // Legacy bare "e<N>" ref: only valid when caller explicitly pins rev == latest.revision.
        if let expectedRevision {
            let normalized = AXTreeCompactor.formatRef(revision: expectedRevision, index: parsed.index)
            if expectedRevision == latest.revision, let exact = latest.node(forRef: normalized) {
                return .found(exact)
            }
            let priorNode = snapshots.first(where: { $0.revision == expectedRevision })?.node(forRef: normalized)
            return makeStaleResult(
                ref: trimmedRef,
                prior: priorNode,
                priorRev: expectedRevision,
                latest: latest
            )
        }

        let latestCandidateRef = AXTreeCompactor.formatRef(revision: latest.revision, index: parsed.index)
        let candidateHint = latest.node(forRef: latestCandidateRef).map { [$0] } ?? Array(latest.nodes.prefix(3))
        return .stale(
            message: "STALE_REF \(trimmedRef): unrevisioned ref rejected (current rev \(latest.revision); "
                + "use r\(latest.revision)e<N> or pass rev)",
            candidates: candidateHint
        )
    }

    public func scopeNode(forRef ref: String, bundleID: String) -> CompactedUINode? {
        let snapshots = state.withLock { $0[bundleID]?.snapshots ?? [] }
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = AXTreeCompactor.parseRef(trimmed), let refRev = parsed.revision {
            return snapshots.first(where: { $0.revision == refRev })?.node(forRef: trimmed)
        }
        return snapshots.reversed().lazy.compactMap { snap -> CompactedUINode? in
            if let direct = snap.node(forRef: trimmed) {
                return direct
            }
            if let parsed = AXTreeCompactor.parseRef(trimmed) {
                let normalized = AXTreeCompactor.formatRef(revision: snap.revision, index: parsed.index)
                return snap.node(forRef: normalized)
            }
            return nil
        }.first
    }

    public func rawNodeID(forScopeRef ref: String, bundleID: String) -> String? {
        scopeNode(forRef: ref, bundleID: bundleID)?.rawID
    }

    public func semanticKey(forScopeRef ref: String, bundleID: String) -> String? {
        scopeNode(forRef: ref, bundleID: bundleID)?.semanticKey
    }

    public func clear(bundleID: String) {
        state.withLock { _ = $0.removeValue(forKey: bundleID) }
    }

    public static func formatDiff(
        from previous: CompactedUISnapshot,
        to current: CompactedUISnapshot
    ) -> String {
        let prevByKey = Dictionary(previous.nodes.map { ($0.semanticKey, $0) }, uniquingKeysWith: { first, _ in first })
        let currByKey = Dictionary(current.nodes.map { ($0.semanticKey, $0) }, uniquingKeysWith: { first, _ in first })

        var changes: [String] = []
        for currNode in current.nodes {
            if let prevNode = prevByKey[currNode.semanticKey] {
                var diffs: [String] = []
                if prevNode.label != currNode.label {
                    diffs.append("lbl=\(prevNode.label ?? "")->\(currNode.label ?? "")")
                }
                if prevNode.value != currNode.value {
                    diffs.append("val=\(prevNode.value ?? "")->\(currNode.value ?? "")")
                }
                if prevNode.enabled != currNode.enabled {
                    diffs.append(currNode.enabled ? "enabled" : "disabled")
                }
                if prevNode.selected != currNode.selected {
                    diffs.append(currNode.selected ? "+sel" : "-sel")
                }
                if prevNode.focused != currNode.focused {
                    diffs.append(currNode.focused ? "+focus" : "-focus")
                }
                if !diffs.isEmpty {
                    let lbl = currNode.label.map { " \"\($0)\"" } ?? ""
                    changes.append("~ [\(currNode.ref)] \(currNode.role)\(lbl) \(diffs.joined(separator: " "))")
                }
            } else {
                changes.append("+ \(currNode.lineText.trimmingCharacters(in: .whitespaces))")
            }
        }
        for prevNode in previous.nodes where currByKey[prevNode.semanticKey] == nil {
            let lbl = prevNode.label.map { " \"\($0)\"" } ?? ""
            changes.append("- [\(prevNode.ref)] \(prevNode.role)\(lbl)")
        }

        if changes.isEmpty {
            return "# diff rev \(previous.revision)->\(current.revision) (no changes)"
        }
        let header = "# diff rev \(previous.revision)->\(current.revision) (\(changes.count) changes)"
        return ([header] + changes).joined(separator: "\n")
    }

    private func makeStaleResult(
        ref: String,
        prior: CompactedUINode?,
        priorRev: Int,
        latest: CompactedUISnapshot
    ) -> UIRefLookupResult {
        guard let prior else {
            return .stale(
                message: "STALE_REF \(ref): not found in rev \(latest.revision)",
                candidates: Array(latest.nodes.prefix(3))
            )
        }
        let ranked = latest.nodes
            .map { (node: $0, score: similarityScore(prior: prior, candidate: $0)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map(\.node)
        let desc = prior.label ?? prior.identifier ?? ""
        return .stale(
            message: "STALE_REF \(ref) (from rev \(priorRev), current rev \(latest.revision); "
                + "was \(prior.role) \"\(desc)\")",
            candidates: ranked
        )
    }

    private func similarityScore(prior: CompactedUINode, candidate: CompactedUINode) -> Int {
        var score = 0
        if prior.semanticKey == candidate.semanticKey { score += 10 }
        if prior.role == candidate.role { score += 3 }
        if let pid = prior.identifier, pid == candidate.identifier { score += 5 }
        if let pl = prior.label?.lowercased(), let cl = candidate.label?.lowercased() {
            if pl == cl {
                score += 5
            } else if cl.contains(pl) || pl.contains(cl) {
                score += 2
            }
        }
        return score
    }
}
