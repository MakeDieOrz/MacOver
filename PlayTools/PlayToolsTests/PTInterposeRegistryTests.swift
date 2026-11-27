import Foundation
import Synchronization
import Testing

private let ptRegistryDynamicCounter = Mutex<Int32>(0)

private func ptRegistryDynamicResolver() -> UnsafeMutableRawPointer? {
    let next = ptRegistryDynamicCounter.withLock { count -> Int32 in
        count += 1
        return count
    }
    return UnsafeMutableRawPointer(bitPattern: 0x1_0000_2000 + Int(next) * 0x10)
}

extension PlayToolsGlobalStateScope {
@Suite(.serialized)
struct PTInterposeRegistryTests {
    @Test
    func lookupHandlesStandardWeakCompatAndDynamicEntries() throws {
        let targetA = try #require(UnsafeRawPointer(bitPattern: 0x1_0000_1000))
        let targetB = try #require(UnsafeRawPointer(bitPattern: 0x1_0000_1100))
        let weakGuardNonNull = try #require(UnsafeRawPointer(bitPattern: 0x1_0000_9000))
        let resolverFn: pt_dlsym_resolver_fn = {
            return ptRegistryDynamicResolver()
        }
        let resolverRaw = unsafeBitCast(resolverFn, to: UnsafeRawPointer.self)

        ptRegistryDynamicCounter.withLock { $0 = 0 }

        "open".withCString { symOpen in
            "weak_present".withCString { symWeakPresent in
                "weak_missing".withCString { symWeakMissing in
                    "objc_enumerateClasses".withCString { symCompatHidden in
                        "environ".withCString { symDynamic in
                            let entries: [pt_dlsym_entry_t] = [
                                pt_dlsym_entry_t(
                                    symbol: symOpen,
                                    target: targetA,
                                    guard: nil,
                                    flags: UInt(PT_DLSYM_FLAG_NONE)
                                ),
                                pt_dlsym_entry_t(
                                    symbol: symWeakPresent,
                                    target: targetB,
                                    guard: weakGuardNonNull,
                                    flags: UInt(PT_DLSYM_FLAG_WEAK_GUARD)
                                ),
                                pt_dlsym_entry_t(
                                    symbol: symWeakMissing,
                                    target: targetB,
                                    guard: nil,
                                    flags: UInt(PT_DLSYM_FLAG_WEAK_GUARD)
                                ),
                                pt_dlsym_entry_t(
                                    symbol: symCompatHidden,
                                    target: targetA,
                                    guard: weakGuardNonNull,
                                    flags: UInt(PT_DLSYM_FLAG_WEAK_GUARD | PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
                                ),
                                pt_dlsym_entry_t(
                                    symbol: symDynamic,
                                    target: resolverRaw,
                                    guard: nil,
                                    flags: UInt(PT_DLSYM_FLAG_DYNAMIC_RESOLVER)
                                ),
                            ]

                            var slots = [UInt16](repeating: 0, count: 32)
                            var index = pt_dlsym_index_t()

                            let dups = entries.withUnsafeBufferPointer { entriesBuf in
                                slots.withUnsafeMutableBufferPointer { slotsBuf in
                                    pt_dlsym_index_build(
                                        &index,
                                        entriesBuf.baseAddress,
                                        entriesBuf.count,
                                        slotsBuf.baseAddress,
                                        slotsBuf.count
                                    )
                                }
                            }
                            #expect(dups == 0)
                            #expect(index.count == 5)

                            // Null and empty inputs are safe
                            #expect(pt_dlsym_index_lookup(&index, nil, false) == nil)
                            #expect(pt_dlsym_index_lookup(&index, "", false) == nil)
                            #expect(pt_dlsym_index_lookup(&index, "missing_symbol", false) == nil)

                            // Standard entry
                            #expect(
                                pt_dlsym_index_lookup(&index, "open", false) ==
                                    UnsafeMutableRawPointer(mutating: targetA)
                            )

                            // Weak guard present vs missing
                            #expect(
                                pt_dlsym_index_lookup(&index, "weak_present", false) ==
                                    UnsafeMutableRawPointer(mutating: targetB)
                            )
                            #expect(pt_dlsym_index_lookup(&index, "weak_missing", false) == nil)

                            // Compat 13.7 visibility flag
                            #expect(
                                pt_dlsym_index_lookup(&index, "objc_enumerateClasses", false) ==
                                    UnsafeMutableRawPointer(mutating: targetA)
                            )
                            #expect(
                                pt_dlsym_index_lookup(&index, "objc_enumerateClasses", true) ==
                                    UnsafeMutableRawPointer(bitPattern: -1)
                            )

                            // Dynamic resolver invoked per lookup
                            #expect(
                                pt_dlsym_index_lookup(&index, "environ", false) ==
                                    UnsafeMutableRawPointer(bitPattern: 0x1_0000_2010)
                            )
                            #expect(
                                pt_dlsym_index_lookup(&index, "environ", false) ==
                                    UnsafeMutableRawPointer(bitPattern: 0x1_0000_2020)
                            )
                        }
                    }
                }
            }
        }
    }

    @Test
    func duplicateDetectionKeepsFirstEntryAndCountsDuplicates() throws {
        let firstTarget = try #require(UnsafeRawPointer(bitPattern: 0x1_0000_3000))
        let secondTarget = try #require(UnsafeRawPointer(bitPattern: 0x1_0000_4000))

        "dup_sym".withCString { symA in
            "dup_sym".withCString { symB in
                let entries: [pt_dlsym_entry_t] = [
                    pt_dlsym_entry_t(
                        symbol: symA,
                        target: firstTarget,
                        guard: nil,
                        flags: UInt(PT_DLSYM_FLAG_NONE)
                    ),
                    pt_dlsym_entry_t(
                        symbol: symB,
                        target: secondTarget,
                        guard: nil,
                        flags: UInt(PT_DLSYM_FLAG_NONE)
                    ),
                ]
                var slots = [UInt16](repeating: 0, count: 16)
                var index = pt_dlsym_index_t()

                let dups = entries.withUnsafeBufferPointer { entriesBuf in
                    slots.withUnsafeMutableBufferPointer { slotsBuf in
                        pt_dlsym_index_build(
                            &index,
                            entriesBuf.baseAddress,
                            entriesBuf.count,
                            slotsBuf.baseAddress,
                            slotsBuf.count
                        )
                    }
                }
                #expect(dups == 1)
                #expect(index.duplicate_count == 1)
                #expect(
                    pt_dlsym_index_lookup(&index, "dup_sym", false) ==
                        UnsafeMutableRawPointer(mutating: firstTarget)
                )
            }
        }
    }
}
}
