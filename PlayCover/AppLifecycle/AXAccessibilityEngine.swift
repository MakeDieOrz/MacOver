import ApplicationServices
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PlayCoverMCP
import ScreenCaptureKit
import UniformTypeIdentifiers

nonisolated enum AXBridgeError: LocalizedError, Sendable {
    case permissionDenied
    case noWindow(pid_t)
    case nodeNotFound(String)
    case actionFailed(String)
    case screenshotFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Accessibility permission is not granted for MacOver. Enable it in Settings -> MCP."
        case .noWindow(let pid):
            return "No accessible or visible window found for pid \(pid)."
        case .nodeNotFound(let id):
            return "AXUIElement handle not found for node \(id). Re-run macover_ui_snapshot."
        case .actionFailed(let detail):
            return "Accessibility action failed: \(detail)"
        case .screenshotFailed(let detail):
            return "Screenshot capture failed: \(detail)"
        }
    }
}

nonisolated struct EncodedScreenshotPayload: Sendable {
    let base64Data: String
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let logicalWidth: Double
    let logicalHeight: Double
}

nonisolated struct ScreenshotCaptureOptions: Sendable {
    let clipRect: UITreeRect?
    let maxDim: Int
    let format: String
    let quality: Double
    let overlayNodes: [CompactedUINode]
}

actor AXAccessibilityEngine {
    private var elementCache: [String: [String: AXUIElement]] = [:]

    static nonisolated func isProcessTrusted(prompt: Bool = false) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func clearCache(for bundleID: String) {
        elementCache.removeValue(forKey: bundleID)
    }

    func captureTree(
        pid: pid_t,
        bundleID: String,
        maxDepth: Int = 12,
        maxNodes: Int = 500
    ) throws -> RawUITreeSnapshot {
        guard Self.isProcessTrusted(prompt: false) else {
            throw AXBridgeError.permissionDenied
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        var windows = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if windows.isEmpty,
           let focused = copyElementAttribute(appElement, kAXFocusedWindowAttribute) {
            windows = [focused]
        }
        guard !windows.isEmpty else {
            throw AXBridgeError.noWindow(pid)
        }

        let primaryWindow = copyElementAttribute(appElement, kAXMainWindowAttribute)
            ?? copyElementAttribute(appElement, kAXFocusedWindowAttribute)
            ?? windows[0]
        let winFrame = readFrame(primaryWindow) ?? UITreeRect(x: 0, y: 0, width: 1280, height: 800)
        var context = TreeBuildContext(maxDepth: maxDepth, maxNodes: maxNodes)

        var rootChildren: [UITreeNode] = []
        rootChildren.reserveCapacity(windows.count)
        for window in windows {
            let originFrame = readFrame(window) ?? winFrame
            if let built = buildNode(window, depth: 0, originFrame: originFrame, context: &context) {
                rootChildren.append(built)
            }
        }
        elementCache[bundleID] = context.nodeMap

        let rootNode: UITreeNode
        if rootChildren.count == 1, let single = rootChildren.first {
            rootNode = single
        } else {
            rootNode = UITreeNode(
                id: "ax-app-root",
                role: "AXWindow",
                label: bundleID,
                frame: UITreeRect(x: 0, y: 0, width: winFrame.width, height: winFrame.height),
                children: rootChildren
            )
        }

        return RawUITreeSnapshot(
            bundleID: bundleID,
            pid: pid,
            width: max(1, winFrame.width),
            height: max(1, winFrame.height),
            source: .ax,
            isCanvasOnlyHint: !context.hasInteractive && winFrame.width > 100 && winFrame.height > 100,
            root: rootNode
        )
    }

    private nonisolated struct AXElementKey: Hashable {
        let element: AXUIElement

        func hash(into hasher: inout Hasher) {
            hasher.combine(CFHash(element))
        }

        static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
            CFEqual(lhs.element, rhs.element)
        }
    }

    private struct TreeBuildContext {
        let maxDepth: Int
        let maxNodes: Int
        var nodeMap: [String: AXUIElement] = [:]
        var visitedElements = Set<AXElementKey>()
        var nodeCounter = 0
        var hasInteractive = false
    }

    private func buildNode(
        _ element: AXUIElement,
        depth: Int,
        originFrame: UITreeRect,
        context: inout TreeBuildContext
    ) -> UITreeNode? {
        if depth > context.maxDepth || context.nodeCounter >= context.maxNodes {
            return nil
        }
        let key = AXElementKey(element: element)
        if context.visitedElements.contains(key) {
            return nil
        }
        context.visitedElements.insert(key)

        context.nodeCounter += 1
        let nodeID = "ax-\(context.nodeCounter)"
        context.nodeMap[nodeID] = element

        let rawRole = (copyAttribute(element, kAXRoleAttribute) as? String) ?? "AXGroup"
        let subrole = copyAttribute(element, kAXSubroleAttribute) as? String
        let title = copyAttribute(element, kAXTitleAttribute) as? String
        let desc = copyAttribute(element, kAXDescriptionAttribute) as? String
        let label = (title?.isEmpty == false ? title : desc)
        let valueStr = stringifyValue(copyAttribute(element, kAXValueAttribute))
        let identifier = copyAttribute(element, kAXIdentifierAttribute) as? String
        let enabled = (copyAttribute(element, kAXEnabledAttribute) as? Bool) ?? true
        let selected = (copyAttribute(element, kAXSelectedAttribute) as? Bool) ?? false
        let focused = (copyAttribute(element, kAXFocusedAttribute) as? Bool) ?? false
        let absFrame = readFrame(element) ?? UITreeRect(x: 0, y: 0, width: 0, height: 0)
        let relFrame = UITreeRect(
            x: absFrame.x - originFrame.x,
            y: absFrame.y - originFrame.y,
            width: absFrame.width,
            height: absFrame.height
        )
        let actions = copyActions(element)
        let interactive = isInteractiveAX(role: rawRole, actions: actions)
        if interactive {
            context.hasInteractive = true
        }
        let isList = rawRole == kAXListRole || rawRole == kAXTableRole || rawRole == kAXOutlineRole

        let axChildren = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var children: [UITreeNode] = []
        children.reserveCapacity(axChildren.count)
        for child in axChildren {
            if context.nodeCounter >= context.maxNodes { break }
            if let built = buildNode(child, depth: depth + 1, originFrame: originFrame, context: &context) {
                children.append(built)
            }
        }

        return UITreeNode(
            id: nodeID,
            role: rawRole,
            subrole: subrole,
            label: label,
            value: valueStr,
            identifier: identifier,
            enabled: enabled,
            selected: selected,
            focused: focused,
            hidden: false,
            alpha: 1.0,
            frame: relFrame,
            actions: actions,
            isInteractive: interactive,
            isListContainer: isList,
            isCanvas: false,
            children: children
        )
    }

    func performAction(
        bundleID: String,
        nodeID: String,
        action: String,
        text: String?,
        clear: Bool
    ) throws {
        guard let element = elementCache[bundleID]?[nodeID] else {
            throw AXBridgeError.nodeNotFound(nodeID)
        }
        AXUIElementSetMessagingTimeout(element, 1.0)

        switch action {
        case "press":
            try performAXAction(element, name: kAXPressAction as CFString)
        case "increment":
            try performAXAction(element, name: kAXIncrementAction as CFString)
        case "decrement":
            try performAXAction(element, name: kAXDecrementAction as CFString)
        case "menu":
            try performAXAction(element, name: kAXShowMenuAction as CFString)
        case "scroll_to":
            try performAXAction(element, name: "AXScrollToVisible" as CFString)
        case "set_value", "input":
            let nextText = text ?? ""
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let finalText: String
            if action == "input" && !clear,
               let existing = stringifyValue(copyAttribute(element, kAXValueAttribute)),
               !existing.isEmpty {
                finalText = existing + nextText
            } else {
                finalText = nextText
            }
            let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, finalText as CFString)
            if err != .success {
                throw AXBridgeError.actionFailed("AXSetValue returned \(err.rawValue)")
            }
        default:
            throw AXBridgeError.actionFailed("Unsupported AX action '\(action)' (use bridge for touch gestures)")
        }
    }

    func captureWindowScreenshot(
        pid: pid_t,
        options: ScreenshotCaptureOptions
    ) async throws -> EncodedScreenshotPayload {
        let clipRect = options.clipRect
        let maxDim = options.maxDim
        let format = options.format
        let quality = options.quality
        let overlayNodes = options.overlayNodes
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let matchingWindows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.frame.width > 20 && $0.frame.height > 20
        }
        let primaryLayerWindows = matchingWindows.filter { $0.windowLayer == 0 }
        let candidatePool = primaryLayerWindows.isEmpty ? matchingWindows : primaryLayerWindows
        guard let targetWindow = candidatePool.max(by: { lhs, rhs in
            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            if lhsArea != rhsArea {
                return lhsArea < rhsArea
            }
            return !lhs.isActive && rhs.isActive
        }) else {
            throw AXBridgeError.noWindow(pid)
        }

        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let config = SCStreamConfiguration()
        config.scalesToFit = true
        let winSize = targetWindow.frame.size
        config.width = max(1, Int(winSize.width.rounded()))
        config.height = max(1, Int(winSize.height.rounded()))
        config.showsCursor = false

        var image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        if !overlayNodes.isEmpty {
            image = Self.drawOverlay(on: image, nodes: overlayNodes, logicalSize: winSize) ?? image
        }

        if let clipRect {
            let scaleX = Double(image.width) / max(1.0, winSize.width)
            let scaleY = Double(image.height) / max(1.0, winSize.height)
            let cropBounds = CGRect(
                x: clipRect.x * scaleX,
                y: clipRect.y * scaleY,
                width: clipRect.width * scaleX,
                height: clipRect.height * scaleY
            ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !cropBounds.isNull, cropBounds.width >= 2, cropBounds.height >= 2,
                  let cropped = image.cropping(to: cropBounds) else {
                throw AXBridgeError.screenshotFailed("Requested clipRect lies outside captured window bounds")
            }
            image = cropped
        }

        let boundedMaxDim = max(128, min(2048, maxDim))
        let maxSide = max(image.width, image.height)
        if maxSide > boundedMaxDim {
            let ratio = Double(boundedMaxDim) / Double(maxSide)
            let targetW = max(1, Int((Double(image.width) * ratio).rounded()))
            let targetH = max(1, Int((Double(image.height) * ratio).rounded()))
            if let resized = Self.resize(image: image, width: targetW, height: targetH) {
                image = resized
            }
        }

        let isPNG = format.lowercased() == "png"
        let utType = isPNG ? UTType.png.identifier : UTType.jpeg.identifier
        let mimeType = isPNG ? "image/png" : "image/jpeg"
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, utType as CFString, 1, nil) else {
            throw AXBridgeError.screenshotFailed("Failed to create CGImageDestination")
        }
        let clampedQuality = min(1.0, max(0.2, quality))
        let options: [CFString: Any] = isPNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: clampedQuality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw AXBridgeError.screenshotFailed("Failed to finalize image encoding")
        }

        return EncodedScreenshotPayload(
            base64Data: (outData as Data).base64EncodedString(),
            mimeType: mimeType,
            pixelWidth: image.width,
            pixelHeight: image.height,
            logicalWidth: winSize.width,
            logicalHeight: winSize.height
        )
    }

    private func performAXAction(_ element: AXUIElement, name: CFString) throws {
        let err = AXUIElementPerformAction(element, name)
        if err != .success {
            throw AXBridgeError.actionFailed("AXPerformAction(\(name)) returned \(err.rawValue)")
        }
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private func copyActions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else {
            return []
        }
        return list
    }

    private func readFrame(_ element: AXUIElement) -> UITreeRect? {
        guard let posVal = copyAttribute(element, kAXPositionAttribute),
              let sizeVal = copyAttribute(element, kAXSizeAttribute),
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        let posAX = unsafeDowncast(posVal, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeVal, to: AXValue.self)
        guard AXValueGetValue(posAX, .cgPoint, &point),
              AXValueGetValue(sizeAX, .cgSize, &size) else {
            return nil
        }
        return UITreeRect(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private func stringifyValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let str = value as? String {
            return str
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue ? "1" : "0"
            }
            return num.stringValue
        }
        return nil
    }

    private func isInteractiveAX(role: String, actions: [String]) -> Bool {
        if actions.contains(kAXPressAction)
            || actions.contains(kAXIncrementAction)
            || actions.contains(kAXDecrementAction)
            || actions.contains(kAXShowMenuAction) {
            return true
        }
        switch role {
        case kAXButtonRole, kAXTextFieldRole, "AXSearchField", kAXTextAreaRole,
             kAXCheckBoxRole, "AXSwitch", kAXSliderRole, kAXPopUpButtonRole,
             kAXRadioButtonRole, "AXLink", kAXMenuItemRole, "AXTab":
            return true
        default:
            return false
        }
    }

    private static func resize(image: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func drawOverlay(
        on image: CGImage,
        nodes: [CompactedUINode],
        logicalSize: CGSize
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scaleX = Double(width) / max(1.0, logicalSize.width)
        let scaleY = Double(height) / max(1.0, logicalSize.height)
        ctx.setLineWidth(2.0)

        for node in nodes.prefix(40) where !node.frame.isEmpty {
            let flippedY = Double(height) - (node.frame.y + node.frame.height) * scaleY
            let rect = CGRect(
                x: node.frame.x * scaleX,
                y: flippedY,
                width: node.frame.width * scaleX,
                height: node.frame.height * scaleY
            )
            ctx.setStrokeColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 0.9)
            ctx.stroke(rect)

            let badgeRect = CGRect(x: rect.minX, y: max(2, rect.maxY - 18), width: 42, height: 18)
            ctx.setFillColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 0.9)
            ctx.fill(badgeRect)

            let font = CTFontCreateWithName("Menlo-Bold" as CFString, 11, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    red: 1, green: 1, blue: 1, alpha: 1
                )
            ]
            let attrStr = CFAttributedStringCreate(nil, node.ref as CFString, attrs as CFDictionary)
            if let attrStr {
                let line = CTLineCreateWithAttributedString(attrStr)
                ctx.textPosition = CGPoint(x: badgeRect.minX + 4, y: badgeRect.minY + 4)
                CTLineDraw(line, ctx)
            }
        }
        return ctx.makeImage()
    }
}
