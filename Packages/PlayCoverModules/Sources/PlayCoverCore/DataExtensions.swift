//
//  DataExtensions.swift
//  PlayCover
//

import Foundation
import MachO

public extension String {
    init(data: Data, offset: Int, commandSize: Int, loadCommandString: lc_str) {
        let loadCommandStringOffset = Int(loadCommandString.offset)
        let stringOffset = offset + loadCommandStringOffset
        let length = commandSize - loadCommandStringOffset
        guard loadCommandStringOffset >= 0,
              length > 0,
              stringOffset >= data.startIndex,
              stringOffset <= data.endIndex,
              (data.endIndex - stringOffset) >= length else {
            self = ""
            return
        }
        let rawData = data[stringOffset..<(stringOffset + length)]
        let endIndex = rawData.firstIndex(of: 0x00) ?? rawData.endIndex
        self = String(data: data[stringOffset..<endIndex], encoding: .utf8) ?? ""
    }
}

public extension Data {
    func extract<T>(_ type: T.Type, offset: Int = 0,
                    swap: ((UnsafeMutablePointer<T>, NXByteOrder) -> Void)? = nil) throws -> T {
        let size = MemoryLayout<T>.size
        guard size >= 0,
              offset >= startIndex,
              offset <= endIndex,
              (endIndex - offset) >= size else {
            throw PlayCoverError.appCorrupted
        }
        return withUnsafeTemporaryAllocation(byteCount: size, alignment: MemoryLayout<T>.alignment) { rawBuf in
            _ = copyBytes(to: rawBuf, from: offset..<(offset + size))
            var result = rawBuf.load(as: T.self)
            swap?(&result, NXHostByteOrder())
            return result
        }
    }
}
