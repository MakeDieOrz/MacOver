import Foundation

public enum UITreeSource: String, Codable, Equatable, Sendable {
    case ax
    case bridge
}

public enum UITreeBoundsMode: String, Codable, Equatable, Sendable {
    case none
    case center
    case rect
}

public struct UITreeRect: Equatable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool {
        !x.isFinite || !y.isFinite || !width.isFinite || !height.isFinite || width <= 0.5 || height <= 0.5
    }

    public var centerX: Double { x + width / 2.0 }
    public var centerY: Double { y + height / 2.0 }

    public func intersects(viewportWidth: Double, viewportHeight: Double) -> Bool {
        guard !isEmpty,
              viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0 else {
            return false
        }
        return x < viewportWidth && (x + width) > 0 && y < viewportHeight && (y + height) > 0
    }
}

public struct UITreeNode: Equatable, Sendable, Codable {
    public let id: String
    public let role: String
    public let subrole: String?
    public let label: String?
    public let value: String?
    public let hint: String?
    public let identifier: String?
    public let enabled: Bool
    public let selected: Bool
    public let focused: Bool
    public let hidden: Bool
    public let alpha: Double
    public let frame: UITreeRect
    public let actions: [String]
    public let isInteractive: Bool
    public let isListContainer: Bool
    public let isCanvas: Bool
    public let children: [UITreeNode]

    public init(
        id: String,
        role: String,
        subrole: String? = nil,
        label: String? = nil,
        value: String? = nil,
        hint: String? = nil,
        identifier: String? = nil,
        enabled: Bool = true,
        selected: Bool = false,
        focused: Bool = false,
        hidden: Bool = false,
        alpha: Double = 1.0,
        frame: UITreeRect,
        actions: [String] = [],
        isInteractive: Bool = false,
        isListContainer: Bool = false,
        isCanvas: Bool = false,
        children: [UITreeNode] = []
    ) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.hint = hint
        self.identifier = identifier
        self.enabled = enabled
        self.selected = selected
        self.focused = focused
        self.hidden = hidden
        self.alpha = alpha
        self.frame = frame
        self.actions = actions
        self.isInteractive = isInteractive
        self.isListContainer = isListContainer
        self.isCanvas = isCanvas
        self.children = children
    }
}

public struct RawUITreeSnapshot: Equatable, Sendable, Codable {
    public let bundleID: String
    public let pid: Int32
    public let width: Double
    public let height: Double
    public let source: UITreeSource
    public let isCanvasOnlyHint: Bool
    public let root: UITreeNode

    public init(
        bundleID: String,
        pid: Int32,
        width: Double,
        height: Double,
        source: UITreeSource,
        isCanvasOnlyHint: Bool = false,
        root: UITreeNode
    ) {
        self.bundleID = bundleID
        self.pid = pid
        self.width = width
        self.height = height
        self.source = source
        self.isCanvasOnlyHint = isCanvasOnlyHint
        self.root = root
    }
}

public struct UISnapshotQuery: Equatable, Sendable {
    public let interactiveOnly: Bool
    public let viewportOnly: Bool
    public let query: String?
    public let roles: Set<String>
    public let scopeRef: String?
    public let scopeSemanticKey: String?
    public let maxNodes: Int
    public let maxDepth: Int
    public let bounds: UITreeBoundsMode

    public init(
        interactiveOnly: Bool = true,
        viewportOnly: Bool = true,
        query: String? = nil,
        roles: [String] = [],
        scopeRef: String? = nil,
        scopeSemanticKey: String? = nil,
        maxNodes: Int = 80,
        maxDepth: Int = 8,
        bounds: UITreeBoundsMode = .none
    ) {
        self.interactiveOnly = interactiveOnly
        self.viewportOnly = viewportOnly
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = (trimmedQuery?.isEmpty == false) ? trimmedQuery : nil
        self.roles = Set(roles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        let trimmedScope = scopeRef?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scopeRef = (trimmedScope?.isEmpty == false) ? trimmedScope : nil
        let trimmedScopeKey = scopeSemanticKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scopeSemanticKey = (trimmedScopeKey?.isEmpty == false) ? trimmedScopeKey : nil
        self.maxNodes = max(1, min(300, maxNodes))
        self.maxDepth = max(1, min(16, maxDepth))
        self.bounds = bounds
    }
}

public struct CompactedUINode: Equatable, Sendable {
    public let ref: String
    public let rawID: String
    public let role: String
    public let label: String?
    public let value: String?
    public let identifier: String?
    public let enabled: Bool
    public let selected: Bool
    public let focused: Bool
    public let frame: UITreeRect
    public let actions: [String]
    public let source: UITreeSource
    public let depth: Int
    public let semanticKey: String
    public let lineText: String

    public init(
        ref: String,
        rawID: String,
        role: String,
        label: String?,
        value: String?,
        identifier: String?,
        enabled: Bool,
        selected: Bool,
        focused: Bool,
        frame: UITreeRect,
        actions: [String],
        source: UITreeSource,
        depth: Int,
        semanticKey: String,
        lineText: String
    ) {
        self.ref = ref
        self.rawID = rawID
        self.role = role
        self.label = label
        self.value = value
        self.identifier = identifier
        self.enabled = enabled
        self.selected = selected
        self.focused = focused
        self.frame = frame
        self.actions = actions
        self.source = source
        self.depth = depth
        self.semanticKey = semanticKey
        self.lineText = lineText
    }
}

public struct CompactedUISnapshot: Equatable, Sendable {
    public let revision: Int
    public let bundleID: String
    public let pid: Int32
    public let width: Double
    public let height: Double
    public let source: UITreeSource
    public let isCanvasOnlyHint: Bool
    public let nodes: [CompactedUINode]
    public let text: String
    public let truncatedByLimit: Bool
    public let scopeNotFound: Bool

    public init(
        revision: Int,
        bundleID: String,
        pid: Int32,
        width: Double,
        height: Double,
        source: UITreeSource,
        isCanvasOnlyHint: Bool,
        nodes: [CompactedUINode],
        text: String,
        truncatedByLimit: Bool,
        scopeNotFound: Bool = false
    ) {
        self.revision = revision
        self.bundleID = bundleID
        self.pid = pid
        self.width = width
        self.height = height
        self.source = source
        self.isCanvasOnlyHint = isCanvasOnlyHint
        self.nodes = nodes
        self.text = text
        self.truncatedByLimit = truncatedByLimit
        self.scopeNotFound = scopeNotFound
    }

    public func node(forRef ref: String) -> CompactedUINode? {
        nodes.first(where: { $0.ref == ref })
    }
}
