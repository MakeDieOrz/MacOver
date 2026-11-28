import Foundation

public struct LogicalPoint: Equatable, Sendable, Codable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct LogicalViewport: Equatable, Sendable, Codable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum CoordinateMapperError: LocalizedError, Equatable, Sendable {
    case invalidViewport
    case outOfBounds(String)

    public var errorDescription: String? {
        switch self {
        case .invalidViewport:
            return "Viewport width and height must be positive finite numbers."
        case .outOfBounds(let detail):
            return "Coordinate out of bounds: \(detail)"
        }
    }
}

public enum CoordinateMapper {
    public static func resolvePoint(
        x: Double?,
        y: Double?,
        nx: Double?,
        ny: Double?,
        viewport: LogicalViewport
    ) throws -> LogicalPoint {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else {
            throw CoordinateMapperError.invalidViewport
        }
        if let nx, let ny {
            guard nx.isFinite, ny.isFinite, nx >= 0, nx <= 1, ny >= 0, ny <= 1 else {
                throw CoordinateMapperError.outOfBounds("normalized (\(nx), \(ny)) must be in 0...1")
            }
            return LogicalPoint(x: nx * viewport.width, y: ny * viewport.height)
        }
        if let x, let y {
            guard x.isFinite, y.isFinite, x >= 0, x <= viewport.width, y >= 0, y <= viewport.height else {
                throw CoordinateMapperError.outOfBounds(
                    "logical (\(x), \(y)) outside 0...\(viewport.width) x 0...\(viewport.height)"
                )
            }
            return LogicalPoint(x: x, y: y)
        }
        throw CoordinateMapperError.outOfBounds("Provide ref, (x, y), or (nx, ny).")
    }

    public static func centerPoint(
        of rect: UITreeRect,
        viewport: LogicalViewport
    ) throws -> LogicalPoint {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else {
            throw CoordinateMapperError.invalidViewport
        }
        guard !rect.isEmpty else {
            throw CoordinateMapperError.outOfBounds("Target node rect is empty.")
        }
        let cx = min(max(0, rect.centerX), viewport.width)
        let cy = min(max(0, rect.centerY), viewport.height)
        return LogicalPoint(x: cx, y: cy)
    }

    public static func normalizedRectToLogical(
        nx: Double,
        ny: Double,
        nw: Double,
        nh: Double,
        viewport: LogicalViewport
    ) throws -> UITreeRect {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else {
            throw CoordinateMapperError.invalidViewport
        }
        guard nx.isFinite, ny.isFinite, nw.isFinite, nh.isFinite,
              nx >= 0, ny >= 0, nw > 0, nh > 0, nx + nw <= 1.001, ny + nh <= 1.001 else {
            throw CoordinateMapperError.outOfBounds("clipNorm (\(nx), \(ny), \(nw), \(nh)) must lie within 0...1")
        }
        return UITreeRect(
            x: nx * viewport.width,
            y: ny * viewport.height,
            width: min(1.0 - nx, nw) * viewport.width,
            height: min(1.0 - ny, nh) * viewport.height
        )
    }
}
