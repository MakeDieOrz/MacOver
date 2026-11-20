//
//  PlaySettings.swift
//  PlayTools
//

import ObjectiveC
#if canImport(UIKit)
import UIKit
#endif

let settings = PlaySettings.shared

#if canImport(UIKit)
extension PlaySettings {
    static func tagInternalView(_ view: UIView) {
        if let keyPtr = UnsafeRawPointer(bitPattern: internalOverlayTagKeyAddress) {
            objc_setAssociatedObject(view, keyPtr, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
#endif
