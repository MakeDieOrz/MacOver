//
//  AssetsExtractor.swift
//  PlayCover
//
//  Created by 이승윤 on 2022/09/07.
//

import CoreGraphics
import Foundation

nonisolated struct AssetImage: CustomStringConvertible {
    let name: String
    let namedImages: [CUINamedImage]
    var description: String { name }
}

nonisolated enum AssetError: Error {
    case fileDoesNotExist
    case catalogInitFail
}

nonisolated struct AssetsExtractor {
    let catalog: CUICatalog

    var imagesList: [AssetImage] {
        var tmpArray = [AssetImage]()
        for imageName in self.catalog.allImageNames() {
            tmpArray.append(assetImage(from: imageName))
        }
        return tmpArray
    }

    init(appUrl url: URL) throws {
        let assetUrl = url.appendingPathComponent("Assets").appendingPathExtension("car")
        guard FileManager.default.fileExists(atPath: assetUrl.path) else {
            throw AssetError.fileDoesNotExist
        }
        do {
            catalog = try CUICatalog(url: assetUrl)
        } catch {
            throw AssetError.catalogInitFail
        }
    }

    func assetImage(from name: String) -> AssetImage {
        let images = self.catalog.images(withName: name)
        var namedImages = [CUINamedImage]()
        for item in images {
            if let image = item as? CUINamedImage {
                namedImages.append(image)
            }
        }
        return AssetImage(name: name, namedImages: namedImages)
    }

    func extractIcons(matching primaryIconName: String = "AppIcon") -> [NSImage] {
        var images = [NSImage]()
        for imageName in catalog.allImageNames() {
            guard imageName.contains("AppIcon")
                || (!primaryIconName.isEmpty && imageName.contains(primaryIconName)) else {
                continue
            }
            for item in catalog.images(withName: imageName) {
                guard let namedImage = item as? CUINamedImage,
                      let image = namedImage.asNSImage() else {
                    continue
                }
                images.append(image)
            }
        }
        return images
    }

    func extractBestIconCGImage(matching primaryIconName: String = "AppIcon", maxPixelSize: Int = 256) -> CGImage? {
        var bestCG: CGImage?
        var bestArea = 0
        for imageName in catalog.allImageNames() {
            guard imageName.contains("AppIcon")
                || (!primaryIconName.isEmpty && imageName.contains(primaryIconName)) else {
                continue
            }
            for item in catalog.images(withName: imageName) {
                guard let namedImage = item as? CUINamedImage,
                      let cgImage = namedImage._rendition().unslicedImage()?.takeUnretainedValue() else {
                    continue
                }
                let width = cgImage.width
                let height = cgImage.height
                guard width > 0, height > 0, width <= 4096, height <= 4096 else { continue }
                let area = width * height
                if area > bestArea {
                    bestArea = area
                    bestCG = cgImage
                }
            }
        }
        guard let bestCG else { return nil }
        return Self.renderDetachedCGImage(from: bestCG, maxPixelSize: maxPixelSize)
    }

    static func renderDetachedCGImage(from cgImage: CGImage, maxPixelSize: Int?) -> CGImage? {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > 0, srcH > 0, srcW <= 4096, srcH <= 4096 else {
            return nil
        }
        let targetW: Int
        let targetH: Int
        if let maxPixelSize, maxPixelSize > 0, max(srcW, srcH) > maxPixelSize {
            let scale = Double(maxPixelSize) / Double(max(srcW, srcH))
            targetW = max(1, Int((Double(srcW) * scale).rounded()))
            targetH = max(1, Int((Double(srcH) * scale).rounded()))
        } else {
            targetW = srcW
            targetH = srcH
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: targetW,
                  height: targetH,
                  bitsPerComponent: 8,
                  bytesPerRow: targetW * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage()
    }

}

nonisolated extension CUINamedImage {
    func asNSImage() -> NSImage? {
        guard let cgImage = self._rendition().unslicedImage()?.takeUnretainedValue(),
              let detachedCGImage = AssetsExtractor.renderDetachedCGImage(from: cgImage, maxPixelSize: nil) else {
            return nil
        }
        return NSImage(
            cgImage: detachedCGImage,
            size: NSSize(width: detachedCGImage.width, height: detachedCGImage.height)
        )
    }
}
