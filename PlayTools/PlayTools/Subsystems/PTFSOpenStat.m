//
//  PTFSOpenStat.m
//  PlayTools
//

#import "PTFSInternal.h"
#import "PTSystemSpooferInternal.h"
#import "PTDyldInternal.h"
#import "PTNetworkInternal.h"
#include <sys/socket.h>
#include <sys/un.h>

__attribute__((visibility("hidden")))
int pt_fs_open_with_caller(const char *filename, int oflag, mode_t mode, const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                            caller,
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &resolved,
                                                            pt_open_flags_are_readonly(oflag));
    if (disp == PT_FS_PATH_HIDDEN) {
        PT_DEBUG_TRACE("fs", "hid open path=%s", filename != NULL ? filename : "<null>");
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        PT_DEBUG_TRACE("fs", "virtual-ancestor open path=%s", filename != NULL ? filename : "<null>");
        errno = (oflag & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (resolved == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (filename != NULL && resolved != filename) {
        PT_DEBUG_TRACE("fs", "redirected open %s -> %s", filename, resolved);
    }
    if (oflag & O_CREAT) {
        return open(resolved, oflag, (int)mode);
    }
    return open(resolved, oflag);
}

static int pt_open(char const* restrict filename, int oflag, ... ) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return pt_fs_open_with_caller(filename, oflag, mode, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_openat_with_caller(int fd, const char *path, int oflag, mode_t mode, const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_mode(fd,
                                                               path,
                                                               caller,
                                                               vbuf,
                                                               sizeof(vbuf),
                                                               &path,
                                                               pt_open_flags_are_readonly(oflag));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (oflag & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (oflag & O_CREAT) {
        return openat(fd, path, oflag, (int)mode);
    }
    return openat(fd, path, oflag);
}

static int pt_openat(int fd, const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return pt_fs_openat_with_caller(fd, path, oflag, mode, __builtin_return_address(0));
}

static int pt_creat(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EACCES;
        return -1;
    }
    return creat(path, mode);
}

extern int pt_orig_open_nocancel(const char *, int, ...) __asm("_open$NOCANCEL");
extern int pt_orig_openat_nocancel(int, const char *, int, ...) __asm("_openat$NOCANCEL");
extern int pt_orig_creat_nocancel(const char *, mode_t) __asm("_creat$NOCANCEL");

static int pt_open_nocancel(char const* restrict filename, int oflag, ...) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                            __builtin_return_address(0),
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &resolved,
                                                            pt_open_flags_are_readonly(oflag));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (oflag & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        int mod = va_arg(ap, int);
        va_end(ap);
        return pt_orig_open_nocancel(resolved, oflag, mod);
    }
    return pt_orig_open_nocancel(resolved, oflag);
}

static int pt_openat_nocancel(int fd, const char *path, int oflag, ...) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_mode(fd,
                                                               path,
                                                               __builtin_return_address(0),
                                                               vbuf,
                                                               sizeof(vbuf),
                                                               &path,
                                                               pt_open_flags_are_readonly(oflag));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (oflag & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        int mod = va_arg(ap, int);
        va_end(ap);
        return pt_orig_openat_nocancel(fd, path, oflag, mod);
    }
    return pt_orig_openat_nocancel(fd, path, oflag);
}

static int pt_creat_nocancel(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EACCES;
        return -1;
    }
    return pt_orig_creat_nocancel(path, mode);
}

static void pt_record_fd_dpclass(int fd, int dpclass);

__attribute__((visibility("hidden")))
int pt_fs_open_dprotected_np_with_caller(const char *path,
                                         int flags,
                                         int dpclass,
                                         int dpflags,
                                         mode_t mode,
                                         const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(path,
                                                            caller,
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &path,
                                                            pt_open_flags_are_readonly(flags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    int ret = (flags & O_CREAT)
        ? open_dprotected_np(path, flags, dpclass, dpflags, (int)mode)
        : open_dprotected_np(path, flags, dpclass, dpflags);
    if (ret >= 0 && dpclass >= 1 && dpclass <= 7 &&
        pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        pt_record_fd_dpclass(ret, dpclass);
    }
    return ret;
}

static int pt_open_dprotected_np(const char *path, int flags, int dpclass, int dpflags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, dpflags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return pt_fs_open_dprotected_np_with_caller(path, flags, dpclass, dpflags, mode, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_openat_dprotected_np_with_caller(int fd,
                                           const char *path,
                                           int flags,
                                           int dpclass,
                                           int dpflags,
                                           mode_t mode,
                                           const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_mode(fd,
                                                               path,
                                                               caller,
                                                               vbuf,
                                                               sizeof(vbuf),
                                                               &path,
                                                               pt_open_flags_are_readonly(flags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    int ret = (flags & O_CREAT)
        ? openat_dprotected_np(fd, path, flags, dpclass, dpflags, (int)mode)
        : openat_dprotected_np(fd, path, flags, dpclass, dpflags);
    if (ret >= 0 && dpclass >= 1 && dpclass <= 7 &&
        pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        pt_record_fd_dpclass(ret, dpclass);
    }
    return ret;
}

static int pt_openat_dprotected_np(int fd, const char *path, int flags, int dpclass, int dpflags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, dpflags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return pt_fs_openat_dprotected_np_with_caller(fd, path, flags, dpclass, dpflags, mode, __builtin_return_address(0));
}

typedef uint64_t pt_guardid_t;
extern int guarded_open_np(const char *path, const pt_guardid_t *guard, u_int guardflags, int flags, ...);
extern int guarded_open_dprotected_np(const char *path, const pt_guardid_t *guard, u_int guardflags, int flags, int dpclass, int dpflags, ...);

__attribute__((visibility("hidden")))
int pt_fs_guarded_open_np_with_caller(const char *path,
                                      const void *guard,
                                      u_int guardflags,
                                      int flags,
                                      mode_t mode,
                                      const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(path,
                                                            caller,
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &path,
                                                            pt_open_flags_are_readonly(flags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (flags & O_CREAT) {
        return guarded_open_np(path, (const pt_guardid_t *)guard, guardflags, flags, mode);
    }
    return guarded_open_np(path, (const pt_guardid_t *)guard, guardflags, flags);
}

static int pt_guarded_open_np(const char *path, const pt_guardid_t *guard, u_int guardflags, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return pt_fs_guarded_open_np_with_caller(path, guard, guardflags, flags, mode, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_guarded_open_dprotected_np_with_caller(const char *path,
                                                 const void *guard,
                                                 u_int guardflags,
                                                 int flags,
                                                 int dpclass,
                                                 int dpflags,
                                                 mode_t mode,
                                                 const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(path,
                                                            caller,
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &path,
                                                            pt_open_flags_are_readonly(flags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    int ret = (flags & O_CREAT)
        ? guarded_open_dprotected_np(path, (const pt_guardid_t *)guard, guardflags, flags, dpclass, dpflags, (int)mode)
        : guarded_open_dprotected_np(path, (const pt_guardid_t *)guard, guardflags, flags, dpclass, dpflags);
    if (ret >= 0 && dpclass >= 1 && dpclass <= 7 &&
        pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        pt_record_fd_dpclass(ret, dpclass);
    }
    return ret;
}

static int pt_guarded_open_dprotected_np(const char *path, const pt_guardid_t *guard, u_int guardflags, int flags, int dpclass, int dpflags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, dpflags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return pt_fs_guarded_open_dprotected_np_with_caller(path, guard, guardflags, flags, dpclass, dpflags, mode, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_open_extended_with_caller(const char *path,
                                    int flags,
                                    uid_t uid,
                                    gid_t gid,
                                    mode_t mode,
                                    void *xsecurity,
                                    const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(path,
                                                            caller,
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &resolved,
                                                            pt_open_flags_are_readonly(flags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (resolved == NULL) {
        errno = EFAULT;
        return -1;
    }
    return (int)pt_orig_syscall(277,
                                (uintptr_t)resolved,
                                (uintptr_t)flags,
                                (uintptr_t)uid,
                                (uintptr_t)gid,
                                (uintptr_t)mode,
                                (uintptr_t)xsecurity,
                                0,
                                0);
}

extern FILE *pt_orig_fopen_darwin_extsn(const char *, const char *) __asm("_fopen$DARWIN_EXTSN");

static FILE *pt_fopen(const char *filename, const char *mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                            __builtin_return_address(0),
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &filename,
                                                            pt_fopen_mode_is_readonly(mode));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return NULL;
    }
    return fopen(filename, mode);
}

static FILE *pt_fopen_darwin_extsn(const char *filename, const char *mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                            __builtin_return_address(0),
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &filename,
                                                            pt_fopen_mode_is_readonly(mode));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return NULL;
    }
    return pt_orig_fopen_darwin_extsn(filename, mode);
}

static FILE *pt_freopen(const char *filename, const char *mode, FILE *stream) {
    char vbuf[PATH_MAX];
    if (filename != NULL) {
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                                __builtin_return_address(0),
                                                                vbuf,
                                                                sizeof(vbuf),
                                                                &filename,
                                                                pt_fopen_mode_is_readonly(mode));
        if (disp == PT_FS_PATH_HIDDEN) {
            errno = ENOENT;
            return NULL;
        }
        if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
            errno = EPERM;
            return NULL;
        }
    }
    return freopen(filename, mode, stream);
}

__attribute__((visibility("hidden")))
int pt_fs_stat_with_caller(const char *path, struct stat *buf, BOOL follow_symlinks, const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        PT_DEBUG_TRACE("fs", "hid %s path=%s", follow_symlinks ? "stat" : "lstat", path != NULL ? path : "<null>");
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        PT_DEBUG_TRACE("fs", "virtual-ancestor %s path=%s", follow_symlinks ? "stat" : "lstat", path != NULL ? path : "<null>");
        return pt_stat_virtual_ancestor(resolved, buf, caller);
    }
    if (resolved == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (path != NULL && resolved != path) {
        PT_DEBUG_TRACE("fs", "redirected %s %s -> %s", follow_symlinks ? "stat" : "lstat", path, resolved);
    }
    int ret = follow_symlinks ? stat(resolved, buf) : lstat(resolved, buf);
    if (ret == 0) {
        pt_sanitize_stat_buf(buf, caller);
    }
    return ret;
}

static int pt_stat(char const* restrict path, struct stat* restrict buf) {
    return pt_fs_stat_with_caller(path, buf, YES, __builtin_return_address(0));
}

static int pt_lstat(char const* restrict path, struct stat* restrict buf) {
    return pt_fs_stat_with_caller(path, buf, NO, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_fstat_with_caller(int fd, struct stat *buf, const void *caller) {
    if (fd < 0) {
        errno = EBADF;
        return -1;
    }
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    int ret = fstat(fd, buf);
    if (ret == 0) {
        pt_sanitize_stat_buf(buf, caller);
    }
    return ret;
}

static int pt_fstat(int fd, struct stat *buf) {
    return pt_fs_fstat_with_caller(fd, buf, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_prepare_legacy_stat_path_with_caller(int dirfd,
                                               BOOL is_at,
                                               const char *path,
                                               const void *caller,
                                               char *vbuf,
                                               size_t vbuf_size,
                                               const char **out_resolved,
                                               BOOL *out_virtual_ancestor) {
    if (out_virtual_ancestor != NULL) {
        *out_virtual_ancestor = NO;
    }
    if (is_at && dirfd != AT_FDCWD && (path == NULL || path[0] != '/') &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        pt_fd_is_sensitive(dirfd, caller)) {
        errno = EBADF;
        return -1;
    }
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = is_at
        ? pt_prepare_fs_path_at_ro(dirfd, path, caller, vbuf, vbuf_size, &resolved)
        : pt_prepare_fs_path_ro(path, caller, vbuf, vbuf_size, &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        if (out_virtual_ancestor != NULL) {
            *out_virtual_ancestor = YES;
        }
        return 0;
    }
    if (resolved == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (out_resolved != NULL) {
        *out_resolved = resolved;
    }
    return 0;
}

__attribute__((visibility("hidden")))
int pt_fs_fstatat_with_caller(int fd, const char *path, struct stat *buf, int flag, const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_ro(fd, path, caller, vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return pt_stat_virtual_ancestor(path, buf, caller);
    }
    int ret = fstatat(fd, path, buf, flag);
    if (ret == 0) {
        pt_sanitize_stat_buf(buf, caller);
    }
    return ret;
}

static int pt_fstatat(int fd, const char *path, struct stat *buf, int flag) {
    return pt_fs_fstatat_with_caller(fd, path, buf, flag, __builtin_return_address(0));
}

static int pt_statx_np(const char *path, struct stat *buf, filesec_t fsec) {
    const void *caller = __builtin_return_address(0);
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, caller, vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return pt_stat_virtual_ancestor(path, buf, caller);
    }
    int ret = statx_np(path, buf, fsec);
    if (ret == 0) {
        pt_sanitize_stat_buf(buf, caller);
    }
    return ret;
}

static int pt_lstatx_np(const char *path, struct stat *buf, filesec_t fsec) {
    const void *caller = __builtin_return_address(0);
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, caller, vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return pt_stat_virtual_ancestor(path, buf, caller);
    }
    int ret = lstatx_np(path, buf, fsec);
    if (ret == 0) {
        pt_sanitize_stat_buf(buf, caller);
    }
    return ret;
}

static int pt_fstatx_np(int fd, struct stat *buf, filesec_t fsec) {
    const void *caller = __builtin_return_address(0);
    if (fd < 0) {
        errno = EBADF;
        return -1;
    }
    if (!pt_is_effective_system_or_playtools_caller(caller) && pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    int ret = fstatx_np(fd, buf, fsec);
    if (ret == 0) {
        pt_sanitize_stat_buf(buf, caller);
    }
    return ret;
}

_Static_assert(sizeof(struct stat) == 144, "arm64 struct stat must be 144 bytes");
#if !__DARWIN_ONLY_64_BIT_INO_T
_Static_assert(sizeof(struct stat) == sizeof(struct stat64), "arm64 struct stat and stat64 must match");
#endif

extern int pt_orig_stat64(const char *, struct stat *) __asm__("_stat64") __attribute__((weak_import));
extern int pt_orig_lstat64(const char *, struct stat *) __asm__("_lstat64") __attribute__((weak_import));
extern int pt_orig_fstat64(int, struct stat *) __asm__("_fstat64") __attribute__((weak_import));
extern int pt_orig_fstatat64(int, const char *, struct stat *, int) __asm__("_fstatat64") __attribute__((weak_import));

static int pt_stat64(const char *path, struct stat *buf) {
    return pt_fs_stat_with_caller(path, buf, YES, __builtin_return_address(0));
}

static int pt_lstat64(const char *path, struct stat *buf) {
    return pt_fs_stat_with_caller(path, buf, NO, __builtin_return_address(0));
}

static int pt_fstat64(int fd, struct stat *buf) {
    return pt_fs_fstat_with_caller(fd, buf, __builtin_return_address(0));
}

static int pt_fstatat64(int fd, const char *path, struct stat *buf, int flag) {
    return pt_fs_fstatat_with_caller(fd, path, buf, flag, __builtin_return_address(0));
}

static int pt_accessx_np(const struct accessx_descriptor *descs, size_t size, int *results, uid_t uid) {
    return pt_fs_access_extended_with_caller((void *)descs, size, results, uid, __builtin_return_address(0));
}

extern int pt_orig_openbyid_np(fsid_t *fsid, fsobj_id_t *objid, int oflags) __asm__("_openbyid_np") __attribute__((weak_import));
extern int pt_orig_openat_authenticated_np(int dirfd, const char *path, int oflags, int authfd) __asm__("_openat_authenticated_np") __attribute__((weak_import));

static int pt_openbyid_np(fsid_t *fsid, fsobj_id_t *objid, int oflags) {
    if (&pt_orig_openbyid_np == NULL) {
        errno = ENOSYS;
        return -1;
    }
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pt_is_bypass_enabled() && fsid != NULL && objid != NULL) {
        char pbuf[PATH_MAX];
        int saved_errno = errno;
        ssize_t r = pt_fs_fsgetpath_with_caller(pbuf, sizeof(pbuf), fsid, *(const uint64_t *)objid, caller);
        if (r < 0 && errno == ENOENT) {
            return -1;
        }
        errno = saved_errno;
    }
    int fd = pt_orig_openbyid_np(fsid, objid, oflags);
    if (fd >= 0 && !is_sys && pt_is_bypass_enabled() && pt_fd_is_sensitive(fd, caller)) {
        close(fd);
        errno = ENOENT;
        return -1;
    }
    return fd;
}

static int pt_openat_authenticated_np(int dirfd, const char *path, int oflags, int authfd) {
    if (&pt_orig_openat_authenticated_np == NULL) {
        errno = ENOSYS;
        return -1;
    }
    const void *caller = __builtin_return_address(0);
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_mode(
        dirfd, path, caller, vbuf, sizeof(vbuf), &resolved, pt_open_flags_are_readonly(oflags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (oflags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    return pt_orig_openat_authenticated_np(dirfd, resolved, oflags, authfd);
}

__attribute__((visibility("hidden")))
int pt_fs_stat_extended_with_caller(const char *path,
                                    void *ub,
                                    void *xsecurity,
                                    size_t *xsecurity_size,
                                    BOOL is_64,
                                    BOOL follow_links,
                                    const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    BOOL virtual_anc = NO;
    if (pt_fs_prepare_legacy_stat_path_with_caller(AT_FDCWD, NO, path, caller, vbuf, sizeof(vbuf), &resolved, &virtual_anc) != 0) {
        return -1;
    }
    if (virtual_anc) {
        if (ub == NULL || !pt_is_valid_user_pointer(ub)) {
            errno = EFAULT;
            return -1;
        }
        struct stat st64;
        memset(&st64, 0, sizeof(st64));
        int sr = pt_fs_stat_with_caller(path, &st64, follow_links, caller);
        if (sr == 0) {
            if (is_64) {
                memcpy(ub, &st64, sizeof(st64));
            } else {
                pt_copy_stat64_to_legacy_user64_stat(&st64, ub);
            }
            if (xsecurity_size != NULL && pt_is_valid_user_pointer(xsecurity_size)) {
                *xsecurity_size = 0;
            }
        }
        return sr;
    }
    int sysno = is_64 ? (follow_links ? 341 : 342) : (follow_links ? 279 : 280);
    int ret = (int)pt_orig_syscall(sysno,
                                   (uintptr_t)resolved,
                                   (uintptr_t)ub,
                                   (uintptr_t)xsecurity,
                                   (uintptr_t)xsecurity_size,
                                   0, 0, 0, 0);
    if (ret == 0 && ub != NULL && pt_is_valid_user_pointer(ub)) {
        if (is_64) {
            pt_sanitize_stat_buf((struct stat *)ub, caller);
        } else {
            pt_sanitize_legacy_user64_stat_in_place(ub, caller);
        }
    }
    return ret;
}

__attribute__((visibility("hidden")))
int pt_fs_fstat_extended_with_caller(int fd,
                                     void *ub,
                                     void *xsecurity,
                                     size_t *xsecurity_size,
                                     BOOL is_64,
                                     const void *caller) {
    if (!pt_is_effective_system_or_playtools_caller(caller) && pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    int sysno = is_64 ? 343 : 281;
    int ret = (int)pt_orig_syscall(sysno,
                                   (uintptr_t)fd,
                                   (uintptr_t)ub,
                                   (uintptr_t)xsecurity,
                                   (uintptr_t)xsecurity_size,
                                   0, 0, 0, 0);
    if (ret == 0 && ub != NULL && pt_is_valid_user_pointer(ub)) {
        if (is_64) {
            pt_sanitize_stat_buf((struct stat *)ub, caller);
        } else {
            pt_sanitize_legacy_user64_stat_in_place(ub, caller);
        }
    }
    return ret;
}

__attribute__((visibility("hidden")))
int pt_fs_access_with_caller(const char *path, int mode, const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(path,
                                                            caller,
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &path,
                                                            (mode & W_OK) == 0);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        if (mode & W_OK) {
            errno = EACCES;
            return -1;
        }
        return 0;
    }
    return access(path, mode);
}

static int pt_access(char const* path, int mode) {
    return pt_fs_access_with_caller(path, mode, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_faccessat_with_caller(int fd, const char *path, int mode, int flag, const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_mode(fd,
                                                               path,
                                                               caller,
                                                               vbuf,
                                                               sizeof(vbuf),
                                                               &path,
                                                               (mode & W_OK) == 0);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        if (mode & W_OK) {
            errno = EACCES;
            return -1;
        }
        return 0;
    }
    return faccessat(fd, path, mode, flag);
}

static int pt_faccessat(int fd, const char *path, int mode, int flag) {
    return pt_fs_faccessat_with_caller(fd, path, mode, flag, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_access_extended_with_caller(void *entries,
                                      size_t size,
                                      void *results,
                                      uid_t uid,
                                      const void *caller) {
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return (int)pt_orig_syscall(284, (uintptr_t)entries, (uintptr_t)size, (uintptr_t)results, (uintptr_t)uid, 0, 0, 0, 0);
    }
    if (entries == NULL || results == NULL ||
        !pt_is_valid_user_pointer(entries) || !pt_is_valid_user_pointer(results)) {
        errno = EFAULT;
        return -1;
    }
    if (size < sizeof(struct accessx_descriptor) || size > 16384U) {
        errno = EINVAL;
        return -1;
    }
    const struct accessx_descriptor *descs = (const struct accessx_descriptor *)entries;
    unsigned int first_off = descs[0].ad_name_offset;
    if (first_off < sizeof(struct accessx_descriptor) ||
        first_off > size ||
        (first_off % sizeof(struct accessx_descriptor)) != 0) {
        errno = EINVAL;
        return -1;
    }
    size_t count = first_off / sizeof(struct accessx_descriptor);
    if (count == 0 || count > 100U) {
        errno = EINVAL;
        return -1;
    }
    const char *base = (const char *)entries;
    const char *prev_path = NULL;
    int *res_out = (int *)results;
    for (size_t i = 0; i < count; i++) {
        const char *cur_path = NULL;
        unsigned int off = descs[i].ad_name_offset;
        if (off != 0) {
            if (off < first_off || off >= size) {
                errno = EINVAL;
                return -1;
            }
            size_t avail = size - off;
            const char *cand = base + off;
            if (memchr(cand, '\0', avail) == NULL) {
                errno = EINVAL;
                return -1;
            }
            cur_path = cand;
            prev_path = cand;
        } else {
            if (prev_path == NULL) {
                errno = EINVAL;
                return -1;
            }
            cur_path = prev_path;
        }

        char vbuf[PATH_MAX];
        const char *resolved = NULL;
        BOOL readonly_req = ((descs[i].ad_flags & (W_OK | 0xF000)) == 0);
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(cur_path,
                                                                caller,
                                                                vbuf,
                                                                sizeof(vbuf),
                                                                &resolved,
                                                                readonly_req);
        if (disp == PT_FS_PATH_HIDDEN) {
            res_out[i] = ENOENT;
            continue;
        }
        if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
            res_out[i] = readonly_req ? 0 : EACCES;
            continue;
        }
        if (resolved == NULL) {
            res_out[i] = EFAULT;
            continue;
        }
        size_t rlen = strlen(resolved) + 1U;
        if (sizeof(struct accessx_descriptor) + rlen > 16384U) {
            res_out[i] = ENAMETOOLONG;
            continue;
        }
        uint8_t single_buf[sizeof(struct accessx_descriptor) + PATH_MAX];
        struct accessx_descriptor *sdesc = (struct accessx_descriptor *)single_buf;
        sdesc->ad_name_offset = (unsigned int)sizeof(struct accessx_descriptor);
        sdesc->ad_flags = descs[i].ad_flags;
        sdesc->ad_pad[0] = descs[i].ad_pad[0];
        sdesc->ad_pad[1] = descs[i].ad_pad[1];
        memcpy(single_buf + sizeof(struct accessx_descriptor), resolved, rlen);
        int single_res = 0;
        int saved_errno = errno;
        intptr_t rc = pt_orig_syscall(284,
                                      (uintptr_t)single_buf,
                                      (uintptr_t)(sizeof(struct accessx_descriptor) + rlen),
                                      (uintptr_t)&single_res,
                                      (uintptr_t)uid,
                                      0, 0, 0, 0);
        int call_errno = errno;
        errno = saved_errno;
        res_out[i] = (rc == 0) ? single_res : call_errno;
    }
    return 0;
}

static ssize_t pt_finish_readlink(ssize_t len,
                                  char *raw_buf,
                                  char * restrict buf,
                                  size_t bufsize,
                                  const void *caller) {
    if (len < 0) {
        return -1;
    }
    raw_buf[len] = '\0';
    const char *out_path = raw_buf;
    size_t out_len = (size_t)len;
    char vout[PATH_MAX];
    if (!pt_is_effective_system_or_playtools_caller(caller)) {
        if ((raw_buf[0] == '/' && pt_is_sensitive_host_fd_path(raw_buf, caller)) ||
            pt_is_hidden_dyld_image_name(raw_buf)) {
            errno = ENOENT;
            return -1;
        }
        const char *virt = pt_virtualize_path_for_app(raw_buf, vout, sizeof(vout), NO);
        if (virt != raw_buf) {
            out_path = virt;
            out_len = strlen(virt);
        }
    }
    size_t copy_len = out_len < bufsize ? out_len : bufsize;
    memcpy(buf, out_path, copy_len);
    return (ssize_t)copy_len;
}

extern ssize_t pt_orig_freadlink(int fd, char *buf, size_t bufsize) __asm("_freadlink") __attribute__((weak_import));

__attribute__((visibility("hidden")))
ssize_t pt_fs_freadlink_with_caller(int fd, char *buf, size_t bufsize, const void *caller) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pt_is_bypass_enabled()) {
        if (pt_is_compat13_7_active()) {
            errno = ENOSYS;
            return -1;
        }
        if (pt_fd_is_sensitive(fd, caller)) {
            errno = EBADF;
            return -1;
        }
    }
    ssize_t r = (&pt_orig_freadlink != NULL)
        ? pt_orig_freadlink(fd, buf, bufsize)
        : (ssize_t)pt_orig_syscall(551, (uintptr_t)fd, (uintptr_t)buf, (uintptr_t)bufsize, 0, 0, 0, 0, 0);
    if (r > 0 && !is_sys && pt_is_bypass_enabled() &&
        buf != NULL && bufsize > 0 && pt_is_valid_user_pointer(buf)) {
        size_t slen = ((size_t)r < PATH_MAX) ? (size_t)r : (PATH_MAX - 1U);
        char raw_buf[PATH_MAX];
        memcpy(raw_buf, buf, slen);
        raw_buf[slen] = '\0';
        if ((raw_buf[0] == '/' && pt_is_sensitive_host_fd_path(raw_buf, caller)) ||
            pt_is_hidden_dyld_image_name(raw_buf)) {
            errno = EBADF;
            return -1;
        }
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(raw_buf, vout, sizeof(vout), NO);
        if (virt != raw_buf) {
            size_t vlen = strlen(virt);
            size_t copy_len = (vlen < bufsize) ? vlen : bufsize;
            memcpy(buf, virt, copy_len);
            return (ssize_t)copy_len;
        }
    }
    return r;
}

static ssize_t pt_freadlink(int fd, char *buf, size_t bufsize) {
    return pt_fs_freadlink_with_caller(fd, buf, bufsize, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_readlink_with_caller(const char *path, char *buf, size_t bufsize, const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EINVAL;
        return -1;
    }
    if (buf == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (bufsize == 0) {
        return readlink(resolved, buf, 0);
    }
    char raw_buf[PATH_MAX];
    ssize_t len = readlink(resolved, raw_buf, sizeof(raw_buf) - 1);
    return pt_finish_readlink(len, raw_buf, buf, bufsize, caller);
}

static ssize_t pt_readlink(const char * restrict path, char * restrict buf, size_t bufsize) {
    return pt_fs_readlink_with_caller(path, buf, bufsize, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_readlinkat_with_caller(int fd, const char *path, char *buf, size_t bufsize, const void *caller) {
    if (pt_fd_is_sensitive(fd, caller)) {
        errno = ENOENT;
        return -1;
    }
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at(fd, path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EINVAL;
        return -1;
    }
    if (buf == NULL || bufsize == 0) {
        return readlinkat(fd, resolved, buf, bufsize);
    }
    char raw_buf[PATH_MAX];
    ssize_t len = readlinkat(fd, resolved, raw_buf, sizeof(raw_buf) - 1);
    return pt_finish_readlink(len, raw_buf, buf, bufsize, caller);
}

static ssize_t pt_readlinkat(int fd, const char * restrict path, char * restrict buf, size_t bufsize) {
    return pt_fs_readlinkat_with_caller(fd, path, buf, bufsize, __builtin_return_address(0));
}

extern char *pt_orig_realpath_legacy(const char *, char *) __asm("_realpath");

static char *pt_realpath_common(const char * restrict file_name,
                                char * restrict resolved_name,
                                const void *caller,
                                char *(*orig_fn)(const char *, char *)) {
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller_ro(file_name, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        char canon[PATH_MAX];
        if (strncmp(resolved, "/private/", 9) == 0 || strcmp(resolved, "/private") == 0) {
            strlcpy(canon, resolved, sizeof(canon));
        } else if (strncmp(resolved, "/var/", 5) == 0 || strcmp(resolved, "/var") == 0) {
            snprintf(canon, sizeof(canon), "/private%s", resolved);
        } else {
            char anc_vout[PATH_MAX];
            const char *virt_anc = pt_virtualize_path_for_app(resolved, anc_vout, sizeof(anc_vout), YES);
            if (strncmp(virt_anc, "/var/", 5) == 0 || strcmp(virt_anc, "/var") == 0) {
                snprintf(canon, sizeof(canon), "/private%s", virt_anc);
            } else if (pt_is_sensitive_host_fd_path(virt_anc, caller)) {
                strlcpy(canon, "/private/var/mobile", sizeof(canon));
            } else {
                strlcpy(canon, virt_anc, sizeof(canon));
            }
        }
        size_t clen = strlen(canon);
        while (clen > 1 && canon[clen - 1] == '/') {
            canon[--clen] = '\0';
        }
        if (resolved_name != NULL) {
            strlcpy(resolved_name, canon, PATH_MAX);
            return resolved_name;
        }
        return strdup(canon);
    }
    if (is_sys_caller < 0) {
        is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    BOOL is_virtual_in = (resolved == vbuf);
    if (is_sys_caller == 0 || is_virtual_in) {
        char tmp_resolved[PATH_MAX];
        char *res = orig_fn(resolved, tmp_resolved);
        if (res == NULL) {
            return NULL;
        }
        if (is_sys_caller == 0 && pt_is_sensitive_host_fd_path(tmp_resolved, caller)) {
            errno = ENOENT;
            return NULL;
        }
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(tmp_resolved, vout, sizeof(vout), YES);
        if (resolved_name != NULL) {
            strlcpy(resolved_name, virt, PATH_MAX);
            return resolved_name;
        }
        return strdup(virt);
    }
    return orig_fn(resolved, resolved_name);
}

static char *pt_realpath(const char * restrict file_name, char * restrict resolved_name) {
    return pt_realpath_common(file_name, resolved_name, __builtin_return_address(0), realpath);
}

static char *pt_realpath_legacy(const char * restrict file_name, char * restrict resolved_name) {
    return pt_realpath_common(file_name, resolved_name, __builtin_return_address(0), pt_orig_realpath_legacy);
}

static char *pt_getcwd_with_caller(char *buf, size_t size, const void *caller) {
    if (buf != NULL && size == 0) {
        errno = EINVAL;
        return NULL;
    }
    char raw_buf[PATH_MAX];
    if (getcwd(raw_buf, sizeof(raw_buf)) == NULL) {
        return NULL;
    }
    const char *out_path = raw_buf;
    char vout[PATH_MAX];
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        out_path = pt_virtualize_path_for_app(raw_buf, vout, sizeof(vout), YES);
        if (pt_is_hidden_path(out_path, caller)) {
            const char *vh = pt_get_virtual_home_cstr();
            out_path = (vh != NULL && vh[0] != '\0') ? vh : "/";
        }
    }
    size_t need = strlen(out_path) + 1;
    if (buf != NULL) {
        if (need > size) {
            errno = ERANGE;
            return NULL;
        }
        memcpy(buf, out_path, need);
        return buf;
    }
    if (size == 0) {
        return strdup(out_path);
    }
    if (need > size) {
        errno = ERANGE;
        return NULL;
    }
    char *alloc = (char *)malloc(size);
    if (alloc == NULL) {
        return NULL;
    }
    memcpy(alloc, out_path, need);
    return alloc;
}

static char *pt_getcwd(char *buf, size_t size) {
    return pt_getcwd_with_caller(buf, size, __builtin_return_address(0));
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static char *pt_getwd(char *buf) {
    if (buf == NULL) {
        errno = EFAULT;
        return NULL;
    }
    return pt_getcwd_with_caller(buf, PATH_MAX, __builtin_return_address(0));
}
#pragma clang diagnostic pop

__attribute__((visibility("hidden")))
int pt_fs_chdir_with_caller(const char *path, const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, caller, vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    return chdir(path);
}

static int pt_chdir(const char *path) {
    return pt_fs_chdir_with_caller(path, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_fchdir_with_caller(int fd, const void *caller) {
    if (pt_fd_is_sensitive(fd, caller)) {
        errno = EACCES;
        return -1;
    }
    return fchdir(fd);
}

static int pt_fchdir(int fd) {
    return pt_fs_fchdir_with_caller(fd, __builtin_return_address(0));
}

static int pt_handle_fcntl_getpath(int ret, int cmd, void *parg, const void *caller) {
    if (ret != -1 && parg != NULL &&
        (cmd == F_GETPATH
#ifdef F_GETPATH_MTMINFO
         || cmd == F_GETPATH_MTMINFO
#endif
#ifdef F_GETPATH_NOFIRMLINK
         || cmd == F_GETPATH_NOFIRMLINK
#endif
         )) {
        char *pathbuf = (char *)parg;
        if (!pt_is_effective_system_or_playtools_caller(caller)) {
            if (pt_is_sensitive_host_fd_path(pathbuf, caller)) {
                pathbuf[0] = '\0';
                errno = EBADF;
                return -1;
            }
            char vout[PATH_MAX];
            const char *virt = pt_virtualize_path_for_app(pathbuf, vout, sizeof(vout), YES);
            if (virt != pathbuf) {
                strlcpy(pathbuf, virt, MAXPATHLEN);
            }
        }
    }
    return ret;
}

#define PT_DPCLASS_CACHE_CAP 256U

typedef struct {
    dev_t dev;
    ino_t ino;
    int dpclass;
    BOOL valid;
} pt_dpclass_entry_t;

static os_unfair_lock s_dpclass_lock = OS_UNFAIR_LOCK_INIT;
static pt_dpclass_entry_t s_dpclass_cache[PT_DPCLASS_CACHE_CAP];
static size_t s_dpclass_next = 0;

__attribute__((visibility("hidden"))) void pt_record_stat_dpclass(dev_t dev, ino_t ino, int dpclass) {
    if (ino == 0 || dpclass <= 0) {
        return;
    }
    os_unfair_lock_lock(&s_dpclass_lock);
    for (size_t i = 0; i < PT_DPCLASS_CACHE_CAP; i++) {
        if (s_dpclass_cache[i].valid &&
            s_dpclass_cache[i].dev == dev &&
            s_dpclass_cache[i].ino == ino) {
            s_dpclass_cache[i].dpclass = dpclass;
            os_unfair_lock_unlock(&s_dpclass_lock);
            return;
        }
    }
    size_t slot = s_dpclass_next % PT_DPCLASS_CACHE_CAP;
    s_dpclass_next = (s_dpclass_next + 1U) % PT_DPCLASS_CACHE_CAP;
    s_dpclass_cache[slot].dev = dev;
    s_dpclass_cache[slot].ino = ino;
    s_dpclass_cache[slot].dpclass = dpclass;
    s_dpclass_cache[slot].valid = YES;
    os_unfair_lock_unlock(&s_dpclass_lock);
}

__attribute__((visibility("hidden"))) int pt_lookup_stat_dpclass(dev_t dev, ino_t ino) {
    if (ino == 0) {
        return 0;
    }
    int found = 0;
    os_unfair_lock_lock(&s_dpclass_lock);
    for (size_t i = 0; i < PT_DPCLASS_CACHE_CAP; i++) {
        if (s_dpclass_cache[i].valid &&
            s_dpclass_cache[i].dev == dev &&
            s_dpclass_cache[i].ino == ino) {
            found = s_dpclass_cache[i].dpclass;
            break;
        }
    }
    os_unfair_lock_unlock(&s_dpclass_lock);
    return found;
}

static void pt_record_fd_dpclass(int fd, int dpclass) {
    if (fd < 0 || dpclass <= 0) {
        return;
    }
    int saved_errno = errno;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        errno = saved_errno;
        return;
    }
    errno = saved_errno;
    pt_record_stat_dpclass(st.st_dev, st.st_ino, dpclass);
}

__attribute__((visibility("hidden"))) int pt_lookup_fd_dpclass(int fd) {
    if (fd < 0) {
        return 0;
    }
    int saved_errno = errno;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        errno = saved_errno;
        return 0;
    }
    errno = saved_errno;
    return pt_lookup_stat_dpclass(st.st_dev, st.st_ino);
}

static int pt_handle_fcntl_get_dpclass(int fd, int ret, int saved_errno, const void *caller) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        BOOL can_spoof = (ret >= 0 || (ret < 0 && (errno == ENOTSUP || errno == EOPNOTSUPP)));
        if (!can_spoof) {
            return ret;
        }
        int recorded = pt_lookup_fd_dpclass(fd);
        if (recorded > 0) {
            errno = saved_errno;
            return recorded;
        }
        if (ret == 0 || (ret < 0 && (errno == ENOTSUP || errno == EOPNOTSUPP))) {
            errno = saved_errno;
            return 3;
        }
    }
    return ret;
}

static int pt_handle_fcntl_set_dpclass(int fd, int dpclass, int ret, int saved_errno, const void *caller) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        if (dpclass >= 1 && dpclass <= 7) {
            if (ret == 0) {
                pt_record_fd_dpclass(fd, dpclass);
                return 0;
            }
            if (ret < 0 && (errno == ENOTSUP || errno == EOPNOTSUPP || errno == EINVAL)) {
                int call_errno = errno;
                struct stat st;
                if (fstat(fd, &st) == 0 && (S_ISREG(st.st_mode) || S_ISDIR(st.st_mode))) {
                    pt_record_fd_dpclass(fd, dpclass);
                    errno = saved_errno;
                    return 0;
                }
                errno = call_errno;
            }
        }
    }
    return ret;
}

__attribute__((visibility("hidden")))
int pt_fs_fcntl_with_caller(int fd, int cmd, uintptr_t arg, const void *caller) {
    switch (cmd) {
        case F_GETPROTECTIONCLASS: {
            int saved_errno = errno;
            int ret = fcntl(fd, cmd);
            return pt_handle_fcntl_get_dpclass(fd, ret, saved_errno, caller);
        }
        case F_SETPROTECTIONCLASS: {
            int saved_errno = errno;
            int dpclass = (int)arg;
            int ret = fcntl(fd, cmd, dpclass);
            return pt_handle_fcntl_set_dpclass(fd, dpclass, ret, saved_errno, caller);
        }
        case F_GETFD:
        case F_GETFL:
        case F_GETOWN:
        case F_FLUSH_DATA:
        case F_CHKCLEAN:
        case F_FULLFSYNC:
        case F_FREEZE_FS:
        case F_THAW_FS:
        case F_GETNOSIGPIPE:
        case F_GETPROTECTIONLEVEL:
        case F_BARRIERFSYNC:
#ifdef F_GETLEASE
        case F_GETLEASE:
#endif
            return fcntl(fd, cmd);

        case F_DUPFD:
        case F_DUPFD_CLOEXEC:
#ifdef F_DUPFD_CLOFORK
        case F_DUPFD_CLOFORK:
#endif
        {
            int ret = fcntl(fd, cmd, (int)arg);
            if (ret >= 0) {
                pt_network_notify_fd_dup(fd, ret);
            }
            return ret;
        }
        case F_SETFD:
        case F_SETFL:
        case F_SETOWN:
        case F_RDAHEAD:
        case F_NOCACHE:
        case F_GLOBAL_NOCACHE:
        case F_NODIRECT:
        case F_SETBACKINGSTORE:
        case F_SETNOSIGPIPE:
        case F_SINGLE_WRITER:
#ifdef F_SETLEASE
        case F_SETLEASE:
#endif
#ifdef F_NOCACHE_EXT
        case F_NOCACHE_EXT:
#endif
            return fcntl(fd, cmd, (int)arg);

        case F_SETSIZE:
            return fcntl(fd, cmd, (off_t)arg);

        default: {
            void *parg = (void *)arg;
            int ret = fcntl(fd, cmd, parg);
            return pt_handle_fcntl_getpath(ret, cmd, parg, caller);
        }
    }
}

static int pt_fcntl(int fd, int cmd, ...) {
    switch (cmd) {
        case F_GETPROTECTIONCLASS: {
            int saved_errno = errno;
            int ret = fcntl(fd, cmd);
            return pt_handle_fcntl_get_dpclass(fd, ret, saved_errno, __builtin_return_address(0));
        }
        case F_SETPROTECTIONCLASS: {
            int saved_errno = errno;
            va_list ap;
            va_start(ap, cmd);
            int dpclass = va_arg(ap, int);
            va_end(ap);
            int ret = fcntl(fd, cmd, dpclass);
            return pt_handle_fcntl_set_dpclass(fd, dpclass, ret, saved_errno, __builtin_return_address(0));
        }
        case F_GETFD:
        case F_GETFL:
        case F_GETOWN:
        case F_FLUSH_DATA:
        case F_CHKCLEAN:
        case F_FULLFSYNC:
        case F_FREEZE_FS:
        case F_THAW_FS:
        case F_GETNOSIGPIPE:
        case F_GETPROTECTIONLEVEL:
        case F_BARRIERFSYNC:
#ifdef F_GETLEASE
        case F_GETLEASE:
#endif
            return fcntl(fd, cmd);

        case F_DUPFD:
        case F_DUPFD_CLOEXEC:
#ifdef F_DUPFD_CLOFORK
        case F_DUPFD_CLOFORK:
#endif
        {
            va_list ap;
            va_start(ap, cmd);
            int iarg = va_arg(ap, int);
            va_end(ap);
            int ret = fcntl(fd, cmd, iarg);
            if (ret >= 0) {
                pt_network_notify_fd_dup(fd, ret);
            }
            return ret;
        }
        case F_SETFD:
        case F_SETFL:
        case F_SETOWN:
        case F_RDAHEAD:
        case F_NOCACHE:
        case F_GLOBAL_NOCACHE:
        case F_NODIRECT:
        case F_SETBACKINGSTORE:
        case F_SETNOSIGPIPE:
        case F_SINGLE_WRITER:
#ifdef F_SETLEASE
        case F_SETLEASE:
#endif
#ifdef F_NOCACHE_EXT
        case F_NOCACHE_EXT:
#endif
        {
            va_list ap;
            va_start(ap, cmd);
            int iarg = va_arg(ap, int);
            va_end(ap);
            return fcntl(fd, cmd, iarg);
        }

        case F_SETSIZE:
        {
            va_list ap;
            va_start(ap, cmd);
            off_t oarg = va_arg(ap, off_t);
            va_end(ap);
            return fcntl(fd, cmd, oarg);
        }

        default:
        {
            va_list ap;
            va_start(ap, cmd);
            void *parg = va_arg(ap, void *);
            va_end(ap);
            int ret = fcntl(fd, cmd, parg);
            return pt_handle_fcntl_getpath(ret, cmd, parg, __builtin_return_address(0));
        }
    }
}

extern int pt_orig_fcntl_nocancel(int, int, ...) __asm("_fcntl$NOCANCEL");

static int pt_fcntl_nocancel(int fd, int cmd, ...) {
    switch (cmd) {
        case F_GETPROTECTIONCLASS: {
            int saved_errno = errno;
            int ret = pt_orig_fcntl_nocancel(fd, cmd);
            return pt_handle_fcntl_get_dpclass(fd, ret, saved_errno, __builtin_return_address(0));
        }
        case F_SETPROTECTIONCLASS: {
            int saved_errno = errno;
            va_list ap;
            va_start(ap, cmd);
            int dpclass = va_arg(ap, int);
            va_end(ap);
            int ret = pt_orig_fcntl_nocancel(fd, cmd, dpclass);
            return pt_handle_fcntl_set_dpclass(fd, dpclass, ret, saved_errno, __builtin_return_address(0));
        }
        case F_GETFD:
        case F_GETFL:
        case F_GETOWN:
        case F_FLUSH_DATA:
        case F_CHKCLEAN:
        case F_FULLFSYNC:
        case F_FREEZE_FS:
        case F_THAW_FS:
        case F_GETNOSIGPIPE:
        case F_GETPROTECTIONLEVEL:
        case F_BARRIERFSYNC:
#ifdef F_GETLEASE
        case F_GETLEASE:
#endif
            return pt_orig_fcntl_nocancel(fd, cmd);

        case F_DUPFD:
        case F_DUPFD_CLOEXEC:
#ifdef F_DUPFD_CLOFORK
        case F_DUPFD_CLOFORK:
#endif
        {
            va_list ap;
            va_start(ap, cmd);
            int iarg = va_arg(ap, int);
            va_end(ap);
            int ret = pt_orig_fcntl_nocancel(fd, cmd, iarg);
            if (ret >= 0) {
                pt_network_notify_fd_dup(fd, ret);
            }
            return ret;
        }
        case F_SETFD:
        case F_SETFL:
        case F_SETOWN:
        case F_RDAHEAD:
        case F_NOCACHE:
        case F_GLOBAL_NOCACHE:
        case F_NODIRECT:
        case F_SETBACKINGSTORE:
        case F_SETNOSIGPIPE:
        case F_SINGLE_WRITER:
#ifdef F_SETLEASE
        case F_SETLEASE:
#endif
#ifdef F_NOCACHE_EXT
        case F_NOCACHE_EXT:
#endif
        {
            va_list ap;
            va_start(ap, cmd);
            int iarg = va_arg(ap, int);
            va_end(ap);
            return pt_orig_fcntl_nocancel(fd, cmd, iarg);
        }

        case F_SETSIZE:
        {
            va_list ap;
            va_start(ap, cmd);
            off_t oarg = va_arg(ap, off_t);
            va_end(ap);
            return pt_orig_fcntl_nocancel(fd, cmd, oarg);
        }

        default:
        {
            va_list ap;
            va_start(ap, cmd);
            void *parg = va_arg(ap, void *);
            va_end(ap);
            int ret = pt_orig_fcntl_nocancel(fd, cmd, parg);
            return pt_handle_fcntl_getpath(ret, cmd, parg, __builtin_return_address(0));
        }
    }
}

static int pt_proc_pidpath(int pid, void *buffer, uint32_t buffersize) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pid != 0 && pid != getpid()) {
        errno = ESRCH;
        return 0;
    }
    int ret = proc_pidpath(pid, buffer, buffersize);
    if (ret > 0 && buffer != NULL && buffersize > 1 && !is_sys) {
        char *pathbuf = (char *)buffer;
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(pathbuf, vout, sizeof(vout), YES);
        const char *effective = (virt != NULL) ? virt : pathbuf;
        if (pt_is_sensitive_host_fd_path(effective, caller)) {
            PT_DEBUG_TRACE("fs", "hid proc_pidpath pid=%d path=%s", pid, pathbuf);
            pathbuf[0] = '\0';
            errno = ESRCH;
            return 0;
        }
        if (virt != NULL && virt != pathbuf) {
            PT_DEBUG_TRACE("fs", "virtualized proc_pidpath %s -> %s", pathbuf, virt);
            size_t n = strlcpy(pathbuf, virt, (size_t)buffersize);
            if (n < (size_t)buffersize) {
                return (int)n;
            }
            errno = ENOMEM;
            return 0;
        }
    }
    return ret;
}

PT_INTERPOSE(pt_open, open)
PT_INTERPOSE_NAMED(pt_open_nocancel, pt_orig_open_nocancel, "open$NOCANCEL")
PT_INTERPOSE(pt_openat, openat)
PT_INTERPOSE_NAMED(pt_openat_nocancel, pt_orig_openat_nocancel, "openat$NOCANCEL")
PT_INTERPOSE(pt_creat, creat)
PT_INTERPOSE_NAMED(pt_creat_nocancel, pt_orig_creat_nocancel, "creat$NOCANCEL")
PT_INTERPOSE(pt_open_dprotected_np, open_dprotected_np)
PT_INTERPOSE(pt_openat_dprotected_np, openat_dprotected_np)
PT_INTERPOSE(pt_guarded_open_np, guarded_open_np)
PT_INTERPOSE(pt_guarded_open_dprotected_np, guarded_open_dprotected_np)
PT_INTERPOSE(pt_fopen, fopen)
PT_INTERPOSE_NAMED(pt_fopen_darwin_extsn, pt_orig_fopen_darwin_extsn, "fopen$DARWIN_EXTSN")
PT_INTERPOSE(pt_freopen, freopen)
PT_INTERPOSE(pt_stat, stat)
PT_INTERPOSE(pt_lstat, lstat)
PT_INTERPOSE(pt_fstatat, fstatat)
PT_INTERPOSE(pt_statx_np, statx_np)
PT_INTERPOSE(pt_lstatx_np, lstatx_np)
PT_INTERPOSE(pt_access, access)
PT_INTERPOSE(pt_faccessat, faccessat)
PT_INTERPOSE(pt_readlink, readlink)
PT_INTERPOSE(pt_readlinkat, readlinkat)
PT_INTERPOSE(pt_realpath, realpath)
PT_DLSYM_ONLY("realpath$DARWIN_EXTSN", pt_realpath)
PT_INTERPOSE_ONLY(pt_realpath_legacy, pt_orig_realpath_legacy)
PT_INTERPOSE(pt_getcwd, getcwd)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
PT_INTERPOSE(pt_getwd, getwd)
#pragma clang diagnostic pop
PT_INTERPOSE(pt_chdir, chdir)
PT_INTERPOSE(pt_fchdir, fchdir)
PT_INTERPOSE(pt_fcntl, fcntl)
PT_INTERPOSE_NAMED(pt_fcntl_nocancel, pt_orig_fcntl_nocancel, "fcntl$NOCANCEL")
PT_INTERPOSE(pt_proc_pidpath, proc_pidpath)
PT_INTERPOSE(pt_fstat, fstat)
PT_INTERPOSE(pt_fstatx_np, fstatx_np)
PT_INTERPOSE(pt_accessx_np, accessx_np)
PT_INTERPOSE_WEAK_NAMED(pt_stat64, pt_orig_stat64, "stat64")
PT_INTERPOSE_WEAK_NAMED(pt_lstat64, pt_orig_lstat64, "lstat64")
PT_INTERPOSE_WEAK_NAMED(pt_fstat64, pt_orig_fstat64, "fstat64")
PT_INTERPOSE_WEAK_NAMED(pt_fstatat64, pt_orig_fstatat64, "fstatat64")
PT_INTERPOSE_WEAK_NAMED(pt_openbyid_np, pt_orig_openbyid_np, "openbyid_np")
PT_INTERPOSE_WEAK_NAMED(pt_openat_authenticated_np, pt_orig_openat_authenticated_np, "openat_authenticated_np")
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_freadlink, pt_orig_freadlink, "freadlink", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
