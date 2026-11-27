//
//  MachOByteSwap.swift
//  PlayCoverMachO
//

import Foundation
import MachO

public enum MachOByteSwap {
    public static func swapFatHeader(_ value: inout fat_header) {
        value.magic = value.magic.byteSwapped
        value.nfat_arch = value.nfat_arch.byteSwapped
    }

    public static func swapFatArch(_ value: inout fat_arch) {
        value.cputype = value.cputype.byteSwapped
        value.cpusubtype = value.cpusubtype.byteSwapped
        value.offset = value.offset.byteSwapped
        value.size = value.size.byteSwapped
        value.align = value.align.byteSwapped
    }

    public static func swapFatArch64(_ value: inout fat_arch_64) {
        value.cputype = value.cputype.byteSwapped
        value.cpusubtype = value.cpusubtype.byteSwapped
        value.offset = value.offset.byteSwapped
        value.size = value.size.byteSwapped
        value.align = value.align.byteSwapped
        value.reserved = value.reserved.byteSwapped
    }

    public static func swapMachHeader64(_ value: inout mach_header_64) {
        value.magic = value.magic.byteSwapped
        value.cputype = value.cputype.byteSwapped
        value.cpusubtype = value.cpusubtype.byteSwapped
        value.filetype = value.filetype.byteSwapped
        value.ncmds = value.ncmds.byteSwapped
        value.sizeofcmds = value.sizeofcmds.byteSwapped
        value.flags = value.flags.byteSwapped
        value.reserved = value.reserved.byteSwapped
    }

    public static func swapLoadCommand(_ value: inout load_command) {
        value.cmd = value.cmd.byteSwapped
        value.cmdsize = value.cmdsize.byteSwapped
    }

    public static func swapSegmentCommand64(_ value: inout segment_command_64) {
        value.cmd = value.cmd.byteSwapped
        value.cmdsize = value.cmdsize.byteSwapped
        value.vmaddr = value.vmaddr.byteSwapped
        value.vmsize = value.vmsize.byteSwapped
        value.fileoff = value.fileoff.byteSwapped
        value.filesize = value.filesize.byteSwapped
        value.maxprot = value.maxprot.byteSwapped
        value.initprot = value.initprot.byteSwapped
        value.nsects = value.nsects.byteSwapped
        value.flags = value.flags.byteSwapped
    }

    public static func swapSection64(_ value: inout section_64) {
        value.addr = value.addr.byteSwapped
        value.size = value.size.byteSwapped
        value.offset = value.offset.byteSwapped
        value.align = value.align.byteSwapped
        value.reloff = value.reloff.byteSwapped
        value.nreloc = value.nreloc.byteSwapped
        value.flags = value.flags.byteSwapped
        value.reserved1 = value.reserved1.byteSwapped
        value.reserved2 = value.reserved2.byteSwapped
        value.reserved3 = value.reserved3.byteSwapped
    }

    public static func swapLinkeditDataCommand(_ value: inout linkedit_data_command) {
        value.cmd = value.cmd.byteSwapped
        value.cmdsize = value.cmdsize.byteSwapped
        value.dataoff = value.dataoff.byteSwapped
        value.datasize = value.datasize.byteSwapped
    }

    public static func swapSymtabCommand(_ value: inout symtab_command) {
        value.cmd = value.cmd.byteSwapped
        value.cmdsize = value.cmdsize.byteSwapped
        value.symoff = value.symoff.byteSwapped
        value.nsyms = value.nsyms.byteSwapped
        value.stroff = value.stroff.byteSwapped
        value.strsize = value.strsize.byteSwapped
    }

    public static func swapDyldInfoCommand(_ value: inout dyld_info_command) {
        value.cmd = value.cmd.byteSwapped
        value.cmdsize = value.cmdsize.byteSwapped
        value.rebase_off = value.rebase_off.byteSwapped
        value.rebase_size = value.rebase_size.byteSwapped
        value.bind_off = value.bind_off.byteSwapped
        value.bind_size = value.bind_size.byteSwapped
        value.weak_bind_off = value.weak_bind_off.byteSwapped
        value.weak_bind_size = value.weak_bind_size.byteSwapped
        value.lazy_bind_off = value.lazy_bind_off.byteSwapped
        value.lazy_bind_size = value.lazy_bind_size.byteSwapped
        value.export_off = value.export_off.byteSwapped
        value.export_size = value.export_size.byteSwapped
    }

    public static func swapDylibCommand(_ value: inout dylib_command) {
        value.cmd = value.cmd.byteSwapped
        value.cmdsize = value.cmdsize.byteSwapped
        value.dylib.name.offset = value.dylib.name.offset.byteSwapped
        value.dylib.timestamp = value.dylib.timestamp.byteSwapped
        value.dylib.current_version = value.dylib.current_version.byteSwapped
        value.dylib.compatibility_version = value.dylib.compatibility_version.byteSwapped
    }

    public static func swapBuildVersionCommand(_ value: inout build_version_command) {
        value.cmd = value.cmd.byteSwapped
        value.cmdsize = value.cmdsize.byteSwapped
        value.platform = value.platform.byteSwapped
        value.minos = value.minos.byteSwapped
        value.sdk = value.sdk.byteSwapped
        value.ntools = value.ntools.byteSwapped
    }

    public static func swapEncryptionCommand64(_ value: inout encryption_info_command_64) {
        value.cmd = value.cmd.byteSwapped
        value.cmdsize = value.cmdsize.byteSwapped
        value.cryptoff = value.cryptoff.byteSwapped
        value.cryptsize = value.cryptsize.byteSwapped
        value.cryptid = value.cryptid.byteSwapped
        value.pad = value.pad.byteSwapped
    }
}
