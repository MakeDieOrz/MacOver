//
//  AssetsExtractor.swift
//  PlayCover
//
//  Created by 이승윤 on 2022/09/07.
//

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

    func extractIcons() -> [NSImage] {
        var images = [NSImage]()
        for assetImage in imagesList where assetImage.name.contains("AppIcon") {
            for namedImage in assetImage.namedImages {
                guard let image = namedImage.asNSImage() else { continue }
                images.append(image)
            }
        }
        return images
    }

}

nonisolated extension CUINamedImage {
    func asNSImage() -> NSImage? {
        guard let cgImage = self._rendition().unslicedImage()?.takeUnretainedValue() else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, width <= 4096, height <= 4096 else {
            return nil
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let detachedCGImage = ctx.makeImage() else {
            return nil
        }
        return NSImage(cgImage: detachedCGImage, size: NSSize(width: width, height: height))
    }
}
