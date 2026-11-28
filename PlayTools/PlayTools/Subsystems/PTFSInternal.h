//
//  PTFSInternal.h
//  PlayTools
//
//  Hidden declarations shared across PTFSVirtualizer modules and callers.
//

#ifndef PTFSInternal_h
#define PTFSInternal_h

#import "PTCommon.h"
#import "PTDetectionRules.h"
#include <dirent.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/statvfs.h>
#include <sys/uio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PT_MAX_GROUP_CONTAINERS 64

typedef struct {
    char real_dir[PATH_MAX];
    size_t real_len;
    char uuid[40];
    char virt_var[128];
    size_t virt_var_len;
    char virt_priv[136];
    size_t virt_priv_len;
} pt_group_container_entry_t;

// Shared state between PTFSVirtualizer and PTFSPathResolver (visibility=hidden)
extern __attribute__((visibility("hidden"))) size_t s_virtual_private_bundle_len;
extern __attribute__((visibility("hidden"))) char s_virtual_var_bundle_dir[PATH_MAX];
extern __attribute__((visibility("hidden"))) size_t s_virtual_var_bundle_len;
extern __attribute__((visibility("hidden"))) char s_virtual_bundle_uuid_parent_var[128];
extern __attribute__((visibility("hidden"))) char s_virtual_var_data_dir[PATH_MAX];
extern __attribute__((visibility("hidden"))) size_t s_virtual_var_data_len;
extern __attribute__((visibility("hidden"))) char s_virtual_tmpdir[PATH_MAX];
extern __attribute__((visibility("hidden"))) _Atomic int s_data_map_state;
extern __attribute__((visibility("hidden"))) os_unfair_lock s_container_map_lock;
extern __attribute__((visibility("hidden"))) bool s_app_info_plist_in_contents;
extern __attribute__((visibility("hidden"))) char s_real_group_containers_root[PATH_MAX];
extern __attribute__((visibility("hidden"))) size_t s_real_group_containers_root_len;
extern __attribute__((visibility("hidden"))) _Atomic bool s_group_map_nonempty;
extern __attribute__((visibility("hidden"))) os_unfair_lock s_group_map_lock;
extern __attribute__((visibility("hidden"))) pt_group_container_entry_t s_group_map[PT_MAX_GROUP_CONTAINERS];
extern __attribute__((visibility("hidden"))) size_t s_group_map_count;
extern __attribute__((visibility("hidden"))) BOOL s_group_root_scanned;

static inline const char *pt_join_path_fast(char *buf,
                                            size_t bufsize,
                                            const char *prefix,
                                            size_t prefix_len,
                                            const char *suffix) {
    if (buf == NULL || bufsize == 0 || prefix == NULL) {
        return NULL;
    }
    size_t slen = (suffix != NULL) ? strlen(suffix) : 0;
    if (prefix_len + slen >= bufsize) {
        return NULL;
    }
    memcpy(buf, prefix, prefix_len);
    if (slen > 0) {
        memcpy(buf + prefix_len, suffix, slen);
    }
    buf[prefix_len + slen] = '\0';
    return buf;
}

// Core path classification, backup & resolution
__attribute__((visibility("hidden"))) BOOL pt_is_system_or_playtools_caller(const void *ret_addr);
__attribute__((visibility("hidden"))) BOOL pt_is_effective_system_or_playtools_caller(const void *ret_addr);
__attribute__((visibility("hidden"))) BOOL pt_needs_lexical_norm(const char *p);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_path(const char *path, const void *caller);
__attribute__((visibility("hidden"))) void pt_ensure_bundle_path_map(void);
__attribute__((visibility("hidden"))) BOOL pt_ensure_data_container_map(void);
__attribute__((visibility("hidden"))) void pt_format_deterministic_uuid(const char *input, uint64_t seed1, uint64_t seed2, char out_uuid[40]);
__attribute__((visibility("hidden"))) const char *pt_register_and_virtualize_group_container(const char *real_group_path, char *buf, size_t bufsize, BOOL use_private_prefix);
__attribute__((visibility("hidden"))) const char *pt_get_virtual_home_cstr(void);
__attribute__((visibility("hidden"))) const char *pt_get_virtual_tmpdir_cstr(void);
__attribute__((visibility("hidden"))) BOOL pt_is_virtual_container_ancestor_dir(const char *path);
__attribute__((visibility("hidden"))) const char *pt_virtualize_path_for_app(const char *path, char *buf, size_t bufsize, BOOL use_private_prefix);
__attribute__((visibility("hidden"))) const char *pt_sanitize_image_path_for_app(const char *raw_path);
__attribute__((visibility("hidden"))) const char *pt_sanitize_image_path_for_cstr(const char *raw_path);
__attribute__((visibility("hidden"))) BOOL pt_is_virtual_container_path(const char *path);
__attribute__((visibility("hidden"))) BOOL pt_is_reverse_mapped_iossupport(const char *orig_path, const char *resolved_path);
__attribute__((visibility("hidden"))) const char *pt_resolve_virtual_path(const char *path, char *buf, size_t bufsize);
__attribute__((visibility("hidden"))) const char *pt_resolve_virtual_bundle_path(const char *path, char *buf, size_t bufsize);
__attribute__((visibility("hidden"))) BOOL pt_fd_is_sensitive(int fd, const void *caller);
__attribute__((visibility("hidden"))) pt_fs_path_disposition_t pt_prepare_fs_path_cached_caller(const char *raw_path, const void *caller, char *vbuf, size_t vbuf_size, const char **out_path, int *inout_is_sys_caller);
__attribute__((visibility("hidden"))) pt_fs_path_disposition_t pt_prepare_fs_path_at_cached_caller(int dirfd, const char *raw_path, const void *caller, char *vbuf, size_t vbuf_size, const char **out_path, int *inout_is_sys_caller, BOOL for_readonly);
__attribute__((visibility("hidden"))) BOOL pt_prepare_fs_path_for_modify(int dirfd, const char *raw_path, const void *caller, char *vbuf, size_t vbuf_size, const char **out_path, int ancestor_errno);
__attribute__((visibility("hidden"))) int pt_stat_virtual_ancestor(const char *virtual_path, struct stat *buf, const void *caller);
__attribute__((visibility("hidden"))) void pt_disable_app_backups_for_safe_mode(void);
__attribute__((visibility("hidden"))) BOOL pt_has_backup_mobileprovision(void);
__attribute__((visibility("hidden"))) const char *pt_copy_virtual_mobileprovision_path(char *buf, size_t bufsize);
__attribute__((visibility("hidden"))) const char *pt_lookup_app_backup_redirect_for_caller(const char *raw_path, const void *caller, char *vbuf, size_t vbuf_size, int *inout_is_sys_caller);
__attribute__((visibility("hidden"))) const uint8_t *pt_get_cached_backup_main_mach_header(size_t *out_len);
__attribute__((visibility("hidden"))) BOOL pt_is_active_app_backup_file_path(const char *p);
__attribute__((visibility("hidden"))) const char *pt_virtualize_app_backup_path(const char *p, char *buf, size_t bufsize, BOOL use_private_prefix);
__attribute__((visibility("hidden"))) BOOL pt_is_synth_system_version_path(const char *p);
__attribute__((visibility("hidden"))) BOOL pt_is_synth_system_version_stat(dev_t dev, ino_t ino);
__attribute__((visibility("hidden"))) void pt_normalize_synth_sysver_stat(struct stat *buf);
__attribute__((visibility("hidden"))) BOOL pt_is_sensitive_host_fd_path(const char *path, const void *caller);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_normalized_path_cached_caller(const char *norm, const void *caller, int *inout_is_sys_caller);
__attribute__((visibility("hidden"))) BOOL pt_is_synth_code_resources_path(const char *p);
__attribute__((visibility("hidden"))) BOOL pt_is_synth_info_plist_path(const char *p);
__attribute__((visibility("hidden"))) NSMutableDictionary *pt_sanitize_code_resources_dict(NSDictionary *dict, BOOL wantMutableContainers);
__attribute__((visibility("hidden"))) void pt_record_stat_dpclass(dev_t dev, ino_t ino, int dpclass);
__attribute__((visibility("hidden"))) int pt_lookup_stat_dpclass(dev_t dev, ino_t ino);
__attribute__((visibility("hidden"))) int pt_lookup_fd_dpclass(int fd);
__attribute__((visibility("hidden"))) BOOL pt_is_sensitive_unix_socket_path(const char *sun_path, const void *caller);
__attribute__((visibility("hidden"))) BOOL pt_path_equals_real_data_root(const char *path);
__attribute__((visibility("hidden"))) void pt_sanitize_statfs_entry(struct statfs *buf, const void *caller, int *inout_is_sys);
__attribute__((visibility("hidden"))) int pt_filter_statfs_array(struct statfs *buf, int count, const void *caller);
__attribute__((visibility("hidden"))) const char *pt_fs_ue_fix_filename(const char *filename);
__attribute__((visibility("hidden"))) ssize_t pt_fs_write_with_caller(int fd, const void *buf, size_t nbyte, off_t offset, BOOL has_offset, BOOL nocancel, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_writev_with_caller(int fd, const struct iovec *iov, int iovcnt, BOOL nocancel, const void *caller);

static inline pt_fs_path_disposition_t pt_prepare_fs_path_cached_caller_ro(const char *raw_path,
                                                                           const void *caller,
                                                                           char *vbuf,
                                                                           size_t vbuf_size,
                                                                           const char **out_path,
                                                                           int *inout_is_sys_caller) {
    return pt_prepare_fs_path_at_cached_caller(AT_FDCWD, raw_path, caller, vbuf, vbuf_size, out_path, inout_is_sys_caller, YES);
}

static inline BOOL pt_open_flags_are_readonly(int oflag) {
    return ((oflag & O_ACCMODE) == O_RDONLY) &&
           ((oflag & (O_CREAT | O_TRUNC | O_APPEND | O_EXCL)) == 0);
}

static inline BOOL pt_fopen_mode_is_readonly(const char *mode) {
    return mode != NULL && mode[0] == 'r' && strchr(mode, '+') == NULL;
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_mode(const char *raw_path,
                                                                const void *caller,
                                                                char *vbuf,
                                                                size_t vbuf_size,
                                                                const char **out_path,
                                                                BOOL for_readonly) {
    int is_sys_caller = -1;
    return pt_prepare_fs_path_at_cached_caller(AT_FDCWD, raw_path, caller, vbuf, vbuf_size, out_path, &is_sys_caller, for_readonly);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path(const char *raw_path,
                                                          const void *caller,
                                                          char *vbuf,
                                                          size_t vbuf_size,
                                                          const char **out_path) {
    return pt_prepare_fs_path_mode(raw_path, caller, vbuf, vbuf_size, out_path, NO);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_ro(const char *raw_path,
                                                             const void *caller,
                                                             char *vbuf,
                                                             size_t vbuf_size,
                                                             const char **out_path) {
    return pt_prepare_fs_path_mode(raw_path, caller, vbuf, vbuf_size, out_path, YES);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_at_mode(int dirfd,
                                                                   const char *raw_path,
                                                                   const void *caller,
                                                                   char *vbuf,
                                                                   size_t vbuf_size,
                                                                   const char **out_path,
                                                                   BOOL for_readonly) {
    int is_sys_caller = -1;
    return pt_prepare_fs_path_at_cached_caller(dirfd, raw_path, caller, vbuf, vbuf_size, out_path, &is_sys_caller, for_readonly);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_at(int dirfd,
                                                             const char *raw_path,
                                                             const void *caller,
                                                             char *vbuf,
                                                             size_t vbuf_size,
                                                             const char **out_path) {
    return pt_prepare_fs_path_at_mode(dirfd, raw_path, caller, vbuf, vbuf_size, out_path, NO);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_at_ro(int dirfd,
                                                                const char *raw_path,
                                                                const void *caller,
                                                                char *vbuf,
                                                                size_t vbuf_size,
                                                                const char **out_path) {
    return pt_prepare_fs_path_at_mode(dirfd, raw_path, caller, vbuf, vbuf_size, out_path, YES);
}

static inline BOOL pt_is_hidden_dirent_name(const char *d_name) {
    if (d_name == NULL || d_name[0] == '\0') {
        return NO;
    }
    if (strncasecmp(d_name, "discord-ipc-", 12) == 0 ||
        strncasecmp(d_name, ".pt_sysver_", 11) == 0 ||
        strncasecmp(d_name, ".pt_coderes_", 12) == 0 ||
        strncasecmp(d_name, ".pt_info_", 9) == 0 ||
        pt_is_hidden_runtime_artifact_name_cstr(d_name)) {
        return YES;
    }
    if (strcasestr(d_name, "Play") != NULL &&
        (strcasestr(d_name, "PlayTools") != NULL ||
         strcasestr(d_name, "Playtools.strings") != NULL ||
         strcasestr(d_name, "io.playcover.PlayCover") != NULL)) {
        return YES;
    }
    if (strcasestr(d_name, "app.makedie.MacOver") != NULL ||
        strcasestr(d_name, "MacOver.app") != NULL ||
        strcasestr(d_name, "AKInterface") != NULL ||
        strcasestr(d_name, "UserPlugins") != NULL ||
        pt_is_registered_hidden_module(d_name)) {
        return YES;
    }
    if (pt_is_bypass_enabled() &&
        (strcasecmp(d_name, ".CFUserTextEncoding") == 0 ||
         strcasecmp(d_name, "Saved Application State") == 0 ||
         strcasestr(d_name, "~iosmac.savedState") != NULL)) {
        return YES;
    }
    return NO;
}

static inline BOOL pt_is_macos_data_root_symlink_name(const char *d_name) {
    if (d_name == NULL || d_name[0] == '\0') {
        return NO;
    }
    return (strcasecmp(d_name, "Desktop") == 0 ||
            strcasecmp(d_name, "Downloads") == 0 ||
            strcasecmp(d_name, "Movies") == 0 ||
            strcasecmp(d_name, "Music") == 0 ||
            strcasecmp(d_name, "Pictures") == 0);
}

static inline void pt_sanitize_stat_buf(struct stat *buf, const void *caller) {
    if (buf != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        if (buf->st_gid == 20) {
            buf->st_gid = 501;
        }
#ifdef SF_RESTRICTED
        buf->st_flags &= ~(uint32_t)SF_RESTRICTED;
#endif
#ifdef SF_FIRMLINK
        buf->st_flags &= ~(uint32_t)SF_FIRMLINK;
#endif
        if (pt_is_synth_system_version_stat(buf->st_dev, buf->st_ino)) {
            pt_normalize_synth_sysver_stat(buf);
        }
    }
}

// Syscall/interpose entrypoints across FS modules
__attribute__((visibility("hidden"))) int pt_fs_open_with_caller(const char *filename, int oflag, mode_t mode, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_openat_with_caller(int fd, const char *path, int oflag, mode_t mode, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_open_dprotected_np_with_caller(const char *path, int flags, int dpclass, int dpflags, mode_t mode, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_openat_dprotected_np_with_caller(int fd, const char *path, int flags, int dpclass, int dpflags, mode_t mode, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_guarded_open_np_with_caller(const char *path, const void *guard, u_int guardflags, int flags, mode_t mode, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_guarded_open_dprotected_np_with_caller(const char *path, const void *guard, u_int guardflags, int flags, int dpclass, int dpflags, mode_t mode, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_open_extended_with_caller(const char *path, int flags, uid_t uid, gid_t gid, mode_t mode, void *xsecurity, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_chdir_with_caller(const char *path, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_fchdir_with_caller(int fd, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_clonefileat_with_caller(int src_dirfd, const char *src, int dst_dirfd, const char *dst, uint32_t flags, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_fclonefileat_with_caller(int src_fd, int dst_dirfd, const char *dst, uint32_t flags, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_stat_with_caller(const char *path, struct stat *buf, BOOL follow_symlinks, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_fstat_with_caller(int fd, struct stat *buf, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_fstatat_with_caller(int fd, const char *path, struct stat *buf, int flag, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_stat_extended_with_caller(const char *path, void *ub, void *xsecurity, size_t *xsecurity_size, BOOL is_64, BOOL follow_links, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_fstat_extended_with_caller(int fd, void *ub, void *xsecurity, size_t *xsecurity_size, BOOL is_64, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_prepare_legacy_stat_path_with_caller(int dirfd, BOOL is_at, const char *path, const void *caller, char *vbuf, size_t vbuf_size, const char **out_resolved, BOOL *out_virtual_ancestor);
__attribute__((visibility("hidden"))) long pt_fs_pathconf_with_caller(const char *path, int name, const void *caller);
__attribute__((visibility("hidden"))) long pt_fs_fpathconf_with_caller(int fd, int name, const void *caller);
__attribute__((visibility("hidden"))) BOOL pt_fs_probe_hidden_region_path(uintptr_t addr, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_access_with_caller(const char *path, int mode, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_faccessat_with_caller(int fd, const char *path, int mode, int flag, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_access_extended_with_caller(void *entries, size_t size, void *results, uid_t uid, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_readlink_with_caller(const char *path, char *buf, size_t bufsize, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_readlinkat_with_caller(int fd, const char *path, char *buf, size_t bufsize, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_freadlink_with_caller(int fd, char *buf, size_t bufsize, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_fcntl_with_caller(int fd, int cmd, uintptr_t arg, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_proc_pidinfo_with_caller(int pid, int flavor, uint64_t arg, void *buffer, int buffersize, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_proc_pidinfo_syscall_with_caller(int pid, int flavor, uint64_t arg, void *buffer, int buffersize, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_proc_pidfdinfo_syscall_with_caller(int pid, int fd, int flavor, void *buffer, int buffersize, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_proc_pidfileportinfo_syscall_with_caller(int pid, uint32_t fileport, int flavor, void *buffer, int buffersize, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_proc_listpids_syscall_with_caller(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize, const void *caller);
__attribute__((visibility("hidden"))) BOOL pt_should_hide_dirent(const char *d_name, uint8_t d_type, const void *caller, int *inout_is_sys_caller, int *inout_in_data_root, DIR *dirp_for_lazy_check, int dirfd_for_check, const char *dirname_for_lazy_check);
__attribute__((visibility("hidden"))) int pt_fs_getattrlist_with_caller(const char *path, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_fgetattrlist_with_caller(int fd, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_getattrlistat_with_caller(int fd, const char *path, void *attrList, void *attrBuf, size_t attrBufSize, unsigned long options, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_getattrlistbulk_with_caller(int dirfd, void *attrList, void *attrBuf, size_t attrBufSize, uint64_t options, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_statfs_with_caller(const char *path, struct statfs *buf, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_fstatfs_with_caller(int fd, struct statfs *buf, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_getfsstat_with_caller(struct statfs *buf, int bufsize, int mode, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_prepare_statfs_path_with_caller(const char *path, const void *caller, char *vbuf, size_t vbuf_size, const char **out_resolved);
__attribute__((visibility("hidden"))) void pt_fs_sanitize_legacy_statfs_strings(char *mnton, size_t mnton_cap, char *mntfrom, size_t mntfrom_cap, const void *caller);
__attribute__((visibility("hidden"))) BOOL pt_fs_legacy_statfs_entry_is_hidden(const char *mnton, const char *mntfrom, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_getdirentries_syscall_with_caller(int fd, void *buf, size_t bufsize, long *basep, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_getdirentries64_syscall_with_caller(int fd, void *buf, size_t bufsize, off_t *position, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_getxattr_with_caller(const char *path, const char *name, void *value, size_t size, u_int32_t position, int options, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_fgetxattr_with_caller(int fd, const char *name, void *value, size_t size, u_int32_t position, int options, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_listxattr_with_caller(const char *path, char *namebuff, size_t size, int options, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_flistxattr_with_caller(int fd, char *namebuff, size_t size, int options, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_fsgetpath_with_caller(char *buf, size_t bufsize, fsid_t *fsid, uint64_t objid, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_fs_fsgetpath_ext_with_caller(char *buf, size_t bufsize, fsid_t *fsid, uint64_t objid, uint64_t flags, const void *caller);
__attribute__((visibility("hidden"))) int pt_fs_searchfs_with_caller(const char *path, void *searchblock, unsigned long *nummatches, unsigned int scriptcode, unsigned int options, void *state, const void *caller);
__attribute__((visibility("hidden"))) Boolean pt_CFURLCopyResourcePropertyForKey(CFURLRef url, CFStringRef key, void *propertyValueTypeRefPtr, CFErrorRef *error);
__attribute__((visibility("hidden"))) CFDictionaryRef pt_CFURLCopyResourcePropertiesForKeys(CFURLRef url, CFArrayRef keys, CFErrorRef *error);

#ifdef __cplusplus
}
#endif

#endif /* PTFSInternal_h */
