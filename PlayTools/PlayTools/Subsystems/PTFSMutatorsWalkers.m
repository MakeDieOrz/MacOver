//
//  PTFSMutatorsWalkers.m
//  PlayTools
//

#import "PTFSInternal.h"
#import "PTSystemSpooferInternal.h"
#include <copyfile.h>
#include <fts.h>
#include <ftw.h>
#include <glob.h>
#include <removefile.h>
#include <spawn.h>
#include <sqlite3.h>
#include <sys/clonefile.h>
#include <sys/xattr.h>


static int pt_statfs(const char *path, struct statfs *buf) {
    return pt_fs_statfs_with_caller(path, buf, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_fstatfs_with_caller(int fd, struct statfs *buf, const void *caller) {
    if (pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    int is_sys_caller = -1;
    int ret = fstatfs(fd, buf);
    if (ret == 0 && buf != NULL) {
        pt_sanitize_statfs_entry(buf, caller, &is_sys_caller);
    }
    return ret;
}

static int pt_fstatfs(int fd, struct statfs *buf) {
    return pt_fs_fstatfs_with_caller(fd, buf, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_prepare_statfs_path_with_caller(const char *path,
                                          const void *caller,
                                          char *vbuf,
                                          size_t vbuf_size,
                                          const char **out_resolved) {
    int is_sys_caller = -1;
    const char *resolved = path;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(path, caller, vbuf, vbuf_size, &resolved, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        pt_ensure_data_container_map();
        resolved = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    }
    if (out_resolved != NULL) {
        *out_resolved = resolved;
    }
    return 0;
}

__attribute__((visibility("hidden")))
BOOL pt_fs_legacy_statfs_entry_is_hidden(const char *mnton, const char *mntfrom, const void *caller) {
    (void)mntfrom;
    if (mnton == NULL || !pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return NO;
    }
    return (strcmp(mnton, "/") != 0 &&
            strcmp(mnton, "/System/Volumes/Data") != 0 &&
            strcmp(mnton, "/private/var") != 0 &&
            strcmp(mnton, "/private/var/mobile") != 0);
}

__attribute__((visibility("hidden")))
void pt_fs_sanitize_legacy_statfs_strings(char *mnton,
                                          size_t mnton_cap,
                                          char *mntfrom,
                                          size_t mntfrom_cap,
                                          const void *caller) {
    if (mnton == NULL || mntfrom == NULL || mnton_cap == 0 || mntfrom_cap == 0 ||
        !pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return;
    }
    mnton[mnton_cap - 1U] = '\0';
    mntfrom[mntfrom_cap - 1U] = '\0';
    if (strcmp(mnton, "/System/Volumes/Data") == 0 ||
        strncmp(mnton, "/Volumes/", 9) == 0 ||
        strncmp(mnton, "/Users/", 7) == 0 ||
        strncmp(mnton, "/System/Volumes/Data/Users/", 27) == 0) {
        strlcpy(mnton, "/private/var", mnton_cap);
        strlcpy(mntfrom, "/dev/disk0s1s2", mntfrom_cap);
    } else if (strncmp(mnton, "/System/Volumes/Data/", 21) == 0) {
        char stripped[MFSTYPENAMELEN + MAXPATHLEN];
        strlcpy(stripped, mnton + 20, sizeof(stripped));
        strlcpy(mnton, stripped, mnton_cap);
    }
    if (strcmp(mnton, "/") == 0) {
        strlcpy(mntfrom, "/dev/disk0s1s1", mntfrom_cap);
    } else if (strcmp(mnton, "/private/var") == 0) {
        strlcpy(mntfrom, "/dev/disk0s1s2", mntfrom_cap);
    }
}

__attribute__((visibility("hidden")))
int pt_fs_getfsstat_with_caller(struct statfs *buf, int bufsize, int mode, const void *caller) {
    if ((buf == NULL || bufsize == 0) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        int raw_cnt = getfsstat(NULL, 0, mode);
        if (raw_cnt <= 0) {
            return raw_cnt;
        }
        int cap = (raw_cnt < 512) ? raw_cnt : 512;
        struct statfs *tmp = (struct statfs *)calloc((size_t)cap, sizeof(struct statfs));
        if (tmp != NULL) {
            int got = getfsstat(tmp, (int)((size_t)cap * sizeof(struct statfs)), mode);
            int kept = (got > 0) ? pt_filter_statfs_array(tmp, got, caller) : got;
            free(tmp);
            return kept;
        }
        return raw_cnt;
    }
    int count = getfsstat(buf, bufsize, mode);
    if (count > 0 && buf != NULL && bufsize > 0) {
        return pt_filter_statfs_array(buf, count, caller);
    }
    return count;
}

static int pt_getfsstat(struct statfs *buf, int bufsize, int mode) {
    return pt_fs_getfsstat_with_caller(buf, bufsize, mode, __builtin_return_address(0));
}

static int pt_getmntinfo(struct statfs **mntbufp, int mode) {
    const void *caller = __builtin_return_address(0);
    int count = getmntinfo(mntbufp, mode);
    if (count > 0 && mntbufp != NULL && *mntbufp != NULL) {
        return pt_filter_statfs_array(*mntbufp, count, caller);
    }
    return count;
}

static int pt_getmntinfo_r_np(struct statfs **mntbufp, int mode) {
    const void *caller = __builtin_return_address(0);
    int count = getmntinfo_r_np(mntbufp, mode);
    if (count > 0 && mntbufp != NULL && *mntbufp != NULL) {
        return pt_filter_statfs_array(*mntbufp, count, caller);
    }
    return count;
}

static void pt_align_statvfs_with_statfs(struct statvfs *vbuf, const struct statfs *sbuf) {
    if (vbuf == NULL || sbuf == NULL) {
        return;
    }
    vbuf->f_bsize = (unsigned long)sbuf->f_iosize;
    vbuf->f_frsize = (unsigned long)sbuf->f_bsize;
    vbuf->f_blocks = (fsblkcnt_t)sbuf->f_blocks;
    vbuf->f_bfree = (fsblkcnt_t)sbuf->f_bfree;
    vbuf->f_bavail = (fsblkcnt_t)sbuf->f_bavail;
    vbuf->f_files = (fsfilcnt_t)sbuf->f_files;
    vbuf->f_ffree = (fsfilcnt_t)sbuf->f_ffree;
    vbuf->f_favail = (fsfilcnt_t)sbuf->f_ffree;
    unsigned long flags = 0;
    if ((sbuf->f_flags & MNT_RDONLY) != 0) {
        flags |= ST_RDONLY;
    }
    if ((sbuf->f_flags & MNT_NOSUID) != 0) {
        flags |= ST_NOSUID;
    }
    vbuf->f_flag = flags;
}

static int pt_statvfs(const char * restrict path, struct statvfs * restrict buf) {
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(path, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        pt_ensure_data_container_map();
        resolved = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    }
    int ret = statvfs(resolved, buf);
    if (ret == 0 && buf != NULL && pt_is_bypass_enabled()) {
        if (is_sys_caller < 0) {
            is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
        }
        if (is_sys_caller == 0) {
            struct statfs sf;
            if (statfs(resolved, &sf) == 0) {
                pt_sanitize_statfs_entry(&sf, caller, &is_sys_caller);
                pt_align_statvfs_with_statfs(buf, &sf);
            }
        }
    }
    return ret;
}

static int pt_fstatvfs(int fd, struct statvfs *buf) {
    const void *caller = __builtin_return_address(0);
    if (pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    int ret = fstatvfs(fd, buf);
    if (ret == 0 && buf != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        struct statfs sf;
        if (fstatfs(fd, &sf) == 0) {
            int is_sys = 0;
            pt_sanitize_statfs_entry(&sf, caller, &is_sys);
            pt_align_statvfs_with_statfs(buf, &sf);
        }
    }
    return ret;
}


static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const char *resolved_old = NULL;
    const char *resolved_new = NULL;
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, old_name, caller, vbuf1, sizeof(vbuf1), &resolved_old, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, new_name, caller, vbuf2, sizeof(vbuf2), &resolved_new, EACCES)) {
        return -1;
    }
    return rename(resolved_old, resolved_new);
}

static int pt_renameat(int fromfd, const char *from, int tofd, const char *to) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(fromfd, from, caller, vbuf1, sizeof(vbuf1), &from, EACCES) ||
        !pt_prepare_fs_path_for_modify(tofd, to, caller, vbuf2, sizeof(vbuf2), &to, EACCES)) {
        return -1;
    }
    return renameat(fromfd, from, tofd, to);
}

static int pt_renamex_np(const char *from, const char *to, unsigned int flags) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, from, caller, vbuf1, sizeof(vbuf1), &from, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, to, caller, vbuf2, sizeof(vbuf2), &to, EACCES)) {
        return -1;
    }
    return renamex_np(from, to, flags);
}

static int pt_renameatx_np(int fromfd, const char *from, int tofd, const char *to, unsigned int flags) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(fromfd, from, caller, vbuf1, sizeof(vbuf1), &from, EACCES) ||
        !pt_prepare_fs_path_for_modify(tofd, to, caller, vbuf2, sizeof(vbuf2), &to, EACCES)) {
        return -1;
    }
    return renameatx_np(fromfd, from, tofd, to, flags);
}

static int pt_unlink(char const* path) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return unlink(path);
}

static int pt_unlinkat(int fd, const char *path, int flag) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return unlinkat(fd, path, flag);
}

static int pt_remove(const char *path) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return remove(path);
}

static int pt_removefile(const char *path, removefile_state_t state, removefile_flags_t flags) {
    char vbuf[PATH_MAX];
    if (path != NULL &&
        !pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return removefile(path, state, flags);
}

static int pt_link(const char *path1, const char *path2) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path1, caller, vbuf1, sizeof(vbuf1), &path1, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, path2, caller, vbuf2, sizeof(vbuf2), &path2, EACCES)) {
        return -1;
    }
    return link(path1, path2);
}

static int pt_linkat(int fd1, const char *path1, int fd2, const char *path2, int flag) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(fd1, path1, caller, vbuf1, sizeof(vbuf1), &path1, EACCES) ||
        !pt_prepare_fs_path_for_modify(fd2, path2, caller, vbuf2, sizeof(vbuf2), &path2, EACCES)) {
        return -1;
    }
    return linkat(fd1, path1, fd2, path2, flag);
}

static int pt_symlink(const char *path1, const char *path2) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path1, caller, vbuf1, sizeof(vbuf1), &path1, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, path2, caller, vbuf2, sizeof(vbuf2), &path2, EACCES)) {
        return -1;
    }
    return symlink(path1, path2);
}

static int pt_symlinkat(const char *path1, int fd, const char *path2) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path1, caller, vbuf1, sizeof(vbuf1), &path1, EACCES) ||
        !pt_prepare_fs_path_for_modify(fd, path2, caller, vbuf2, sizeof(vbuf2), &path2, EACCES)) {
        return -1;
    }
    return symlinkat(path1, fd, path2);
}

static int pt_chmod(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return chmod(path, mode);
}

static int pt_lchmod(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return lchmod(path, mode);
}

static int pt_fchmodat(int fd, const char *path, mode_t mode, int flag) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return fchmodat(fd, path, mode, flag);
}

static int pt_chown(const char *path, uid_t owner, gid_t group) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return chown(path, owner, group);
}

static int pt_lchown(const char *path, uid_t owner, gid_t group) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return lchown(path, owner, group);
}

static int pt_fchownat(int fd, const char *path, uid_t owner, gid_t group, int flag) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return fchownat(fd, path, owner, group, flag);
}

static int pt_chflags(const char *path, __uint32_t flags) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return chflags(path, flags);
}

static int pt_lchflags(const char *path, __uint32_t flags) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return lchflags(path, flags);
}

static int pt_truncate(const char *path, off_t length) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return truncate(path, length);
}

static int pt_utimes(const char *path, const struct timeval *times) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return utimes(path, times);
}

static int pt_lutimes(const char *path, const struct timeval *times) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return lutimes(path, times);
}

static int pt_utimensat(int fd, const char *path, const struct timespec times[2], int flag) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return utimensat(fd, path, times, flag);
}

static int pt_utime(const char *path, const struct utimbuf *times) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return utime(path, times);
}

static BOOL pt_is_hidden_traversed_entry(const char *path,
                                         const char *d_name_hint,
                                         const void *caller,
                                         int *inout_is_sys_caller) {
    if (path == NULL || path[0] == '\0' || !pt_is_bypass_enabled()) {
        return NO;
    }
    if (*inout_is_sys_caller < 0) {
        *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    if (*inout_is_sys_caller != 0) {
        return NO;
    }

    char lex_buf[PATH_MAX];
    const char *norm = path;
    if (norm[0] == '/' && pt_needs_lexical_norm(norm)) {
        const char *collapsed = pt_normalize_lexical_path(norm, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            norm = collapsed;
        }
    }
    if (pt_is_hidden_normalized_path_cached_caller(norm, caller, inout_is_sys_caller)) {
        return YES;
    }

    const char *base = d_name_hint;
    if (base == NULL || base[0] == '\0') {
        const char *slash = strrchr(norm, '/');
        base = (slash != NULL) ? (slash + 1) : norm;
    }
    if (pt_is_hidden_dirent_name(base)) {
        return YES;
    }
    if (pt_is_macos_data_root_symlink_name(base) && norm[0] == '/') {
        const char *slash = strrchr(norm, '/');
        if (slash != NULL) {
            BOOL is_data_root = NO;
            size_t parent_len = (size_t)(slash - norm);
            if (parent_len == 0) {
                is_data_root = pt_path_equals_real_data_root("/");
            } else if (parent_len < PATH_MAX) {
                char parent[PATH_MAX];
                memcpy(parent, norm, parent_len);
                parent[parent_len] = '\0';
                is_data_root = pt_path_equals_real_data_root(parent);
            }
            if (is_data_root) {
                if (strcmp(base, "Desktop") == 0) {
                    return YES;
                }
                struct stat st;
                if (lstat(norm, &st) == 0 && S_ISLNK(st.st_mode)) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

typedef struct pt_ftw_tls_ctx {
    int (*ftw_fn)(const char *, const struct stat *, int);
    int (*nftw_fn)(const char *, const struct stat *, int, struct FTW *);
    const void *caller;
    int is_sys_caller;
    struct pt_ftw_tls_ctx *prev;
} pt_ftw_tls_ctx_t;

static _Thread_local pt_ftw_tls_ctx_t *tls_pt_ftw_ctx = NULL;

static int pt_ftw_trampoline(const char *fpath, const struct stat *sb, int typeflag) {
    pt_ftw_tls_ctx_t *ctx = tls_pt_ftw_ctx;
    if (ctx == NULL || ctx->ftw_fn == NULL) {
        return 0;
    }
    if (fpath != NULL && pt_is_hidden_traversed_entry(fpath, NULL, ctx->caller, &ctx->is_sys_caller)) {
        return 0;
    }
    char vout[PATH_MAX];
    const char *virt = fpath;
    if (fpath != NULL && ctx->is_sys_caller == 0) {
        virt = pt_virtualize_path_for_app(fpath, vout, sizeof(vout), YES);
    }
    return ctx->ftw_fn(virt, sb, typeflag);
}

static int pt_nftw_trampoline(const char *fpath, const struct stat *sb, int typeflag, struct FTW *ftwbuf) {
    pt_ftw_tls_ctx_t *ctx = tls_pt_ftw_ctx;
    if (ctx == NULL || ctx->nftw_fn == NULL) {
        return 0;
    }
    if (fpath != NULL && pt_is_hidden_traversed_entry(fpath, NULL, ctx->caller, &ctx->is_sys_caller)) {
        return 0;
    }
    char vout[PATH_MAX];
    const char *virt = fpath;
    struct FTW ftw_local;
    struct FTW *out_ftwbuf = ftwbuf;
    if (fpath != NULL && ctx->is_sys_caller == 0) {
        virt = pt_virtualize_path_for_app(fpath, vout, sizeof(vout), YES);
        if (virt != fpath && ftwbuf != NULL) {
            ftw_local = *ftwbuf;
            const char *slash = strrchr(virt, '/');
            ftw_local.base = (slash != NULL) ? (int)(slash - virt + 1) : 0;
            out_ftwbuf = &ftw_local;
        }
    }
    return ctx->nftw_fn(virt, sb, typeflag, out_ftwbuf);
}

static int pt_ftw(const char *dirpath, int (*fn)(const char *, const struct stat *, int), int nopenfd) {
    char vbuf[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(dirpath, caller, vbuf, sizeof(vbuf), &dirpath, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (fn == NULL || !pt_is_bypass_enabled() || is_sys_caller == 1 ||
        (is_sys_caller < 0 && pt_is_effective_system_or_playtools_caller(caller))) {
        return ftw(dirpath, fn, nopenfd);
    }
    pt_ftw_tls_ctx_t ctx = {
        .ftw_fn = fn,
        .nftw_fn = NULL,
        .caller = caller,
        .is_sys_caller = 0,
        .prev = tls_pt_ftw_ctx,
    };
    tls_pt_ftw_ctx = &ctx;
    int ret = ftw(dirpath, pt_ftw_trampoline, nopenfd);
    tls_pt_ftw_ctx = ctx.prev;
    return ret;
}

static int pt_nftw(const char *dirpath, int (*fn)(const char *, const struct stat *, int, struct FTW *), int nopenfd, int flags) {
    char vbuf[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(dirpath, caller, vbuf, sizeof(vbuf), &dirpath, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (fn == NULL || !pt_is_bypass_enabled() || is_sys_caller == 1 ||
        (is_sys_caller < 0 && pt_is_effective_system_or_playtools_caller(caller))) {
        return nftw(dirpath, fn, nopenfd, flags);
    }
    pt_ftw_tls_ctx_t ctx = {
        .ftw_fn = NULL,
        .nftw_fn = fn,
        .caller = caller,
        .is_sys_caller = 0,
        .prev = tls_pt_ftw_ctx,
    };
    tls_pt_ftw_ctx = &ctx;
    int ret = nftw(dirpath, pt_nftw_trampoline, nopenfd, flags);
    tls_pt_ftw_ctx = ctx.prev;
    return ret;
}

typedef struct pt_fts_child_record {
    FTSENT *ent;
    char *orig_path;
    char *orig_accpath;
    char *virt_path;
    char *virt_accpath;
    FTSENT *orig_link;
    BOOL link_overridden;
    __typeof__(((FTSENT *)0)->fts_pathlen) orig_pathlen;
    struct pt_fts_child_record *next;
} pt_fts_child_record_t;

typedef struct {
    const void *caller;
    int is_sys_caller;
    BOOL use_private_prefix;
    FTSENT *cur_ent;
    char *orig_cur_path;
    char *orig_cur_accpath;
    __typeof__(((FTSENT *)0)->fts_pathlen) orig_cur_pathlen;
    pt_fts_child_record_t *children;
    char cur_virt_path[PATH_MAX];
} pt_fts_state_t;

static os_unfair_lock s_fts_states_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_fts_states = NULL;

static pt_fts_state_t *pt_fts_lookup_state(FTS *ftsp) {
    if (ftsp == NULL) {
        return NULL;
    }
    pt_fts_state_t *state = NULL;
    os_unfair_lock_lock(&s_fts_states_lock);
    if (s_fts_states != NULL) {
        state = (pt_fts_state_t *)CFDictionaryGetValue(s_fts_states, ftsp);
    }
    os_unfair_lock_unlock(&s_fts_states_lock);
    return state;
}

static void pt_fts_restore_cur(pt_fts_state_t *state) {
    if (state == NULL || state->cur_ent == NULL) {
        return;
    }
    state->cur_ent->fts_path = state->orig_cur_path;
    state->cur_ent->fts_accpath = state->orig_cur_accpath;
    state->cur_ent->fts_pathlen = state->orig_cur_pathlen;
    state->cur_ent = NULL;
    state->orig_cur_path = NULL;
    state->orig_cur_accpath = NULL;
    state->orig_cur_pathlen = 0;
}

static void pt_fts_restore_children(pt_fts_state_t *state) {
    if (state == NULL) {
        return;
    }
    pt_fts_child_record_t *rec = state->children;
    state->children = NULL;
    while (rec != NULL) {
        pt_fts_child_record_t *next = rec->next;
        if (rec->ent != NULL) {
            rec->ent->fts_path = rec->orig_path;
            rec->ent->fts_accpath = rec->orig_accpath;
            rec->ent->fts_pathlen = rec->orig_pathlen;
            if (rec->link_overridden) {
                rec->ent->fts_link = rec->orig_link;
            }
        }
        free(rec->virt_path);
        free(rec->virt_accpath);
        free(rec);
        rec = next;
    }
}

static FTS *pt_fts_open_common(char * const *path_argv,
                               int options,
                               int (*compar)(const FTSENT **, const FTSENT **),
#ifdef __BLOCKS__
                               int (^compar_b)(const FTSENT **, const FTSENT **),
                               BOOL use_block,
#endif
                               const void *caller) {
    if (path_argv == NULL || path_argv[0] == NULL || !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
#ifdef __BLOCKS__
        if (use_block) {
            return fts_open_b(path_argv, options, compar_b);
        }
#endif
        return fts_open(path_argv, options, compar);
    }

    size_t argc = 0;
    while (path_argv[argc] != NULL) {
        argc++;
    }
    char **mapped_argv = (char **)calloc(argc + 1U, sizeof(char *));
    char **owned_strs = (char **)calloc(argc + 1U, sizeof(char *));
    if (mapped_argv == NULL || owned_strs == NULL) {
        free(mapped_argv);
        free(owned_strs);
        errno = ENOMEM;
        return NULL;
    }

    size_t out_idx = 0;
    size_t owned_idx = 0;
    int sys_caller = 0;
    for (size_t i = 0; i < argc; i++) {
        char vbuf[PATH_MAX];
        const char *resolved = NULL;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(path_argv[i], caller, vbuf, sizeof(vbuf), &resolved, &sys_caller);
        if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
            continue;
        }
        char *dup = strdup(resolved != NULL ? resolved : path_argv[i]);
        if (dup == NULL) {
            for (size_t j = 0; j < owned_idx; j++) {
                free(owned_strs[j]);
            }
            free(owned_strs);
            free(mapped_argv);
            errno = ENOMEM;
            return NULL;
        }
        owned_strs[owned_idx++] = dup;
        mapped_argv[out_idx++] = dup;
    }

    if (out_idx == 0) {
        for (size_t j = 0; j < owned_idx; j++) {
            free(owned_strs[j]);
        }
        free(owned_strs);
        free(mapped_argv);
        errno = ENOENT;
        return NULL;
    }

#ifdef __BLOCKS__
    FTS *ftsp = use_block ? fts_open_b(mapped_argv, options, compar_b) : fts_open(mapped_argv, options, compar);
#else
    FTS *ftsp = fts_open(mapped_argv, options, compar);
#endif
    int saved_errno = errno;
    for (size_t j = 0; j < owned_idx; j++) {
        free(owned_strs[j]);
    }
    free(owned_strs);
    free(mapped_argv);

    if (ftsp != NULL) {
        pt_fts_state_t *state = (pt_fts_state_t *)calloc(1U, sizeof(pt_fts_state_t));
        if (state != NULL) {
            state->caller = caller;
            state->is_sys_caller = 0;
            state->use_private_prefix = (strncmp(path_argv[0], "/private/", 9) == 0);
            os_unfair_lock_lock(&s_fts_states_lock);
            if (s_fts_states == NULL) {
                s_fts_states = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
            }
            if (s_fts_states != NULL) {
                CFDictionarySetValue(s_fts_states, ftsp, state);
            } else {
                free(state);
            }
            os_unfair_lock_unlock(&s_fts_states_lock);
        }
    }
    errno = saved_errno;
    return ftsp;
}

static FTS *pt_fts_open(char * const *path_argv, int options, int (*compar)(const FTSENT **, const FTSENT **)) {
    return pt_fts_open_common(path_argv, options, compar,
#ifdef __BLOCKS__
                              NULL, NO,
#endif
                              __builtin_return_address(0));
}

#ifdef __BLOCKS__
static FTS *pt_fts_open_b(char * const *path_argv, int options, int (^compar)(const FTSENT **, const FTSENT **)) {
    return pt_fts_open_common(path_argv, options, NULL, compar, YES, __builtin_return_address(0));
}
#endif

static FTSENT *pt_fts_read(FTS *ftsp) {
    pt_fts_state_t *state = pt_fts_lookup_state(ftsp);
    if (state != NULL) {
        pt_fts_restore_cur(state);
        pt_fts_restore_children(state);
    }
    if (ftsp == NULL || state == NULL || !pt_is_bypass_enabled()) {
        return fts_read(ftsp);
    }

    for (;;) {
        FTSENT *ent = fts_read(ftsp);
        if (ent == NULL) {
            return NULL;
        }
        if (ent->fts_path != NULL &&
            pt_is_hidden_traversed_entry(ent->fts_path, ent->fts_name, state->caller, &state->is_sys_caller)) {
            if (ent->fts_info == FTS_D) {
                fts_set(ftsp, ent, FTS_SKIP);
            }
            continue;
        }
        if (ent->fts_path != NULL && state->is_sys_caller == 0) {
            const char *virt = pt_virtualize_path_for_app(ent->fts_path, state->cur_virt_path, sizeof(state->cur_virt_path), state->use_private_prefix);
            if (virt != ent->fts_path) {
                state->cur_ent = ent;
                state->orig_cur_path = ent->fts_path;
                state->orig_cur_accpath = ent->fts_accpath;
                state->orig_cur_pathlen = ent->fts_pathlen;
                ent->fts_path = state->cur_virt_path;
                size_t vlen = strlen(state->cur_virt_path);
                size_t max_plen = (sizeof(ent->fts_pathlen) == sizeof(unsigned short)) ? (size_t)USHRT_MAX : SIZE_MAX;
                ent->fts_pathlen = (__typeof__(ent->fts_pathlen))MIN(vlen, max_plen);
                if (ent->fts_accpath != NULL && ent->fts_accpath[0] == '/') {
                    ent->fts_accpath = state->cur_virt_path;
                }
            }
        }
        return ent;
    }
}

static const char *pt_fts_build_child_fullpath(const FTSENT *c, char *buf, size_t bufsize) {
    if (c == NULL || buf == NULL || bufsize == 0) {
        return NULL;
    }
    if (c->fts_path != NULL && c->fts_path[0] != '\0') {
        size_t plen = strlen(c->fts_path);
        int n = (plen > 0 && c->fts_path[plen - 1] == '/')
            ? snprintf(buf, bufsize, "%s%s", c->fts_path, c->fts_name)
            : snprintf(buf, bufsize, "%s/%s", c->fts_path, c->fts_name);
        return (n > 0 && (size_t)n < bufsize) ? buf : NULL;
    }
    if (c->fts_accpath != NULL && c->fts_accpath[0] != '\0') {
        return c->fts_accpath;
    }
    return c->fts_name;
}

static FTSENT *pt_fts_children(FTS *ftsp, int instr) {
    pt_fts_state_t *state = pt_fts_lookup_state(ftsp);
    if (state != NULL) {
        pt_fts_restore_cur(state);
        pt_fts_restore_children(state);
    }
    FTSENT *head = fts_children(ftsp, instr);
    if (head == NULL || state == NULL || !pt_is_bypass_enabled() || state->is_sys_caller == 1) {
        return head;
    }

    FTSENT *out_head = NULL;
    FTSENT *prev_visible = NULL;
    pt_fts_child_record_t *prev_visible_rec = NULL;
    pt_fts_child_record_t *rec_tail = NULL;

    for (FTSENT *curr = head; curr != NULL;) {
        FTSENT *next = curr->fts_link;
        pt_fts_child_record_t *rec = (pt_fts_child_record_t *)calloc(1U, sizeof(pt_fts_child_record_t));
        if (rec == NULL) {
            pt_fts_restore_children(state);
            return head;
        }
        rec->ent = curr;
        rec->orig_path = curr->fts_path;
        rec->orig_accpath = curr->fts_accpath;
        rec->orig_pathlen = curr->fts_pathlen;
        rec->orig_link = next;
        rec->link_overridden = NO;
        if (rec_tail == NULL) {
            state->children = rec;
        } else {
            rec_tail->next = rec;
        }
        rec_tail = rec;

        char fullbuf[PATH_MAX];
        const char *full = pt_fts_build_child_fullpath(curr, fullbuf, sizeof(fullbuf));
        BOOL hidden = (full != NULL &&
                       pt_is_hidden_traversed_entry(full, curr->fts_name, state->caller, &state->is_sys_caller));
        if (hidden) {
            if (prev_visible != NULL) {
                prev_visible->fts_link = next;
                if (prev_visible_rec != NULL) {
                    prev_visible_rec->link_overridden = YES;
                }
            }
        } else {
            if (out_head == NULL) {
                out_head = curr;
            }
            if (state->is_sys_caller == 0) {
                if (curr->fts_path != NULL && curr->fts_path[0] != '\0') {
                    char vbuf[PATH_MAX];
                    const char *vp = pt_virtualize_path_for_app(curr->fts_path, vbuf, sizeof(vbuf), state->use_private_prefix);
                    if (vp != curr->fts_path) {
                        rec->virt_path = strdup(vp);
                        if (rec->virt_path != NULL) {
                            curr->fts_path = rec->virt_path;
                            size_t vplen = strlen(rec->virt_path);
                            size_t sep = (vplen > 0 && rec->virt_path[vplen - 1] == '/') ? 0U : 1U;
                            size_t new_plen = vplen + sep + (size_t)curr->fts_namelen;
                            size_t max_plen = (sizeof(curr->fts_pathlen) == sizeof(unsigned short)) ? (size_t)USHRT_MAX : SIZE_MAX;
                            curr->fts_pathlen = (__typeof__(curr->fts_pathlen))MIN(new_plen, max_plen);
                            if (curr->fts_accpath != NULL && curr->fts_accpath[0] == '/') {
                                if (rec->orig_path != NULL && strcmp(curr->fts_accpath, rec->orig_path) == 0) {
                                    curr->fts_accpath = rec->virt_path;
                                } else {
                                    char vabuf[PATH_MAX];
                                    const char *va = pt_virtualize_path_for_app(curr->fts_accpath, vabuf, sizeof(vabuf), state->use_private_prefix);
                                    if (va != curr->fts_accpath) {
                                        rec->virt_accpath = strdup(va);
                                        if (rec->virt_accpath != NULL) {
                                            curr->fts_accpath = rec->virt_accpath;
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if (curr->fts_accpath != NULL && curr->fts_accpath[0] == '/') {
                    char vabuf[PATH_MAX];
                    const char *va = pt_virtualize_path_for_app(curr->fts_accpath, vabuf, sizeof(vabuf), state->use_private_prefix);
                    if (va != curr->fts_accpath) {
                        rec->virt_accpath = strdup(va);
                        if (rec->virt_accpath != NULL) {
                            curr->fts_accpath = rec->virt_accpath;
                        }
                    }
                }
            }
            prev_visible = curr;
            prev_visible_rec = rec;
        }
        curr = next;
    }
    return out_head;
}

static int pt_fts_set(FTS *ftsp, FTSENT *sp, int instr) {
    pt_fts_state_t *state = pt_fts_lookup_state(ftsp);
    if (state != NULL) {
        pt_fts_restore_cur(state);
        if (sp != NULL) {
            for (pt_fts_child_record_t *rec = state->children; rec != NULL; rec = rec->next) {
                if (rec->ent == sp) {
                    sp->fts_path = rec->orig_path;
                    sp->fts_accpath = rec->orig_accpath;
                    sp->fts_pathlen = rec->orig_pathlen;
                    break;
                }
            }
        }
    }
    return fts_set(ftsp, sp, instr);
}

static int pt_fts_close(FTS *ftsp) {
    if (ftsp != NULL) {
        pt_fts_state_t *state = NULL;
        os_unfair_lock_lock(&s_fts_states_lock);
        if (s_fts_states != NULL) {
            state = (pt_fts_state_t *)CFDictionaryGetValue(s_fts_states, ftsp);
            if (state != NULL) {
                CFDictionaryRemoveValue(s_fts_states, ftsp);
            }
        }
        os_unfair_lock_unlock(&s_fts_states_lock);
        if (state != NULL) {
            pt_fts_restore_cur(state);
            pt_fts_restore_children(state);
            free(state);
        }
    }
    return fts_close(ftsp);
}

static int pt_filter_and_virtualize_glob(glob_t *pglob,
                                         int flags,
                                         size_t start_match_idx,
                                         const void *caller,
                                         int *inout_is_sys_caller) {
    if (pglob == NULL || pglob->gl_pathv == NULL || pglob->gl_pathc <= start_match_idx) {
        return 0;
    }
    size_t offs = ((flags & GLOB_DOOFFS) != 0) ? pglob->gl_offs : 0U;
    size_t orig_pathc = pglob->gl_pathc;
    size_t write_idx = start_match_idx;
    for (size_t i = start_match_idx; i < orig_pathc; i++) {
        char *entry = pglob->gl_pathv[offs + i];
        if (entry == NULL) {
            continue;
        }
        if (pt_is_hidden_traversed_entry(entry, NULL, caller, inout_is_sys_caller)) {
            free(entry);
            continue;
        }
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(entry, vout, sizeof(vout), YES);
        if (virt != entry) {
            char *vdup = strdup(virt);
            if (vdup != NULL) {
                free(entry);
                entry = vdup;
            }
        }
        pglob->gl_pathv[offs + write_idx] = entry;
        write_idx++;
    }
    for (size_t i = write_idx; i < orig_pathc; i++) {
        pglob->gl_pathv[offs + i] = NULL;
    }
    pglob->gl_pathc = write_idx;
    if (write_idx == 0) {
        if ((flags & GLOB_APPEND) == 0) {
            globfree(pglob);
            pglob->gl_pathc = 0;
            pglob->gl_pathv = NULL;
        }
        return GLOB_NOMATCH;
    }
    return 0;
}

static int pt_glob(const char * __restrict pattern,
                   int flags,
                   int (*errfunc)(const char *, int),
                   glob_t * __restrict pglob) {
    char vbuf[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    const char *resolved_pattern = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(pattern, caller, vbuf, sizeof(vbuf), &resolved_pattern, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        if (pglob != NULL && (flags & GLOB_APPEND) == 0) {
            pglob->gl_pathc = 0;
            pglob->gl_pathv = NULL;
        }
        return GLOB_NOMATCH;
    }
    size_t start_idx = ((flags & GLOB_APPEND) != 0 && pglob != NULL) ? pglob->gl_pathc : 0U;
    int rc = glob(resolved_pattern, flags, errfunc, pglob);
    if ((rc == 0 || rc == GLOB_ABORTED) && pt_is_bypass_enabled() &&
        (is_sys_caller == 0 || (is_sys_caller < 0 && !pt_is_effective_system_or_playtools_caller(caller)))) {
        is_sys_caller = 0;
        int frc = pt_filter_and_virtualize_glob(pglob, flags, start_idx, caller, &is_sys_caller);
        if (rc == 0 && frc != 0) {
            return frc;
        }
    }
    return rc;
}

static int pt_glob_b(const char * __restrict pattern,
                     int flags,
                     int (^errblk)(const char *, int),
                     glob_t * __restrict pglob) {
    char vbuf[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    const char *resolved_pattern = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(pattern, caller, vbuf, sizeof(vbuf), &resolved_pattern, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        if (pglob != NULL && (flags & GLOB_APPEND) == 0) {
            pglob->gl_pathc = 0;
            pglob->gl_pathv = NULL;
        }
        return GLOB_NOMATCH;
    }
    size_t start_idx = ((flags & GLOB_APPEND) != 0 && pglob != NULL) ? pglob->gl_pathc : 0U;
    int rc = glob_b(resolved_pattern, flags, errblk, pglob);
    if ((rc == 0 || rc == GLOB_ABORTED) && pt_is_bypass_enabled() &&
        (is_sys_caller == 0 || (is_sys_caller < 0 && !pt_is_effective_system_or_playtools_caller(caller)))) {
        is_sys_caller = 0;
        int frc = pt_filter_and_virtualize_glob(pglob, flags, start_idx, caller, &is_sys_caller);
        if (rc == 0 && frc != 0) {
            return frc;
        }
    }
    return rc;
}

static int pt_posix_spawn_file_actions_addopen(posix_spawn_file_actions_t * actions,
                                               int fildes,
                                               const char * restrict path,
                                               int oflag,
                                               mode_t mode) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        return ENOENT;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return EPERM;
    }
    return posix_spawn_file_actions_addopen(actions, fildes, resolved, oflag, mode);
}

static inline BOOL pt_is_hidden_xattr_name(const char *name) {
    return pt_is_hidden_xattr_name_cstr(name) ? YES : NO;
}

static ssize_t pt_listxattr_filtered(BOOL is_fd,
                                     int fd,
                                     const char *path,
                                     char *namebuff,
                                     size_t size,
                                     int options) {
    ssize_t raw_size = is_fd ? flistxattr(fd, NULL, 0, options) : listxattr(path, NULL, 0, options);
    if (raw_size <= 0) {
        return raw_size;
    }
    char stack_tmp[4096];
    char *tmp = stack_tmp;
    if ((size_t)raw_size > sizeof(stack_tmp)) {
        tmp = (char *)malloc((size_t)raw_size);
        if (tmp == NULL) {
            errno = ENOMEM;
            return -1;
        }
    }
    ssize_t filled = is_fd ? flistxattr(fd, tmp, (size_t)raw_size, options)
                           : listxattr(path, tmp, (size_t)raw_size, options);
    if (filled < 0) {
        int saved_errno = errno;
        if (tmp != stack_tmp) {
            free(tmp);
        }
        errno = saved_errno;
        return -1;
    }
    ssize_t filtered_len = pt_filter_xattr_list_buffer(tmp, filled);
    if (namebuff != NULL && size > 0) {
        if ((size_t)filtered_len > size) {
            if (tmp != stack_tmp) {
                free(tmp);
            }
            errno = ERANGE;
            return -1;
        }
        if (filtered_len > 0) {
            memcpy(namebuff, tmp, (size_t)filtered_len);
        }
    }
    if (tmp != stack_tmp) {
        free(tmp);
    }
    return filtered_len;
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_getxattr_with_caller(const char *path, const char *name, void *value, size_t size, u_int32_t position, int options, const void *caller) {
    int is_sys = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(path, caller, vbuf, sizeof(vbuf), &path, &is_sys);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (is_sys < 0) {
        is_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    if (is_sys == 0 && pt_is_bypass_enabled() && pt_is_hidden_xattr_name(name)) {
        errno = ENOATTR;
        return -1;
    }
    return getxattr(path, name, value, size, position, options);
}

static ssize_t pt_getxattr(const char *path, const char *name, void *value, size_t size, u_int32_t position, int options) {
    return pt_fs_getxattr_with_caller(path, name, value, size, position, options, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_fgetxattr_with_caller(int fd, const char *name, void *value, size_t size, u_int32_t position, int options, const void *caller) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys) {
        if (pt_fd_is_sensitive(fd, caller)) {
            errno = EBADF;
            return -1;
        }
        if (pt_is_bypass_enabled() && pt_is_hidden_xattr_name(name)) {
            errno = ENOATTR;
            return -1;
        }
    }
    return fgetxattr(fd, name, value, size, position, options);
}

static ssize_t pt_fgetxattr(int fd, const char *name, void *value, size_t size, u_int32_t position, int options) {
    return pt_fs_fgetxattr_with_caller(fd, name, value, size, position, options, __builtin_return_address(0));
}

static int pt_setxattr(const char *path, const char *name, const void *value, size_t size, u_int32_t position, int options) {
    const void *caller = __builtin_return_address(0);
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, caller, vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    if (!pt_is_effective_system_or_playtools_caller(caller) &&
        pt_is_bypass_enabled() &&
        pt_is_hidden_xattr_name(name)) {
        errno = EPERM;
        return -1;
    }
    return setxattr(path, name, value, size, position, options);
}

static int pt_fsetxattr(int fd, const char *name, const void *value, size_t size, u_int32_t position, int options) {
    const void *caller = __builtin_return_address(0);
    if (!pt_is_effective_system_or_playtools_caller(caller)) {
        if (pt_fd_is_sensitive(fd, caller)) {
            errno = EACCES;
            return -1;
        }
        if (pt_is_bypass_enabled() && pt_is_hidden_xattr_name(name)) {
            errno = EPERM;
            return -1;
        }
    }
    return fsetxattr(fd, name, value, size, position, options);
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_listxattr_with_caller(const char *path, char *namebuff, size_t size, int options, const void *caller) {
    int is_sys = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(path, caller, vbuf, sizeof(vbuf), &path, &is_sys);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (is_sys < 0) {
        is_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    if (is_sys != 0 || !pt_is_bypass_enabled()) {
        return listxattr(path, namebuff, size, options);
    }
    if (namebuff == NULL || size == 0) {
        return pt_listxattr_filtered(NO, -1, path, NULL, 0, options);
    }
    ssize_t ret = listxattr(path, namebuff, size, options);
    if (ret < 0 && errno == ERANGE) {
        return pt_listxattr_filtered(NO, -1, path, namebuff, size, options);
    }
    return pt_filter_xattr_list_buffer(namebuff, ret);
}

static ssize_t pt_listxattr(const char *path, char *namebuff, size_t size, int options) {
    return pt_fs_listxattr_with_caller(path, namebuff, size, options, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_flistxattr_with_caller(int fd, char *namebuff, size_t size, int options, const void *caller) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    if (is_sys || !pt_is_bypass_enabled()) {
        return flistxattr(fd, namebuff, size, options);
    }
    if (namebuff == NULL || size == 0) {
        return pt_listxattr_filtered(YES, fd, NULL, NULL, 0, options);
    }
    ssize_t ret = flistxattr(fd, namebuff, size, options);
    if (ret < 0 && errno == ERANGE) {
        return pt_listxattr_filtered(YES, fd, NULL, namebuff, size, options);
    }
    return pt_filter_xattr_list_buffer(namebuff, ret);
}

static ssize_t pt_flistxattr(int fd, char *namebuff, size_t size, int options) {
    return pt_fs_flistxattr_with_caller(fd, namebuff, size, options, __builtin_return_address(0));
}

static int pt_removexattr(const char *path, const char *name, int options) {
    const void *caller = __builtin_return_address(0);
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, caller, vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    if (!pt_is_effective_system_or_playtools_caller(caller) &&
        pt_is_bypass_enabled() &&
        pt_is_hidden_xattr_name(name)) {
        errno = ENOATTR;
        return -1;
    }
    return removexattr(path, name, options);
}

static int pt_fremovexattr(int fd, const char *name, int options) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys) {
        if (pt_fd_is_sensitive(fd, caller)) {
            errno = EACCES;
            return -1;
        }
        if (pt_is_bypass_enabled() && pt_is_hidden_xattr_name(name)) {
            errno = ENOATTR;
            return -1;
        }
    }
    return fremovexattr(fd, name, options);
}

static int pt_copyfile(const char *from, const char *to, copyfile_state_t state, copyfile_flags_t flags) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (from != NULL &&
        !pt_prepare_fs_path_for_modify(AT_FDCWD, from, caller, vbuf1, sizeof(vbuf1), &from, EACCES)) {
        return -1;
    }
    if (to != NULL &&
        !pt_prepare_fs_path_for_modify(AT_FDCWD, to, caller, vbuf2, sizeof(vbuf2), &to, EACCES)) {
        return -1;
    }
    return copyfile(from, to, state, flags);
}

static int pt_clonefile(const char *src, const char *dst, uint32_t flags) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, src, caller, vbuf1, sizeof(vbuf1), &src, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, dst, caller, vbuf2, sizeof(vbuf2), &dst, EACCES)) {
        return -1;
    }
    return clonefile(src, dst, flags);
}

__attribute__((visibility("hidden")))
int pt_fs_clonefileat_with_caller(int src_dirfd,
                                  const char *src,
                                  int dst_dirfd,
                                  const char *dst,
                                  uint32_t flags,
                                  const void *caller) {
    if (pt_fd_is_sensitive(src_dirfd, caller)) {
        errno = ENOENT;
        return -1;
    }
    if (pt_fd_is_sensitive(dst_dirfd, caller)) {
        errno = EACCES;
        return -1;
    }
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    pt_fs_path_disposition_t disp_src = pt_prepare_fs_path_at(src_dirfd, src, caller, vbuf1, sizeof(vbuf1), &src);
    if (disp_src == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp_src == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (!pt_prepare_fs_path_for_modify(dst_dirfd, dst, caller, vbuf2, sizeof(vbuf2), &dst, EACCES)) {
        return -1;
    }
    return clonefileat(src_dirfd, src, dst_dirfd, dst, flags);
}

static int pt_clonefileat(int src_dirfd, const char *src, int dst_dirfd, const char *dst, uint32_t flags) {
    return pt_fs_clonefileat_with_caller(src_dirfd, src, dst_dirfd, dst, flags, __builtin_return_address(0));
}

static size_t pt_count_template_xs(const char *tmpl, int slen) {
    if (tmpl == NULL || slen < 0) {
        return 0;
    }
    size_t tlen = strlen(tmpl);
    if (tlen < (size_t)slen) {
        return 0;
    }
    size_t end = tlen - (size_t)slen;
    size_t x_count = 0;
    while (end > x_count && tmpl[end - 1 - x_count] == 'X') {
        x_count++;
    }
    return x_count;
}

static void pt_copy_template_xs(char *tmpl, const char *vbuf, int slen, size_t x_count) {
    if (tmpl == NULL || vbuf == NULL || slen < 0 || x_count == 0) {
        return;
    }
    size_t tlen = strlen(tmpl);
    size_t vlen = strlen(vbuf);
    size_t tail = x_count + (size_t)slen;
    if (tlen >= tail && vlen >= tail) {
        memcpy(tmpl + tlen - tail, vbuf + vlen - tail, x_count);
    }
}

static int pt_mkstemp(char *tmpl) {
    if (tmpl == NULL) {
        errno = EINVAL;
        return -1;
    }
    size_t x_count = pt_count_template_xs(tmpl, 0);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        int fd = mkstemp(vbuf);
        if (fd >= 0) {
            pt_copy_template_xs(tmpl, vbuf, 0, x_count);
        }
        return fd;
    }
    return mkstemp(tmpl);
}

static int pt_mkstemps(char *tmpl, int slen) {
    if (tmpl == NULL) {
        return mkstemps(tmpl, slen);
    }
    size_t x_count = pt_count_template_xs(tmpl, slen);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        int fd = mkstemps(vbuf, slen);
        if (fd >= 0) {
            pt_copy_template_xs(tmpl, vbuf, slen, x_count);
        }
        return fd;
    }
    return mkstemps(tmpl, slen);
}

static int pt_mkostemp(char *tmpl, int oflags) {
    if (tmpl == NULL) {
        return mkostemp(tmpl, oflags);
    }
    size_t x_count = pt_count_template_xs(tmpl, 0);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        int fd = mkostemp(vbuf, oflags);
        if (fd >= 0) {
            pt_copy_template_xs(tmpl, vbuf, 0, x_count);
        }
        return fd;
    }
    return mkostemp(tmpl, oflags);
}

static int pt_mkostemps(char *tmpl, int slen, int oflags) {
    if (tmpl == NULL) {
        return mkostemps(tmpl, slen, oflags);
    }
    size_t x_count = pt_count_template_xs(tmpl, slen);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        int fd = mkostemps(vbuf, slen, oflags);
        if (fd >= 0) {
            pt_copy_template_xs(tmpl, vbuf, slen, x_count);
        }
        return fd;
    }
    return mkostemps(tmpl, slen, oflags);
}

static char *pt_mkdtemp(char *tmpl) {
    if (tmpl == NULL) {
        errno = EINVAL;
        return NULL;
    }
    size_t x_count = pt_count_template_xs(tmpl, 0);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        char *res = mkdtemp(vbuf);
        if (res == NULL) {
            return NULL;
        }
        pt_copy_template_xs(tmpl, vbuf, 0, x_count);
        return tmpl;
    }
    return mkdtemp(tmpl);
}

extern char *pt_orig_mktemp(char *) __asm("_mktemp");
static char *pt_mktemp(char *tmpl) {
    if (tmpl == NULL) {
        errno = EINVAL;
        return NULL;
    }
    size_t x_count = pt_count_template_xs(tmpl, 0);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        char *res = pt_orig_mktemp(vbuf);
        if (res == NULL || vbuf[0] == '\0') {
            tmpl[0] = '\0';
            return tmpl;
        }
        pt_copy_template_xs(tmpl, vbuf, 0, x_count);
        return tmpl;
    }
    return pt_orig_mktemp(tmpl);
}

extern char *_amkrtemp(const char *path);
static char *pt_amkrtemp(const char *path) {
    char vbuf[PATH_MAX];
    path = pt_resolve_virtual_path(pt_fs_ue_fix_filename(path), vbuf, sizeof(vbuf));
    return _amkrtemp(path);
}


static const char *pt_resolve_sqlite_filename(const char *filename, char *buf, size_t bufsize, const char **out_check_path, char *check_buf, size_t check_bufsize) {
    if (out_check_path != NULL) {
        *out_check_path = NULL;
    }
    if (filename == NULL || buf == NULL || bufsize == 0) {
        return filename;
    }
    if (filename[0] == '/') {
        const char *fixed = pt_fs_ue_fix_filename(filename);
        const char *resolved = pt_resolve_virtual_path(fixed, buf, bufsize);
        if (out_check_path != NULL) {
            *out_check_path = pt_is_reverse_mapped_iossupport(fixed, resolved) ? fixed : resolved;
        }
        return resolved;
    }
    if (strncmp(filename, "file:", 5) == 0) {
        const char *path_start = NULL;
        if (strncmp(filename, "file://localhost/", 17) == 0) {
            path_start = filename + 16;
        } else if (strncmp(filename, "file:///", 8) == 0) {
            path_start = filename + 7;
        } else if (filename[5] == '/') {
            path_start = filename + 5;
        }
        if (path_start != NULL) {
            const char *tail = strpbrk(path_start, "?#");
            size_t path_len = (tail != NULL) ? (size_t)(tail - path_start) : strlen(path_start);
            if (path_len > 0 && path_len < PATH_MAX) {
                char path_only[PATH_MAX];
                memcpy(path_only, path_start, path_len);
                path_only[path_len] = '\0';
                const char *resolved = pt_resolve_virtual_path(path_only, check_buf, check_bufsize);
                if (out_check_path != NULL) {
                    if (pt_is_reverse_mapped_iossupport(path_only, resolved)) {
                        *out_check_path = NULL;
                    } else {
                        *out_check_path = (resolved == path_only) ? NULL : resolved;
                        if (*out_check_path == NULL && path_len < check_bufsize) {
                            memcpy(check_buf, path_only, path_len + 1);
                            *out_check_path = check_buf;
                        }
                    }
                }
                if (resolved != path_only) {
                    int n = snprintf(buf, bufsize, "file://%s%s", resolved, (tail != NULL) ? tail : "");
                    if (n >= 0 && (size_t)n < bufsize) {
                        return buf;
                    }
                }
            }
        }
    }
    return filename;
}

static int pt_sqlite3_open(const char *filename, sqlite3 **ppDb) {
    char vbuf[PATH_MAX + 128];
    char cbuf[PATH_MAX];
    const char *check_path = NULL;
    filename = pt_resolve_sqlite_filename(filename, vbuf, sizeof(vbuf), &check_path, cbuf, sizeof(cbuf));
    if (check_path != NULL &&
        (pt_is_hidden_path(check_path, __builtin_return_address(0)) ||
         pt_is_virtual_container_ancestor_dir(check_path))) {
        if (ppDb != NULL) {
            *ppDb = NULL;
        }
        return SQLITE_CANTOPEN;
    }
    return sqlite3_open(filename, ppDb);
}

static int pt_sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs) {
    char vbuf[PATH_MAX + 128];
    char cbuf[PATH_MAX];
    const char *check_path = NULL;
    filename = pt_resolve_sqlite_filename(filename, vbuf, sizeof(vbuf), &check_path, cbuf, sizeof(cbuf));
    if (check_path != NULL &&
        (pt_is_hidden_path(check_path, __builtin_return_address(0)) ||
         (pt_is_virtual_container_ancestor_dir(check_path) && (flags & (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) != 0) ||
         pt_is_virtual_container_ancestor_dir(check_path))) {
        if (ppDb != NULL) {
            *ppDb = NULL;
        }
        return SQLITE_CANTOPEN;
    }
    return sqlite3_open_v2(filename, ppDb, flags, zVfs);
}

PT_INTERPOSE(pt_statfs, statfs)
PT_DLSYM_ONLY("statfs64", pt_statfs)
PT_INTERPOSE(pt_fstatfs, fstatfs)
PT_DLSYM_ONLY("fstatfs64", pt_fstatfs)
PT_INTERPOSE(pt_getfsstat, getfsstat)
PT_DLSYM_ONLY("getfsstat64", pt_getfsstat)
PT_INTERPOSE(pt_getmntinfo, getmntinfo)
PT_INTERPOSE(pt_getmntinfo_r_np, getmntinfo_r_np)
PT_INTERPOSE(pt_statvfs, statvfs)
PT_INTERPOSE(pt_fstatvfs, fstatvfs)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
PT_INTERPOSE(pt_mktemp, mktemp)
#pragma clang diagnostic pop
PT_INTERPOSE(pt_rename, rename)
PT_INTERPOSE(pt_renameat, renameat)
PT_INTERPOSE(pt_renamex_np, renamex_np)
PT_INTERPOSE(pt_renameatx_np, renameatx_np)
PT_INTERPOSE(pt_unlink, unlink)
PT_INTERPOSE(pt_unlinkat, unlinkat)
PT_INTERPOSE(pt_remove, remove)
PT_INTERPOSE(pt_removefile, removefile)
PT_INTERPOSE(pt_link, link)
PT_INTERPOSE(pt_linkat, linkat)
PT_INTERPOSE(pt_symlink, symlink)
PT_INTERPOSE(pt_symlinkat, symlinkat)
PT_INTERPOSE(pt_chmod, chmod)
PT_INTERPOSE(pt_lchmod, lchmod)
PT_INTERPOSE(pt_fchmodat, fchmodat)
PT_INTERPOSE(pt_chown, chown)
PT_INTERPOSE(pt_lchown, lchown)
PT_INTERPOSE(pt_fchownat, fchownat)
PT_INTERPOSE(pt_chflags, chflags)
PT_INTERPOSE(pt_lchflags, lchflags)
PT_INTERPOSE(pt_truncate, truncate)
PT_INTERPOSE(pt_utimes, utimes)
PT_INTERPOSE(pt_lutimes, lutimes)
PT_INTERPOSE(pt_utimensat, utimensat)
PT_INTERPOSE(pt_utime, utime)
PT_INTERPOSE(pt_ftw, ftw)
PT_INTERPOSE(pt_nftw, nftw)
PT_INTERPOSE(pt_fts_open, fts_open)
#ifdef __BLOCKS__
PT_INTERPOSE(pt_fts_open_b, fts_open_b)
#endif
PT_INTERPOSE(pt_fts_read, fts_read)
PT_INTERPOSE(pt_fts_children, fts_children)
PT_INTERPOSE(pt_fts_set, fts_set)
PT_INTERPOSE(pt_fts_close, fts_close)
PT_INTERPOSE(pt_glob, glob)
PT_INTERPOSE(pt_glob_b, glob_b)
PT_INTERPOSE(pt_posix_spawn_file_actions_addopen, posix_spawn_file_actions_addopen)
PT_INTERPOSE(pt_getxattr, getxattr)
PT_INTERPOSE(pt_fgetxattr, fgetxattr)
PT_INTERPOSE(pt_setxattr, setxattr)
PT_INTERPOSE(pt_fsetxattr, fsetxattr)
PT_INTERPOSE(pt_listxattr, listxattr)
PT_INTERPOSE(pt_flistxattr, flistxattr)
PT_INTERPOSE(pt_removexattr, removexattr)
PT_INTERPOSE(pt_fremovexattr, fremovexattr)
PT_INTERPOSE(pt_copyfile, copyfile)
PT_INTERPOSE(pt_clonefile, clonefile)
PT_INTERPOSE(pt_clonefileat, clonefileat)
PT_INTERPOSE(pt_mkstemp, mkstemp)
PT_INTERPOSE(pt_mkstemps, mkstemps)
PT_INTERPOSE(pt_mkostemp, mkostemp)
PT_INTERPOSE(pt_mkostemps, mkostemps)
PT_INTERPOSE(pt_mkdtemp, mkdtemp)
PT_INTERPOSE(pt_amkrtemp, _amkrtemp)
PT_INTERPOSE(pt_sqlite3_open, sqlite3_open)
PT_INTERPOSE(pt_sqlite3_open_v2, sqlite3_open_v2)
