import Foundation
import XCTest

private var ptRegistryDynamicCounter: Int32 = 0

private func ptRegistryDynamicResolver() -> UnsafeMutableRawPointer? {
    ptRegistryDynamicCounter += 1
    return UnsafeMutableRawPointer(bitPattern: 0x1_0000_2000 + Int(ptRegistryDynamicCounter) * 0x10)
}

final class PTInterposeRegistryTests: XCTestCase {
    func testLookupHandlesStandardWeakCompatAndDynamicEntries() throws {
        let targetA = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x1_0000_1000))
        let targetB = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x1_0000_1100))
        let weakGuardNonNull = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x1_0000_9000))
        let resolverFn: pt_dlsym_resolver_fn = {
            return ptRegistryDynamicResolver()
        }
        let resolverRaw = unsafeBitCast(resolverFn, to: UnsafeRawPointer.self)

        ptRegistryDynamicCounter = 0

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
                            XCTAssertEqual(dups, 0)
                            XCTAssertEqual(index.count, 5)

                            // Null and empty inputs are safe
                            XCTAssertNil(pt_dlsym_index_lookup(&index, nil, false))
                            XCTAssertNil(pt_dlsym_index_lookup(&index, "", false))
                            XCTAssertNil(pt_dlsym_index_lookup(&index, "missing_symbol", false))

                            // Standard entry
                            XCTAssertEqual(
                                pt_dlsym_index_lookup(&index, "open", false),
                                UnsafeMutableRawPointer(mutating: targetA)
                            )

                            // Weak guard present vs missing
                            XCTAssertEqual(
                                pt_dlsym_index_lookup(&index, "weak_present", false),
                                UnsafeMutableRawPointer(mutating: targetB)
                            )
                            XCTAssertNil(pt_dlsym_index_lookup(&index, "weak_missing", false))

                            // Compat 13.7 visibility flag
                            XCTAssertEqual(
                                pt_dlsym_index_lookup(&index, "objc_enumerateClasses", false),
                                UnsafeMutableRawPointer(mutating: targetA)
                            )
                            XCTAssertNil(pt_dlsym_index_lookup(&index, "objc_enumerateClasses", true))

                            // Dynamic resolver invoked per lookup
                            XCTAssertEqual(
                                pt_dlsym_index_lookup(&index, "environ", false),
                                UnsafeMutableRawPointer(bitPattern: 0x1_0000_2010)
                            )
                            XCTAssertEqual(
                                pt_dlsym_index_lookup(&index, "environ", false),
                                UnsafeMutableRawPointer(bitPattern: 0x1_0000_2020)
                            )
                        }
                    }
                }
            }
        }
    }

    func testDuplicateDetectionKeepsFirstEntryAndCountsDuplicates() throws {
        let firstTarget = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x1_0000_3000))
        let secondTarget = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x1_0000_4000))

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
                XCTAssertEqual(dups, 1)
                XCTAssertEqual(index.duplicate_count, 1)
                XCTAssertEqual(
                    pt_dlsym_index_lookup(&index, "dup_sym", false),
                    UnsafeMutableRawPointer(mutating: firstTarget)
                )
            }
        }
    }
}
