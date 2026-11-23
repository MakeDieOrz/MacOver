//
//  InlineSyscallPatcher.swift
//  PlayCoverMachO
//

import CryptoKit
import Foundation
import MachO
import PlayCoverCore

public struct SVCPatchSite: Codable, Equatable, Sendable {
    public let sliceOffset: UInt64
    public let fileOffset: UInt64
    public let vmAddress: UInt64
    public let vmOffset: UInt64

    public init(sliceOffset: UInt64, fileOffset: UInt64, vmAddress: UInt64, vmOffset: UInt64) {
        self.sliceOffset = sliceOffset
        self.fileOffset = fileOffset
        self.vmAddress = vmAddress
        self.vmOffset = vmOffset
    }
}

public struct SVCPatchedFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let originalSHA256: String
    public let patchedSHA256: String
    public let sites: [SVCPatchSite]

    public init(relativePath: String, originalSHA256: String, patchedSHA256: String, sites: [SVCPatchSite]) {
        self.relativePath = relativePath
        self.originalSHA256 = originalSHA256
        self.patchedSHA256 = patchedSHA256
        self.sites = sites
    }
}

public struct SVCPatchManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let bundleIdentifier: String
    public let originalInstruction: UInt32
    public let patchInstruction: UInt32
    public let files: [SVCPatchedFile]

    public init(
        schemaVersion: Int = SVCPatchManifest.currentSchemaVersion,
        bundleIdentifier: String,
        originalInstruction: UInt32 = InlineSyscallPatcher.svcInstruction,
        patchInstruction: UInt32 = InlineSyscallPatcher.brkInstruction,
        files: [SVCPatchedFile]
    ) {
        self.schemaVersion = schemaVersion
        self.bundleIdentifier = bundleIdentifier
        self.originalInstruction = originalInstruction
        self.patchInstruction = patchInstruction
        self.files = files
    }
}

public enum InlineSyscallPatcher {
    public static let svcInstruction: UInt32 = 0xD400_1001
    public static let brkInstruction: UInt32 = 0xD42A_0E80

    public struct ReconcileResult: Equatable, Sendable {
        public let modified: Bool
        public let modifiedBinaryURLs: [URL]
        public let patchedSiteCount: Int

        public init(modified: Bool, modifiedBinaryURLs: [URL], patchedSiteCount: Int) {
            self.modified = modified
            self.modifiedBinaryURLs = modifiedBinaryURLs
            self.patchedSiteCount = patchedSiteCount
        }
    }

    private struct InstructionSection {
        let fileStart: UInt64
        let fileEnd: UInt64
        let vmAddress: UInt64
    }

    private static let excludedBundleComponents: Set<String> = [
        "PlayTools.framework",
        "AKInterface.bundle",
        "UserPlugins",
        "_CodeSignature"
    ]

    public static func reconcile(
        appBundleURL: URL,
        bundleIdentifier: String,
        manifestURL: URL,
        enabled: Bool
    ) throws -> ReconcileResult {
        if enabled {
            return try applyPatches(
                appBundleURL: appBundleURL,
                bundleIdentifier: bundleIdentifier,
                manifestURL: manifestURL
            )
        }
        return try revertPatches(appBundleURL: appBundleURL, manifestURL: manifestURL)
    }

    private static func applyPatches(
        appBundleURL: URL,
        bundleIdentifier: String,
        manifestURL: URL
    ) throws -> ReconcileResult {
        let existingManifest = try loadValidManifestIfPresent(at: manifestURL)
        let candidateFiles = try collectCandidateMachOFiles(in: appBundleURL)
        var existingByPath: [String: SVCPatchedFile] = [:]
        if let existingManifest, existingManifest.bundleIdentifier == bundleIdentifier {
            for entry in existingManifest.files {
                existingByPath[entry.relativePath] = entry
            }
        }

        // Fast idempotency check: every manifest file already holds brkInstruction at its sites,
        // and no candidate Mach-O has remaining unpatched svcInstruction sites.
        if let existingManifest,
           existingManifest.bundleIdentifier == bundleIdentifier,
           try isBundleAlreadyPatched(
               appBundleURL: appBundleURL,
               candidateFiles: candidateFiles,
               manifest: existingManifest,
               existingByPath: existingByPath
           ) {
            let totalSites = existingManifest.files.reduce(0) { $0 + $1.sites.count }
            return ReconcileResult(modified: false, modifiedBinaryURLs: [], patchedSiteCount: totalSites)
        }

        var nextEntries: [SVCPatchedFile] = []
        var modifiedURLs: [URL] = []

        for candidate in candidateFiles {
            var data = try Data(contentsOf: candidate.url)
            let existingEntry = existingByPath[candidate.relativePath]
            let newSites = try scanInstructionSites(in: data, matching: svcInstruction)

            if let existingEntry, !existingEntry.sites.isEmpty,
               verifyAllSites(in: data, sites: existingEntry.sites, expectedWord: brkInstruction) {
                if newSites.isEmpty {
                    nextEntries.append(existingEntry)
                    continue
                }
                // Edge case: binary previously patched at existingEntry.sites and somehow acquired additional sites
                // without invalidating those sites; revert known sites first so originalSHA256 is clean.
                try writeWord(svcInstruction, to: &data, sites: existingEntry.sites)
                let combinedSites = (existingEntry.sites + newSites)
                    .sorted { $0.fileOffset < $1.fileOffset }
                let origSHA = sha256Hex(data)
                try writeWord(brkInstruction, to: &data, sites: combinedSites)
                let patchedSHA = sha256Hex(data)
                try writeAtomicPreservingPermissions(data, to: candidate.url)
                modifiedURLs.append(candidate.url)
                nextEntries.append(SVCPatchedFile(
                    relativePath: candidate.relativePath,
                    originalSHA256: origSHA,
                    patchedSHA256: patchedSHA,
                    sites: combinedSites
                ))
                continue
            }

            guard !newSites.isEmpty else {
                continue
            }

            let originalSHA = sha256Hex(data)
            try writeWord(brkInstruction, to: &data, sites: newSites)
            let patchedSHA = sha256Hex(data)
            try writeAtomicPreservingPermissions(data, to: candidate.url)
            modifiedURLs.append(candidate.url)
            nextEntries.append(SVCPatchedFile(
                relativePath: candidate.relativePath,
                originalSHA256: originalSHA,
                patchedSHA256: patchedSHA,
                sites: newSites
            ))
        }

        if nextEntries.isEmpty {
            try removeManifestIfExists(at: manifestURL)
            return ReconcileResult(
                modified: !modifiedURLs.isEmpty,
                modifiedBinaryURLs: modifiedURLs,
                patchedSiteCount: 0
            )
        }

        let updatedManifest = SVCPatchManifest(
            bundleIdentifier: bundleIdentifier,
            files: nextEntries.sorted { $0.relativePath < $1.relativePath }
        )
        if existingManifest != updatedManifest {
            try writeManifest(updatedManifest, to: manifestURL)
        }
        let totalSites = updatedManifest.files.reduce(0) { $0 + $1.sites.count }
        return ReconcileResult(
            modified: !modifiedURLs.isEmpty,
            modifiedBinaryURLs: modifiedURLs,
            patchedSiteCount: totalSites
        )
    }

    private static func revertPatches(
        appBundleURL: URL,
        manifestURL: URL
    ) throws -> ReconcileResult {
        guard let manifest = try loadValidManifestIfPresent(at: manifestURL) else {
            return ReconcileResult(modified: false, modifiedBinaryURLs: [], patchedSiteCount: 0)
        }

        var modifiedURLs: [URL] = []
        let origWord = manifest.originalInstruction
        let patchWord = manifest.patchInstruction

        for fileEntry in manifest.files {
            guard !fileEntry.sites.isEmpty,
                  let targetURL = resolveSafeBundleChildURL(
                      appBundleURL: appBundleURL,
                      relativePath: fileEntry.relativePath
                  ),
                  let isRegular = try? isRegularNonSymlinkFile(at: targetURL),
                  isRegular else {
                continue
            }

            var data = try Data(contentsOf: targetURL)
            let currentSHA = sha256Hex(data)
            if currentSHA == fileEntry.originalSHA256 {
                continue
            }

            let allPatched = verifyAllSites(in: data, sites: fileEntry.sites, expectedWord: patchWord)
            if !allPatched {
                if currentSHA == fileEntry.patchedSHA256 ||
                    verifyAllSites(in: data, sites: fileEntry.sites, expectedWord: origWord) {
                    continue
                }
                // Mixed partial/re-signed check: only revert sites that still hold patchWord when every remaining
                // site holds origWord so we never corrupt an unrelated updated binary.
                guard verifySitesInSet(
                    in: data,
                    sites: fileEntry.sites,
                    allowedA: patchWord,
                    allowedB: origWord
                ), hasAnySite(in: data, sites: fileEntry.sites, expectedWord: patchWord) else {
                    continue
                }
            }

            try writeWord(origWord, to: &data, sites: fileEntry.sites)
            try writeAtomicPreservingPermissions(data, to: targetURL)
            modifiedURLs.append(targetURL)
        }

        try removeManifestIfExists(at: manifestURL)
        return ReconcileResult(
            modified: !modifiedURLs.isEmpty,
            modifiedBinaryURLs: modifiedURLs,
            patchedSiteCount: 0
        )
    }

    private static func isBundleAlreadyPatched(
        appBundleURL: URL,
        candidateFiles: [(relativePath: String, url: URL)],
        manifest: SVCPatchManifest,
        existingByPath: [String: SVCPatchedFile]
    ) throws -> Bool {
        let candidatesByPath = Dictionary(uniqueKeysWithValues: candidateFiles.map { ($0.relativePath, $0.url) })
        for entry in manifest.files {
            guard let targetURL = candidatesByPath[entry.relativePath] ??
                resolveSafeBundleChildURL(appBundleURL: appBundleURL, relativePath: entry.relativePath),
                let isRegular = try? isRegularNonSymlinkFile(at: targetURL),
                isRegular else {
                return false
            }
            let data = try Data(contentsOf: targetURL, options: .mappedIfSafe)
            guard verifyAllSites(in: data, sites: entry.sites, expectedWord: manifest.patchInstruction) else {
                return false
            }
        }
        for candidate in candidateFiles {
            let data = try Data(contentsOf: candidate.url, options: .mappedIfSafe)
            let unpatched = try scanInstructionSites(in: data, matching: svcInstruction)
            if !unpatched.isEmpty {
                return false
            }
            if existingByPath[candidate.relativePath] == nil && !unpatched.isEmpty {
                return false
            }
        }
        return true
    }

    // MARK: - Bundle Enumeration

    private static func collectCandidateMachOFiles(
        in appBundleURL: URL
    ) throws -> [(relativePath: String, url: URL)] {
        let resolvedBundleURL = appBundleURL.standardizedFileURL.resolvingSymlinksInPath()
        var found: [String: URL] = [:]

        if let mainExecURL = resolveMainExecutableURL(in: resolvedBundleURL),
           try isRegularNonSymlinkFile(at: mainExecURL),
           hasMachOMagicPrefix(at: mainExecURL),
           let rel = relativePath(of: mainExecURL, from: resolvedBundleURL) {
            found[rel] = mainExecURL
        }

        let scanRoots = [
            resolvedBundleURL.appendingPathComponent("Frameworks", isDirectory: true),
            resolvedBundleURL.appendingPathComponent("PlugIns", isDirectory: true),
            resolvedBundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true),
            resolvedBundleURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        ]

        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]

        for root in scanRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
                  (try? !isSymbolicLink(at: root)) ?? false else {
                continue
            }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            while let item = enumerator.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: resourceKeys)
                if values?.isSymbolicLink == true {
                    if values?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if excludedBundleComponents.contains(item.lastPathComponent) {
                    if values?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values?.isRegularFile == true else {
                    continue
                }
                guard let rel = relativePath(of: item, from: resolvedBundleURL),
                      !pathContainsExcludedComponent(rel),
                      hasMachOMagicPrefix(at: item) else {
                    continue
                }
                found[rel] = item
            }
        }

        return found.keys.sorted().compactMap { key in
            found[key].map { (relativePath: key, url: $0) }
        }
    }

    private static func resolveMainExecutableURL(in bundleURL: URL) -> URL? {
        let directInfo = bundleURL.appendingPathComponent("Info.plist")
        let contentsInfo = bundleURL.appendingPathComponent("Contents/Info.plist")
        for (plistURL, execBase) in [(directInfo, bundleURL),
                                     (contentsInfo, bundleURL.appendingPathComponent("Contents/MacOS"))] {
            if let dict = NSDictionary(contentsOf: plistURL),
               let name = dict["CFBundleExecutable"] as? String,
               !name.isEmpty,
               !name.contains("..") {
                return execBase.appendingPathComponent(name)
            }
        }
        if let bundle = Bundle(url: bundleURL), let execURL = bundle.executableURL {
            return execURL
        }
        return nil
    }

    private static func relativePath(of url: URL, from rootURL: URL) -> String? {
        let rootComps = rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let childComps = url.standardizedFileURL.pathComponents
        guard childComps.count > rootComps.count,
              Array(childComps.prefix(rootComps.count)) == rootComps else {
            return nil
        }
        return childComps.dropFirst(rootComps.count).joined(separator: "/")
    }

    private static func resolveSafeBundleChildURL(appBundleURL: URL, relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/") else {
            return nil
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              !parts.contains("."),
              !parts.contains(".."),
              !parts.contains(where: { excludedBundleComponents.contains(String($0)) }) else {
            return nil
        }
        let resolvedRoot = appBundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = parts.reduce(resolvedRoot) { acc, part in
            acc.appendingPathComponent(String(part), isDirectory: false)
        }
        guard self.relativePath(of: candidate, from: resolvedRoot) == relativePath else {
            return nil
        }
        return candidate
    }

    private static func pathContainsExcludedComponent(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { excludedBundleComponents.contains(String($0)) }
    }

    private static func isSymbolicLink(at url: URL) throws -> Bool {
        let vals = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return vals.isSymbolicLink == true
    }

    private static func isRegularNonSymlinkFile(at url: URL) throws -> Bool {
        let vals = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return vals.isSymbolicLink != true && vals.isRegularFile == true
    }

    private static func hasMachOMagicPrefix(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4), prefix.count == 4 else {
            return false
        }
        let leWord = loadUInt32LE(from: prefix, at: 0)
        if leWord == MH_MAGIC_64 {
            return true
        }
        let beWord = loadUInt32BE(from: prefix, at: 0)
        return beWord == FAT_MAGIC || beWord == FAT_MAGIC_64
    }

    // MARK: - Mach-O Parsing & Instruction Scanning

    private static func scanInstructionSites(in data: Data, matching targetWord: UInt32) throws -> [SVCPatchSite] {
        guard data.count >= MemoryLayout<mach_header_64>.size else {
            return []
        }

        let slices = try arm64Slices(in: data)
        guard !slices.isEmpty else {
            return []
        }

        var sites: [SVCPatchSite] = []
        for slice in slices {
            try scanSlice(
                in: data,
                sliceOffset: slice.offset,
                sliceSize: slice.size,
                matching: targetWord,
                into: &sites
            )
        }
        return sites
    }

    private static func arm64Slices(in data: Data) throws -> [(offset: UInt64, size: UInt64)] {
        guard data.count >= 4 else { return [] }
        let leMagic = loadUInt32LE(from: data, at: 0)
        if leMagic == MH_MAGIC_64 {
            return [(0, UInt64(data.count))]
        }

        let beMagic = loadUInt32BE(from: data, at: 0)
        guard beMagic == FAT_MAGIC || beMagic == FAT_MAGIC_64 else {
            return []
        }

        guard let header = loadStruct(fat_header.self, from: data, at: 0) else {
            return []
        }
        let nfat = Int(UInt32(bigEndian: header.nfat_arch))
        guard nfat > 0, nfat <= 64 else {
            return []
        }

        let isFat64 = (beMagic == FAT_MAGIC_64)
        let archStride = isFat64 ? MemoryLayout<fat_arch_64>.size : MemoryLayout<fat_arch>.size
        let tableStart = MemoryLayout<fat_header>.size
        guard tableStart + nfat * archStride <= data.count else {
            return []
        }

        var result: [(offset: UInt64, size: UInt64)] = []
        for idx in 0..<nfat {
            let entryOffset = tableStart + idx * archStride
            let cpu: Int32
            let sliceOff: UInt64
            let sliceSz: UInt64
            if isFat64 {
                guard let arch = loadStruct(fat_arch_64.self, from: data, at: entryOffset) else {
                    return []
                }
                cpu = Int32(bitPattern: UInt32(bigEndian: UInt32(bitPattern: arch.cputype)))
                sliceOff = UInt64(bigEndian: arch.offset)
                sliceSz = UInt64(bigEndian: arch.size)
            } else {
                guard let arch = loadStruct(fat_arch.self, from: data, at: entryOffset) else {
                    return []
                }
                cpu = Int32(bitPattern: UInt32(bigEndian: UInt32(bitPattern: arch.cputype)))
                sliceOff = UInt64(UInt32(bigEndian: arch.offset))
                sliceSz = UInt64(UInt32(bigEndian: arch.size))
            }

            guard cpu == CPU_TYPE_ARM64,
                  sliceSz >= UInt64(MemoryLayout<mach_header_64>.size),
                  sliceOff <= UInt64(data.count),
                  sliceSz <= UInt64(data.count) - sliceOff else {
                continue
            }
            if loadUInt32LE(from: data, at: Int(sliceOff)) == MH_MAGIC_64 {
                result.append((sliceOff, sliceSz))
            }
        }
        return result
    }

    private static func scanSlice(
        in data: Data,
        sliceOffset: UInt64,
        sliceSize: UInt64,
        matching targetWord: UInt32,
        into sites: inout [SVCPatchSite]
    ) throws {
        guard sliceOffset + UInt64(MemoryLayout<mach_header_64>.size) <= UInt64(data.count),
              let mh = loadStruct(mach_header_64.self, from: data, at: Int(sliceOffset)),
              mh.magic == MH_MAGIC_64,
              mh.cputype == CPU_TYPE_ARM64 else {
            return
        }

        let headerSize = UInt64(MemoryLayout<mach_header_64>.size)
        let cmdsEnd = sliceOffset + headerSize + UInt64(mh.sizeofcmds)
        let sliceEnd = sliceOffset + sliceSize
        guard cmdsEnd <= sliceEnd, cmdsEnd <= UInt64(data.count) else {
            return
        }

        var textSegmentVMAddr: UInt64?
        var sections: [InstructionSection] = []
        var rawDataInCodeRanges: [Range<UInt64>] = []

        var cmdOffset = sliceOffset + headerSize
        for _ in 0..<mh.ncmds {
            guard cmdOffset + UInt64(MemoryLayout<load_command>.size) <= cmdsEnd,
                  let lc = loadStruct(load_command.self, from: data, at: Int(cmdOffset)),
                  lc.cmdsize >= UInt32(MemoryLayout<load_command>.size),
                  cmdOffset + UInt64(lc.cmdsize) <= cmdsEnd else {
                break
            }

            if lc.cmd == UInt32(LC_SEGMENT_64),
               lc.cmdsize >= UInt32(MemoryLayout<segment_command_64>.size),
               let seg = loadStruct(segment_command_64.self, from: data, at: Int(cmdOffset)) {
                let segName = extractSegmentName(seg.segname)
                if segName == "__TEXT" {
                    textSegmentVMAddr = seg.vmaddr
                }

                let sectHeaderSize = UInt64(MemoryLayout<section_64>.size)
                var sectOffset = cmdOffset + UInt64(MemoryLayout<segment_command_64>.size)
                let segCmdEnd = cmdOffset + UInt64(lc.cmdsize)
                for _ in 0..<seg.nsects {
                    guard sectOffset + sectHeaderSize <= segCmdEnd,
                          let sec = loadStruct(section_64.self, from: data, at: Int(sectOffset)) else {
                        break
                    }
                    sectOffset += sectHeaderSize

                    let sectionType = sec.flags & UInt32(SECTION_TYPE)
                    let isZerofill = (sectionType == UInt32(S_ZEROFILL) || sectionType == UInt32(S_GB_ZEROFILL))
                    let instrMask = UInt32(S_ATTR_PURE_INSTRUCTIONS) | UInt32(S_ATTR_SOME_INSTRUCTIONS)
                    guard !isZerofill,
                          (sec.flags & instrMask) != 0,
                          sec.offset > 0,
                          sec.size >= 4 else {
                        continue
                    }

                    let fileStart = sliceOffset + UInt64(sec.offset)
                    guard fileStart <= sliceEnd,
                          sec.size <= sliceEnd - fileStart else {
                        continue
                    }
                    sections.append(InstructionSection(
                        fileStart: fileStart,
                        fileEnd: fileStart + sec.size,
                        vmAddress: sec.addr
                    ))
                }
            } else if lc.cmd == UInt32(LC_DATA_IN_CODE),
                      lc.cmdsize >= UInt32(MemoryLayout<linkedit_data_command>.size),
                      let dic = loadStruct(linkedit_data_command.self, from: data, at: Int(cmdOffset)) {
                let entrySize = UInt64(MemoryLayout<data_in_code_entry>.size)
                let tableStart = sliceOffset + UInt64(dic.dataoff)
                let tableSize = UInt64(dic.datasize)
                if tableSize >= entrySize,
                   tableStart <= sliceEnd,
                   tableSize <= sliceEnd - tableStart {
                    let count = tableSize / entrySize
                    for i in 0..<count {
                        let off = Int(tableStart + i * entrySize)
                        guard let entry = loadStruct(data_in_code_entry.self, from: data, at: off),
                              entry.length > 0 else {
                            continue
                        }
                        let rangeStart = sliceOffset + UInt64(entry.offset)
                        let rangeEnd = rangeStart + UInt64(entry.length)
                        if rangeStart < sliceEnd {
                            rawDataInCodeRanges.append(rangeStart..<min(rangeEnd, sliceEnd))
                        }
                    }
                }
            }

            cmdOffset += UInt64(lc.cmdsize)
        }

        let baseTextVMAddr = textSegmentVMAddr ?? 0
        let mergedDIC = mergeSortedRanges(rawDataInCodeRanges)
        let sortedSections = sections.sorted { $0.fileStart < $1.fileStart }

        var dicIndex = 0
        for section in sortedSections {
            let alignRem = section.fileStart & 3
            var cursor = alignRem == 0 ? section.fileStart : (section.fileStart + (4 - alignRem))
            guard cursor + 4 <= section.fileEnd else {
                continue
            }

            data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
                while cursor + 4 <= section.fileEnd {
                    while dicIndex < mergedDIC.count && mergedDIC[dicIndex].upperBound <= cursor {
                        dicIndex += 1
                    }
                    if dicIndex < mergedDIC.count &&
                        cursor + 4 > mergedDIC[dicIndex].lowerBound &&
                        cursor < mergedDIC[dicIndex].upperBound {
                        cursor += 4
                        continue
                    }

                    let byteOffset = Int(cursor)
                    let word = UInt32(littleEndian: base.advanced(by: byteOffset).loadUnaligned(as: UInt32.self))
                    if word == targetWord {
                        let deltaInSection = cursor - section.fileStart
                        let vmAddr = section.vmAddress + deltaInSection
                        let vmOffset = vmAddr >= baseTextVMAddr ? (vmAddr - baseTextVMAddr) : 0
                        sites.append(SVCPatchSite(
                            sliceOffset: sliceOffset,
                            fileOffset: cursor,
                            vmAddress: vmAddr,
                            vmOffset: vmOffset
                        ))
                    }
                    cursor += 4
                }
            }
        }
    }

    private static func mergeSortedRanges(_ ranges: [Range<UInt64>]) -> [Range<UInt64>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted {
            if $0.lowerBound != $1.lowerBound {
                return $0.lowerBound < $1.lowerBound
            }
            return $0.upperBound < $1.upperBound
        }
        var merged: [Range<UInt64>] = [sorted[0]]
        for next in sorted.dropFirst() {
            let lastIdx = merged.count - 1
            if next.lowerBound <= merged[lastIdx].upperBound {
                if next.upperBound > merged[lastIdx].upperBound {
                    merged[lastIdx] = merged[lastIdx].lowerBound..<next.upperBound
                }
            } else {
                merged.append(next)
            }
        }
        return merged
    }

    // MARK: - Site Verification & Binary/Manifest I/O

    private static func verifyAllSites(in data: Data, sites: [SVCPatchSite], expectedWord: UInt32) -> Bool {
        guard !sites.isEmpty else { return false }
        for site in sites {
            guard site.fileOffset + 4 <= UInt64(data.count) else {
                return false
            }
            if loadUInt32LE(from: data, at: Int(site.fileOffset)) != expectedWord {
                return false
            }
        }
        return true
    }

    private static func verifySitesInSet(
        in data: Data,
        sites: [SVCPatchSite],
        allowedA: UInt32,
        allowedB: UInt32
    ) -> Bool {
        guard !sites.isEmpty else { return false }
        for site in sites {
            guard site.fileOffset + 4 <= UInt64(data.count) else {
                return false
            }
            let word = loadUInt32LE(from: data, at: Int(site.fileOffset))
            if word != allowedA && word != allowedB {
                return false
            }
        }
        return true
    }

    private static func hasAnySite(in data: Data, sites: [SVCPatchSite], expectedWord: UInt32) -> Bool {
        for site in sites {
            guard site.fileOffset + 4 <= UInt64(data.count) else {
                continue
            }
            if loadUInt32LE(from: data, at: Int(site.fileOffset)) == expectedWord {
                return true
            }
        }
        return false
    }

    private static func writeWord(_ word: UInt32, to data: inout Data, sites: [SVCPatchSite]) throws {
        var little = word.littleEndian
        let bytes = withUnsafeBytes(of: &little) { Array($0) }
        for site in sites {
            let off = Int(site.fileOffset)
            guard off >= 0, off + 4 <= data.count else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFAULT))
            }
            data.replaceSubrange(off..<(off + 4), with: bytes)
        }
    }

    private static func writeAtomicPreservingPermissions(_ data: Data, to fileURL: URL) throws {
        let perms = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]) as? NSNumber
        try data.write(to: fileURL, options: .atomic)
        if let perms {
            try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: fileURL.path)
        }
    }

    private static func loadValidManifestIfPresent(at manifestURL: URL) throws -> SVCPatchManifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SVCPatchManifest.self, from: data)
        guard manifest.schemaVersion == SVCPatchManifest.currentSchemaVersion else {
            return nil
        }
        return manifest
    }

    private static func writeManifest(_ manifest: SVCPatchManifest, to manifestURL: URL) throws {
        let dir = manifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private static func removeManifestIfExists(at manifestURL: URL) throws {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: manifestURL)
    }

    private static func extractSegmentName(
        _ tuple: (
            Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
            Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8
        )
    ) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let prefix = raw.prefix { $0 != 0 }
            return String(bytes: prefix, encoding: .utf8) ?? ""
        }
    }

    private static func loadStruct<T>(_ type: T.Type, from data: Data, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= data.count else {
            return nil
        }
        return data.withUnsafeBytes { rawBuffer in
            rawBuffer.baseAddress.map { base in
                base.advanced(by: offset).loadUnaligned(as: T.self)
            }
        }
    }

    private static func loadUInt32LE(from data: Data, at offset: Int) -> UInt32 {
        guard let raw = loadStruct(UInt32.self, from: data, at: offset) else { return 0 }
        return UInt32(littleEndian: raw)
    }

    private static func loadUInt32BE(from data: Data, at offset: Int) -> UInt32 {
        guard let raw = loadStruct(UInt32.self, from: data, at: offset) else { return 0 }
        return UInt32(bigEndian: raw)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
