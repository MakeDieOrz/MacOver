//
//  PTSystemSpooferSyscallMIG.m
//  PlayTools
//

#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"
#import "PTDyldInternal.h"
#import "PTNetworkInternal.h"
#import "PTEntitlementsInternal.h"
#import "PTSvcInternal.h"
#import "PTKernelABI.h"
#include <mach/mach_vm.h>
#include <signal.h>
#include <sys/event.h>
#include <time.h>

extern intptr_t pt_orig_syscall(int, ...) __asm("_syscall");

#define PT_XNU_SYSCALL_MAX_ARGS 8

static inline BOOL pt_va_can_pop_uintptr(va_list ap, uintptr_t stack_bot, uintptr_t stack_top) {
#if defined(__aarch64__) && defined(__APPLE__)
    uintptr_t slot = (uintptr_t)ap;
    if (stack_top != 0 && stack_bot < stack_top) {
        return (slot >= stack_bot && slot + sizeof(uintptr_t) <= stack_top);
    }
#elif defined(__x86_64__)
    if (ap[0].gp_offset < 48U) {
        return YES;
    }
    uintptr_t slot = (uintptr_t)ap[0].overflow_arg_area;
    if (stack_top != 0 && stack_bot < stack_top) {
        return (slot >= stack_bot && slot + sizeof(uintptr_t) <= stack_top);
    }
#else
    (void)ap;
    (void)stack_bot;
    (void)stack_top;
#endif
    return YES;
}

#define PT_VA_POP_UINTPTR(ap, bot, top) \
    (pt_va_can_pop_uintptr((ap), (bot), (top)) ? va_arg((ap), uintptr_t) : (uintptr_t)0)

static inline BOOL pt_fcntl_cmd_has_no_arg(int cmd) {
    switch (cmd) {
        case F_GETFD:
        case F_GETFL:
        case F_GETOWN:
#ifdef F_FLUSH_DATA
        case F_FLUSH_DATA:
#endif
#ifdef F_CHKCLEAN
        case F_CHKCLEAN:
#endif
#ifdef F_FULLFSYNC
        case F_FULLFSYNC:
#endif
#ifdef F_FREEZE_FS
        case F_FREEZE_FS:
#endif
#ifdef F_THAW_FS
        case F_THAW_FS:
#endif
#ifdef F_GETPROTECTIONCLASS
        case F_GETPROTECTIONCLASS:
#endif
#ifdef F_GETNOSIGPIPE
        case F_GETNOSIGPIPE:
#endif
#ifdef F_GETPROTECTIONLEVEL
        case F_GETPROTECTIONLEVEL:
#endif
#ifdef F_BARRIERFSYNC
        case F_BARRIERFSYNC:
#endif
#ifdef F_GETLEASE
        case F_GETLEASE:
#endif
            return YES;
        default:
            return NO;
    }
}

typedef struct {
    int16_t  f_otype;
    int16_t  f_oflags;
    int64_t  f_bsize;
    int64_t  f_iosize;
    int64_t  f_blocks;
    int64_t  f_bfree;
    int64_t  f_bavail;
    int64_t  f_files;
    int64_t  f_ffree;
    fsid_t   f_fsid;
    uid_t    f_owner;
    int16_t  f_reserved1;
    int16_t  f_type;
    int64_t  f_flags;
    int64_t  f_reserved2[2];
    char     f_fstypename[15];
    char     f_mntonname[90];
    char     f_mntfromname[90];
    char     f_reserved3;
    int64_t  f_reserved4[4];
} pt_user64_statfs_t;

_Static_assert(sizeof(pt_user64_statfs_t) == 336, "pt_user64_statfs_t ABI size mismatch");
_Static_assert(offsetof(pt_user64_statfs_t, f_fstypename) == 104, "pt_user64_statfs_t f_fstypename offset mismatch");
_Static_assert(offsetof(pt_user64_statfs_t, f_mntonname) == 119, "pt_user64_statfs_t f_mntonname offset mismatch");
_Static_assert(offsetof(pt_user64_statfs_t, f_mntfromname) == 209, "pt_user64_statfs_t f_mntfromname offset mismatch");

typedef struct {
    dev_t    st_dev;
    uint32_t st_ino;
    uint16_t st_mode;
    uint16_t st_nlink;
    uint32_t st_uid;
    uint32_t st_gid;
    dev_t    st_rdev;
    int64_t  st_atime_sec;
    int64_t  st_atime_nsec;
    int64_t  st_mtime_sec;
    int64_t  st_mtime_nsec;
    int64_t  st_ctime_sec;
    int64_t  st_ctime_nsec;
    int64_t  st_size;
    int64_t  st_blocks;
    int32_t  st_blksize;
    uint32_t st_flags;
    uint32_t st_gen;
    int32_t  st_lspare;
    int64_t  st_qspare[2];
} pt_user64_stat_t;

_Static_assert(sizeof(pt_user64_stat_t) == 120, "pt_user64_stat_t ABI size mismatch");
_Static_assert(offsetof(pt_user64_stat_t, st_gid) == 16, "pt_user64_stat_t st_gid offset mismatch");

static BOOL pt_legacy_user64_statfs_looks_valid(const pt_user64_statfs_t *entry) {
    if (entry == NULL) {
        return NO;
    }
    if (entry->f_fstypename[0] < 'a' || entry->f_fstypename[0] > 'z' ||
        entry->f_mntonname[0] != '/') {
        return NO;
    }
    for (size_t i = 0; i < sizeof(entry->f_fstypename); i++) {
        char c = entry->f_fstypename[i];
        if (c == '\0') {
            return (i >= 2U);
        }
        if (c < 0x20 || c > 0x7e) {
            return NO;
        }
    }
    return NO;
}

static void pt_sanitize_legacy_user64_statfs_in_place(pt_user64_statfs_t *entry, const void *caller) {
    if (pt_legacy_user64_statfs_looks_valid(entry)) {
        pt_fs_sanitize_legacy_statfs_strings(entry->f_mntonname,
                                             sizeof(entry->f_mntonname),
                                             entry->f_mntfromname,
                                             sizeof(entry->f_mntfromname),
                                             caller);
    }
}

__attribute__((visibility("hidden"))) void pt_sanitize_legacy_user64_stat_in_place(void *ub, const void *caller) {
    if (ub == NULL || !pt_is_valid_user_pointer(ub) ||
        !pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return;
    }
    uint32_t g = 0;
    memcpy(&g, (const uint8_t *)ub + offsetof(pt_user64_stat_t, st_gid), sizeof(g));
    if (g == 20U) {
        g = 501U;
        memcpy((uint8_t *)ub + offsetof(pt_user64_stat_t, st_gid), &g, sizeof(g));
    }
    uint32_t fl = 0;
    memcpy(&fl, (const uint8_t *)ub + offsetof(pt_user64_stat_t, st_flags), sizeof(fl));
    uint32_t clean_fl = fl;
#ifdef SF_RESTRICTED
    clean_fl &= ~(uint32_t)SF_RESTRICTED;
#endif
#ifdef SF_FIRMLINK
    clean_fl &= ~(uint32_t)SF_FIRMLINK;
#endif
    if (clean_fl != fl) {
        memcpy((uint8_t *)ub + offsetof(pt_user64_stat_t, st_flags), &clean_fl, sizeof(clean_fl));
    }
}

__attribute__((visibility("hidden"))) void pt_copy_stat64_to_legacy_user64_stat(const struct stat *src, void *dst_ub) {
    if (src == NULL || dst_ub == NULL) {
        return;
    }
    pt_user64_stat_t out;
    memset(&out, 0, sizeof(out));
    out.st_dev = src->st_dev;
    out.st_ino = (uint32_t)src->st_ino;
    out.st_mode = (uint16_t)src->st_mode;
    out.st_nlink = (uint16_t)src->st_nlink;
    out.st_uid = (uint32_t)src->st_uid;
    out.st_gid = (uint32_t)src->st_gid;
    out.st_rdev = src->st_rdev;
    out.st_atime_sec = (int64_t)src->st_atimespec.tv_sec;
    out.st_atime_nsec = (int64_t)src->st_atimespec.tv_nsec;
    out.st_mtime_sec = (int64_t)src->st_mtimespec.tv_sec;
    out.st_mtime_nsec = (int64_t)src->st_mtimespec.tv_nsec;
    out.st_ctime_sec = (int64_t)src->st_ctimespec.tv_sec;
    out.st_ctime_nsec = (int64_t)src->st_ctimespec.tv_nsec;
    out.st_size = (int64_t)src->st_size;
    out.st_blocks = (int64_t)src->st_blocks;
    out.st_blksize = (int32_t)src->st_blksize;
    out.st_flags = (uint32_t)src->st_flags;
    out.st_gen = (uint32_t)src->st_gen;
    memcpy(dst_ub, &out, sizeof(out));
}

__attribute__((visibility("hidden")))
intptr_t pt_syscall_dispatch_with_caller(int number,
                                         const uintptr_t args[PT_XNU_SYSCALL_MAX_ARGS],
                                         const void *caller,
                                         BOOL *out_handled) {
    if (out_handled != NULL) {
        *out_handled = YES;
    }
    if (number == 0 || number == 198) {
        number = (int)args[0];
        if (number == 0 || number == 198) {
            errno = ENOSYS;
            return -1;
        }
        uintptr_t shifted[PT_XNU_SYSCALL_MAX_ARGS] = {0};
        for (int i = 0; i < PT_XNU_SYSCALL_MAX_ARGS - 1; i++) {
            shifted[i] = args[i + 1];
        }
        return pt_syscall_dispatch_with_caller(number, shifted, caller, out_handled);
    }

    switch (number) {
        case 202: { // SYS___sysctl
            int *name = (int *)args[0];
            u_int namelen = (u_int)args[1];
            void *oldp = (void *)args[2];
            size_t *oldlenp = (size_t *)args[3];
            void *newp = (void *)args[4];
            size_t newlen = (size_t)args[5];
            return (intptr_t)pt_sysctl_with_caller(name, namelen, oldp, oldlenp, newp, newlen, caller);
        }
        case 274: { // SYS_sysctlbyname (XNU 6-arg ABI: name, namelen, oldp, oldlenp, newp, newlen)
            const char *name = (const char *)args[0];
            size_t namelen = (size_t)args[1];
            void *oldp = (void *)args[2];
            size_t *oldlenp = (size_t *)args[3];
            void *newp = (void *)args[4];
            size_t newlen = (size_t)args[5];
            if (name != NULL && namelen > 0 && namelen < 256U && pt_is_valid_user_pointer(name)) {
                char nbuf[256];
                size_t slen = strnlen(name, namelen);
                memcpy(nbuf, name, slen);
                nbuf[slen] = '\0';
                return (intptr_t)pt_sysctlbyname_with_caller(nbuf, oldp, oldlenp, newp, newlen, caller);
            }
            return (intptr_t)pt_orig_kernel_sysctlbyname(name, namelen, oldp, oldlenp, newp, newlen);
        }
        case 169: { // SYS_csops
            pid_t pid = (pid_t)args[0];
            unsigned int ops = (unsigned int)args[1];
            void *useraddr = (void *)args[2];
            size_t usersize = (size_t)args[3];
            return (intptr_t)pt_csops_with_caller(pid, ops, useraddr, usersize, caller);
        }
        case 170: { // SYS_csops_audittoken
            pid_t pid = (pid_t)args[0];
            unsigned int ops = (unsigned int)args[1];
            void *useraddr = (void *)args[2];
            size_t usersize = (size_t)args[3];
            audit_token_t *token = (audit_token_t *)(uintptr_t)args[4];
            if (pid == 0 || pid == getpid()) {
                return (intptr_t)pt_csops_audittoken_with_caller(pid, ops, useraddr, usersize, token, caller);
            }
            if (out_handled != NULL) {
                *out_handled = NO;
            }
            return 0;
        }
        case 18: { // SYS_getfsstat (legacy 336B user64_statfs ABI)
            void *buf = (void *)(uintptr_t)args[0];
            int bufsize = (int)args[1];
            int mode = (int)args[2];
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                if (buf == NULL || bufsize == 0) {
                    return (intptr_t)pt_fs_getfsstat_with_caller(NULL, 0, mode, caller);
                }
                if (bufsize > 0 && pt_is_valid_user_pointer(buf)) {
                    intptr_t raw_cnt = pt_orig_syscall(18, 0, 0, (uintptr_t)mode, 0, 0, 0, 0, 0);
                    if (raw_cnt <= 0) {
                        return raw_cnt;
                    }
                    int cap = (int)raw_cnt + 16;
                    if (cap > 512) {
                        cap = 512;
                    }
                    const size_t stride = sizeof(pt_user64_statfs_t);
                    pt_user64_statfs_t *tmp = (pt_user64_statfs_t *)calloc((size_t)cap, stride);
                    if (tmp != NULL) {
                        intptr_t got = pt_orig_syscall(18, (uintptr_t)tmp, (uintptr_t)((size_t)cap * stride),
                                                       (uintptr_t)mode, 0, 0, 0, 0, 0);
                        if (got > 0 && got <= cap &&
                            pt_legacy_user64_statfs_looks_valid(&tmp[0]) &&
                            (got == 1 || pt_legacy_user64_statfs_looks_valid(&tmp[1]))) {
                            intptr_t kept = 0;
                            for (intptr_t i = 0; i < got; i++) {
                                pt_user64_statfs_t cur = tmp[i];
                                cur.f_mntonname[sizeof(cur.f_mntonname) - 1U] = '\0';
                                cur.f_mntfromname[sizeof(cur.f_mntfromname) - 1U] = '\0';
                                if (pt_fs_legacy_statfs_entry_is_hidden(cur.f_mntonname, cur.f_mntfromname, caller)) {
                                    continue;
                                }
                                pt_sanitize_legacy_user64_statfs_in_place(&cur, caller);
                                tmp[kept++] = cur;
                            }
                            intptr_t max_entries = (intptr_t)((size_t)bufsize / stride);
                            intptr_t copy_n = (kept < max_entries) ? kept : max_entries;
                            if (copy_n > 0) {
                                memcpy(buf, tmp, (size_t)copy_n * stride);
                            }
                            free(tmp);
                            return copy_n;
                        }
                        free(tmp);
                    }
                }
            }
            return pt_orig_syscall(18, args[0], args[1], args[2], 0, 0, 0, 0, 0);
        }
        case 347: { // SYS_getfsstat64
            return (intptr_t)pt_fs_getfsstat_with_caller(
                (struct statfs *)(uintptr_t)args[0],
                (int)args[1],
                (int)args[2],
                caller);
        }
        case 426: { // SYS___mac_getfsstat
            if (args[2] != 0 && pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                errno = EPERM;
                return -1;
            }
            return (intptr_t)pt_fs_getfsstat_with_caller(
                (struct statfs *)(uintptr_t)args[0],
                (int)args[1],
                (int)args[4],
                caller);
        }
        case 425: { // SYS___mac_get_mount
            char vbuf[PATH_MAX];
            const char *path = (const char *)(uintptr_t)args[0];
            pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, caller, vbuf, sizeof(vbuf), &path);
            if (disp == PT_FS_PATH_HIDDEN) {
                errno = ENOENT;
                return -1;
            }
            return pt_orig_syscall(425, (uintptr_t)path, args[1], 0, 0, 0, 0, 0, 0);
        }
        case 479: { // SYS_openbyid_np
            BOOL app_bypass = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
            if (app_bypass) {
                const void *fsid_ptr = (const void *)(uintptr_t)args[0];
                const void *objid_ptr = (const void *)(uintptr_t)args[1];
                if (fsid_ptr != NULL && objid_ptr != NULL &&
                    pt_is_valid_user_pointer(fsid_ptr) && pt_is_valid_user_pointer(objid_ptr)) {
                    fsid_t fsid_copy;
                    uint64_t objid_copy = 0;
                    memcpy(&fsid_copy, fsid_ptr, sizeof(fsid_copy));
                    memcpy(&objid_copy, objid_ptr, sizeof(objid_copy));
                    char pbuf[PATH_MAX];
                    int saved_errno = errno;
                    ssize_t r = pt_fs_fsgetpath_with_caller(pbuf, sizeof(pbuf), &fsid_copy, objid_copy, caller);
                    if (r < 0 && errno == ENOENT) {
                        return -1;
                    }
                    errno = saved_errno;
                }
            }
            intptr_t fd_ret = pt_orig_syscall(479, args[0], args[1], args[2], 0, 0, 0, 0, 0);
            if (fd_ret >= 0 && app_bypass && pt_fd_is_sensitive((int)fd_ret, caller)) {
                close((int)fd_ret);
                errno = ENOENT;
                return -1;
            }
            return fd_ret;
        }
        case 54: { // SYS_ioctl
            return (intptr_t)pt_network_ioctl_with_caller(
                (int)args[0],
                (unsigned long)args[1],
                args[2],
                caller);
        }
        case 142: { // SYS_gethostuuid
            return (intptr_t)pt_gethostuuid_with_caller(
                (unsigned char *)(uintptr_t)args[0],
                (const struct timespec *)(uintptr_t)args[1],
                caller);
        }
        case 157: { // SYS_statfs (legacy 336B user64_statfs ABI)
            char vbuf[PATH_MAX];
            const char *resolved = NULL;
            if (pt_fs_prepare_statfs_path_with_caller((const char *)(uintptr_t)args[0],
                                                      caller,
                                                      vbuf,
                                                      sizeof(vbuf),
                                                      &resolved) != 0) {
                return -1;
            }
            intptr_t r = pt_orig_syscall(157, (uintptr_t)resolved, args[1], 0, 0, 0, 0, 0, 0);
            if (r == 0 && args[1] != 0 && pt_is_valid_user_pointer((const void *)(uintptr_t)args[1])) {
                pt_sanitize_legacy_user64_statfs_in_place((pt_user64_statfs_t *)(uintptr_t)args[1], caller);
            }
            return r;
        }
        case 345: { // SYS_statfs64
            return (intptr_t)pt_fs_statfs_with_caller(
                (const char *)(uintptr_t)args[0],
                (struct statfs *)(uintptr_t)args[1],
                caller);
        }
        case 158: { // SYS_fstatfs (legacy 336B user64_statfs ABI)
            if (pt_fd_is_sensitive((int)args[0], caller)) {
                errno = EBADF;
                return -1;
            }
            intptr_t r = pt_orig_syscall(158, args[0], args[1], 0, 0, 0, 0, 0, 0);
            if (r == 0 && args[1] != 0 && pt_is_valid_user_pointer((const void *)(uintptr_t)args[1])) {
                pt_sanitize_legacy_user64_statfs_in_place((pt_user64_statfs_t *)(uintptr_t)args[1], caller);
            }
            return r;
        }
        case 346: { // SYS_fstatfs64
            return (intptr_t)pt_fs_fstatfs_with_caller(
                (int)args[0],
                (struct statfs *)(uintptr_t)args[1],
                caller);
        }
        case 234: { // SYS_getxattr
            return (intptr_t)pt_fs_getxattr_with_caller(
                (const char *)(uintptr_t)args[0],
                (const char *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (uint32_t)args[4],
                (int)args[5],
                caller);
        }
        case 235: { // SYS_fgetxattr
            return (intptr_t)pt_fs_fgetxattr_with_caller(
                (int)args[0],
                (const char *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (uint32_t)args[4],
                (int)args[5],
                caller);
        }
        case 240: { // SYS_listxattr
            return (intptr_t)pt_fs_listxattr_with_caller(
                (const char *)(uintptr_t)args[0],
                (char *)(uintptr_t)args[1],
                (size_t)args[2],
                (int)args[3],
                caller);
        }
        case 241: { // SYS_flistxattr
            return (intptr_t)pt_fs_flistxattr_with_caller(
                (int)args[0],
                (char *)(uintptr_t)args[1],
                (size_t)args[2],
                (int)args[3],
                caller);
        }
        case 344: { // SYS_getdirentries64
            return (intptr_t)pt_fs_getdirentries64_syscall_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (size_t)args[2],
                (off_t *)(uintptr_t)args[3],
                caller);
        }
        case 461: { // SYS_getattrlistbulk
            return (intptr_t)pt_fs_getattrlistbulk_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (uint64_t)args[4],
                caller);
        }
        case 4:    // SYS_write
        case 397: { // SYS_write_nocancel
            return (intptr_t)pt_fs_write_with_caller(
                (int)args[0],
                (const void *)(uintptr_t)args[1],
                (size_t)args[2],
                0,
                NO,
                (number == 397),
                caller);
        }
        case 154:  // SYS_pwrite
        case 415: { // SYS_pwrite_nocancel
            return (intptr_t)pt_fs_write_with_caller(
                (int)args[0],
                (const void *)(uintptr_t)args[1],
                (size_t)args[2],
                (off_t)args[3],
                YES,
                (number == 415),
                caller);
        }
        case 121:  // SYS_writev
        case 412: { // SYS_writev_nocancel
            return (intptr_t)pt_fs_writev_with_caller(
                (int)args[0],
                (const struct iovec *)(uintptr_t)args[1],
                (int)args[2],
                (number == 412),
                caller);
        }
        case 5: // SYS_open
        case 398: { // SYS_open_nocancel
            const char *path = (const char *)args[0];
            int oflag = (int)args[1];
            mode_t mode = (oflag & O_CREAT) ? (mode_t)args[2] : 0;
            return (intptr_t)pt_fs_open_with_caller(path, oflag, mode, caller);
        }
        case 463: // SYS_openat
        case 464: { // SYS_openat_nocancel
            int fd = (int)args[0];
            const char *path = (const char *)args[1];
            int oflag = (int)args[2];
            mode_t mode = (oflag & O_CREAT) ? (mode_t)args[3] : 0;
            return (intptr_t)pt_fs_openat_with_caller(fd, path, oflag, mode, caller);
        }
        case 188: // SYS_stat (legacy 120B user64_stat ABI)
        case 190: { // SYS_lstat (legacy 120B user64_stat ABI)
            const char *path = (const char *)(uintptr_t)args[0];
            void *ub = (void *)(uintptr_t)args[1];
            char vbuf[PATH_MAX];
            const char *resolved = NULL;
            BOOL virtual_anc = NO;
            if (pt_fs_prepare_legacy_stat_path_with_caller(AT_FDCWD, NO, path, caller,
                                                           vbuf, sizeof(vbuf),
                                                           &resolved, &virtual_anc) != 0) {
                return -1;
            }
            if (virtual_anc) {
                if (ub == NULL || !pt_is_valid_user_pointer(ub)) {
                    errno = EFAULT;
                    return -1;
                }
                struct stat st64;
                memset(&st64, 0, sizeof(st64));
                int sr = pt_fs_stat_with_caller(path, &st64, number == 188, caller);
                if (sr == 0) {
                    pt_copy_stat64_to_legacy_user64_stat(&st64, ub);
                }
                return (intptr_t)sr;
            }
            intptr_t r = pt_orig_syscall(number, (uintptr_t)resolved, (uintptr_t)ub, 0, 0, 0, 0, 0, 0);
            if (r == 0) {
                pt_sanitize_legacy_user64_stat_in_place(ub, caller);
            }
            return r;
        }
        case 338: { // SYS_stat64
            const char *path = (const char *)args[0];
            struct stat *ub = (struct stat *)args[1];
            return (intptr_t)pt_fs_stat_with_caller(path, ub, YES, caller);
        }
        case 189: { // SYS_fstat (legacy 120B user64_stat ABI)
            int fd = (int)args[0];
            void *ub = (void *)(uintptr_t)args[1];
            BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
            if (!is_sys && (pt_is_hidden_fd(fd) || pt_fd_is_sensitive(fd, caller))) {
                errno = EBADF;
                return -1;
            }
            intptr_t r = pt_orig_syscall(189, (uintptr_t)fd, (uintptr_t)ub, 0, 0, 0, 0, 0, 0);
            if (r == 0) {
                pt_sanitize_legacy_user64_stat_in_place(ub, caller);
            }
            return r;
        }
        case 339: { // SYS_fstat64
            int fd = (int)args[0];
            struct stat *ub = (struct stat *)args[1];
            return (intptr_t)pt_fs_fstat_with_caller(fd, ub, caller);
        }
        case 340: { // SYS_lstat64
            const char *path = (const char *)args[0];
            struct stat *ub = (struct stat *)args[1];
            return (intptr_t)pt_fs_stat_with_caller(path, ub, NO, caller);
        }
        case 191: { // SYS_pathconf
            return (intptr_t)pt_fs_pathconf_with_caller(
                (const char *)(uintptr_t)args[0], (int)args[1], caller);
        }
        case 192: { // SYS_fpathconf
            return (intptr_t)pt_fs_fpathconf_with_caller((int)args[0], (int)args[1], caller);
        }
        case 216: { // SYS_open_dprotected_np
            const char *path = (const char *)args[0];
            int flags = (int)args[1];
            int dpclass = (int)args[2];
            int dpflags = (int)args[3];
            mode_t mode = (flags & O_CREAT) ? (mode_t)args[4] : 0;
            return (intptr_t)pt_fs_open_dprotected_np_with_caller(path, flags, dpclass, dpflags, mode, caller);
        }
        case 217: { // SYS_fsgetpath_ext
            return (intptr_t)pt_fs_fsgetpath_ext_with_caller(
                (char *)(uintptr_t)args[0],
                (size_t)args[1],
                (fsid_t *)(uintptr_t)args[2],
                (uint64_t)args[3],
                (uint64_t)args[4],
                caller);
        }
        case 225: { // SYS_searchfs
            return (intptr_t)pt_fs_searchfs_with_caller(
                (const char *)(uintptr_t)args[0],
                (void *)(uintptr_t)args[1],
                (unsigned long *)(uintptr_t)args[2],
                (unsigned int)args[3],
                (unsigned int)args[4],
                (void *)(uintptr_t)args[5],
                caller);
        }
        case 353: { // SYS_getauid
            return (intptr_t)pt_getauid_with_caller((void *)(uintptr_t)args[0], caller);
        }
        case 357: { // SYS_getaudit_addr
            return (intptr_t)pt_getaudit_addr_with_caller((void *)(uintptr_t)args[0], (int)args[1], caller);
        }
        case 462: { // SYS_clonefileat
            return (intptr_t)pt_fs_clonefileat_with_caller(
                (int)args[0],
                (const char *)(uintptr_t)args[1],
                (int)args[2],
                (const char *)(uintptr_t)args[3],
                (uint32_t)args[4],
                caller);
        }
        case 218: { // SYS_openat_dprotected_np
            int fd = (int)args[0];
            const char *path = (const char *)args[1];
            int flags = (int)args[2];
            int dpclass = (int)args[3];
            int dpflags = (int)args[4];
            mode_t mode = (flags & O_CREAT) ? (mode_t)args[5] : 0;
            return (intptr_t)pt_fs_openat_dprotected_np_with_caller(fd, path, flags, dpclass, dpflags, mode, caller);
        }
        case 363: { // SYS_kevent
            return (intptr_t)pt_kevent_with_caller(
                (int)args[0],
                (const struct kevent *)(uintptr_t)args[1],
                (int)args[2],
                (struct kevent *)(uintptr_t)args[3],
                (int)args[4],
                (const struct timespec *)(uintptr_t)args[5],
                caller);
        }
        case 369: { // SYS_kevent64
            return (intptr_t)pt_kevent64_with_caller(
                (int)args[0],
                (const struct kevent64_s *)(uintptr_t)args[1],
                (int)args[2],
                (struct kevent64_s *)(uintptr_t)args[3],
                (int)args[4],
                (unsigned int)args[5],
                (const struct timespec *)(uintptr_t)args[6],
                caller);
        }
        case 374: { // SYS_kevent_qos
            return (intptr_t)pt_kevent_qos_with_caller(
                (int)args[0],
                (const pt_kevent_qos_s *)(uintptr_t)args[1],
                (int)args[2],
                (pt_kevent_qos_s *)(uintptr_t)args[3],
                (int)args[4],
                (void *)(uintptr_t)args[5],
                (size_t *)(uintptr_t)args[6],
                (unsigned int)args[7],
                caller);
        }
        case 375: { // SYS_kevent_id
            return (intptr_t)pt_kevent_id_with_caller(
                (uint64_t)args[0],
                (const pt_kevent_qos_s *)(uintptr_t)args[1],
                (int)args[2],
                (pt_kevent_qos_s *)(uintptr_t)args[3],
                (int)args[4],
                (void *)(uintptr_t)args[5],
                (size_t *)(uintptr_t)args[6],
                (unsigned int)args[7],
                caller);
        }
        case 348: { // SYS___pthread_chdir
            char vbuf[PATH_MAX];
            const char *path = (const char *)(uintptr_t)args[0];
            pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, caller, vbuf, sizeof(vbuf), &path);
            if (disp == PT_FS_PATH_HIDDEN) {
                errno = ENOENT;
                return -1;
            }
            if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
                errno = EPERM;
                return -1;
            }
            return pt_orig_syscall(348, (uintptr_t)path, 0, 0, 0, 0, 0, 0, 0);
        }
        case 349: { // SYS___pthread_fchdir
            if (!pt_is_effective_system_or_playtools_caller(caller) &&
                (pt_is_hidden_fd((int)args[0]) || pt_fd_is_sensitive((int)args[0], caller))) {
                errno = EBADF;
                return -1;
            }
            return pt_orig_syscall(349, args[0], 0, 0, 0, 0, 0, 0, 0);
        }
        case 517: { // SYS_fclonefileat
            return (intptr_t)pt_fs_fclonefileat_with_caller(
                (int)args[0],
                (int)args[1],
                (const char *)(uintptr_t)args[2],
                (uint32_t)args[3],
                caller);
        }
        case 194: { // SYS_getrlimit
            return (intptr_t)pt_getrlimit_with_caller(
                (int)args[0],
                (struct rlimit *)(uintptr_t)args[1],
                caller);
        }
        case 534: { // SYS_memorystatus_available_memory
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                return (intptr_t)pt_compute_spoofed_available_memory();
            }
            break;
        }
        case 6:    // SYS_close
        case 399:  // SYS_close_nocancel
        case 442: { // SYS_guarded_close_np
            int fd = (int)args[0];
            if (pt_is_hidden_fd(fd) && !pt_is_effective_system_or_playtools_caller(caller)) {
                errno = EBADF;
                return -1;
            }
            intptr_t r = pt_orig_syscall(number, args[0], args[1], 0, 0, 0, 0, 0, 0);
            if (r == 0) {
                pt_network_notify_fd_close(fd);
            }
            return r;
        }
        case 149: { // SYS_dup3
            int oldfd = (int)args[0];
            int newfd = (int)args[1];
            BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
            if (!is_sys && (pt_is_hidden_fd(oldfd) || pt_is_hidden_fd(newfd))) {
                errno = EBADF;
                return -1;
            }
            if (pt_is_bypass_enabled() &&
                !is_sys &&
                pt_fd_is_sensitive(oldfd, caller)) {
                errno = EBADF;
                return -1;
            }
            intptr_t r = pt_orig_syscall(149, args[0], args[1], args[2], 0, 0, 0, 0, 0);
            if (r >= 0) {
                if (newfd >= 0 && newfd != oldfd) {
                    pt_network_notify_fd_close(newfd);
                }
                pt_network_notify_fd_dup(oldfd, (int)r);
            }
            return r;
        }
        case 104: { // SYS_bind
            return (intptr_t)pt_network_bind_with_caller(
                (int)args[0],
                (const struct sockaddr *)(uintptr_t)args[1],
                (socklen_t)args[2],
                104,
                caller);
        }
        case 98:   // SYS_connect
        case 409: { // SYS_connect_nocancel
            return (intptr_t)pt_network_connect_with_caller(
                (int)args[0],
                (const struct sockaddr *)(uintptr_t)args[1],
                (socklen_t)args[2],
                number,
                caller);
        }
        case 447: { // SYS_connectx
            return (intptr_t)pt_network_connectx_with_caller(
                (int)args[0],
                (const sa_endpoints_t *)(uintptr_t)args[1],
                (sae_associd_t)args[2],
                (unsigned int)args[3],
                (const struct iovec *)(uintptr_t)args[4],
                (unsigned int)args[5],
                (size_t *)(uintptr_t)args[6],
                (sae_connid_t *)(uintptr_t)args[7],
                447,
                caller);
        }
        case 30:   // SYS_accept
        case 404: { // SYS_accept_nocancel
            return (intptr_t)pt_network_accept_with_caller(
                (int)args[0],
                (struct sockaddr *)(uintptr_t)args[1],
                (socklen_t *)(uintptr_t)args[2],
                number,
                caller);
        }
        case 133:  // SYS_sendto
        case 413: { // SYS_sendto_nocancel
            return (intptr_t)pt_network_sendto_with_caller(
                (int)args[0],
                (const void *)(uintptr_t)args[1],
                (size_t)args[2],
                (int)args[3],
                (const struct sockaddr *)(uintptr_t)args[4],
                (socklen_t)args[5],
                number,
                caller);
        }
        case 28:   // SYS_sendmsg
        case 402: { // SYS_sendmsg_nocancel
            return (intptr_t)pt_network_sendmsg_with_caller(
                (int)args[0],
                (const struct msghdr *)(uintptr_t)args[1],
                (int)args[2],
                number,
                caller);
        }
        case 29:   // SYS_recvfrom
        case 403: { // SYS_recvfrom_nocancel
            return (intptr_t)pt_network_recvfrom_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (size_t)args[2],
                (int)args[3],
                (struct sockaddr *)(uintptr_t)args[4],
                (socklen_t *)(uintptr_t)args[5],
                number,
                caller);
        }
        case 27:   // SYS_recvmsg
        case 401: { // SYS_recvmsg_nocancel
            return (intptr_t)pt_network_recvmsg_with_caller(
                (int)args[0],
                (struct msghdr *)(uintptr_t)args[1],
                (int)args[2],
                number,
                caller);
        }
        case 32: { // SYS_getsockname
            return (intptr_t)pt_network_getsockname_with_caller(
                (int)args[0],
                (struct sockaddr *)(uintptr_t)args[1],
                (socklen_t *)(uintptr_t)args[2],
                32,
                caller);
        }
        case 31: { // SYS_getpeername
            return (intptr_t)pt_network_getpeername_with_caller(
                (int)args[0],
                (struct sockaddr *)(uintptr_t)args[1],
                (socklen_t *)(uintptr_t)args[2],
                31,
                caller);
        }
        case 483: { // SYS_csrctl
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                errno = ENOSYS;
                return -1;
            }
            break;
        }
        case 469: { // SYS_fstatat (legacy 120B user64_stat ABI)
            int fd = (int)args[0];
            const char *path = (const char *)(uintptr_t)args[1];
            void *ub = (void *)(uintptr_t)args[2];
            int flag = (int)args[3];
            char vbuf[PATH_MAX];
            const char *resolved = NULL;
            BOOL virtual_anc = NO;
            if (pt_fs_prepare_legacy_stat_path_with_caller(fd, YES, path, caller,
                                                           vbuf, sizeof(vbuf),
                                                           &resolved, &virtual_anc) != 0) {
                return -1;
            }
            if (virtual_anc) {
                if (ub == NULL || !pt_is_valid_user_pointer(ub)) {
                    errno = EFAULT;
                    return -1;
                }
                struct stat st64;
                memset(&st64, 0, sizeof(st64));
                int sr = pt_fs_fstatat_with_caller(fd, path, &st64, flag, caller);
                if (sr == 0) {
                    pt_copy_stat64_to_legacy_user64_stat(&st64, ub);
                }
                return (intptr_t)sr;
            }
            intptr_t r = pt_orig_syscall(469, (uintptr_t)fd, (uintptr_t)resolved, (uintptr_t)ub, (uintptr_t)flag, 0, 0, 0, 0);
            if (r == 0) {
                pt_sanitize_legacy_user64_stat_in_place(ub, caller);
            }
            return r;
        }
        case 470: { // SYS_fstatat64
            int fd = (int)args[0];
            const char *path = (const char *)args[1];
            struct stat *ub = (struct stat *)args[2];
            int flag = (int)args[3];
            return (intptr_t)pt_fs_fstatat_with_caller(fd, path, ub, flag, caller);
        }
        case 33: { // SYS_access
            const char *path = (const char *)args[0];
            int mode = (int)args[1];
            return (intptr_t)pt_fs_access_with_caller(path, mode, caller);
        }
        case 466: { // SYS_faccessat
            int fd = (int)args[0];
            const char *path = (const char *)args[1];
            int mode = (int)args[2];
            int flag = (int)args[3];
            return (intptr_t)pt_fs_faccessat_with_caller(fd, path, mode, flag, caller);
        }
        case 58: { // SYS_readlink
            const char *path = (const char *)args[0];
            char *buf = (char *)args[1];
            size_t count = (size_t)args[2];
            return (intptr_t)pt_fs_readlink_with_caller(path, buf, count, caller);
        }
        case 473: { // SYS_readlinkat
            int fd = (int)args[0];
            const char *path = (const char *)args[1];
            char *buf = (char *)args[2];
            size_t count = (size_t)args[3];
            return (intptr_t)pt_fs_readlinkat_with_caller(fd, path, buf, count, caller);
        }
        case 92: // SYS_fcntl
        case 406: { // SYS_fcntl_nocancel
            int fd = (int)args[0];
            int cmd = (int)args[1];
            uintptr_t arg = pt_fcntl_cmd_has_no_arg(cmd) ? 0 : args[2];
            return (intptr_t)pt_fs_fcntl_with_caller(fd, cmd, arg, caller);
        }
        case 26: { // SYS_ptrace
            int req = (int)args[0];
            pid_t pid = (pid_t)args[1];
            caddr_t addr = (caddr_t)args[2];
            int data = (int)args[3];
            return (intptr_t)pt_ptrace_with_caller(req, pid, addr, data, caller);
        }
        case 2: // SYS_fork
        case 66: // SYS_vfork
        case 59: // SYS_execve
        case 244: // SYS_posix_spawn
        case 380: { // SYS___mac_execve
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                errno = EPERM;
                return -1;
            }
            break;
        }
        case 37: { // SYS_kill
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                pid_t pid = (pid_t)(int)args[0];
                pid_t self_pid = getpid();
                if (pid == -1) {
                    errno = EPERM;
                    return -1;
                }
                if ((pid > 0 && pid != self_pid) ||
                    (pid < -1 && (pid_t)(-pid) != getpgrp())) {
                    errno = ESRCH;
                    return -1;
                }
            }
            break;
        }
        case 151:  // SYS_getpgid
        case 310:  // SYS_getsid
        case 538:  // SYS_task_inspect_for_pid
        case 539: { // SYS_task_read_for_pid
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                pid_t pid = (pid_t)(int)args[0];
                if (pid != 0 && pid != getpid()) {
                    errno = ESRCH;
                    return -1;
                }
            }
            break;
        }
        case 39: { // SYS_getppid
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                return 1;
            }
            break;
        }
        case 41:   // SYS_dup
        case 90: { // SYS_dup2
            int oldfd = (int)args[0];
            int newfd = (number == 90) ? (int)args[1] : -1;
            BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
            if (!is_sys && (pt_is_hidden_fd(oldfd) || (number == 90 && pt_is_hidden_fd(newfd)))) {
                errno = EBADF;
                return -1;
            }
            if (pt_is_bypass_enabled() &&
                !is_sys &&
                pt_fd_is_sensitive(oldfd, caller)) {
                errno = EBADF;
                return -1;
            }
            intptr_t r = pt_orig_syscall(number, args[0], args[1], 0, 0, 0, 0, 0, 0);
            if (r >= 0) {
                if (number == 90 && newfd >= 0 && newfd != oldfd) {
                    pt_network_notify_fd_close(newfd);
                }
                pt_network_notify_fd_dup(oldfd, (int)r);
            }
            return r;
        }
        case 43: { // SYS_getegid
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                return (intptr_t)pt_getegid_with_caller(caller);
            }
            break;
        }
        case 47: { // SYS_getgid
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                return (intptr_t)pt_getgid_with_caller(caller);
            }
            break;
        }
        case 79: { // SYS_getgroups
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                return (intptr_t)pt_getgroups_with_caller((int)args[0], (gid_t *)(uintptr_t)args[1], caller);
            }
            break;
        }
        case 220: { // SYS_getattrlist
            return (intptr_t)pt_fs_getattrlist_with_caller(
                (const char *)(uintptr_t)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (unsigned int)args[4],
                caller);
        }
        case 228: { // SYS_fgetattrlist
            return (intptr_t)pt_fs_fgetattrlist_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (unsigned int)args[4],
                caller);
        }
        case 476: { // SYS_getattrlistat
            return (intptr_t)pt_fs_getattrlistat_with_caller(
                (int)args[0],
                (const char *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (void *)(uintptr_t)args[3],
                (size_t)args[4],
                (unsigned long)args[5],
                caller);
        }
        case 12: { // SYS_chdir
            return (intptr_t)pt_fs_chdir_with_caller((const char *)(uintptr_t)args[0], caller);
        }
        case 13: { // SYS_fchdir
            return (intptr_t)pt_fs_fchdir_with_caller((int)args[0], caller);
        }
        case 49: { // SYS_getlogin
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                char *namebuf = (char *)(uintptr_t)args[0];
                size_t namelen = (size_t)args[1];
                if (namebuf == NULL || !pt_is_valid_user_pointer(namebuf) || namelen == 0) {
                    errno = EINVAL;
                    return -1;
                }
                strlcpy(namebuf, "mobile", namelen);
                return 0;
            }
            break;
        }
        case 196: { // SYS_getdirentries
            return (intptr_t)pt_fs_getdirentries_syscall_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (size_t)args[2],
                (long *)(uintptr_t)args[3],
                caller);
        }
        case 222: { // SYS_getdirentriesattr
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                errno = ENOTSUP;
                return -1;
            }
            break;
        }
        case 277: { // SYS_open_extended
            return (intptr_t)pt_fs_open_extended_with_caller(
                (const char *)(uintptr_t)args[0],
                (int)args[1],
                (uid_t)args[2],
                (gid_t)args[3],
                (int)args[4],
                (void *)(uintptr_t)args[5],
                caller);
        }
        case 279: // SYS_stat_extended
        case 280: { // SYS_lstat_extended
            return (intptr_t)pt_fs_stat_extended_with_caller(
                (const char *)(uintptr_t)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t *)(uintptr_t)args[3],
                NO,
                number == 279,
                caller);
        }
        case 281: { // SYS_fstat_extended
            return (intptr_t)pt_fs_fstat_extended_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t *)(uintptr_t)args[3],
                NO,
                caller);
        }
        case 284: { // SYS_access_extended
            return (intptr_t)pt_fs_access_extended_with_caller(
                (void *)(uintptr_t)args[0],
                (size_t)args[1],
                (void *)(uintptr_t)args[2],
                (uid_t)args[3],
                caller);
        }
        case 341: // SYS_stat64_extended
        case 342: { // SYS_lstat64_extended
            return (intptr_t)pt_fs_stat_extended_with_caller(
                (const char *)(uintptr_t)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t *)(uintptr_t)args[3],
                YES,
                number == 341,
                caller);
        }
        case 343: { // SYS_fstat64_extended
            return (intptr_t)pt_fs_fstat_extended_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t *)(uintptr_t)args[3],
                YES,
                caller);
        }
        case 441: { // SYS_guarded_open_np
            return (intptr_t)pt_fs_guarded_open_np_with_caller(
                (const char *)(uintptr_t)args[0],
                (const void *)(uintptr_t)args[1],
                (unsigned int)args[2],
                (int)args[3],
                (mode_t)args[4],
                caller);
        }
        case 484: { // SYS_guarded_open_dprotected_np
            return (intptr_t)pt_fs_guarded_open_dprotected_np_with_caller(
                (const char *)(uintptr_t)args[0],
                (const void *)(uintptr_t)args[1],
                (unsigned int)args[2],
                (int)args[3],
                (int)args[4],
                (int)args[5],
                (mode_t)args[6],
                caller);
        }
        case 336: { // SYS_proc_info
            int32_t callnum = (int32_t)args[0];
            int32_t pid = (int32_t)args[1];
            uint32_t flavor = (uint32_t)args[2];
            uint64_t arg = (uint64_t)args[3];
            void *buffer = (void *)args[4];
            int32_t buffersize = (int32_t)args[5];
            BOOL is_bypass_app = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
            if (callnum == 1) { // PROC_INFO_CALL_LISTPIDS
                return (intptr_t)pt_fs_proc_listpids_syscall_with_caller((uint32_t)pid, (uint32_t)flavor, buffer, buffersize, caller);
            } else if (callnum == 2) { // PROC_INFO_CALL_PIDINFO
                return (intptr_t)pt_fs_proc_pidinfo_syscall_with_caller(pid, (int)flavor, arg, buffer, buffersize, caller);
            } else if (callnum == 3) { // PROC_INFO_CALL_PIDFDINFO
                return (intptr_t)pt_fs_proc_pidfdinfo_syscall_with_caller(pid, (int)arg, (int)flavor, buffer, buffersize, caller);
            } else if (callnum == 6) { // PROC_INFO_CALL_PIDFILEPORTINFO
                return (intptr_t)pt_fs_proc_pidfileportinfo_syscall_with_caller(pid, (uint32_t)arg, (int)flavor, buffer, buffersize, caller);
            } else if (is_bypass_app) {
                if (callnum == 4 || callnum == 11) { // KERNMSGBUF / LISTCOALITIONS
                    errno = EPERM;
                    return -1;
                }
                if (callnum == 10) { // PIDORIGINATORINFO
                    errno = ESRCH;
                    return -1;
                }
                if (pid != 0 && pid != getpid()) {
                    errno = ESRCH;
                    return -1;
                }
            }
            break;
        }
        case 545: { // SYS_proc_info_extended_id
            int32_t callnum = (int32_t)args[0];
            int32_t pid = (int32_t)args[1];
            uint32_t flavor = (uint32_t)args[2];
            uint64_t arg = (uint64_t)args[5];
            void *buffer = (void *)(uintptr_t)args[6];
            int32_t buffersize = (int32_t)args[7];
            BOOL is_bypass_app = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
            if (callnum == 1) { // PROC_INFO_CALL_LISTPIDS
                return (intptr_t)pt_fs_proc_listpids_syscall_with_caller((uint32_t)pid, flavor, buffer, buffersize, caller);
            } else if (callnum == 2) { // PROC_INFO_CALL_PIDINFO
                return (intptr_t)pt_fs_proc_pidinfo_syscall_with_caller(pid, (int)flavor, arg, buffer, buffersize, caller);
            } else if (callnum == 3) { // PROC_INFO_CALL_PIDFDINFO
                return (intptr_t)pt_fs_proc_pidfdinfo_syscall_with_caller(pid, (int)arg, (int)flavor, buffer, buffersize, caller);
            } else if (callnum == 6) { // PROC_INFO_CALL_PIDFILEPORTINFO
                return (intptr_t)pt_fs_proc_pidfileportinfo_syscall_with_caller(pid, (uint32_t)arg, (int)flavor, buffer, buffersize, caller);
            } else if (is_bypass_app) {
                if (callnum == 4 || callnum == 11) {
                    errno = EPERM;
                    return -1;
                }
                if (callnum == 10) {
                    errno = ESRCH;
                    return -1;
                }
                if (pid != 0 && pid != getpid()) {
                    errno = ESRCH;
                    return -1;
                }
            }
            break;
        }
        case 10:   // SYS_unlink
        case 15:   // SYS_chmod
        case 16:   // SYS_chown
        case 34:   // SYS_chflags
        case 137:  // SYS_rmdir
        case 138:  // SYS_utimes
        case 200:  // SYS_truncate
        case 221:  // SYS_setattrlist
        case 236:  // SYS_setxattr
        case 238:  // SYS_removexattr
        case 282:  // SYS_chmod_extended
        case 364:  // SYS_lchown
        case 136:  // SYS_mkdir
        case 292: { // SYS_mkdir_extended
            char vbuf[PATH_MAX];
            const char *path = (const char *)(uintptr_t)args[0];
            int anc_err = (number == 136 || number == 292) ? EEXIST : EACCES;
            if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, caller, vbuf, sizeof(vbuf), &path, anc_err)) {
                return -1;
            }
            return pt_orig_syscall(number, (uintptr_t)path, args[1], args[2], args[3], args[4], args[5], args[6], args[7]);
        }
        case 214:  // SYS_fchflagsat
        case 467:  // SYS_fchmodat
        case 468:  // SYS_fchownat
        case 472:  // SYS_unlinkat
        case 475:  // SYS_mkdirat
        case 524: { // SYS_setattrlistat
            char vbuf[PATH_MAX];
            int dirfd = (int)args[0];
            const char *path = (const char *)(uintptr_t)args[1];
            int anc_err = (number == 475) ? EEXIST : EACCES;
            if (!pt_prepare_fs_path_for_modify(dirfd, path, caller, vbuf, sizeof(vbuf), &path, anc_err)) {
                return -1;
            }
            return pt_orig_syscall(number, args[0], (uintptr_t)path, args[2], args[3], args[4], args[5], args[6], args[7]);
        }
        case 9:    // SYS_link
        case 57:   // SYS_symlink
        case 128:  // SYS_rename
        case 223: { // SYS_exchangedata
            char vbuf1[PATH_MAX];
            char vbuf2[PATH_MAX];
            const char *p1 = (const char *)(uintptr_t)args[0];
            const char *p2 = (const char *)(uintptr_t)args[1];
            if (!pt_prepare_fs_path_for_modify(AT_FDCWD, p1, caller, vbuf1, sizeof(vbuf1), &p1, EACCES) ||
                !pt_prepare_fs_path_for_modify(AT_FDCWD, p2, caller, vbuf2, sizeof(vbuf2), &p2, EACCES)) {
                return -1;
            }
            return pt_orig_syscall(number, (uintptr_t)p1, (uintptr_t)p2, args[2], args[3], args[4], args[5], args[6], args[7]);
        }
        case 474: { // SYS_symlinkat(path1, fd, path2)
            char vbuf1[PATH_MAX];
            char vbuf2[PATH_MAX];
            const char *p1 = (const char *)(uintptr_t)args[0];
            int fd2 = (int)args[1];
            const char *p2 = (const char *)(uintptr_t)args[2];
            if (!pt_prepare_fs_path_for_modify(AT_FDCWD, p1, caller, vbuf1, sizeof(vbuf1), &p1, EACCES) ||
                !pt_prepare_fs_path_for_modify(fd2, p2, caller, vbuf2, sizeof(vbuf2), &p2, EACCES)) {
                return -1;
            }
            return pt_orig_syscall(474, (uintptr_t)p1, args[1], (uintptr_t)p2, 0, 0, 0, 0, 0);
        }
        case 465:  // SYS_renameat(fromfd, from, tofd, to)
        case 471:  // SYS_linkat(fd1, name1, fd2, name2, flag)
        case 488: { // SYS_renameatx_np(fromfd, from, tofd, to, flags)
            char vbuf1[PATH_MAX];
            char vbuf2[PATH_MAX];
            int fd1 = (int)args[0];
            const char *p1 = (const char *)(uintptr_t)args[1];
            int fd2 = (int)args[2];
            const char *p2 = (const char *)(uintptr_t)args[3];
            if (!pt_prepare_fs_path_for_modify(fd1, p1, caller, vbuf1, sizeof(vbuf1), &p1, EACCES) ||
                !pt_prepare_fs_path_for_modify(fd2, p2, caller, vbuf2, sizeof(vbuf2), &p2, EACCES)) {
                return -1;
            }
            return pt_orig_syscall(number, args[0], (uintptr_t)p1, args[2], (uintptr_t)p2, args[4], 0, 0, 0);
        }
        case 229:  // SYS_fsetattrlist
        case 237:  // SYS_fsetxattr
        case 239: { // SYS_fremovexattr
            if (!pt_is_effective_system_or_playtools_caller(caller) &&
                (pt_is_hidden_fd((int)args[0]) || pt_fd_is_sensitive((int)args[0], caller))) {
                errno = EBADF;
                return -1;
            }
            break;
        }
        case 551: { // SYS_freadlink
            return (intptr_t)pt_fs_freadlink_with_caller(
                (int)args[0],
                (char *)(uintptr_t)args[1],
                (size_t)args[2],
                caller);
        }
        case 381: { // SYS___mac_syscall
            return (intptr_t)pt_mac_syscall_with_caller(
                (const char *)(uintptr_t)args[0],
                (int)args[1],
                (void *)(uintptr_t)args[2],
                caller,
                out_handled);
        }
        case 427: { // SYS_fsgetpath
            return (intptr_t)pt_fs_fsgetpath_with_caller(
                (char *)(uintptr_t)args[0],
                (size_t)args[1],
                (fsid_t *)(uintptr_t)args[2],
                (uint64_t)args[3],
                caller);
        }
        default:
            break;
    }

    if (out_handled != NULL) {
        *out_handled = NO;
    }
    return 0;
}

static intptr_t pt_syscall(int number, ...) {
    pthread_t self_thr = pthread_self();
    uintptr_t stack_top = (self_thr != NULL) ? (uintptr_t)pthread_get_stackaddr_np(self_thr) : 0;
    size_t stack_sz = (self_thr != NULL) ? pthread_get_stacksize_np(self_thr) : 0;
    uintptr_t stack_bot = (stack_top >= stack_sz && stack_sz > 0) ? (stack_top - stack_sz) : 0;

    va_list ap;
    va_start(ap, number);

    uintptr_t args[PT_XNU_SYSCALL_MAX_ARGS] = {0};
    for (int i = 0; i < PT_XNU_SYSCALL_MAX_ARGS; i++) {
        if (!pt_va_can_pop_uintptr(ap, stack_bot, stack_top)) {
            break;
        }
        args[i] = va_arg(ap, uintptr_t);
    }
    va_end(ap);

    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return pt_orig_syscall(number, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]);
    }

    const void *caller = __builtin_return_address(0);
    if (number == 0 || number == 198) {
        if (args[0] == 0 && stack_top > 0 && stack_bot == stack_top) {
            errno = EFAULT;
            return -1;
        }
    }

    BOOL handled = NO;
    intptr_t res = pt_syscall_dispatch_with_caller(number, args, caller, &handled);
    if (handled) {
        return res;
    }
    return pt_orig_syscall(number, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]);
}

#pragma mark - MIG Reply Sanitization

#ifndef PT_MIG_REQ_RING_SIZE
#define PT_MIG_REQ_RING_SIZE 16U
#endif

typedef kern_return_t (*PTMachMsg2InternalFn)(void *data,
                                              uint64_t option64,
                                              uint64_t msgh_bits_and_send_size,
                                              uint64_t msgh_remote_and_local_port,
                                              uint64_t msgh_voucher_and_id,
                                              uint64_t desc_count_and_rcv_name,
                                              uint64_t rcv_size,
                                              uint64_t priority_and_timeout);

typedef struct {
    int req_id;
    mach_port_t target_port;
    uint64_t addr;
    uint64_t size;
    uint64_t dst;
    uint32_t region_depth_or_flavor;
    uint32_t region_info_cnt;
    uint32_t list_count;
    uint64_t list_addrs[VM_MAP_ENTRY_MAX];
} PTMIGVMMeta;

typedef struct {
    mach_port_t reply_port;
    int req_id;
    int32_t req_flavor;
    bool target_is_self;
    PTMIGVMMeta vm_meta;
    bool valid;
} PTMIGPendingRequest;

static os_unfair_lock s_mig_req_ring_lock = OS_UNFAIR_LOCK_INIT;
static PTMIGPendingRequest s_mig_req_ring[PT_MIG_REQ_RING_SIZE];
static uint32_t s_mig_req_ring_next = 0;
static _Thread_local PTMIGVMMeta s_tls_mig_vm_meta = {0};
static _Thread_local int s_tls_in_pt_mach_msg = 0;

static void pt_mig_vm_meta_copy(PTMIGVMMeta *dst, const PTMIGVMMeta *src) {
    dst->req_id = src->req_id;
    dst->target_port = src->target_port;
    dst->addr = src->addr;
    dst->size = src->size;
    dst->dst = src->dst;
    dst->region_depth_or_flavor = src->region_depth_or_flavor;
    dst->region_info_cnt = src->region_info_cnt;
    dst->list_count = src->list_count;
    if (src->list_count > 0U && src->list_count <= VM_MAP_ENTRY_MAX) {
        memcpy(dst->list_addrs, src->list_addrs, (size_t)src->list_count * sizeof(uint64_t));
    }
}

static BOOL pt_is_tracked_mig_req_id(int req_id) {
    return (req_id == 200 ||
            req_id == 201 ||
            req_id == 216 ||
            req_id == 204 ||
            req_id == 219 ||
            req_id == 3402 ||
            req_id == 3405 ||
            req_id == 3413 ||
            req_id == 3414 ||
            req_id == 3415 ||
            req_id == 3460 ||
            req_id == 3603 ||
            req_id == 3612 ||
            req_id == 3613 ||
            req_id == 3614 ||
            req_id == 3615 ||
            req_id == 3630 ||
            req_id == 3805 ||
            req_id == 3806 ||
            req_id == 3808 ||
            req_id == 3809 ||
            req_id == 3822 ||
            req_id == 3824 ||
            req_id == 4804 ||
            req_id == 4805 ||
            req_id == 4807 ||
            req_id == 4808 ||
            req_id == 4815 ||
            req_id == 4816);
}

static void pt_mig_ring_push(mach_port_t reply_port, int req_id, int32_t req_flavor, bool target_is_self) {
    if (reply_port == MACH_PORT_NULL || !target_is_self) {
        return;
    }
    if (!pt_is_tracked_mig_req_id(req_id)) {
        return;
    }
    bool has_tls = (s_tls_mig_vm_meta.req_id == req_id);
    os_unfair_lock_lock(&s_mig_req_ring_lock);
    for (uint32_t i = 0; i < PT_MIG_REQ_RING_SIZE; i++) {
        if (s_mig_req_ring[i].valid && s_mig_req_ring[i].reply_port == reply_port) {
            s_mig_req_ring[i].req_id = req_id;
            s_mig_req_ring[i].req_flavor = req_flavor;
            s_mig_req_ring[i].target_is_self = target_is_self;
            if (has_tls) {
                pt_mig_vm_meta_copy(&s_mig_req_ring[i].vm_meta, &s_tls_mig_vm_meta);
            } else {
                memset(&s_mig_req_ring[i].vm_meta, 0, sizeof(PTMIGVMMeta));
            }
            os_unfair_lock_unlock(&s_mig_req_ring_lock);
            return;
        }
    }
    uint32_t slot = s_mig_req_ring_next % PT_MIG_REQ_RING_SIZE;
    s_mig_req_ring_next = (s_mig_req_ring_next + 1U) % PT_MIG_REQ_RING_SIZE;
    s_mig_req_ring[slot].reply_port = reply_port;
    s_mig_req_ring[slot].req_id = req_id;
    s_mig_req_ring[slot].req_flavor = req_flavor;
    s_mig_req_ring[slot].target_is_self = target_is_self;
    if (has_tls) {
        pt_mig_vm_meta_copy(&s_mig_req_ring[slot].vm_meta, &s_tls_mig_vm_meta);
    } else {
        memset(&s_mig_req_ring[slot].vm_meta, 0, sizeof(PTMIGVMMeta));
    }
    s_mig_req_ring[slot].valid = true;
    os_unfair_lock_unlock(&s_mig_req_ring_lock);
}

static bool pt_mig_ring_pop(mach_port_t reply_port,
                            int *out_req_id,
                            int32_t *out_req_flavor,
                            bool *out_target_is_self,
                            PTMIGVMMeta *out_vm_meta) {
    if (reply_port == MACH_PORT_NULL) {
        return false;
    }
    os_unfair_lock_lock(&s_mig_req_ring_lock);
    for (uint32_t i = 0; i < PT_MIG_REQ_RING_SIZE; i++) {
        if (s_mig_req_ring[i].valid && s_mig_req_ring[i].reply_port == reply_port) {
            if (out_req_id != NULL) {
                *out_req_id = s_mig_req_ring[i].req_id;
            }
            if (out_req_flavor != NULL) {
                *out_req_flavor = s_mig_req_ring[i].req_flavor;
            }
            if (out_target_is_self != NULL) {
                *out_target_is_self = s_mig_req_ring[i].target_is_self;
            }
            if (out_vm_meta != NULL) {
                pt_mig_vm_meta_copy(out_vm_meta, &s_mig_req_ring[i].vm_meta);
            }
            s_mig_req_ring[i].valid = false;
            os_unfair_lock_unlock(&s_mig_req_ring_lock);
            return true;
        }
    }
    os_unfair_lock_unlock(&s_mig_req_ring_lock);
    return false;
}

static void pt_mig_ring_erase(mach_port_t reply_port, int req_id, int32_t req_flavor) {
    if (reply_port == MACH_PORT_NULL) {
        return;
    }
    os_unfair_lock_lock(&s_mig_req_ring_lock);
    for (uint32_t i = 0; i < PT_MIG_REQ_RING_SIZE; i++) {
        if (s_mig_req_ring[i].valid &&
            s_mig_req_ring[i].reply_port == reply_port &&
            s_mig_req_ring[i].req_id == req_id &&
            s_mig_req_ring[i].req_flavor == req_flavor) {
            s_mig_req_ring[i].valid = false;
            break;
        }
    }
    os_unfair_lock_unlock(&s_mig_req_ring_lock);
}

static bool pt_extract_mig_request_meta(void *req_buf,
                                        mach_msg_bits_t bits,
                                        mach_msg_size_t send_size,
                                        mach_port_t remote_port,
                                        int req_id,
                                        int32_t *out_flavor,
                                        bool *out_target_is_self,
                                        exception_mask_t *out_orig_exc_mask,
                                        bool *out_patched_exc_mask) {
    s_tls_mig_vm_meta.req_id = 0;
    s_tls_mig_vm_meta.list_count = 0U;
    if (out_orig_exc_mask != NULL) {
        *out_orig_exc_mask = 0;
    }
    if (out_patched_exc_mask != NULL) {
        *out_patched_exc_mask = false;
    }
    if (req_buf == NULL || !pt_is_tracked_mig_req_id(req_id)) {
        return false;
    }
    bool is_complex = ((bits & MACH_MSGH_BITS_COMPLEX) != 0);
    if (req_id == 3413 || req_id == 3415 || req_id == 3613 || req_id == 3615) {
        // task/thread_set/swap_exception_ports carries new_port descriptor (complex).
        if (send_size < sizeof(mach_msg_header_t)) {
            return false;
        }
        BOOL is_thread = (req_id == 3613 || req_id == 3615);
        bool target_self = is_thread ? (remote_port != MACH_PORT_NULL) : (remote_port == mach_task_self());
        if (target_self && is_complex && send_size >= 60U) {
            uint8_t *bytes = (uint8_t *)req_buf;
            mach_msg_port_descriptor_t port_desc;
            exception_mask_t orig_mask = 0;
            exception_behavior_t behavior = 0;
            thread_state_flavor_t flavor = 0;
            memcpy(&port_desc, bytes + 28U, sizeof(port_desc));
            memcpy(&orig_mask, bytes + 48U, sizeof(orig_mask));
            memcpy(&behavior, bytes + 52U, sizeof(behavior));
            memcpy(&flavor, bytes + 56U, sizeof(flavor));
            if ((orig_mask & EXC_MASK_BREAKPOINT) != 0 &&
                port_desc.type == MACH_MSG_PORT_DESCRIPTOR &&
                pt_svc_record_bp_handler_from_mig(is_thread, remote_port, orig_mask, port_desc.name, behavior, flavor)) {
                exception_mask_t filtered = orig_mask & ~((exception_mask_t)EXC_MASK_BREAKPOINT);
                memcpy(bytes + 48U, &filtered, sizeof(filtered));
                if (out_orig_exc_mask != NULL) {
                    *out_orig_exc_mask = orig_mask;
                }
                if (out_patched_exc_mask != NULL) {
                    *out_patched_exc_mask = true;
                }
            }
        }
        if (out_flavor != NULL) {
            *out_flavor = 0;
        }
        if (out_target_is_self != NULL) {
            *out_target_is_self = target_self;
        }
        return (req_id == 3415 || req_id == 3615);
    }
    if (is_complex) {
        return false;
    }
    if (req_id == 201 || req_id == 3402 || req_id == 3614 || req_id == 3460 || req_id == 3630) {
        if (send_size < sizeof(mach_msg_header_t)) {
            return false;
        }
        s_tls_mig_vm_meta.req_id = req_id;
        s_tls_mig_vm_meta.target_port = remote_port;
        if (out_flavor != NULL) {
            *out_flavor = 0;
        }
        if (out_target_is_self != NULL) {
            *out_target_is_self = (req_id == 201 || req_id == 3614 || req_id == 3630) ? true : (remote_port == mach_task_self());
        }
        return true;
    }
    const size_t body_off = sizeof(mach_msg_header_t) + sizeof(NDR_record_t);
    if (req_id == 4804 || req_id == 3805) {
        if (send_size < body_off + sizeof(uint64_t) * 2U) {
            return false;
        }
        uint64_t addr = 0;
        uint64_t sz = 0;
        memcpy(&addr, (const uint8_t *)req_buf + body_off, sizeof(addr));
        memcpy(&sz, (const uint8_t *)req_buf + body_off + sizeof(uint64_t), sizeof(sz));
        s_tls_mig_vm_meta.req_id = req_id;
        s_tls_mig_vm_meta.addr = addr;
        s_tls_mig_vm_meta.size = sz;
        s_tls_mig_vm_meta.dst = 0;
        s_tls_mig_vm_meta.list_count = 0U;
        if (out_flavor != NULL) {
            *out_flavor = 0;
        }
        if (out_target_is_self != NULL) {
            *out_target_is_self = (remote_port == mach_task_self());
        }
        return true;
    }
    if (req_id == 4805 || req_id == 3806) {
        const size_t list_bytes = (size_t)VM_MAP_ENTRY_MAX * 16U;
        if (send_size < body_off + list_bytes + sizeof(natural_t)) {
            return false;
        }
        const uint8_t *bytes = (const uint8_t *)req_buf;
        natural_t cnt = 0;
        memcpy(&cnt, bytes + body_off + list_bytes, sizeof(cnt));
        if (cnt > VM_MAP_ENTRY_MAX) {
            cnt = VM_MAP_ENTRY_MAX;
        }
        s_tls_mig_vm_meta.req_id = req_id;
        s_tls_mig_vm_meta.list_count = (uint32_t)cnt;
        for (natural_t i = 0; i < cnt; i++) {
            uint64_t a = 0;
            memcpy(&a, bytes + body_off + (size_t)i * 16U, sizeof(a));
            s_tls_mig_vm_meta.list_addrs[i] = a;
        }
        if (out_flavor != NULL) {
            *out_flavor = 0;
        }
        if (out_target_is_self != NULL) {
            *out_target_is_self = (remote_port == mach_task_self());
        }
        return true;
    }
    if (req_id == 4816 || req_id == 3824 || req_id == 4815 || req_id == 3822) {
        // Header(24) + NDR(8) + address(8) + flavor/nesting_depth(4) + infoCnt(4) = 48 bytes
        if (send_size < body_off + sizeof(uint64_t) + sizeof(uint32_t) * 2U) {
            return false;
        }
        const uint8_t *bytes = (const uint8_t *)req_buf;
        uint32_t depth_or_flavor = 0;
        uint32_t info_cnt = 0;
        memcpy(&depth_or_flavor, bytes + body_off + sizeof(uint64_t), sizeof(depth_or_flavor));
        memcpy(&info_cnt, bytes + body_off + sizeof(uint64_t) + sizeof(uint32_t), sizeof(info_cnt));
        s_tls_mig_vm_meta.req_id = req_id;
        s_tls_mig_vm_meta.target_port = remote_port;
        s_tls_mig_vm_meta.region_depth_or_flavor = depth_or_flavor;
        s_tls_mig_vm_meta.region_info_cnt = info_cnt;
        s_tls_mig_vm_meta.list_count = 0U;
        if (out_flavor != NULL) {
            *out_flavor = (int32_t)depth_or_flavor;
        }
        if (out_target_is_self != NULL) {
            *out_target_is_self = (remote_port == mach_task_self());
        }
        return true;
    }
    if (req_id == 4807 || req_id == 3808 || req_id == 4808 || req_id == 3809) {
        if (send_size < body_off + sizeof(uint64_t) * 3U) {
            return false;
        }
        uint64_t addr = 0;
        uint64_t sz = 0;
        uint64_t dst = 0;
        memcpy(&addr, (const uint8_t *)req_buf + body_off, sizeof(addr));
        memcpy(&sz, (const uint8_t *)req_buf + body_off + sizeof(uint64_t), sizeof(sz));
        memcpy(&dst, (const uint8_t *)req_buf + body_off + sizeof(uint64_t) * 2U, sizeof(dst));
        s_tls_mig_vm_meta.req_id = req_id;
        s_tls_mig_vm_meta.addr = addr;
        s_tls_mig_vm_meta.size = sz;
        s_tls_mig_vm_meta.dst = dst;
        s_tls_mig_vm_meta.list_count = 0U;
        if (out_flavor != NULL) {
            *out_flavor = 0;
        }
        if (out_target_is_self != NULL) {
            *out_target_is_self = (remote_port == mach_task_self());
        }
        return true;
    }
    const size_t min_req_size = body_off + sizeof(int32_t);
    if (send_size < min_req_size) {
        return false;
    }
    int32_t flavor = 0;
    memcpy(&flavor, (const uint8_t *)req_buf + body_off, sizeof(flavor));
    if (out_flavor != NULL) {
        *out_flavor = flavor;
    }
    if (out_target_is_self != NULL) {
        *out_target_is_self = (req_id == 200 || req_id == 216 || req_id == 204 || req_id == 219 ||
                               req_id == 3603 || req_id == 3612)
            ? true
            : (remote_port == mach_task_self());
    }
    return true;
}

static void pt_sanitize_mig_host_kernel_version_reply(void *rcv_buf, size_t usable_bytes, size_t rcv_cap) {
    const size_t prefix = sizeof(mach_msg_header_t) + sizeof(NDR_record_t);
    const size_t rc_off = prefix;
    const size_t str_off_off = rc_off + sizeof(kern_return_t);
    const size_t str_cnt_off = str_off_off + sizeof(mach_msg_type_number_t);
    const size_t str_data_off = str_cnt_off + sizeof(mach_msg_type_number_t);
    if (usable_bytes < str_data_off || rcv_cap < str_data_off + 2U) {
        return;
    }
    uint8_t *bytes = (uint8_t *)rcv_buf;
    kern_return_t reply_rc = KERN_FAILURE;
    memcpy(&reply_rc, bytes + rc_off, sizeof(reply_rc));
    if (reply_rc != KERN_SUCCESS) {
        return;
    }
    mach_msg_type_number_t ver_off = 0;
    mach_msg_type_number_t ver_cnt = 0;
    memcpy(&ver_off, bytes + str_off_off, sizeof(ver_off));
    memcpy(&ver_cnt, bytes + str_cnt_off, sizeof(ver_cnt));
    if (ver_off != 0U || ver_cnt == 0U || ver_cnt > sizeof(kernel_version_t) ||
        str_data_off + (size_t)ver_cnt > usable_bytes) {
        return;
    }
    size_t max_str = rcv_cap - str_data_off;
    if (max_str > sizeof(kernel_version_t)) {
        max_str = sizeof(kernel_version_t);
    }
    char kver[sizeof(kernel_version_t)];
    memset(kver, 0, sizeof(kver));
    pt_format_kernel_version(pt_get_active_device_profile(), kver, max_str);
    size_t new_cnt = strlen(kver) + 1U;
    if (new_cnt > max_str) {
        new_cnt = max_str;
        kver[new_cnt - 1U] = '\0';
    }
    if ((size_t)ver_cnt > new_cnt) {
        memset(bytes + str_data_off + new_cnt, 0, (size_t)ver_cnt - new_cnt);
    }
    memcpy(bytes + str_data_off, kver, new_cnt);
    mach_msg_type_number_t new_cnt_u32 = (mach_msg_type_number_t)new_cnt;
    memcpy(bytes + str_cnt_off, &new_cnt_u32, sizeof(new_cnt_u32));
    size_t padded_total = (str_data_off + new_cnt + 3U) & ~3U;
    if (padded_total <= rcv_cap) {
        if (padded_total > str_data_off + new_cnt) {
            memset(bytes + str_data_off + new_cnt, 0, padded_total - (str_data_off + new_cnt));
        }
        mach_msg_header_t *hdr_mut = (mach_msg_header_t *)rcv_buf;
        hdr_mut->msgh_size = (mach_msg_size_t)padded_total;
    }
}

static void pt_sanitize_mig_host_processor_info_reply(void *rcv_buf, size_t usable_bytes) {
    const size_t body_off = sizeof(mach_msg_header_t);
    const size_t desc_off = body_off + sizeof(mach_msg_body_t);
    const size_t ndr_off = desc_off + sizeof(mach_msg_ool_descriptor_t);
    const size_t proc_cnt_off = ndr_off + sizeof(NDR_record_t);
    const size_t info_cnt_off = proc_cnt_off + sizeof(natural_t);
    const size_t min_sz = info_cnt_off + sizeof(mach_msg_type_number_t);
    if (usable_bytes < min_sz) {
        return;
    }
    uint8_t *bytes = (uint8_t *)rcv_buf;
    mach_msg_body_t body;
    memcpy(&body, bytes + body_off, sizeof(body));
    if (body.msgh_descriptor_count != 1U) {
        return;
    }
    mach_msg_ool_descriptor_t desc;
    memcpy(&desc, bytes + desc_off, sizeof(desc));
    if (desc.type != MACH_MSG_OOL_DESCRIPTOR || desc.address == NULL || desc.size == 0U) {
        return;
    }
    natural_t proc_cnt = 0;
    mach_msg_type_number_t info_cnt = 0;
    memcpy(&proc_cnt, bytes + proc_cnt_off, sizeof(proc_cnt));
    memcpy(&info_cnt, bytes + info_cnt_off, sizeof(info_cnt));
    if (proc_cnt == 0U || info_cnt == 0U || (info_cnt % proc_cnt) != 0U ||
        (size_t)desc.size != (size_t)info_cnt * sizeof(integer_t)) {
        return;
    }
    natural_t spoof_cores = (natural_t)pt_get_active_device_profile()->cores;
    if (spoof_cores == 0U || proc_cnt == spoof_cores) {
        return;
    }
    mach_msg_type_number_t per_core = info_cnt / proc_cnt;
    mach_msg_type_number_t new_info_cnt = per_core * spoof_cores;
    size_t used_bytes = (size_t)new_info_cnt * sizeof(integer_t);
    if (proc_cnt < spoof_cores) {
        vm_address_t new_addr = 0;
        if (per_core == 0U ||
            vm_allocate(mach_task_self(), &new_addr, (vm_size_t)used_bytes, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
            return;
        }
        const integer_t *src = (const integer_t *)desc.address;
        integer_t *dst = (integer_t *)new_addr;
        memcpy(dst, src, (size_t)desc.size);
        for (natural_t i = proc_cnt; i < spoof_cores; i++) {
            natural_t src_idx = i % proc_cnt;
            memcpy(dst + (size_t)i * per_core,
                   src + (size_t)src_idx * per_core,
                   (size_t)per_core * sizeof(integer_t));
        }
        vm_deallocate(mach_task_self(), (vm_address_t)desc.address, (vm_size_t)desc.size);
        desc.address = (void *)new_addr;
    }
    if (vm_page_size > 0) {
        size_t page_sz = (size_t)vm_page_size;
        size_t alloc_bytes = ((used_bytes + page_sz - 1U) / page_sz) * page_sz;
        if (alloc_bytes > used_bytes) {
            memset((uint8_t *)desc.address + used_bytes, 0, alloc_bytes - used_bytes);
        }
    }
    desc.size = (mach_msg_size_t)used_bytes;
    memcpy(bytes + desc_off, &desc, sizeof(desc));
    memcpy(bytes + proc_cnt_off, &spoof_cores, sizeof(spoof_cores));
    memcpy(bytes + info_cnt_off, &new_info_cnt, sizeof(new_info_cnt));
}

static void pt_sanitize_mig_task_threads_reply(void *rcv_buf, size_t usable_bytes) {
    const size_t body_off = sizeof(mach_msg_header_t);
    const size_t desc_off = body_off + sizeof(mach_msg_body_t);
    const size_t ndr_off = desc_off + sizeof(mach_msg_ool_ports_descriptor_t);
    const size_t cnt_off = ndr_off + sizeof(NDR_record_t);
    const size_t min_sz = cnt_off + sizeof(mach_msg_type_number_t);
    if (usable_bytes < min_sz) {
        return;
    }
    uint8_t *bytes = (uint8_t *)rcv_buf;
    mach_msg_body_t body;
    memcpy(&body, bytes + body_off, sizeof(body));
    if (body.msgh_descriptor_count != 1U) {
        return;
    }
    mach_msg_ool_ports_descriptor_t desc;
    memcpy(&desc, bytes + desc_off, sizeof(desc));
    if (desc.type != MACH_MSG_OOL_PORTS_DESCRIPTOR || desc.address == NULL || desc.count == 0U || desc.count > 16384U) {
        return;
    }
    mach_msg_type_number_t act_cnt = 0;
    memcpy(&act_cnt, bytes + cnt_off, sizeof(act_cnt));
    if (act_cnt != desc.count) {
        return;
    }
    thread_act_t *orig_list = (thread_act_t *)desc.address;
    mach_msg_type_number_t orig_cnt = desc.count;
    thread_act_t stack_kept[256];
    thread_act_t *kept_buf = stack_kept;
    if (orig_cnt > (mach_msg_type_number_t)(sizeof(stack_kept) / sizeof(stack_kept[0]))) {
        kept_buf = (thread_act_t *)malloc((size_t)orig_cnt * sizeof(thread_act_t));
        if (kept_buf == NULL) {
            return;
        }
    }
    mach_msg_type_number_t kept = 0;
    for (mach_msg_type_number_t i = 0; i < orig_cnt; i++) {
        thread_act_t thr = orig_list[i];
        if (pt_is_hidden_mach_thread(thr)) {
            mach_port_deallocate(mach_task_self(), thr);
        } else {
            kept_buf[kept++] = thr;
        }
    }
    if (kept < orig_cnt) {
        if (kept == 0U) {
            vm_deallocate(mach_task_self(), (vm_address_t)orig_list, (vm_size_t)(orig_cnt * sizeof(thread_act_t)));
            desc.address = NULL;
            desc.count = 0U;
            act_cnt = 0U;
        } else {
            vm_address_t new_addr = 0;
            if (vm_allocate(mach_task_self(), &new_addr, (vm_size_t)(kept * sizeof(thread_act_t)), VM_FLAGS_ANYWHERE) == KERN_SUCCESS) {
                memcpy((void *)new_addr, kept_buf, (size_t)kept * sizeof(thread_act_t));
                vm_deallocate(mach_task_self(), (vm_address_t)orig_list, (vm_size_t)(orig_cnt * sizeof(thread_act_t)));
                desc.address = (void *)new_addr;
            } else {
                memcpy(orig_list, kept_buf, (size_t)kept * sizeof(thread_act_t));
                memset(orig_list + kept, 0, (size_t)(orig_cnt - kept) * sizeof(thread_act_t));
            }
            desc.count = kept;
            act_cnt = kept;
        }
        memcpy(bytes + desc_off, &desc, sizeof(desc));
        memcpy(bytes + cnt_off, &act_cnt, sizeof(act_cnt));
    }
    if (kept_buf != stack_kept) {
        free(kept_buf);
    }
}

static void pt_sanitize_mig_exception_ports_reply(void *rcv_buf, size_t usable_bytes) {
    mach_port_t svc_port = MACH_PORT_NULL;
    mach_port_t saved_port = MACH_PORT_NULL;
    exception_mask_t saved_mask = 0;
    exception_behavior_t saved_beh = 0;
    thread_state_flavor_t saved_flavor = 0;
    if (!pt_svc_get_redaction_info(&svc_port, &saved_port, &saved_mask, &saved_beh, &saved_flavor)) {
        return;
    }
    BOOL consumed_saved_port = NO;
    const size_t body_off = sizeof(mach_msg_header_t);
    const size_t descs_off = body_off + sizeof(mach_msg_body_t);
    if (usable_bytes < descs_off) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }
    uint8_t *bytes = (uint8_t *)rcv_buf;
    mach_msg_body_t body;
    memcpy(&body, bytes + body_off, sizeof(body));
    uint32_t desc_cnt = body.msgh_descriptor_count;
    if (desc_cnt == 0U || desc_cnt > 32U) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }

    // Detect OOL ports descriptor vs inline port descriptors.
    if (desc_cnt == 1U && usable_bytes >= descs_off + sizeof(mach_msg_ool_ports_descriptor_t)) {
        mach_msg_ool_ports_descriptor_t ool;
        memcpy(&ool, bytes + descs_off, sizeof(ool));
        if (ool.type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
            if (ool.address != NULL && ool.count > 0U && ool.count <= 32U) {
                mach_port_t *ports = (mach_port_t *)ool.address;
                for (mach_msg_size_t i = 0; i < ool.count; i++) {
                    if (ports[i] == svc_port) {
                        mach_port_deallocate(mach_task_self(), svc_port);
                        if (!consumed_saved_port && MACH_PORT_VALID(saved_port)) {
                            ports[i] = saved_port;
                            consumed_saved_port = YES;
                        } else {
                            ports[i] = MACH_PORT_NULL;
                        }
                    }
                }
            }
            if (!consumed_saved_port && MACH_PORT_VALID(saved_port)) {
                mach_port_deallocate(mach_task_self(), saved_port);
            }
            return;
        }
    }

    size_t descs_bytes = (size_t)desc_cnt * sizeof(mach_msg_port_descriptor_t);
    size_t ndr_off = descs_off + descs_bytes;
    size_t cnt_off = ndr_off + sizeof(NDR_record_t);
    size_t arrays_off = cnt_off + sizeof(mach_msg_type_number_t);
    if (usable_bytes < arrays_off) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }
    mach_msg_type_number_t masks_cnt = 0;
    memcpy(&masks_cnt, bytes + cnt_off, sizeof(masks_cnt));
    if (masks_cnt > desc_cnt || desc_cnt > 32U || masks_cnt > 32U) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }
    size_t arr_bytes = (size_t)masks_cnt * sizeof(uint32_t);
    size_t needed_end = arrays_off + 3U * arr_bytes;
    if (usable_bytes < needed_end) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }

    mach_msg_port_descriptor_t descs[32];
    exception_mask_t masks[32];
    exception_behavior_t behaviors[32];
    thread_state_flavor_t flavors[32];
    memset(descs, 0, sizeof(descs));
    memset(masks, 0, sizeof(masks));
    memset(behaviors, 0, sizeof(behaviors));
    memset(flavors, 0, sizeof(flavors));
    memcpy(descs, bytes + descs_off, descs_bytes);
    if (masks_cnt > 0U) {
        memcpy(masks, bytes + arrays_off, arr_bytes);
        memcpy(behaviors, bytes + arrays_off + arr_bytes, arr_bytes);
        memcpy(flavors, bytes + arrays_off + 2U * arr_bytes, arr_bytes);
    }

    for (uint32_t i = 0; i < desc_cnt; i++) {
        if (descs[i].type != MACH_MSG_PORT_DESCRIPTOR) {
            if (MACH_PORT_VALID(saved_port)) {
                mach_port_deallocate(mach_task_self(), saved_port);
            }
            return;
        }
    }

    BOOL modified = NO;
    uint32_t out_cnt = 0;
    for (uint32_t i = 0; i < masks_cnt; i++) {
        if (descs[i].name == svc_port) {
            modified = YES;
            mach_port_deallocate(mach_task_self(), svc_port);
            if (!consumed_saved_port && MACH_PORT_VALID(saved_port)) {
                descs[out_cnt] = descs[i];
                descs[out_cnt].name = saved_port;
                masks[out_cnt] = (saved_mask != 0) ? saved_mask : masks[i];
                behaviors[out_cnt] = saved_beh;
                flavors[out_cnt] = saved_flavor;
                consumed_saved_port = YES;
                out_cnt++;
            } else {
                exception_mask_t rem_mask = masks[i] & ~((exception_mask_t)EXC_MASK_BREAKPOINT);
                if (rem_mask != 0) {
                    descs[out_cnt] = descs[i];
                    descs[out_cnt].name = MACH_PORT_NULL;
                    masks[out_cnt] = rem_mask;
                    behaviors[out_cnt] = behaviors[i];
                    flavors[out_cnt] = flavors[i];
                    out_cnt++;
                }
            }
            continue;
        }
        if (out_cnt != i) {
            descs[out_cnt] = descs[i];
            masks[out_cnt] = masks[i];
            behaviors[out_cnt] = behaviors[i];
            flavors[out_cnt] = flavors[i];
        }
        out_cnt++;
    }
    for (uint32_t i = masks_cnt; i < desc_cnt; i++) {
        if (descs[i].name == svc_port) {
            modified = YES;
            mach_port_deallocate(mach_task_self(), svc_port);
            descs[i].name = MACH_PORT_NULL;
        }
    }
    if (!consumed_saved_port && MACH_PORT_VALID(saved_port)) {
        mach_port_deallocate(mach_task_self(), saved_port);
    }
    if (!modified) {
        return;
    }

    for (uint32_t j = out_cnt; j < desc_cnt; j++) {
        descs[j].name = MACH_PORT_NULL;
        descs[j].pad1 = 0;
        descs[j].pad2 = 0;
        descs[j].disposition = MACH_MSG_TYPE_PORT_SEND;
        descs[j].type = MACH_MSG_PORT_DESCRIPTOR;
    }
    memcpy(bytes + descs_off, descs, descs_bytes);
    mach_msg_type_number_t new_masks_cnt = out_cnt;
    memcpy(bytes + cnt_off, &new_masks_cnt, sizeof(new_masks_cnt));
    size_t new_arr_bytes = (size_t)out_cnt * sizeof(uint32_t);
    if (out_cnt > 0U) {
        memcpy(bytes + arrays_off, masks, new_arr_bytes);
        memcpy(bytes + arrays_off + new_arr_bytes, behaviors, new_arr_bytes);
        memcpy(bytes + arrays_off + 2U * new_arr_bytes, flavors, new_arr_bytes);
    }
    size_t new_total = arrays_off + 3U * new_arr_bytes;
    if (new_total < needed_end) {
        memset(bytes + new_total, 0, needed_end - new_total);
    }
    mach_msg_header_t *hdr_mut = (mach_msg_header_t *)rcv_buf;
    hdr_mut->msgh_size = (mach_msg_size_t)new_total;
}

static void pt_sanitize_mig_vm_read_reply(void *rcv_buf, size_t usable_bytes, uint64_t vm_addr) {
    const size_t body_off = sizeof(mach_msg_header_t);
    const size_t desc_off = body_off + sizeof(mach_msg_body_t);
    const size_t min_sz = desc_off + sizeof(mach_msg_ool_descriptor_t);
    if (vm_addr == 0 || usable_bytes < min_sz) {
        return;
    }
    const uint8_t *bytes = (const uint8_t *)rcv_buf;
    mach_msg_body_t body;
    memcpy(&body, bytes + body_off, sizeof(body));
    if (body.msgh_descriptor_count != 1U) {
        return;
    }
    mach_msg_ool_descriptor_t desc;
    memcpy(&desc, bytes + desc_off, sizeof(desc));
    if (desc.type == MACH_MSG_OOL_DESCRIPTOR && desc.address != NULL && desc.size > 0U) {
        pt_sanitize_vm_read_buffer((uintptr_t)vm_addr, (uint8_t *)desc.address, (size_t)desc.size);
    }
}

static void pt_sanitize_mig_exc_ports_info_reply(void *rcv_buf,
                                                 size_t usable_bytes,
                                                 BOOL is_thread,
                                                 mach_port_t target_port) {
    const size_t prefix = sizeof(mach_msg_header_t) + sizeof(NDR_record_t);
    const size_t rc_off = prefix;
    const size_t cnt_off = rc_off + sizeof(kern_return_t);
    const size_t arr_off = cnt_off + sizeof(mach_msg_type_number_t);
    if (usable_bytes < arr_off) {
        return;
    }
    uint8_t *bytes = (uint8_t *)rcv_buf;
    kern_return_t rc = KERN_FAILURE;
    mach_msg_type_number_t cnt = 0;
    memcpy(&rc, bytes + rc_off, sizeof(rc));
    memcpy(&cnt, bytes + cnt_off, sizeof(cnt));
    if (rc != KERN_SUCCESS || cnt == 0U || cnt > 32U) {
        return;
    }
    const size_t elem_stride = sizeof(exception_mask_t) + sizeof(ipc_info_port_t) +
                               sizeof(exception_behavior_t) + sizeof(thread_state_flavor_t);
    size_t orig_total = arr_off + (size_t)cnt * elem_stride;
    if (usable_bytes < orig_total) {
        return;
    }
    exception_mask_t masks[32];
    ipc_info_port_t handlers[32];
    exception_behavior_t behaviors[32];
    thread_state_flavor_t flavors[32];
    size_t masks_sz = (size_t)cnt * sizeof(exception_mask_t);
    size_t handlers_sz = (size_t)cnt * sizeof(ipc_info_port_t);
    size_t beh_sz = (size_t)cnt * sizeof(exception_behavior_t);
    size_t flav_sz = (size_t)cnt * sizeof(thread_state_flavor_t);
    memcpy(masks, bytes + arr_off, masks_sz);
    memcpy(handlers, bytes + arr_off + masks_sz, handlers_sz);
    memcpy(behaviors, bytes + arr_off + masks_sz + handlers_sz, beh_sz);
    memcpy(flavors, bytes + arr_off + masks_sz + handlers_sz + beh_sz, flav_sz);
    mach_msg_type_number_t new_cnt = cnt;
    pt_svc_redact_exc_ports_info_arrays(is_thread, target_port, masks, &new_cnt, handlers, behaviors, flavors);
    if (new_cnt > cnt) {
        return;
    }
    size_t n_masks_sz = (size_t)new_cnt * sizeof(exception_mask_t);
    size_t n_handlers_sz = (size_t)new_cnt * sizeof(ipc_info_port_t);
    size_t n_beh_sz = (size_t)new_cnt * sizeof(exception_behavior_t);
    size_t n_flav_sz = (size_t)new_cnt * sizeof(thread_state_flavor_t);
    memcpy(bytes + cnt_off, &new_cnt, sizeof(new_cnt));
    if (new_cnt > 0U) {
        memcpy(bytes + arr_off, masks, n_masks_sz);
        memcpy(bytes + arr_off + n_masks_sz, handlers, n_handlers_sz);
        memcpy(bytes + arr_off + n_masks_sz + n_handlers_sz, behaviors, n_beh_sz);
        memcpy(bytes + arr_off + n_masks_sz + n_handlers_sz + n_beh_sz, flavors, n_flav_sz);
    }
    size_t new_total = arr_off + (size_t)new_cnt * elem_stride;
    if (new_total < orig_total) {
        memset(bytes + new_total, 0, orig_total - new_total);
    }
    mach_msg_header_t *hdr_mut = (mach_msg_header_t *)rcv_buf;
    hdr_mut->msgh_size = (mach_msg_size_t)new_total;
}

extern __attribute__((visibility("hidden"))) void pt_svc_sanitize_arm_debug_state_buf(thread_state_flavor_t flavor,
                                                                                      void *state_buf,
                                                                                      size_t state_bytes);
extern __attribute__((visibility("hidden"))) BOOL pt_sanitize_vm_region_info(uintptr_t cur_addr,
                                                                             uintptr_t cur_size,
                                                                             vm_region_flavor_t flavor,
                                                                             vm_region_info_t info,
                                                                             mach_msg_type_number_t infoCnt,
                                                                             BOOL is_recurse);

static void pt_sanitize_mig_vm_region_complex_reply(void *rcv_buf,
                                                    size_t usable_bytes,
                                                    size_t rcv_cap,
                                                    bool is_mach_vm,
                                                    const PTMIGVMMeta *vm_meta,
                                                    const void *caller) {
    // Head(24) + body(4) + object_name(12@28) + NDR(8@40) + address(8@48) + size(8@56) + infoCnt(4@64) + int info[](@68)
    const size_t obj_off = 28U;
    const size_t addr_off = 48U;
    const size_t size_off = 56U;
    const size_t cnt_off = 64U;
    const size_t info_off = 68U;
    if (usable_bytes < info_off || rcv_cap < info_off) {
        return;
    }
    uint8_t *bytes = (uint8_t *)rcv_buf;
    uint64_t cur_addr = 0;
    uint64_t cur_size = 0;
    mach_msg_type_number_t cur_cnt = 0;
    memcpy(&cur_addr, bytes + addr_off, sizeof(cur_addr));
    memcpy(&cur_size, bytes + size_off, sizeof(cur_size));
    memcpy(&cur_cnt, bytes + cnt_off, sizeof(cur_cnt));
    if (cur_cnt > 10U || info_off + (size_t)cur_cnt * sizeof(int) > usable_bytes) {
        return;
    }
    int info_buf[10];
    memset(info_buf, 0, sizeof(info_buf));
    if (cur_cnt > 0U) {
        memcpy(info_buf, bytes + info_off, (size_t)cur_cnt * sizeof(int));
    }
    vm_region_flavor_t flavor = (vm_region_flavor_t)vm_meta->region_depth_or_flavor;
    if (!pt_vm_region_should_hide_range((uintptr_t)cur_addr, (uintptr_t)cur_size, flavor, info_buf, cur_cnt, NO, caller)) {
        if (cur_cnt > 0U &&
            pt_sanitize_vm_region_info((uintptr_t)cur_addr, (uintptr_t)cur_size, flavor, (vm_region_info_t)info_buf, cur_cnt, NO)) {
            memcpy(bytes + info_off, info_buf, (size_t)cur_cnt * sizeof(int));
        }
        return;
    }
    mach_msg_port_descriptor_t obj_desc;
    memcpy(&obj_desc, bytes + obj_off, sizeof(obj_desc));
    if (MACH_PORT_VALID(obj_desc.name)) {
        mach_port_deallocate(mach_task_self(), obj_desc.name);
        obj_desc.name = MACH_PORT_NULL;
    }
    mach_port_t new_obj = MACH_PORT_NULL;
    kern_return_t kr = KERN_INVALID_ADDRESS;
    mach_msg_type_number_t out_cnt = (vm_meta->region_info_cnt > 0U && vm_meta->region_info_cnt <= 10U)
        ? vm_meta->region_info_cnt : cur_cnt;
    size_t cap_ints = (rcv_cap - info_off) / sizeof(int);
    if ((size_t)out_cnt > cap_ints) {
        out_cnt = (mach_msg_type_number_t)cap_ints;
    }
    if (cur_size > 0ULL && cur_addr + cur_size > cur_addr) {
        uint64_t next_addr = cur_addr + cur_size;
        uint64_t next_size = 0;
        memset(info_buf, 0, sizeof(info_buf));
        if (is_mach_vm) {
            mach_vm_address_t a = (mach_vm_address_t)next_addr;
            mach_vm_size_t s = 0;
            kr = pt_mach_vm_region_with_caller(mach_task_self(), &a, &s, flavor, (vm_region_info_t)info_buf, &out_cnt, &new_obj, caller);
            next_addr = (uint64_t)a;
            next_size = (uint64_t)s;
        } else {
            vm_address_t a = (vm_address_t)next_addr;
            vm_size_t s = 0;
            kr = pt_vm_region_64_with_caller(mach_task_self(), &a, &s, flavor, (vm_region_info_t)info_buf, &out_cnt, &new_obj, caller);
            next_addr = (uint64_t)a;
            next_size = (uint64_t)s;
        }
        cur_addr = next_addr;
        cur_size = next_size;
    }
    mach_msg_header_t *hdr_mut = (mach_msg_header_t *)rcv_buf;
    if (kr == KERN_SUCCESS && out_cnt <= 10U && info_off + (size_t)out_cnt * sizeof(int) <= rcv_cap) {
        obj_desc.name = new_obj;
        memcpy(bytes + obj_off, &obj_desc, sizeof(obj_desc));
        memcpy(bytes + addr_off, &cur_addr, sizeof(cur_addr));
        memcpy(bytes + size_off, &cur_size, sizeof(cur_size));
        memcpy(bytes + cnt_off, &out_cnt, sizeof(out_cnt));
        if (out_cnt > 0U) {
            memcpy(bytes + info_off, info_buf, (size_t)out_cnt * sizeof(int));
        }
        size_t new_total = info_off + (size_t)out_cnt * sizeof(int);
        if (new_total < usable_bytes) {
            memset(bytes + new_total, 0, usable_bytes - new_total);
        }
        hdr_mut->msgh_size = (mach_msg_size_t)new_total;
    } else {
        if (MACH_PORT_VALID(new_obj)) {
            mach_port_deallocate(mach_task_self(), new_obj);
        }
        if (kr == KERN_SUCCESS) {
            kr = KERN_INVALID_ADDRESS;
        }
        hdr_mut->msgh_bits &= ~((mach_msg_bits_t)MACH_MSGH_BITS_COMPLEX);
        hdr_mut->msgh_size = (mach_msg_size_t)sizeof(mig_reply_error_t);
        memcpy(bytes + sizeof(mach_msg_header_t), &NDR_record, sizeof(NDR_record));
        memcpy(bytes + sizeof(mach_msg_header_t) + sizeof(NDR_record), &kr, sizeof(kr));
    }
}

static void pt_sanitize_mig_vm_region_recurse_reply(void *rcv_buf,
                                                    size_t usable_bytes,
                                                    size_t rcv_cap,
                                                    bool is_mach_vm,
                                                    const PTMIGVMMeta *vm_meta,
                                                    const void *caller) {
    // Head(24) + NDR(8@24) + RetCode(4@32) + address(8@36) + size(8@44) + nesting_depth(4@52) + infoCnt(4@56) + int info[](@60)
    const size_t addr_off = 36U;
    const size_t size_off = 44U;
    const size_t depth_off = 52U;
    const size_t cnt_off = 56U;
    const size_t info_off = 60U;
    if (usable_bytes < info_off || rcv_cap < info_off) {
        return;
    }
    uint8_t *bytes = (uint8_t *)rcv_buf;
    uint64_t cur_addr = 0;
    uint64_t cur_size = 0;
    natural_t cur_depth = 0;
    mach_msg_type_number_t cur_cnt = 0;
    memcpy(&cur_addr, bytes + addr_off, sizeof(cur_addr));
    memcpy(&cur_size, bytes + size_off, sizeof(cur_size));
    memcpy(&cur_depth, bytes + depth_off, sizeof(cur_depth));
    memcpy(&cur_cnt, bytes + cnt_off, sizeof(cur_cnt));
    if (cur_cnt > 21U || info_off + (size_t)cur_cnt * sizeof(int) > usable_bytes) {
        return;
    }
    int info_buf[21];
    memset(info_buf, 0, sizeof(info_buf));
    if (cur_cnt > 0U) {
        memcpy(info_buf, bytes + info_off, (size_t)cur_cnt * sizeof(int));
    }
    if (!pt_vm_region_should_hide_range((uintptr_t)cur_addr, (uintptr_t)cur_size, 0, info_buf, cur_cnt, YES, caller)) {
        if (cur_cnt > 0U &&
            pt_sanitize_vm_region_info((uintptr_t)cur_addr, (uintptr_t)cur_size, 0, (vm_region_info_t)info_buf, cur_cnt, YES)) {
            memcpy(bytes + info_off, info_buf, (size_t)cur_cnt * sizeof(int));
        }
        return;
    }
    kern_return_t kr = KERN_INVALID_ADDRESS;
    natural_t out_depth = (natural_t)vm_meta->region_depth_or_flavor;
    mach_msg_type_number_t out_cnt = (vm_meta->region_info_cnt > 0U && vm_meta->region_info_cnt <= 21U)
        ? vm_meta->region_info_cnt : cur_cnt;
    size_t cap_ints = (rcv_cap - info_off) / sizeof(int);
    if ((size_t)out_cnt > cap_ints) {
        out_cnt = (mach_msg_type_number_t)cap_ints;
    }
    if (cur_size > 0ULL && cur_addr + cur_size > cur_addr) {
        uint64_t next_addr = cur_addr + cur_size;
        uint64_t next_size = 0;
        memset(info_buf, 0, sizeof(info_buf));
        if (is_mach_vm) {
            mach_vm_address_t a = (mach_vm_address_t)next_addr;
            mach_vm_size_t s = 0;
            kr = pt_mach_vm_region_recurse_with_caller(mach_task_self(), &a, &s, &out_depth, (vm_region_recurse_info_t)info_buf, &out_cnt, caller);
            next_addr = (uint64_t)a;
            next_size = (uint64_t)s;
        } else {
            vm_address_t a = (vm_address_t)next_addr;
            vm_size_t s = 0;
            kr = pt_vm_region_recurse_64_with_caller(mach_task_self(), &a, &s, &out_depth, (vm_region_recurse_info_t)info_buf, &out_cnt, caller);
            next_addr = (uint64_t)a;
            next_size = (uint64_t)s;
        }
        cur_addr = next_addr;
        cur_size = next_size;
    }
    mach_msg_header_t *hdr_mut = (mach_msg_header_t *)rcv_buf;
    if (kr == KERN_SUCCESS && out_cnt <= 21U && info_off + (size_t)out_cnt * sizeof(int) <= rcv_cap) {
        memcpy(bytes + addr_off, &cur_addr, sizeof(cur_addr));
        memcpy(bytes + size_off, &cur_size, sizeof(cur_size));
        memcpy(bytes + depth_off, &out_depth, sizeof(out_depth));
        memcpy(bytes + cnt_off, &out_cnt, sizeof(out_cnt));
        if (out_cnt > 0U) {
            memcpy(bytes + info_off, info_buf, (size_t)out_cnt * sizeof(int));
        }
        size_t new_total = info_off + (size_t)out_cnt * sizeof(int);
        if (new_total < usable_bytes) {
            memset(bytes + new_total, 0, usable_bytes - new_total);
        }
        hdr_mut->msgh_size = (mach_msg_size_t)new_total;
    } else {
        if (kr == KERN_SUCCESS) {
            kr = KERN_INVALID_ADDRESS;
        }
        memcpy(bytes + sizeof(mach_msg_header_t) + sizeof(NDR_record), &kr, sizeof(kr));
        hdr_mut->msgh_size = (mach_msg_size_t)sizeof(mig_reply_error_t);
    }
}

static void pt_sanitize_mig_reply_if_needed(void *rcv_buf,
                                            size_t rcv_cap,
                                            mach_port_t rcv_name,
                                            bool had_inline_req,
                                            int inline_req_id,
                                            int32_t inline_req_flavor,
                                            bool inline_target_is_self,
                                            const void *caller) {
    if (rcv_buf == NULL || rcv_cap < sizeof(mach_msg_header_t)) {
        return;
    }
    const mach_msg_header_t *hdr = (const mach_msg_header_t *)rcv_buf;
    int reply_id = hdr->msgh_id;
    bool is_simple_reply = (reply_id == 300 || reply_id == 301 || reply_id == 316 ||
                            reply_id == 319 || reply_id == 3505 || reply_id == 3560 ||
                            reply_id == 3703 || reply_id == 3712 || reply_id == 3730 ||
                            reply_id == 3906 || reply_id == 3908 || reply_id == 3909 || reply_id == 3922 ||
                            reply_id == 4905 || reply_id == 4907 || reply_id == 4908 || reply_id == 4915);
    bool is_complex_reply = (reply_id == 304 || reply_id == 3502 || reply_id == 3514 ||
                             reply_id == 3515 || reply_id == 3714 || reply_id == 3715 ||
                             reply_id == 3905 || reply_id == 3924 || reply_id == 4904 || reply_id == 4916);
    if (!is_simple_reply && !is_complex_reply) {
        return;
    }
    size_t usable_bytes = (hdr->msgh_size > 0 && hdr->msgh_size < rcv_cap) ? (size_t)hdr->msgh_size : rcv_cap;

    int req_id = inline_req_id;
    int32_t req_flavor = inline_req_flavor;
    bool target_is_self = inline_target_is_self;
    PTMIGVMMeta vm_meta;
    memset(&vm_meta, 0, sizeof(vm_meta));
    if (had_inline_req) {
        if (s_tls_mig_vm_meta.req_id == req_id) {
            pt_mig_vm_meta_copy(&vm_meta, &s_tls_mig_vm_meta);
        }
    } else {
        bool matched = false;
        if (hdr->msgh_local_port != MACH_PORT_NULL) {
            matched = pt_mig_ring_pop(hdr->msgh_local_port, &req_id, &req_flavor, &target_is_self, &vm_meta);
        }
        if (!matched && rcv_name != MACH_PORT_NULL && rcv_name != hdr->msgh_local_port) {
            matched = pt_mig_ring_pop(rcv_name, &req_id, &req_flavor, &target_is_self, &vm_meta);
        }
        if (!matched) {
            return;
        }
    }

    if (is_complex_reply) {
        if ((hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) == 0 || !target_is_self) {
            return;
        }
        if (reply_id == 304 && req_id == 204) {
            pt_sanitize_mig_host_processor_info_reply(rcv_buf, usable_bytes);
        } else if (reply_id == 3502 && req_id == 3402) {
            pt_sanitize_mig_task_threads_reply(rcv_buf, usable_bytes);
        } else if ((reply_id == 3514 && req_id == 3414) ||
                   (reply_id == 3515 && req_id == 3415) ||
                   (reply_id == 3714 && req_id == 3614) ||
                   (reply_id == 3715 && req_id == 3615)) {
            pt_sanitize_mig_exception_ports_reply(rcv_buf, usable_bytes);
        } else if ((reply_id == 4904 && req_id == 4804) ||
                   (reply_id == 3905 && req_id == 3805)) {
            pt_sanitize_mig_vm_read_reply(rcv_buf, usable_bytes, vm_meta.addr);
        } else if ((reply_id == 4916 && req_id == 4816) ||
                   (reply_id == 3924 && req_id == 3824)) {
            pt_sanitize_mig_vm_region_complex_reply(rcv_buf, usable_bytes, rcv_cap, reply_id == 4916, &vm_meta, caller);
        }
        return;
    }

    if ((hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0) {
        return;
    }
    if (reply_id == 301 && req_id == 201) {
        pt_sanitize_mig_host_kernel_version_reply(rcv_buf, usable_bytes, rcv_cap);
        return;
    }
    const size_t prefix = sizeof(mach_msg_header_t) + sizeof(NDR_record_t);
    if (usable_bytes < prefix + sizeof(kern_return_t)) {
        return;
    }

    const uint8_t *bytes = (const uint8_t *)rcv_buf;
    kern_return_t reply_rc = KERN_FAILURE;
    memcpy(&reply_rc, bytes + prefix, sizeof(reply_rc));
    if (reply_rc != KERN_SUCCESS) {
        return;
    }

    if ((reply_id == 3560 && req_id == 3460) || (reply_id == 3730 && req_id == 3630)) {
        if (target_is_self) {
            pt_sanitize_mig_exc_ports_info_reply(rcv_buf, usable_bytes, reply_id == 3730, vm_meta.target_port);
        }
        return;
    }
    if ((reply_id == 4905 && req_id == 4805) || (reply_id == 3906 && req_id == 3806)) {
        const size_t list_off = prefix + sizeof(kern_return_t);
        if (target_is_self && vm_meta.list_count > 0U &&
            usable_bytes >= list_off + (size_t)vm_meta.list_count * 16U) {
            for (uint32_t i = 0; i < vm_meta.list_count && i < VM_MAP_ENTRY_MAX; i++) {
                uint64_t out_addr = 0;
                uint64_t out_size = 0;
                memcpy(&out_addr, bytes + list_off + (size_t)i * 16U, sizeof(out_addr));
                memcpy(&out_size, bytes + list_off + (size_t)i * 16U + sizeof(uint64_t), sizeof(out_size));
                if (vm_meta.list_addrs[i] != 0ULL && out_addr != 0ULL && out_size > 0ULL) {
                    pt_sanitize_vm_read_buffer((uintptr_t)vm_meta.list_addrs[i],
                                               (uint8_t *)(uintptr_t)out_addr,
                                               (size_t)out_size);
                }
            }
        }
        return;
    }
    if ((reply_id == 4915 && req_id == 4815) || (reply_id == 3922 && req_id == 3822)) {
        if (target_is_self) {
            pt_sanitize_mig_vm_region_recurse_reply(rcv_buf, usable_bytes, rcv_cap, reply_id == 4915, &vm_meta, caller);
        }
        return;
    }
    if ((reply_id == 4907 && req_id == 4807) || (reply_id == 3908 && req_id == 3808)) {
        if (target_is_self && vm_meta.addr != 0 && vm_meta.dst != 0 && vm_meta.size > 0) {
            pt_sanitize_vm_read_buffer((uintptr_t)vm_meta.addr,
                                       (uint8_t *)(uintptr_t)vm_meta.dst,
                                       (size_t)vm_meta.size);
        }
        return;
    }
    if ((reply_id == 4908 && req_id == 4808) || (reply_id == 3909 && req_id == 3809)) {
        if (target_is_self &&
            vm_meta.addr != 0 &&
            vm_meta.dst != 0 &&
            usable_bytes >= prefix + sizeof(kern_return_t) + sizeof(uint64_t)) {
            uint64_t outsize = 0;
            memcpy(&outsize, bytes + prefix + sizeof(kern_return_t), sizeof(outsize));
            if (outsize > 0) {
                pt_sanitize_vm_read_buffer((uintptr_t)vm_meta.addr,
                                           (uint8_t *)(uintptr_t)vm_meta.dst,
                                           (size_t)outsize);
            }
        }
        return;
    }

    if (usable_bytes < prefix + sizeof(kern_return_t) + sizeof(natural_t)) {
        return;
    }
    natural_t payload_count = 0;
    memcpy(&payload_count, bytes + prefix + sizeof(kern_return_t), sizeof(payload_count));
    size_t payload_offset = prefix + sizeof(kern_return_t) + sizeof(natural_t);
    if (payload_count == 0 || (size_t)payload_count > (SIZE_MAX - payload_offset) / sizeof(natural_t)) {
        return;
    }
    size_t payload_bytes = (size_t)payload_count * sizeof(natural_t);
    if (payload_offset + payload_bytes > usable_bytes) {
        return;
    }
    uint8_t *payload = (uint8_t *)rcv_buf + payload_offset;

    if (reply_id == 300 && req_id == 200 && req_flavor == HOST_BASIC_INFO) {
        host_basic_info_data_t info_local;
        memset(&info_local, 0, sizeof(info_local));
        size_t copy_bytes = (payload_bytes < sizeof(info_local)) ? payload_bytes : sizeof(info_local);
        memcpy(&info_local, payload, copy_bytes);
        pt_sanitize_host_basic_info_buf(&info_local, copy_bytes);
        memcpy(payload, &info_local, copy_bytes);
    } else if (reply_id == 300 && req_id == 200 && req_flavor == HOST_PREFERRED_USER_ARCH) {
        host_preferred_user_arch_data_t arch_local;
        memset(&arch_local, 0, sizeof(arch_local));
        size_t copy_bytes = (payload_bytes < sizeof(arch_local)) ? payload_bytes : sizeof(arch_local);
        memcpy(&arch_local, payload, copy_bytes);
        pt_sanitize_host_preferred_user_arch_buf(&arch_local, copy_bytes);
        memcpy(payload, &arch_local, copy_bytes);
    } else if (reply_id == 316 && req_id == 216 && req_flavor == HOST_VM_INFO) {
        vm_statistics_data_t vm_local;
        memset(&vm_local, 0, sizeof(vm_local));
        size_t copy_bytes = (payload_bytes < sizeof(vm_local)) ? payload_bytes : sizeof(vm_local);
        memcpy(&vm_local, payload, copy_bytes);
        pt_sanitize_host_vm_info_buf(&vm_local, copy_bytes);
        memcpy(payload, &vm_local, copy_bytes);
    } else if (reply_id == 319 && req_id == 219 &&
               (req_flavor == HOST_VM_INFO64 || req_flavor == HOST_VM_INFO)) {
        vm_statistics64_data_t vm64_local;
        memset(&vm64_local, 0, sizeof(vm64_local));
        size_t copy_bytes = (payload_bytes < sizeof(vm64_local)) ? payload_bytes : sizeof(vm64_local);
        memcpy(&vm64_local, payload, copy_bytes);
        pt_sanitize_host_vm_info64_buf(&vm64_local, copy_bytes, req_flavor == HOST_VM_INFO64);
        memcpy(payload, &vm64_local, copy_bytes);
    } else if (reply_id == 3505 && target_is_self && req_id == 3405) {
        if (req_flavor == TASK_VM_INFO || req_flavor == TASK_VM_INFO_PURGEABLE) {
            task_vm_info_data_t vm_local;
            memset(&vm_local, 0, sizeof(vm_local));
            size_t copy_bytes = (payload_bytes < sizeof(vm_local)) ? payload_bytes : sizeof(vm_local);
            memcpy(&vm_local, payload, copy_bytes);
            pt_sanitize_task_vm_info_buf(&vm_local, copy_bytes);
            memcpy(payload, &vm_local, copy_bytes);
        } else if (req_flavor == TASK_AUDIT_TOKEN) {
            audit_token_t tok_local;
            memset(&tok_local, 0, sizeof(tok_local));
            size_t copy_bytes = (payload_bytes < sizeof(tok_local)) ? payload_bytes : sizeof(tok_local);
            memcpy(&tok_local, payload, copy_bytes);
            pt_sanitize_task_audit_token_buf(&tok_local, copy_bytes);
            memcpy(payload, &tok_local, copy_bytes);
        } else if (req_flavor == TASK_SECURITY_TOKEN) {
            security_token_t sec_local;
            memset(&sec_local, 0, sizeof(sec_local));
            size_t copy_bytes = (payload_bytes < sizeof(sec_local)) ? payload_bytes : sizeof(sec_local);
            memcpy(&sec_local, payload, copy_bytes);
            pt_sanitize_task_security_token_buf(&sec_local, copy_bytes);
            memcpy(payload, &sec_local, copy_bytes);
        } else if (req_flavor == TASK_DYLD_INFO && payload_bytes >= sizeof(task_dyld_info_data_t)) {
            task_dyld_info_data_t dyld_local;
            memcpy(&dyld_local, payload, sizeof(dyld_local));
            pt_sanitize_task_dyld_info_buf(&dyld_local, sizeof(dyld_local));
            memcpy(payload, &dyld_local, sizeof(dyld_local));
        }
    } else if (reply_id == 3712 && target_is_self && req_id == 3612 &&
               req_flavor == THREAD_EXTENDED_INFO) {
        size_t min_ext_bytes = offsetof(thread_extended_info_data_t, pth_name) +
            sizeof(((thread_extended_info_data_t *)0)->pth_name);
        if (payload_bytes >= min_ext_bytes) {
            thread_extended_info_data_t ext;
            memset(&ext, 0, sizeof(ext));
            size_t copy_bytes = (payload_bytes < sizeof(ext)) ? payload_bytes : sizeof(ext);
            memcpy(&ext, payload, copy_bytes);
            char namebuf[sizeof(ext.pth_name) + 1];
            size_t nlen = strnlen(ext.pth_name, sizeof(ext.pth_name));
            memcpy(namebuf, ext.pth_name, nlen);
            namebuf[nlen] = '\0';
            if (pt_is_hidden_thread_name(namebuf)) {
                memset(ext.pth_name, 0, sizeof(ext.pth_name));
                memcpy(payload, &ext, copy_bytes);
            }
        }
    } else if (reply_id == 3703 && target_is_self && req_id == 3603) {
        pt_svc_sanitize_arm_debug_state_buf((thread_state_flavor_t)req_flavor, payload, payload_bytes);
    }
}

__attribute__((visibility("hidden")))
bool pt_mig_prepare_trap_request(void *req_buf,
                                 mach_msg_bits_t bits,
                                 mach_msg_size_t send_size,
                                 mach_port_t remote_port,
                                 mach_port_t local_port,
                                 int req_id,
                                 bool receiving,
                                 int32_t *out_flavor,
                                 bool *out_target_is_self) {
    int32_t flavor = 0;
    bool target_is_self = false;
    bool had_req = pt_extract_mig_request_meta(req_buf,
                                               bits,
                                               send_size,
                                               remote_port,
                                               req_id,
                                               &flavor,
                                               &target_is_self,
                                               NULL,
                                               NULL);
    if (out_flavor != NULL) {
        *out_flavor = flavor;
    }
    if (out_target_is_self != NULL) {
        *out_target_is_self = target_is_self;
    }
    if (had_req && !receiving) {
        pt_mig_ring_push(local_port, req_id, flavor, target_is_self);
    }
    return had_req;
}

__attribute__((visibility("hidden")))
void pt_mig_finish_trap_reply(void *rcv_buf,
                              size_t rcv_cap,
                              mach_port_t rcv_name,
                              bool sending,
                              bool receiving,
                              bool had_req,
                              int req_id,
                              int32_t req_flavor,
                              bool target_is_self,
                              mach_port_t reply_port,
                              kern_return_t kr,
                              const void *caller) {
    if (sending && !receiving && had_req && kr != KERN_SUCCESS) {
        pt_mig_ring_erase(reply_port, req_id, req_flavor);
    }
    if (kr == KERN_SUCCESS && receiving && rcv_buf != NULL && rcv_cap >= sizeof(mach_msg_header_t)) {
        pt_sanitize_mig_reply_if_needed(rcv_buf, rcv_cap, rcv_name, had_req, req_id, req_flavor, target_is_self, caller);
    }
}

extern kern_return_t pt_orig_mach_msg2_internal(void *data,
                                                uint64_t option64,
                                                uint64_t msgh_bits_and_send_size,
                                                uint64_t msgh_remote_and_local_port,
                                                uint64_t msgh_voucher_and_id,
                                                uint64_t desc_count_and_rcv_name,
                                                uint64_t rcv_size,
                                                uint64_t priority_and_timeout)
    __asm("_mach_msg2_internal") __attribute__((weak_import));

extern mach_msg_return_t pt_orig_mach_msg_trap(mach_msg_header_t *msg,
                                               mach_msg_option_t option,
                                               mach_msg_size_t send_size,
                                               mach_msg_size_t rcv_size,
                                               mach_port_name_t rcv_name,
                                               mach_msg_timeout_t timeout,
                                               mach_port_name_t notify)
    __asm("_mach_msg_trap") __attribute__((weak_import));

extern mach_msg_return_t pt_orig_mach_msg_overwrite_trap(mach_msg_header_t *msg,
                                                         mach_msg_option_t option,
                                                         mach_msg_size_t send_size,
                                                         mach_msg_size_t rcv_size,
                                                         mach_port_name_t rcv_name,
                                                         mach_msg_timeout_t timeout,
                                                         mach_port_name_t notify,
                                                         mach_msg_header_t *rcv_msg,
                                                         mach_msg_size_t rcv_limit)
    __asm("_mach_msg_overwrite_trap") __attribute__((weak_import));

extern kern_return_t pt_orig_mach_msg2_trap(void *data,
                                            uint64_t option64,
                                            uint64_t msgh_bits_and_send_size,
                                            uint64_t msgh_remote_and_local_port,
                                            uint64_t msgh_voucher_and_id,
                                            uint64_t desc_count_and_rcv_name,
                                            uint64_t rcv_size,
                                            uint64_t priority_and_timeout)
    __asm("_mach_msg2_trap") __attribute__((weak_import));

static void pt_mig_prepare_complex_reply_for_reenqueue(mach_msg_header_t *hdr) {
    if (hdr == NULL || (hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) == 0 ||
        hdr->msgh_size < sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t)) {
        return;
    }
    uint8_t *bytes = (uint8_t *)hdr;
    mach_msg_body_t body;
    memcpy(&body, bytes + sizeof(mach_msg_header_t), sizeof(body));
    size_t off = sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t);
    for (mach_msg_size_t i = 0; i < body.msgh_descriptor_count; i++) {
        if (off + sizeof(mach_msg_descriptor_t) > hdr->msgh_size) {
            break;
        }
        mach_msg_descriptor_t *desc = (mach_msg_descriptor_t *)(bytes + off);
        uint8_t dtype = desc->type.type;
        if (dtype == MACH_MSG_PORT_DESCRIPTOR) {
            off += sizeof(mach_msg_port_descriptor_t);
        } else if (dtype == MACH_MSG_OOL_DESCRIPTOR || dtype == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
            desc->out_of_line.deallocate = 1;
            off += sizeof(mach_msg_ool_descriptor_t);
        } else if (dtype == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
            desc->ool_ports.deallocate = 1;
            off += sizeof(mach_msg_ool_ports_descriptor_t);
        } else {
            break;
        }
    }
}

static BOOL pt_try_mach_msg_split_kobject_rpc(mach_msg_header_t *msg,
                                              mach_msg_option_t option,
                                              mach_msg_size_t effective_send_size,
                                              mach_msg_timeout_t timeout,
                                              int req_id,
                                              int32_t req_flavor,
                                              bool target_is_self,
                                              mach_port_t reply_port,
                                              const void *caller,
                                              mach_msg_return_t *out_kr) {
    if (&pt_orig_mach_msg2_internal == NULL ||
        msg == NULL ||
        !MACH_PORT_VALID(reply_port) ||
        MACH_MSGH_BITS_LOCAL(msg->msgh_bits) != MACH_MSG_TYPE_MAKE_SEND_ONCE ||
        effective_send_size < sizeof(mach_msg_header_t) ||
        effective_send_size > 4096U) {
        return NO;
    }
    union {
        mach_msg_header_t hdr;
        uint8_t bytes[4096];
    } tmp;
    memset(&tmp, 0, sizeof(tmp));
    memcpy(tmp.bytes, msg, effective_send_size);

    uint64_t opt64 = 0x0000000200000003ULL; // MACH64_SEND_KOBJECT_CALL | MACH_SEND_MSG | MACH_RCV_MSG
    uint64_t prio_timeout = 0ULL;
    if ((option & MACH_SEND_TIMEOUT) != 0) {
        opt64 |= (uint64_t)(MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT);
        prio_timeout = (uint64_t)timeout;
    }

    s_tls_in_pt_mach_msg++;
    kern_return_t kr = pt_orig_mach_msg2_internal(
        tmp.bytes,
        opt64,
        (uint64_t)msg->msgh_bits | ((uint64_t)effective_send_size << 32),
        (uint64_t)msg->msgh_remote_port | ((uint64_t)reply_port << 32),
        (uint64_t)(uint32_t)msg->msgh_id << 32,
        (uint64_t)reply_port << 32,
        (uint64_t)sizeof(tmp),
        prio_timeout);
    if (kr != KERN_SUCCESS) {
        s_tls_in_pt_mach_msg--;
        *out_kr = kr;
        return YES;
    }

    pt_sanitize_mig_reply_if_needed(tmp.bytes,
                                    sizeof(tmp),
                                    reply_port,
                                    true,
                                    req_id,
                                    req_flavor,
                                    target_is_self,
                                    caller);

    pt_mig_prepare_complex_reply_for_reenqueue(&tmp.hdr);
    tmp.hdr.msgh_remote_port = reply_port;
    tmp.hdr.msgh_local_port = MACH_PORT_NULL;
    tmp.hdr.msgh_bits = (tmp.hdr.msgh_bits & ~MACH_MSGH_BITS_PORTS_MASK) |
                        MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND_ONCE, 0);

    mach_msg_return_t send_kr = mach_msg(&tmp.hdr,
                                         MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                         tmp.hdr.msgh_size,
                                         0,
                                         MACH_PORT_NULL,
                                         500,
                                         MACH_PORT_NULL);
    s_tls_in_pt_mach_msg--;
    if (send_kr != MACH_MSG_SUCCESS) {
        mach_msg_destroy(&tmp.hdr);
    }
    *out_kr = send_kr;
    return YES;
}

static mach_msg_return_t pt_mach_msg_overwrite_impl(mach_msg_header_t *msg,
                                                    mach_msg_option_t option,
                                                    mach_msg_size_t send_size,
                                                    mach_msg_size_t rcv_size,
                                                    mach_port_name_t rcv_name,
                                                    mach_msg_timeout_t timeout,
                                                    mach_port_name_t notify,
                                                    mach_msg_header_t *rcv_msg,
                                                    mach_msg_size_t rcv_limit,
                                                    bool use_trap,
                                                    const void *caller) {
    BOOL force_dyld = pt_dyld_is_force_task_dyld_sanitize();
    if (s_tls_in_pt_mach_msg > 0 ||
        !pt_is_bypass_enabled() ||
        (!force_dyld && pt_is_effective_system_or_playtools_caller(caller))) {
        return use_trap
            ? ((&pt_orig_mach_msg_overwrite_trap != NULL)
                ? pt_orig_mach_msg_overwrite_trap(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg, rcv_limit)
                : KERN_NOT_SUPPORTED)
            : mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg, rcv_limit);
    }
    bool sending = (option & MACH_SEND_MSG) != 0 && msg != NULL;
    bool receiving = (option & MACH_RCV_MSG) != 0;
    mach_msg_header_t *actual_rcv = (rcv_msg != NULL) ? rcv_msg : msg;
    mach_msg_size_t actual_rcv_cap = (rcv_msg != NULL) ? rcv_limit : rcv_size;
    if (actual_rcv == NULL) {
        receiving = false;
    }
    if (!sending && !receiving) {
        return use_trap
            ? ((&pt_orig_mach_msg_overwrite_trap != NULL)
                ? pt_orig_mach_msg_overwrite_trap(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg, rcv_limit)
                : KERN_NOT_SUPPORTED)
            : mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg, rcv_limit);
    }

    bool had_req = false;
    int req_id = 0;
    int32_t req_flavor = 0;
    bool target_is_self = false;
    mach_port_t reply_port = MACH_PORT_NULL;
    exception_mask_t orig_exc_mask = 0;
    bool patched_exc_mask = false;
    if (sending) {
        mach_msg_size_t effective_send_size = (send_size > 0) ? send_size : msg->msgh_size;
        had_req = pt_extract_mig_request_meta(msg,
                                              msg->msgh_bits,
                                              effective_send_size,
                                              msg->msgh_remote_port,
                                              msg->msgh_id,
                                              &req_flavor,
                                              &target_is_self,
                                              &orig_exc_mask,
                                              &patched_exc_mask);
        if (had_req) {
            req_id = msg->msgh_id;
            reply_port = msg->msgh_local_port;
            if (!receiving) {
                if (!use_trap) {
                    mach_msg_return_t split_kr = MACH_MSG_SUCCESS;
                    if (pt_try_mach_msg_split_kobject_rpc(msg,
                                                          option,
                                                          effective_send_size,
                                                          timeout,
                                                          req_id,
                                                          req_flavor,
                                                          target_is_self,
                                                          reply_port,
                                                          caller,
                                                          &split_kr)) {
                        if (patched_exc_mask) {
                            memcpy((uint8_t *)msg + 48U, &orig_exc_mask, sizeof(orig_exc_mask));
                        }
                        return split_kr;
                    }
                }
                pt_mig_ring_push(reply_port, req_id, req_flavor, target_is_self);
            }
        }
    }

    s_tls_in_pt_mach_msg++;
    mach_msg_return_t kr = use_trap
        ? ((&pt_orig_mach_msg_overwrite_trap != NULL)
            ? pt_orig_mach_msg_overwrite_trap(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg, rcv_limit)
            : KERN_NOT_SUPPORTED)
        : mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg, rcv_limit);
    s_tls_in_pt_mach_msg--;
    if (patched_exc_mask && (!receiving || actual_rcv != msg || kr != MACH_MSG_SUCCESS)) {
        memcpy((uint8_t *)msg + 48U, &orig_exc_mask, sizeof(orig_exc_mask));
    }
    if (sending && !receiving && had_req && kr != MACH_MSG_SUCCESS) {
        pt_mig_ring_erase(reply_port, req_id, req_flavor);
    }
    if (kr == MACH_MSG_SUCCESS && receiving) {
        pt_sanitize_mig_reply_if_needed(actual_rcv,
                                        (size_t)actual_rcv_cap,
                                        rcv_name,
                                        had_req,
                                        req_id,
                                        req_flavor,
                                        target_is_self,
                                        caller);
    }
    return kr;
}

static mach_msg_return_t pt_mach_msg_overwrite(mach_msg_header_t *msg,
                                               mach_msg_option_t option,
                                               mach_msg_size_t send_size,
                                               mach_msg_size_t rcv_size,
                                               mach_port_name_t rcv_name,
                                               mach_msg_timeout_t timeout,
                                               mach_port_name_t notify,
                                               mach_msg_header_t *rcv_msg,
                                               mach_msg_size_t rcv_limit) {
    return pt_mach_msg_overwrite_impl(msg, option, send_size, rcv_size, rcv_name, timeout, notify,
                                      rcv_msg, rcv_limit, false, __builtin_return_address(0));
}

static mach_msg_return_t pt_mach_msg_overwrite_trap(mach_msg_header_t *msg,
                                                    mach_msg_option_t option,
                                                    mach_msg_size_t send_size,
                                                    mach_msg_size_t rcv_size,
                                                    mach_port_name_t rcv_name,
                                                    mach_msg_timeout_t timeout,
                                                    mach_port_name_t notify,
                                                    mach_msg_header_t *rcv_msg,
                                                    mach_msg_size_t rcv_limit) {
    return pt_mach_msg_overwrite_impl(msg, option, send_size, rcv_size, rcv_name, timeout, notify,
                                      rcv_msg, rcv_limit, true, __builtin_return_address(0));
}

static mach_msg_return_t pt_mach_msg_impl(mach_msg_header_t *msg,
                                          mach_msg_option_t option,
                                          mach_msg_size_t send_size,
                                          mach_msg_size_t rcv_size,
                                          mach_port_name_t rcv_name,
                                          mach_msg_timeout_t timeout,
                                          mach_port_name_t notify,
                                          bool use_trap,
                                          const void *caller) {
    BOOL force_dyld = pt_dyld_is_force_task_dyld_sanitize();
    if (s_tls_in_pt_mach_msg > 0 ||
        !pt_is_bypass_enabled() ||
        (!force_dyld && pt_is_effective_system_or_playtools_caller(caller))) {
        return use_trap
            ? ((&pt_orig_mach_msg_trap != NULL)
                ? pt_orig_mach_msg_trap(msg, option, send_size, rcv_size, rcv_name, timeout, notify)
                : KERN_NOT_SUPPORTED)
            : mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
    }
    bool sending = (option & MACH_SEND_MSG) != 0 && msg != NULL;
    bool receiving = (option & MACH_RCV_MSG) != 0 && msg != NULL;
    if (!sending && !receiving) {
        return use_trap
            ? ((&pt_orig_mach_msg_trap != NULL)
                ? pt_orig_mach_msg_trap(msg, option, send_size, rcv_size, rcv_name, timeout, notify)
                : KERN_NOT_SUPPORTED)
            : mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
    }

    bool had_req = false;
    int req_id = 0;
    int32_t req_flavor = 0;
    bool target_is_self = false;
    mach_port_t reply_port = MACH_PORT_NULL;
    exception_mask_t orig_exc_mask = 0;
    bool patched_exc_mask = false;
    if (sending) {
        mach_msg_size_t effective_send_size = (send_size > 0) ? send_size : msg->msgh_size;
        had_req = pt_extract_mig_request_meta(msg,
                                              msg->msgh_bits,
                                              effective_send_size,
                                              msg->msgh_remote_port,
                                              msg->msgh_id,
                                              &req_flavor,
                                              &target_is_self,
                                              &orig_exc_mask,
                                              &patched_exc_mask);
        if (had_req) {
            req_id = msg->msgh_id;
            reply_port = msg->msgh_local_port;
            if (!receiving) {
                if (!use_trap) {
                    mach_msg_return_t split_kr = MACH_MSG_SUCCESS;
                    if (pt_try_mach_msg_split_kobject_rpc(msg,
                                                          option,
                                                          effective_send_size,
                                                          timeout,
                                                          req_id,
                                                          req_flavor,
                                                          target_is_self,
                                                          reply_port,
                                                          caller,
                                                          &split_kr)) {
                        if (patched_exc_mask) {
                            memcpy((uint8_t *)msg + 48U, &orig_exc_mask, sizeof(orig_exc_mask));
                        }
                        return split_kr;
                    }
                }
                pt_mig_ring_push(reply_port, req_id, req_flavor, target_is_self);
            }
        }
    }

    s_tls_in_pt_mach_msg++;
    mach_msg_return_t kr = use_trap
        ? ((&pt_orig_mach_msg_trap != NULL)
            ? pt_orig_mach_msg_trap(msg, option, send_size, rcv_size, rcv_name, timeout, notify)
            : KERN_NOT_SUPPORTED)
        : mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
    s_tls_in_pt_mach_msg--;
    if (patched_exc_mask && (!receiving || kr != MACH_MSG_SUCCESS)) {
        memcpy((uint8_t *)msg + 48U, &orig_exc_mask, sizeof(orig_exc_mask));
    }
    if (sending && !receiving && had_req && kr != MACH_MSG_SUCCESS) {
        pt_mig_ring_erase(reply_port, req_id, req_flavor);
    }
    if (kr == MACH_MSG_SUCCESS && receiving) {
        pt_sanitize_mig_reply_if_needed(msg,
                                        (size_t)rcv_size,
                                        rcv_name,
                                        had_req,
                                        req_id,
                                        req_flavor,
                                        target_is_self,
                                        caller);
    }
    return kr;
}

static mach_msg_return_t pt_mach_msg(mach_msg_header_t *msg,
                                     mach_msg_option_t option,
                                     mach_msg_size_t send_size,
                                     mach_msg_size_t rcv_size,
                                     mach_port_name_t rcv_name,
                                     mach_msg_timeout_t timeout,
                                     mach_port_name_t notify) {
    return pt_mach_msg_impl(msg, option, send_size, rcv_size, rcv_name, timeout, notify,
                            false, __builtin_return_address(0));
}

static mach_msg_return_t pt_mach_msg_trap(mach_msg_header_t *msg,
                                          mach_msg_option_t option,
                                          mach_msg_size_t send_size,
                                          mach_msg_size_t rcv_size,
                                          mach_port_name_t rcv_name,
                                          mach_msg_timeout_t timeout,
                                          mach_port_name_t notify) {
    return pt_mach_msg_impl(msg, option, send_size, rcv_size, rcv_name, timeout, notify,
                            true, __builtin_return_address(0));
}

static kern_return_t pt_mach_msg2_impl(void *data,
                                       uint64_t option64,
                                       uint64_t msgh_bits_and_send_size,
                                       uint64_t msgh_remote_and_local_port,
                                       uint64_t msgh_voucher_and_id,
                                       uint64_t desc_count_and_rcv_name,
                                       uint64_t rcv_size,
                                       uint64_t priority_and_timeout,
                                       bool use_trap,
                                       const void *caller) {
    if (use_trap ? (&pt_orig_mach_msg2_trap == NULL) : (&pt_orig_mach_msg2_internal == NULL)) {
        return KERN_NOT_SUPPORTED;
    }
    BOOL force_dyld = pt_dyld_is_force_task_dyld_sanitize();
    if (s_tls_in_pt_mach_msg > 0 ||
        !pt_is_bypass_enabled() ||
        (!force_dyld && pt_is_effective_system_or_playtools_caller(caller))) {
        return use_trap
            ? pt_orig_mach_msg2_trap(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                                     msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout)
            : pt_orig_mach_msg2_internal(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                                         msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout);
    }

    bool is_vector = (option64 & 0x0000000100000000ULL) != 0;
    bool sending = !is_vector && (option64 & MACH_SEND_MSG) != 0 && data != NULL;
    bool receiving = !is_vector && (option64 & MACH_RCV_MSG) != 0 && data != NULL;
    if (!sending && !receiving) {
        return use_trap
            ? pt_orig_mach_msg2_trap(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                                     msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout)
            : pt_orig_mach_msg2_internal(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                                         msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout);
    }

    bool had_req = false;
    int req_id = 0;
    int32_t req_flavor = 0;
    bool target_is_self = false;
    mach_port_t reply_port = MACH_PORT_NULL;
    exception_mask_t orig_exc_mask = 0;
    bool patched_exc_mask = false;
    if (sending) {
        const mach_msg_header_t *hdr = (const mach_msg_header_t *)data;
        mach_msg_bits_t bits = (mach_msg_bits_t)(msgh_bits_and_send_size & 0xFFFFFFFFU);
        mach_msg_size_t send_size = (mach_msg_size_t)(msgh_bits_and_send_size >> 32);
        if (send_size == 0) {
            send_size = hdr->msgh_size;
        }
        mach_port_t remote_port = (mach_port_t)(msgh_remote_and_local_port & 0xFFFFFFFFU);
        mach_port_t local_port = (mach_port_t)(msgh_remote_and_local_port >> 32);
        int parsed_id = (int)(msgh_voucher_and_id >> 32);
        if (parsed_id == 0) {
            parsed_id = hdr->msgh_id;
        }
        if (local_port == MACH_PORT_NULL) {
            local_port = hdr->msgh_local_port;
        }
        had_req = pt_extract_mig_request_meta(data, bits, send_size, remote_port, parsed_id, &req_flavor,
                                              &target_is_self, &orig_exc_mask, &patched_exc_mask);
        if (had_req) {
            req_id = parsed_id;
            reply_port = local_port;
            if (!receiving) {
                pt_mig_ring_push(reply_port, req_id, req_flavor, target_is_self);
            }
        }
    }

    s_tls_in_pt_mach_msg++;
    kern_return_t kr = use_trap
        ? pt_orig_mach_msg2_trap(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                                 msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout)
        : pt_orig_mach_msg2_internal(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                                     msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout);
    s_tls_in_pt_mach_msg--;
    if (patched_exc_mask && (!receiving || kr != KERN_SUCCESS)) {
        memcpy((uint8_t *)data + 48U, &orig_exc_mask, sizeof(orig_exc_mask));
    }
    if (sending && !receiving && had_req && kr != KERN_SUCCESS) {
        pt_mig_ring_erase(reply_port, req_id, req_flavor);
    }
    if (kr == KERN_SUCCESS && receiving) {
        mach_port_t rcv_name = (mach_port_t)(desc_count_and_rcv_name >> 32);
        size_t rcv_cap = (size_t)(uint32_t)(rcv_size & 0xFFFFFFFFULL);
        pt_sanitize_mig_reply_if_needed(data, rcv_cap, rcv_name, had_req, req_id, req_flavor, target_is_self, caller);
    }
    return kr;
}

static kern_return_t pt_mach_msg2_internal(void *data,
                                           uint64_t option64,
                                           uint64_t msgh_bits_and_send_size,
                                           uint64_t msgh_remote_and_local_port,
                                           uint64_t msgh_voucher_and_id,
                                           uint64_t desc_count_and_rcv_name,
                                           uint64_t rcv_size,
                                           uint64_t priority_and_timeout) {
    return pt_mach_msg2_impl(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                             msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout,
                             false, __builtin_return_address(0));
}

static kern_return_t pt_mach_msg2_trap(void *data,
                                       uint64_t option64,
                                       uint64_t msgh_bits_and_send_size,
                                       uint64_t msgh_remote_and_local_port,
                                       uint64_t msgh_voucher_and_id,
                                       uint64_t desc_count_and_rcv_name,
                                       uint64_t rcv_size,
                                       uint64_t priority_and_timeout) {
    return pt_mach_msg2_impl(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                             msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout,
                             true, __builtin_return_address(0));
}

extern void pt_orig_raw_syscall(void) __asm__("___syscall") __attribute__((weak_import));

PT_INTERPOSE_NAMED(pt_syscall, pt_orig_syscall, "syscall")
PT_INTERPOSE_WEAK_NAMED(pt_syscall, pt_orig_raw_syscall, "__syscall")
PT_INTERPOSE(pt_mach_msg, mach_msg)
PT_INTERPOSE(pt_mach_msg_overwrite, mach_msg_overwrite)
PT_INTERPOSE_WEAK_NAMED(pt_mach_msg2_internal, pt_orig_mach_msg2_internal, "mach_msg2_internal")
PT_INTERPOSE_WEAK_NAMED(pt_mach_msg_trap, pt_orig_mach_msg_trap, "mach_msg_trap")
PT_INTERPOSE_WEAK_NAMED(pt_mach_msg_overwrite_trap, pt_orig_mach_msg_overwrite_trap, "mach_msg_overwrite_trap")
PT_INTERPOSE_WEAK_NAMED(pt_mach_msg2_trap, pt_orig_mach_msg2_trap, "mach_msg2_trap")
