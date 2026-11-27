//
//  PTFSPathResolver.m
//  PlayTools
//

#import "PTFSInternal.h"
#import "PTSystemSpooferInternal.h"
#import "PTDyldInternal.h"

static os_unfair_lock s_image_path_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_image_path_ptr_cache = NULL;
static CFMutableDictionaryRef s_image_path_str_cache = NULL;

static void pt_maybe_init_test_group_root_locked(void) {
    if (s_real_group_containers_root_len > 0) {
        return;
    }
    const char *test_group_root = pt_raw_getenv("PLAYTOOLS_TEST_GROUP_CONTAINERS_ROOT");
    if (test_group_root != NULL && test_group_root[0] == '/') {
        if (strncmp(test_group_root, "/System/Volumes/Data/", 21) == 0) {
            test_group_root += 20;
        }
        size_t glen = strlen(test_group_root);
        while (glen > 1 && test_group_root[glen - 1] == '/') {
            glen--;
        }
        if (glen > 0 && glen < sizeof(s_real_group_containers_root)) {
            memcpy(s_real_group_containers_root, test_group_root, glen);
            s_real_group_containers_root[glen] = '\0';
            s_real_group_containers_root_len = glen;
        }
    }
}

__attribute__((visibility("hidden"))) BOOL pt_ensure_data_container_map(void) {
    int st = atomic_load_explicit(&s_data_map_state, memory_order_acquire);
    if (st != 0) {
        return (st == 1);
    }
    os_unfair_lock_lock(&s_container_map_lock);
    st = atomic_load_explicit(&s_data_map_state, memory_order_relaxed);
    if (st != 0) {
        os_unfair_lock_unlock(&s_container_map_lock);
        return (st == 1);
    }

    pt_maybe_init_test_group_root_locked();

    const char *test_data = pt_raw_getenv("PLAYTOOLS_TEST_DATA_CONTAINER");
    const char *raw_home = NULL;
    BOOL is_test_override = NO;
    if (test_data != NULL && test_data[0] != '\0') {
        raw_home = test_data;
        is_test_override = YES;
    } else {
        raw_home = pt_raw_getenv("CFFIXED_USER_HOME");
        if (raw_home == NULL || raw_home[0] == '\0') {
            raw_home = pt_raw_getenv("HOME");
        }
    }

    BOOL ready = NO;
    if ((is_test_override && raw_home[0] == '/') ||
        (raw_home != NULL && strstr(raw_home, "/Library/Containers/") != NULL)) {
        if (strncmp(raw_home, "/System/Volumes/Data/", 21) == 0) {
            raw_home += 20;
        }
        size_t home_len = strlen(raw_home);
        while (home_len > 1 && raw_home[home_len - 1] == '/') {
            home_len--;
        }
        if (home_len > 0 && home_len < sizeof(s_real_data_container_dir)) {
            memcpy(s_real_data_container_dir, raw_home, home_len);
            s_real_data_container_dir[home_len] = '\0';
            s_real_data_container_len = home_len;

            char real_tmp[PATH_MAX];
            snprintf(real_tmp, sizeof(real_tmp), "%s/tmp", s_real_data_container_dir);
            mkdir(real_tmp, 0755);

            char data_uuid[40];
            pt_format_deterministic_uuid(s_real_data_container_dir,
                                         0x517cc1b727220a95ULL,
                                         0x2545f4914f6cdd1dULL,
                                         data_uuid);

            snprintf(s_virtual_var_data_dir, sizeof(s_virtual_var_data_dir),
                     "/var/mobile/Containers/Data/Application/%s", data_uuid);
            s_virtual_var_data_len = strlen(s_virtual_var_data_dir);

            snprintf(s_virtual_private_data_dir, sizeof(s_virtual_private_data_dir),
                     "/private/var/mobile/Containers/Data/Application/%s", data_uuid);
            s_virtual_private_data_len = strlen(s_virtual_private_data_dir);

            snprintf(s_virtual_tmpdir, sizeof(s_virtual_tmpdir),
                     "%s/tmp/", s_virtual_private_data_dir);

            if (s_real_group_containers_root_len == 0) {
                const char *containers_marker = strstr(s_real_data_container_dir, "/Library/Containers/");
                if (containers_marker != NULL && containers_marker > s_real_data_container_dir) {
                    size_t prefix_len = (size_t)(containers_marker - s_real_data_container_dir);
                    int gn = snprintf(s_real_group_containers_root, sizeof(s_real_group_containers_root),
                                      "%.*s/Library/Group Containers",
                                      (int)prefix_len, s_real_data_container_dir);
                    if (gn > 0 && (size_t)gn < sizeof(s_real_group_containers_root)) {
                        s_real_group_containers_root_len = (size_t)gn;
                    }
                }
            }

            atomic_store_explicit(&s_data_map_state, 1, memory_order_release);
            ready = YES;
        }
    }
    os_unfair_lock_unlock(&s_container_map_lock);
    return ready;
}

static const pt_group_container_entry_t *pt_group_register_dir_locked(const char *real_group_dir) {
    if (real_group_dir == NULL || real_group_dir[0] != '/') {
        return NULL;
    }
    const char *p = real_group_dir;
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    size_t len = strlen(p);
    while (len > 1 && p[len - 1] == '/') {
        len--;
    }
    if (len <= 1 || len >= PATH_MAX) {
        return NULL;
    }
    for (size_t i = 0; i < s_group_map_count; i++) {
        if (s_group_map[i].real_len == len &&
            strncmp(s_group_map[i].real_dir, p, len) == 0) {
            return &s_group_map[i];
        }
    }
    if (s_group_map_count >= PT_MAX_GROUP_CONTAINERS) {
        return NULL;
    }
    pt_group_container_entry_t *entry = &s_group_map[s_group_map_count];
    memcpy(entry->real_dir, p, len);
    entry->real_dir[len] = '\0';
    entry->real_len = len;

    const char *slash = strrchr(entry->real_dir, '/');
    const char *group_id = (slash != NULL && slash[1] != '\0') ? (slash + 1) : entry->real_dir;
    pt_format_deterministic_uuid(group_id,
                                 0x94d049bb133111ebULL,
                                 0xbf58476d1ce4e5b9ULL,
                                 entry->uuid);

    snprintf(entry->virt_var, sizeof(entry->virt_var),
             "/var/mobile/Containers/Shared/AppGroup/%s", entry->uuid);
    entry->virt_var_len = strlen(entry->virt_var);

    snprintf(entry->virt_priv, sizeof(entry->virt_priv),
             "/private/var/mobile/Containers/Shared/AppGroup/%s", entry->uuid);
    entry->virt_priv_len = strlen(entry->virt_priv);

    s_group_map_count++;
    atomic_store_explicit(&s_group_map_nonempty, true, memory_order_release);
    return entry;
}

static const char *pt_group_format_virtual(const pt_group_container_entry_t *entry,
                                           const char *suffix,
                                           char *buf,
                                           size_t bufsize,
                                           BOOL use_private_prefix) {
    if (entry == NULL || buf == NULL || bufsize == 0) {
        return NULL;
    }
    const char *prefix = use_private_prefix ? entry->virt_priv : entry->virt_var;
    int n = snprintf(buf, bufsize, "%s%s", prefix, (suffix != NULL) ? suffix : "");
    return (n >= 0 && (size_t)n < bufsize) ? buf : NULL;
}

static const char *pt_group_match_candidate_locked(const char *cand,
                                                   char *buf,
                                                   size_t bufsize,
                                                   BOOL use_private_prefix) {
    if (cand == NULL || cand[0] != '/') {
        return NULL;
    }
    for (size_t i = 0; i < s_group_map_count; i++) {
        const pt_group_container_entry_t *e = &s_group_map[i];
        const char *suffix = pt_match_prefix_modulo_private(cand, e->real_dir, e->real_len);
        if (suffix != NULL) {
            return pt_group_format_virtual(e, suffix, buf, bufsize, use_private_prefix);
        }
    }
    if (s_real_group_containers_root_len > 0) {
        const char *sub = pt_match_prefix_modulo_private(cand, s_real_group_containers_root, s_real_group_containers_root_len);
        if (sub != NULL && sub[0] == '/') {
            const char *gid = sub + 1;
            if (gid[0] != '\0' && gid[0] != '/') {
                const char *slash = strchr(gid, '/');
                size_t gid_len = (slash != NULL) ? (size_t)(slash - gid) : strlen(gid);
                char group_dir[PATH_MAX];
                int n = snprintf(group_dir, sizeof(group_dir), "%s/%.*s",
                                 s_real_group_containers_root, (int)gid_len, gid);
                if (n > 0 && (size_t)n < sizeof(group_dir)) {
                    const pt_group_container_entry_t *entry = pt_group_register_dir_locked(group_dir);
                    if (entry != NULL) {
                        const char *suffix = (slash != NULL) ? slash : "";
                        return pt_group_format_virtual(entry, suffix, buf, bufsize, use_private_prefix);
                    }
                }
            }
        }
    }
    return NULL;
}

static const char *pt_group_try_virtualize_known_or_root(const char *p,
                                                        char *buf,
                                                        size_t bufsize,
                                                        BOOL use_private_prefix) {
    if (p == NULL || p[0] != '/' || buf == NULL || bufsize == 0) {
        return NULL;
    }
    if (strncmp(p, "/System/", 8) == 0 || strncmp(p, "/usr/", 5) == 0 || strncmp(p, "/dev/", 5) == 0) {
        return NULL;
    }
    BOOL has_known = atomic_load_explicit(&s_group_map_nonempty, memory_order_acquire);
    if (!has_known) {
        if (s_real_group_containers_root_len == 0 ||
            pt_match_prefix_modulo_private(p, s_real_group_containers_root, s_real_group_containers_root_len) == NULL) {
            return NULL;
        }
    }
    os_unfair_lock_lock(&s_group_map_lock);
    const char *res = pt_group_match_candidate_locked(p, buf, bufsize, use_private_prefix);
    if (res == NULL && strncmp(p, "/private/", 9) == 0) {
        res = pt_group_match_candidate_locked(p + 8, buf, bufsize, use_private_prefix);
    }
    os_unfair_lock_unlock(&s_group_map_lock);
    return res;
}

static void pt_scan_group_containers_root_locked(void) {
    if (s_group_root_scanned || s_real_group_containers_root_len == 0) {
        return;
    }
    s_group_root_scanned = YES;
    DIR *dirp = opendir(s_real_group_containers_root);
    if (dirp == NULL) {
        return;
    }
    struct dirent *ent = NULL;
    while ((ent = readdir(dirp)) != NULL) {
        if (ent->d_name[0] == '.') {
            continue;
        }
        if (ent->d_type != DT_DIR && ent->d_type != DT_UNKNOWN && ent->d_type != DT_LNK) {
            continue;
        }
        char child[PATH_MAX];
        int n = snprintf(child, sizeof(child), "%s/%s", s_real_group_containers_root, ent->d_name);
        if (n > 0 && (size_t)n < sizeof(child)) {
            if (ent->d_type == DT_UNKNOWN) {
                struct stat st;
                if (stat(child, &st) != 0 || !S_ISDIR(st.st_mode)) {
                    continue;
                }
            }
            pt_group_register_dir_locked(child);
        }
    }
    closedir(dirp);
}

static BOOL pt_lookup_virtual_group_container(const char *work,
                                              char *out_real_dir,
                                              size_t out_real_dir_size,
                                              const char **out_suffix) {
    if (work == NULL) {
        return NO;
    }
    BOOL is_priv = (strncasecmp(work, "/private/var/mobile/Containers/Shared/AppGroup/", 47) == 0);
    BOOL is_var = (!is_priv && strncasecmp(work, "/var/mobile/Containers/Shared/AppGroup/", 39) == 0);
    if (!is_priv && !is_var) {
        return NO;
    }

    os_unfair_lock_lock(&s_group_map_lock);
    for (int pass = 0; pass < 2; pass++) {
        for (size_t i = 0; i < s_group_map_count; i++) {
            const pt_group_container_entry_t *e = &s_group_map[i];
            const char *vprefix = is_priv ? e->virt_priv : e->virt_var;
            size_t vlen = is_priv ? e->virt_priv_len : e->virt_var_len;
            if (strncasecmp(work, vprefix, vlen) == 0 &&
                (work[vlen] == '/' || work[vlen] == '\0')) {
                if (out_real_dir != NULL && out_real_dir_size > 0) {
                    strlcpy(out_real_dir, e->real_dir, out_real_dir_size);
                }
                if (out_suffix != NULL) {
                    *out_suffix = work + vlen;
                }
                os_unfair_lock_unlock(&s_group_map_lock);
                return YES;
            }
        }
        if (pass == 0 && !s_group_root_scanned && s_real_group_containers_root_len > 0) {
            pt_scan_group_containers_root_locked();
        } else {
            break;
        }
    }
    os_unfair_lock_unlock(&s_group_map_lock);
    return NO;
}

__attribute__((visibility("hidden")))
const char *pt_register_and_virtualize_group_container(const char *real_group_path,
                                                       char *buf,
                                                       size_t bufsize,
                                                       BOOL use_private_prefix) {
    if (real_group_path == NULL || real_group_path[0] == '\0' || buf == NULL || bufsize == 0) {
        return real_group_path;
    }
    pt_ensure_data_container_map();

    char lex_buf[PATH_MAX];
    const char *p = real_group_path;
    if (p[0] == '/' && pt_needs_lexical_norm(p)) {
        const char *collapsed = pt_normalize_lexical_path(p, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            p = collapsed;
        }
    }
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    size_t len = strlen(p);
    while (len > 1 && p[len - 1] == '/') {
        len--;
    }
    if (p[0] != '/' || len <= 1 || len >= PATH_MAX) {
        return real_group_path;
    }
    char clean[PATH_MAX];
    memcpy(clean, p, len);
    clean[len] = '\0';

    const char *existing = pt_group_try_virtualize_known_or_root(clean, buf, bufsize, use_private_prefix);
    if (existing != NULL) {
        return existing;
    }

    os_unfair_lock_lock(&s_group_map_lock);
    const pt_group_container_entry_t *entry = pt_group_register_dir_locked(clean);
    const char *virt = pt_group_format_virtual(entry, "", buf, bufsize, use_private_prefix);
    os_unfair_lock_unlock(&s_group_map_lock);
    return (virt != NULL) ? virt : real_group_path;
}

__attribute__((visibility("hidden")))
const char *pt_get_virtual_home_cstr(void) {
    if (!pt_ensure_data_container_map()) {
        return NULL;
    }
    return (s_real_data_container_len > 0) ? s_virtual_var_data_dir : NULL;
}

__attribute__((visibility("hidden")))
const char *pt_get_virtual_tmpdir_cstr(void) {
    if (!pt_ensure_data_container_map()) {
        return NULL;
    }
    return (s_real_data_container_len > 0) ? s_virtual_tmpdir : NULL;
}

static BOOL pt_is_clean_virtual_ancestor_dir(const char *p) {
    if (p == NULL || p[0] != '/') {
        return NO;
    }
    if (strncasecmp(p, "/private/", 9) == 0) {
        p += 8;
    }
    if (strncasecmp(p, "/var/", 5) != 0) {
        return NO;
    }
    size_t len = strlen(p);
    while (len > 1 && p[len - 1] == '/') {
        len--;
    }
    if (len >= 128) {
        return NO;
    }
    char clean[128];
    memcpy(clean, p, len);
    clean[len] = '\0';

    if (strcasecmp(clean, "/var/mobile") == 0 ||
        strcasecmp(clean, "/var/mobile/Containers") == 0 ||
        strcasecmp(clean, "/var/mobile/Containers/Data") == 0 ||
        strcasecmp(clean, "/var/mobile/Containers/Data/Application") == 0 ||
        strcasecmp(clean, "/var/mobile/Containers/Shared") == 0 ||
        strcasecmp(clean, "/var/mobile/Containers/Shared/AppGroup") == 0 ||
        strcasecmp(clean, "/var/containers") == 0 ||
        strcasecmp(clean, "/var/containers/Bundle") == 0 ||
        strcasecmp(clean, "/var/containers/Bundle/Application") == 0) {
        return YES;
    }
    if (strncasecmp(clean, "/var/containers/Bundle/Application/", 35) == 0) {
        pt_ensure_bundle_path_map();
        if (s_virtual_bundle_uuid_parent_var[0] != '\0' &&
            strcasecmp(clean, s_virtual_bundle_uuid_parent_var) == 0) {
            return YES;
        }
    }
    return NO;
}

__attribute__((visibility("hidden")))
BOOL pt_is_virtual_container_ancestor_dir(const char *path) {
    if (path == NULL || path[0] != '/') {
        return NO;
    }
    char lex_buf[PATH_MAX];
    const char *p = path;
    if (pt_needs_lexical_norm(p)) {
        const char *collapsed = pt_normalize_lexical_path(p, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            p = collapsed;
        }
    }
    return pt_is_clean_virtual_ancestor_dir(p);
}

static _Atomic bool s_has_synth_sysver = false;
static os_unfair_lock s_synth_sysver_lock = OS_UNFAIR_LOCK_INIT;
static char s_synth_sysver_path[PATH_MAX] = {0};
static char s_synth_sysver_ver[32] = {0};
static char s_synth_sysver_build[32] = {0};
static dev_t s_synth_sysver_dev = 0;
static ino_t s_synth_sysver_ino = 0;

__attribute__((visibility("hidden"))) BOOL pt_is_synth_system_version_path(const char *p) {
    if (p == NULL || !atomic_load_explicit(&s_has_synth_sysver, memory_order_acquire) ||
        strstr(p, ".pt_sysver_") == NULL) {
        return NO;
    }
    BOOL match = NO;
    os_unfair_lock_lock(&s_synth_sysver_lock);
    if (s_synth_sysver_path[0] != '\0') {
        const char *rem = pt_match_prefix_modulo_private(p, s_synth_sysver_path, strlen(s_synth_sysver_path));
        match = (rem != NULL && rem[0] == '\0');
    }
    os_unfair_lock_unlock(&s_synth_sysver_lock);
    return match;
}

__attribute__((visibility("hidden"))) BOOL pt_is_synth_system_version_stat(dev_t dev, ino_t ino) {
    if (!atomic_load_explicit(&s_has_synth_sysver, memory_order_acquire) || ino == 0) {
        return NO;
    }
    BOOL match = NO;
    os_unfair_lock_lock(&s_synth_sysver_lock);
    match = (s_synth_sysver_path[0] != '\0' &&
             dev == s_synth_sysver_dev &&
             ino == s_synth_sysver_ino);
    os_unfair_lock_unlock(&s_synth_sysver_lock);
    return match;
}

__attribute__((visibility("hidden"))) void pt_normalize_synth_sysver_stat(struct stat *buf) {
    if (buf == NULL) {
        return;
    }
    static dev_t s_root_dev = 0;
    static dispatch_once_t s_root_once;
    dispatch_once(&s_root_once, ^{
        struct stat rst;
        if (stat("/", &rst) == 0) {
            s_root_dev = rst.st_dev;
        }
    });
    buf->st_uid = 0;
    buf->st_gid = 0;
    buf->st_mode = (buf->st_mode & ~(mode_t)07777) | (mode_t)0444;
    if (s_root_dev != 0) {
        buf->st_dev = s_root_dev;
    }
}

static BOOL pt_collapse_macos_framework_versions_in_place(char *work, size_t cap) {
    return pt_collapse_macos_framework_versions_in_place_cstr(work, cap) ? YES : NO;
}

__attribute__((visibility("hidden")))
const char *pt_virtualize_path_for_app(const char *path, char *buf, size_t bufsize, BOOL use_private_prefix) {
    if (path == NULL || buf == NULL || bufsize == 0) {
        return path;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    const char *p = path;
    if (strncasecmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    if (strncasecmp(p, "/System/iOSSupport/", 19) == 0) {
        p += 18;
    }
    if (pt_is_synth_system_version_path(p)) {
        size_t n = strlcpy(buf, "/System/Library/CoreServices/SystemVersion.plist", bufsize);
        return (n < bufsize) ? buf : path;
    }
    if (pt_is_synth_code_resources_path(p)) {
        const char *bprefix = use_private_prefix ? s_virtual_private_bundle_dir : s_virtual_var_bundle_dir;
        size_t bplen = use_private_prefix ? s_virtual_private_bundle_len : s_virtual_var_bundle_len;
        if (bplen > 0) {
            const char *joined = pt_join_path_fast(buf, bufsize, bprefix, bplen, "/_CodeSignature/CodeResources");
            if (joined != NULL) {
                return joined;
            }
        }
    }
    if (pt_is_synth_info_plist_path(p)) {
        const char *bprefix = use_private_prefix ? s_virtual_private_bundle_dir : s_virtual_var_bundle_dir;
        size_t bplen = use_private_prefix ? s_virtual_private_bundle_len : s_virtual_var_bundle_len;
        if (bplen > 0) {
            const char *joined = pt_join_path_fast(buf, bufsize, bprefix, bplen, "/Info.plist");
            if (joined != NULL) {
                return joined;
            }
        }
    }
    if (s_real_data_container_len > 0) {
        const char *suffix = pt_match_prefix_modulo_private(p, s_real_data_container_dir, s_real_data_container_len);
        if (suffix != NULL) {
            const char *prefix = use_private_prefix ? s_virtual_private_data_dir : s_virtual_var_data_dir;
            size_t plen = use_private_prefix ? s_virtual_private_data_len : s_virtual_var_data_len;
            const char *joined = pt_join_path_fast(buf, bufsize, prefix, plen, suffix);
            return (joined != NULL) ? joined : path;
        }
    }
    if (s_real_app_bundle_len > 0) {
        const char *suffix = pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, s_real_app_bundle_len);
        if (suffix != NULL) {
            const char *prefix = use_private_prefix ? s_virtual_private_bundle_dir : s_virtual_var_bundle_dir;
            size_t plen = use_private_prefix ? s_virtual_private_bundle_len : s_virtual_var_bundle_len;
            const char *joined = pt_join_path_fast(buf, bufsize, prefix, plen, suffix);
            return (joined != NULL) ? joined : path;
        }
    }
    const char *backup_virt = pt_virtualize_app_backup_path(p, buf, bufsize, use_private_prefix);
    if (backup_virt != NULL) {
        return backup_virt;
    }
    const char *group_virt = pt_group_try_virtualize_known_or_root(p, buf, bufsize, use_private_prefix);
    if (group_virt != NULL) {
        return group_virt;
    }
    if (strcasecmp(p, "/System/Library/CoreServices/iOSSystemVersion.plist") == 0) {
        size_t n = strlcpy(buf, "/System/Library/CoreServices/SystemVersion.plist", bufsize);
        return (n < bufsize) ? buf : path;
    }
    if (strncasecmp(p, "/System/", 8) == 0 || strncasecmp(p, "/Library/", 9) == 0) {
        size_t plen = strlen(p);
        if (plen < bufsize) {
            memcpy(buf, p, plen + 1U);
            if (pt_collapse_macos_framework_versions_in_place(buf, bufsize) || p != path) {
                return buf;
            }
            return path;
        }
    }
    if (p != path) {
        size_t n = strlcpy(buf, p, bufsize);
        return (n < bufsize) ? buf : path;
    }
    return path;
}

__attribute__((visibility("hidden"))) BOOL pt_is_sensitive_host_fd_path(const char *path, const void *caller) {
    if (path == NULL || path[0] == '\0' || !pt_is_bypass_enabled()) {
        return NO;
    }
    const char *p = path;
    if (strncasecmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    if (strncasecmp(p, "/System/iOSSupport/System/Library/", 34) == 0 ||
        strncasecmp(p, "/System/iOSSupport/usr/", 23) == 0) {
        p += 18;
    }
    if (pt_is_active_app_backup_file_path(p) ||
        pt_is_synth_system_version_path(p) ||
        pt_is_synth_code_resources_path(p) ||
        pt_is_synth_info_plist_path(p) ||
        strcasecmp(p, "/System/Library/CoreServices/iOSSystemVersion.plist") == 0) {
        return NO;
    }
    int is_sys_caller = -1;
    if (pt_is_hidden_normalized_path_cached_caller(p, caller, &is_sys_caller)) {
        return YES;
    }
    if (pt_is_hidden_dyld_image_name(p)) {
        return YES;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    if (s_real_data_container_len > 0 &&
        pt_match_prefix_modulo_private(p, s_real_data_container_dir, s_real_data_container_len) != NULL) {
        return NO;
    }
    if (s_real_app_bundle_len > 0 &&
        pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) {
        return NO;
    }
    if (strncasecmp(p, "/Library/Application Support/MacOver", 36) == 0 ||
        strncasecmp(p, "/Library/Application Support/PlayCover", 38) == 0 ||
        strcasestr(p, "/Library/Containers/app.makedie.") != NULL ||
        strcasestr(p, "/Library/Preferences/app.makedie.") != NULL ||
        strcasestr(p, "/Library/Containers/io.playcover.") != NULL ||
        strcasestr(p, "/Library/Preferences/io.playcover.") != NULL) {
        return YES;
    }
    const char *user_root = pt_get_host_user_root_cstr();
    if (user_root != NULL) {
        size_t ur_len = strlen(user_root);
        if (ur_len > 1 && strncasecmp(p, user_root, ur_len) == 0 && (p[ur_len] == '/' || p[ur_len] == '\0')) {
            char tmp[PATH_MAX];
            if (pt_group_try_virtualize_known_or_root(p, tmp, sizeof(tmp), YES) != NULL) {
                return NO;
            }
            return YES;
        }
    }
    return NO;
}

// Lock-free write-once fast cache for immortal dyld image string pointers (zero TLV / zero lock on hit).
static _Atomic(const char *) s_img_fast_keys[256];
static _Atomic(const char *) s_img_fast_vals[256];

static inline void pt_img_fast_cache_try_publish(size_t slot, const char *raw_path, const char *sanitized) {
    if (raw_path == NULL || raw_path == (const char *)1 || sanitized == NULL) {
        return;
    }
    const char *expected = NULL;
    if (atomic_compare_exchange_strong_explicit(&s_img_fast_keys[slot],
                                                &expected,
                                                (const char *)1,
                                                memory_order_acq_rel,
                                                memory_order_relaxed)) {
        atomic_store_explicit(&s_img_fast_vals[slot], sanitized, memory_order_relaxed);
        atomic_store_explicit(&s_img_fast_keys[slot], raw_path, memory_order_release);
    }
}

static const char *pt_sanitize_image_path_internal(const char *raw_path, BOOL allow_ptr_cache) {
    if (raw_path == NULL) {
        return NULL;
    }
    uintptr_t raw_u = (uintptr_t)raw_path;
    size_t fast_slot = (size_t)(((raw_u >> 3) ^ (raw_u >> 12)) & 255U);
    if (allow_ptr_cache) {
        const char *k = atomic_load_explicit(&s_img_fast_keys[fast_slot], memory_order_acquire);
        if (k == raw_path) {
            return atomic_load_explicit(&s_img_fast_vals[fast_slot], memory_order_relaxed);
        }
    }

    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();

    if (allow_ptr_cache) {
        os_unfair_lock_lock(&s_image_path_lock);
        if (s_image_path_ptr_cache != NULL) {
            const void *cached = CFDictionaryGetValue(s_image_path_ptr_cache, raw_path);
            if (cached != NULL) {
                os_unfair_lock_unlock(&s_image_path_lock);
                pt_img_fast_cache_try_publish(fast_slot, raw_path, (const char *)cached);
                return (const char *)cached;
            }
        }
        os_unfair_lock_unlock(&s_image_path_lock);
    }

    const char *p = raw_path;
    for (int pass = 0; pass < 4; pass++) {
        if (strncmp(p, "/System/Volumes/Preboot/Cryptexes/OS/", 37) == 0) {
            p += 36;
        } else if (strncmp(p, "/System/Cryptexes/OS/", 21) == 0) {
            p += 20;
        } else if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
            p += 20;
        } else if (strncmp(p, "/System/iOSSupport/", 19) == 0) {
            p += 18;
        } else {
            break;
        }
    }

    char transformed[PATH_MAX];
    const char *candidate = p;

    const char *bundle_suf = (s_real_app_bundle_len > 0) ? pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, s_real_app_bundle_len) : NULL;
    const char *data_suf = (bundle_suf == NULL && s_real_data_container_len > 0) ? pt_match_prefix_modulo_private(p, s_real_data_container_dir, s_real_data_container_len) : NULL;
    if (bundle_suf != NULL) {
        int n = snprintf(transformed, sizeof(transformed), "%s%s",
                         s_virtual_private_bundle_dir, bundle_suf);
        if (n >= 0 && (size_t)n < sizeof(transformed)) {
            candidate = transformed;
        }
    } else if (data_suf != NULL) {
        int n = snprintf(transformed, sizeof(transformed), "%s%s",
                         s_virtual_private_data_dir, data_suf);
        if (n >= 0 && (size_t)n < sizeof(transformed)) {
            candidate = transformed;
        }
    } else if ((strncmp(p, "/System/", 8) == 0 || strncmp(p, "/Library/", 9) == 0)) {
        size_t plen = strlen(p);
        if (plen < sizeof(transformed)) {
            char work[PATH_MAX];
            memcpy(work, p, plen + 1U);
            if (pt_collapse_macos_framework_versions_in_place(work, sizeof(work))) {
                memcpy(transformed, work, strlen(work) + 1U);
                candidate = transformed;
            }
        }
    } else {
        const char *group_virt = pt_group_try_virtualize_known_or_root(p, transformed, sizeof(transformed), YES);
        if (group_virt != NULL) {
            candidate = group_virt;
        }
    }

    os_unfair_lock_lock(&s_image_path_lock);
    if (s_image_path_ptr_cache == NULL) {
        s_image_path_ptr_cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        s_image_path_str_cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
    }
    const char *interned = NULL;
    if (candidate == raw_path && allow_ptr_cache) {
        interned = raw_path;
    } else {
        CFStringRef keyRef = CFStringCreateWithCString(kCFAllocatorDefault, candidate, kCFStringEncodingUTF8);
        if (keyRef != NULL) {
            const void *existing = CFDictionaryGetValue(s_image_path_str_cache, keyRef);
            if (existing != NULL) {
                interned = (const char *)existing;
            } else if (CFDictionaryGetCount(s_image_path_str_cache) < 4096) {
                char *dup = strdup(candidate);
                if (dup != NULL) {
                    CFDictionarySetValue(s_image_path_str_cache, keyRef, dup);
                    interned = dup;
                }
            }
            CFRelease(keyRef);
        }
        if (interned == NULL) {
            interned = allow_ptr_cache ? p : raw_path;
        }
    }
    if (allow_ptr_cache && CFDictionaryGetCount(s_image_path_ptr_cache) < 4096) {
        CFDictionarySetValue(s_image_path_ptr_cache, raw_path, interned);
        pt_img_fast_cache_try_publish(fast_slot, raw_path, interned);
    }
    os_unfair_lock_unlock(&s_image_path_lock);
    return interned;
}

__attribute__((visibility("hidden")))
const char *pt_sanitize_image_path_for_app(const char *raw_path) {
    return pt_sanitize_image_path_internal(raw_path, YES);
}

__attribute__((visibility("hidden")))
const char *pt_sanitize_image_path_for_cstr(const char *raw_path) {
    return pt_sanitize_image_path_internal(raw_path, NO);
}

__attribute__((visibility("hidden")))
BOOL pt_is_virtual_container_path(const char *path) {
    if (path == NULL || path[0] != '/') {
        return NO;
    }
    char lex_buf[PATH_MAX];
    const char *work = path;
    if (pt_needs_lexical_norm(work)) {
        const char *collapsed = pt_normalize_lexical_path(work, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            work = collapsed;
        }
    }
    if (strncasecmp(work, "/var/", 5) != 0 && strncasecmp(work, "/private/var/", 13) != 0) {
        return NO;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    if (s_real_data_container_len > 0) {
        if (s_virtual_var_data_len > 0 &&
            strncasecmp(work, s_virtual_var_data_dir, s_virtual_var_data_len) == 0 &&
            (work[s_virtual_var_data_len] == '/' || work[s_virtual_var_data_len] == '\0')) {
            return YES;
        }
        if (s_virtual_private_data_len > 0 &&
            strncasecmp(work, s_virtual_private_data_dir, s_virtual_private_data_len) == 0 &&
            (work[s_virtual_private_data_len] == '/' || work[s_virtual_private_data_len] == '\0')) {
            return YES;
        }
    }
    if (s_real_app_bundle_len > 0) {
        if (s_virtual_private_bundle_len > 0 &&
            strncasecmp(work, s_virtual_private_bundle_dir, s_virtual_private_bundle_len) == 0 &&
            (work[s_virtual_private_bundle_len] == '/' || work[s_virtual_private_bundle_len] == '\0')) {
            return YES;
        }
        if (s_virtual_var_bundle_len > 0 &&
            strncasecmp(work, s_virtual_var_bundle_dir, s_virtual_var_bundle_len) == 0 &&
            (work[s_virtual_var_bundle_len] == '/' || work[s_virtual_var_bundle_len] == '\0')) {
            return YES;
        }
    }
    if (pt_lookup_virtual_group_container(work, NULL, 0, NULL)) {
        return YES;
    }
    return NO;
}

static const char *pt_try_map_clean_virtual_container_path(const char *work, char *buf, size_t bufsize) {
    if (work == NULL || buf == NULL || bufsize == 0) {
        return NULL;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    if (s_real_data_container_len > 0) {
        if (s_virtual_var_data_len > 0 &&
            strncasecmp(work, s_virtual_var_data_dir, s_virtual_var_data_len) == 0 &&
            (work[s_virtual_var_data_len] == '/' || work[s_virtual_var_data_len] == '\0')) {
            return pt_join_path_fast(buf, bufsize, s_real_data_container_dir, s_real_data_container_len, work + s_virtual_var_data_len);
        }
        if (s_virtual_private_data_len > 0 &&
            strncasecmp(work, s_virtual_private_data_dir, s_virtual_private_data_len) == 0 &&
            (work[s_virtual_private_data_len] == '/' || work[s_virtual_private_data_len] == '\0')) {
            return pt_join_path_fast(buf, bufsize, s_real_data_container_dir, s_real_data_container_len, work + s_virtual_private_data_len);
        }
    }
    if (s_real_app_bundle_len > 0) {
        const char *bundle_rel = NULL;
        if (s_virtual_private_bundle_len > 0 &&
            strncasecmp(work, s_virtual_private_bundle_dir, s_virtual_private_bundle_len) == 0 &&
            (work[s_virtual_private_bundle_len] == '/' || work[s_virtual_private_bundle_len] == '\0')) {
            bundle_rel = work + s_virtual_private_bundle_len;
        } else if (s_virtual_var_bundle_len > 0 &&
                   strncasecmp(work, s_virtual_var_bundle_dir, s_virtual_var_bundle_len) == 0 &&
                   (work[s_virtual_var_bundle_len] == '/' || work[s_virtual_var_bundle_len] == '\0')) {
            bundle_rel = work + s_virtual_var_bundle_len;
        }
        if (bundle_rel != NULL) {
            if (s_app_info_plist_in_contents && strcasecmp(bundle_rel, "/Info.plist") == 0) {
                return pt_join_path_fast(buf, bufsize, s_real_app_bundle_dir, s_real_app_bundle_len, "/Contents/Info.plist");
            }
            return pt_join_path_fast(buf, bufsize, s_real_app_bundle_dir, s_real_app_bundle_len, bundle_rel);
        }
    }
    char real_group_dir[PATH_MAX];
    const char *suffix = NULL;
    if (pt_lookup_virtual_group_container(work, real_group_dir, sizeof(real_group_dir), &suffix)) {
        int n = snprintf(buf, bufsize, "%s%s", real_group_dir, (suffix != NULL) ? suffix : "");
        return (n >= 0 && (size_t)n < bufsize) ? buf : NULL;
    }
    return NULL;
}

__attribute__((visibility("hidden"))) BOOL pt_is_reverse_mapped_iossupport(const char *orig_path, const char *resolved_path) {
    if (orig_path == NULL || resolved_path == NULL || orig_path == resolved_path) {
        return NO;
    }
    return (strncasecmp(resolved_path, "/System/iOSSupport/System/Library/", 34) == 0 &&
            strncasecmp(orig_path, "/System/iOSSupport", 18) != 0);
}

__attribute__((visibility("hidden")))
const char *pt_resolve_virtual_path(const char *path, char *buf, size_t bufsize) {
    if (path == NULL || buf == NULL || bufsize == 0 || path[0] != '/') {
        return path;
    }
    char lex_buf[PATH_MAX];
    const char *work = path;
    BOOL was_normalized = NO;
    if (pt_needs_lexical_norm(work)) {
        const char *collapsed = pt_normalize_lexical_path(work, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            work = collapsed;
            was_normalized = YES;
        }
    }
    if (strncasecmp(work, "/var/", 5) == 0 || strncasecmp(work, "/private/var/", 13) == 0) {
        const char *mapped = pt_try_map_clean_virtual_container_path(work, buf, bufsize);
        if (mapped != NULL) {
            return mapped;
        }
        if (was_normalized && pt_is_clean_virtual_ancestor_dir(work)) {
            size_t wlen = strlen(work);
            if (wlen < bufsize) {
                memcpy(buf, work, wlen + 1);
                return buf;
            }
        }
        return path;
    }
    if ((strncasecmp(work, "/System/Library/Frameworks/", 27) == 0 ||
         strncasecmp(work, "/System/Library/PrivateFrameworks/", 34) == 0) &&
        access(work, F_OK) != 0) {
        int n = snprintf(buf, bufsize, "/System/iOSSupport%s", work);
        if (n > 0 && (size_t)n < bufsize && access(buf, F_OK) == 0) {
            return buf;
        }
    }
    return path;
}

__attribute__((visibility("hidden")))
const char *pt_resolve_virtual_bundle_path(const char *path, char *buf, size_t bufsize) {
    return pt_resolve_virtual_path(path, buf, bufsize);
}


__attribute__((visibility("hidden"))) _Atomic uint8_t ue_status = 0;

__attribute__((visibility("hidden"))) const char *pt_fs_ue_fix_filename(const char *filename) {
    if (filename == NULL || atomic_load_explicit(&ue_status, memory_order_relaxed) != 2) {
        return filename;
    }
    static char UE_PATTERN[1024] = "//Users/";
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8);
    });
    char const* p = filename;
    char const* last_p = p;
    while ((p = strstr(p, UE_PATTERN))) {
        last_p = ++p;
    }
    return last_p;
}

__attribute__((visibility("hidden"))) BOOL pt_fd_is_sensitive(int fd, const void *caller) {
    if (fd < 0 || !pt_is_bypass_enabled()) {
        return NO;
    }
    if (pt_is_effective_system_or_playtools_caller(caller)) {
        return NO;
    }
    int saved_errno = errno;
    char fd_path[PATH_MAX];
    if (fcntl(fd, F_GETPATH, fd_path) == -1) {
        errno = saved_errno;
        return NO;
    }
    BOOL sens = pt_is_sensitive_host_fd_path(fd_path, caller);
    errno = saved_errno;
    return sens;
}

static size_t pt_count_path_components(const char *p) {
    size_t count = 0;
    if (p == NULL) {
        return 0;
    }
    while (*p != '\0') {
        while (*p == '/') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        count++;
        while (*p != '\0' && *p != '/') {
            p++;
        }
    }
    return count;
}

static const char *pt_strip_private_vol_prefix(const char *p) {
    if (p == NULL) {
        return NULL;
    }
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    if (strncmp(p, "/private/", 9) == 0) {
        p += 8;
    }
    return p;
}

static void pt_compute_escaped_virtual_ancestor(const char *real_base,
                                                const char *virt_base,
                                                const char *norm_work,
                                                char *vbuf,
                                                size_t vbuf_size) {
    if (vbuf == NULL || vbuf_size == 0) {
        return;
    }
    const char *rb = pt_strip_private_vol_prefix(real_base);
    const char *nw = pt_strip_private_vol_prefix(norm_work);
    size_t common = 0;
    if (rb != NULL && nw != NULL) {
        size_t i = 0;
        while (rb[i] != '\0' && nw[i] != '\0' && rb[i] == nw[i]) {
            if (rb[i] == '/' && i > 0) {
                common = i;
            }
            i++;
        }
        if (rb[i] == '\0' && (nw[i] == '/' || nw[i] == '\0')) {
            common = i;
        } else if (nw[i] == '\0' && (rb[i] == '/' || rb[i] == '\0')) {
            common = i;
        }
    }
    size_t up_levels = (rb != NULL && common < strlen(rb)) ? pt_count_path_components(rb + common) : 1;
    if (up_levels == 0) {
        up_levels = 1;
    }
    strlcpy(vbuf, virt_base, vbuf_size);
    for (size_t k = 0; k < up_levels; k++) {
        char *slash = strrchr(vbuf, '/');
        if (slash == NULL || slash <= vbuf + 12) { // keep at least "/private/var"
            break;
        }
        *slash = '\0';
    }
}

static _Atomic int s_has_ios_sysver_plist = -1;

static BOOL pt_has_ios_system_version_plist(void) {
    int cached = atomic_load_explicit(&s_has_ios_sysver_plist, memory_order_acquire);
    if (cached >= 0) {
        return cached == 1;
    }
    BOOL exists = (access("/System/Library/CoreServices/iOSSystemVersion.plist", F_OK) == 0);
    atomic_store_explicit(&s_has_ios_sysver_plist, exists ? 1 : 0, memory_order_release);
    return exists;
}

static BOOL pt_write_all_fd(int fd, const char *data, size_t len) {
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, data + written, len - written);
        if (n > 0) {
            written += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            return NO;
        }
    }
    return YES;
}

static BOOL pt_ensure_synthesized_system_version_plist(const char *ver,
                                                       const char *build,
                                                       char *out_buf,
                                                       size_t out_cap) {
    if (ver == NULL || ver[0] == '\0' || build == NULL || build[0] == '\0' ||
        out_buf == NULL || out_cap == 0) {
        return NO;
    }

    os_unfair_lock_lock(&s_synth_sysver_lock);
    if (s_synth_sysver_path[0] != '\0' &&
        strcmp(s_synth_sysver_ver, ver) == 0 &&
        strcmp(s_synth_sysver_build, build) == 0) {
        pt_enter_internal_scope();
        struct stat st;
        BOOL alive = (stat(s_synth_sysver_path, &st) == 0 &&
                      st.st_dev == s_synth_sysver_dev &&
                      st.st_ino == s_synth_sysver_ino);
        pt_leave_internal_scope();
        if (alive) {
            size_t n = strlcpy(out_buf, s_synth_sysver_path, out_cap);
            os_unfair_lock_unlock(&s_synth_sysver_lock);
            return n < out_cap;
        }
    }

    const char *copyright = pt_is_compat13_7_active() ? "1983-2020 Apple Inc." : "1983-2025 Apple Inc.";
    char xml[1024];
    int xml_len = snprintf(xml, sizeof(xml),
                           "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                           "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
                           "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                           "<plist version=\"1.0\">\n"
                           "<dict>\n"
                           "\t<key>ProductBuildVersion</key>\n"
                           "\t<string>%s</string>\n"
                           "\t<key>ProductCopyright</key>\n"
                           "\t<string>%s</string>\n"
                           "\t<key>ProductName</key>\n"
                           "\t<string>iPhone OS</string>\n"
                           "\t<key>ProductUserVisibleVersion</key>\n"
                           "\t<string>%s</string>\n"
                           "\t<key>ProductVersion</key>\n"
                           "\t<string>%s</string>\n"
                           "</dict>\n"
                           "</plist>\n",
                           build, copyright, ver, ver);
    if (xml_len <= 0 || (size_t)xml_len >= sizeof(xml)) {
        os_unfair_lock_unlock(&s_synth_sysver_lock);
        return NO;
    }

    pt_ensure_data_container_map();
    char container_tmp[PATH_MAX];
    const char *dirs[3] = { NULL, NULL, "/tmp" };
    if (s_real_data_container_len > 0) {
        int dn = snprintf(container_tmp, sizeof(container_tmp), "%s/tmp", s_real_data_container_dir);
        if (dn > 0 && (size_t)dn < sizeof(container_tmp)) {
            dirs[0] = container_tmp;
        }
    }
    const char *env_tmp = pt_raw_getenv("TMPDIR");
    char env_tmp_buf[PATH_MAX];
    if (env_tmp != NULL && env_tmp[0] == '/') {
        strlcpy(env_tmp_buf, env_tmp, sizeof(env_tmp_buf));
        size_t elen = strlen(env_tmp_buf);
        while (elen > 1 && env_tmp_buf[elen - 1] == '/') {
            env_tmp_buf[--elen] = '\0';
        }
        dirs[1] = env_tmp_buf;
    }

    BOOL ok = NO;
    char chosen_path[PATH_MAX] = {0};
    struct stat chosen_st;
    memset(&chosen_st, 0, sizeof(chosen_st));
    pid_t pid = getpid();

    pt_enter_internal_scope();
    for (size_t i = 0; i < 3 && !ok; i++) {
        const char *dir = dirs[i];
        if (dir == NULL || dir[0] != '/') {
            continue;
        }
        if (i == 0) {
            (void)mkdir(dir, 0700);
        }
        char target[PATH_MAX];
        char staging[PATH_MAX];
        int tn = snprintf(target, sizeof(target), "%s/.pt_sysver_%d_%s_%s.plist",
                          dir, (int)pid, ver, build);
        int sn = snprintf(staging, sizeof(staging), "%s/.pt_sysver_%d_tmp.plist",
                          dir, (int)pid);
        if (tn <= 0 || (size_t)tn >= sizeof(target) ||
            sn <= 0 || (size_t)sn >= sizeof(staging)) {
            continue;
        }
        int fd = pt_orig_open_nocancel(staging, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) {
            continue;
        }
        BOOL wrote = pt_write_all_fd(fd, xml, (size_t)xml_len);
        (void)fchmod(fd, 0444);
        (void)close(fd);
        if (wrote && rename(staging, target) == 0 && stat(target, &chosen_st) == 0) {
            strlcpy(chosen_path, target, sizeof(chosen_path));
            ok = YES;
        } else {
            (void)unlink(staging);
        }
    }
    pt_leave_internal_scope();

    if (ok) {
        strlcpy(s_synth_sysver_path, chosen_path, sizeof(s_synth_sysver_path));
        strlcpy(s_synth_sysver_ver, ver, sizeof(s_synth_sysver_ver));
        strlcpy(s_synth_sysver_build, build, sizeof(s_synth_sysver_build));
        s_synth_sysver_dev = chosen_st.st_dev;
        s_synth_sysver_ino = chosen_st.st_ino;
        atomic_store_explicit(&s_has_synth_sysver, 1, memory_order_release);
        size_t n = strlcpy(out_buf, s_synth_sysver_path, out_cap);
        os_unfair_lock_unlock(&s_synth_sysver_lock);
        return n < out_cap;
    }
    os_unfair_lock_unlock(&s_synth_sysver_lock);
    return NO;
}

static pt_fs_path_disposition_t pt_prepare_fs_path_abs_cached_caller(const char *cleaned,
                                                                      const void *caller,
                                                                      char *vbuf,
                                                                      size_t vbuf_size,
                                                                      const char **out_path,
                                                                      int *inout_is_sys_caller,
                                                                      BOOL for_readonly) {
    *out_path = cleaned;
    if (cleaned == NULL || cleaned[0] == '\0') {
        return PT_FS_PATH_NORMAL;
    }

    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();

    char lex_buf[PATH_MAX];
    const char *norm = cleaned;
    BOOL was_normalized = NO;
    if (cleaned[0] == '/' && pt_needs_lexical_norm(cleaned)) {
        const char *collapsed = pt_normalize_lexical_path(cleaned, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            norm = collapsed;
            was_normalized = YES;
        }
    }

    if (was_normalized) {
        const char *raw_work = cleaned;
        if (strncasecmp(raw_work, "/System/Volumes/Data/", 21) == 0) {
            raw_work += 20;
        }
        BOOL started_in_real_data = (s_real_data_container_len > 0 &&
                                     pt_match_prefix_modulo_private(raw_work, s_real_data_container_dir, s_real_data_container_len) != NULL);
        BOOL started_in_real_bundle = (s_real_app_bundle_len > 0 &&
                                       pt_match_prefix_modulo_private(raw_work, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL);
        char grp_real[PATH_MAX];
        char grp_virt[136];
        grp_real[0] = '\0';
        grp_virt[0] = '\0';
        BOOL started_in_group = NO;
        if (!started_in_real_data && !started_in_real_bundle &&
            atomic_load_explicit(&s_group_map_nonempty, memory_order_acquire)) {
            os_unfair_lock_lock(&s_group_map_lock);
            for (size_t i = 0; i < s_group_map_count; i++) {
                if (s_group_map[i].real_len > 0 &&
                    pt_match_prefix_modulo_private(raw_work, s_group_map[i].real_dir, s_group_map[i].real_len) != NULL) {
                    strlcpy(grp_real, s_group_map[i].real_dir, sizeof(grp_real));
                    strlcpy(grp_virt, s_group_map[i].virt_priv, sizeof(grp_virt));
                    started_in_group = YES;
                    break;
                }
            }
            os_unfair_lock_unlock(&s_group_map_lock);
        }
        if (started_in_real_data || started_in_real_bundle || started_in_group) {
            const char *norm_work = norm;
            if (strncasecmp(norm_work, "/System/Volumes/Data/", 21) == 0) {
                norm_work += 20;
            }
            BOOL escaped_data = (started_in_real_data &&
                                 pt_match_prefix_modulo_private(norm_work, s_real_data_container_dir, s_real_data_container_len) == NULL);
            BOOL escaped_bundle = (started_in_real_bundle &&
                                   pt_match_prefix_modulo_private(norm_work, s_real_app_bundle_dir, s_real_app_bundle_len) == NULL);
            BOOL escaped_group = (started_in_group &&
                                  pt_match_prefix_modulo_private(norm_work, grp_real, strlen(grp_real)) == NULL);
            if ((escaped_data || escaped_bundle || escaped_group) && pt_is_bypass_enabled()) {
                if (*inout_is_sys_caller < 0) {
                    *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
                }
                if (*inout_is_sys_caller == 0) {
                    if (vbuf != NULL && vbuf_size > 0) {
                        if (escaped_data) {
                            pt_compute_escaped_virtual_ancestor(s_real_data_container_dir,
                                                                s_virtual_private_data_dir,
                                                                norm_work, vbuf, vbuf_size);
                        } else if (escaped_bundle) {
                            pt_compute_escaped_virtual_ancestor(s_real_app_bundle_dir,
                                                                s_virtual_private_bundle_dir,
                                                                norm_work, vbuf, vbuf_size);
                        } else {
                            pt_compute_escaped_virtual_ancestor(grp_real,
                                                                grp_virt,
                                                                norm_work, vbuf, vbuf_size);
                        }
                        *out_path = vbuf;
                    }
                    return PT_FS_PATH_VIRTUAL_ANCESTOR;
                }
            }
        }
    }

    if (norm[0] == '/' &&
        (strncasecmp(norm, "/var/", 5) == 0 || strncasecmp(norm, "/private/var/", 13) == 0)) {
        const char *mapped = pt_try_map_clean_virtual_container_path(norm, vbuf, vbuf_size);
        if (mapped != NULL) {
            *out_path = mapped;
            norm = mapped;
        } else if (pt_is_clean_virtual_ancestor_dir(norm)) {
            if (vbuf != NULL && vbuf_size > 0) {
                strlcpy(vbuf, norm, vbuf_size);
                *out_path = vbuf;
            }
            return PT_FS_PATH_VIRTUAL_ANCESTOR;
        }
    }

    if (for_readonly) {
        const char *backup = pt_lookup_app_backup_redirect_for_caller(
            norm, caller, vbuf, vbuf_size, inout_is_sys_caller);
        if (backup != NULL) {
            *out_path = backup;
            return PT_FS_PATH_NORMAL;
        }
    }

    if (pt_is_nonsensitive_app_or_tmp_path(norm,
                                            s_real_app_bundle_dir,
                                            s_real_app_bundle_len,
                                            s_real_data_container_dir,
                                            s_real_data_container_len)) {
        return PT_FS_PATH_NORMAL;
    }

    if (pt_is_hidden_normalized_path_cached_caller(norm, caller, inout_is_sys_caller)) {
        return PT_FS_PATH_HIDDEN;
    }

    if (for_readonly && pt_is_bypass_enabled() && vbuf != NULL && vbuf_size > 0) {
        const char *sv_norm = norm;
        if (strncasecmp(sv_norm, "/System/Volumes/Data/", 21) == 0) {
            sv_norm += 20;
        }
        if (strcasecmp(sv_norm, "/System/Library/CoreServices/SystemVersion.plist") == 0) {
            if (*inout_is_sys_caller < 0) {
                *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            }
            if (*inout_is_sys_caller == 0) {
                const char *eff_ver = NULL;
                const char *eff_build = NULL;
                pt_get_effective_ios_version_and_build(&eff_ver, &eff_build);
                if (eff_ver != NULL && eff_build != NULL &&
                    pt_ensure_synthesized_system_version_plist(eff_ver, eff_build, vbuf, vbuf_size)) {
                    *out_path = vbuf;
                    return PT_FS_PATH_NORMAL;
                }
                if (pt_has_ios_system_version_plist()) {
                    strlcpy(vbuf, "/System/Library/CoreServices/iOSSystemVersion.plist", vbuf_size);
                    *out_path = vbuf;
                    return PT_FS_PATH_NORMAL;
                }
            }
        }
    }

    if (norm[0] == '/' && tolower((unsigned char)norm[1]) == 's' && strncasecmp(norm, "/System/Library/", 16) == 0) {
        BOOL is_fw = (strncmp(norm + 16, "Frameworks/", 11) == 0);
        BOOL is_pfw = (!is_fw && strncmp(norm + 16, "PrivateFrameworks/", 18) == 0);
        if (is_fw || is_pfw) {
            size_t nlen = strlen(norm);
            static const char kFwInfoSuffix[] = ".framework/Info.plist";
            static const size_t kFwInfoSuffixLen = sizeof(kFwInfoSuffix) - 1;
            BOOL handled_info = NO;
            if (nlen > kFwInfoSuffixLen &&
                norm[nlen - 1] == 't' &&
                memcmp(norm + nlen - kFwInfoSuffixLen, kFwInfoSuffix, kFwInfoSuffixLen) == 0 &&
                strstr(norm + 16, "/Versions/") == NULL &&
                strstr(norm + 16, "/Resources/") == NULL &&
                access(norm, F_OK) != 0 &&
                vbuf != NULL &&
                vbuf_size > 0) {
                size_t fw_dir_len = nlen - 11; // strip "/Info.plist"
                int n = snprintf(vbuf, vbuf_size, "%.*s/Resources/Info.plist",
                                 (int)fw_dir_len, norm);
                if (n > 0 && (size_t)n < vbuf_size && access(vbuf, F_OK) == 0) {
                    *out_path = vbuf;
                    handled_info = YES;
                } else {
                    n = snprintf(vbuf, vbuf_size, "/System/iOSSupport%.*s/Resources/Info.plist",
                                 (int)fw_dir_len, norm);
                    if (n > 0 && (size_t)n < vbuf_size && access(vbuf, F_OK) == 0) {
                        *out_path = vbuf;
                        handled_info = YES;
                    }
                }
            }
            if (!handled_info && vbuf != NULL && vbuf_size > 0 && access(norm, F_OK) != 0) {
                int n = snprintf(vbuf, vbuf_size, "/System/iOSSupport%s", norm);
                if (n > 0 && (size_t)n < vbuf_size && access(vbuf, F_OK) == 0) {
                    *out_path = vbuf;
                }
            }
        }
    }

    return PT_FS_PATH_NORMAL;
}

__attribute__((visibility("hidden"))) pt_fs_path_disposition_t pt_prepare_fs_path_at_cached_caller(int dirfd,
                                                                     const char *raw_path,
                                                                     const void *caller,
                                                                     char *vbuf,
                                                                     size_t vbuf_size,
                                                                     const char **out_path,
                                                                     int *inout_is_sys_caller,
                                                                     BOOL for_readonly) {
    const char *cleaned = pt_fs_ue_fix_filename(raw_path);
    *out_path = cleaned;
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return PT_FS_PATH_NORMAL;
    }
    if (cleaned == NULL || cleaned[0] == '\0') {
        if (dirfd != AT_FDCWD && dirfd >= 0 && pt_is_bypass_enabled() && pt_fd_is_sensitive(dirfd, caller)) {
            return PT_FS_PATH_HIDDEN;
        }
        return PT_FS_PATH_NORMAL;
    }
    if (cleaned[0] != '/') {
        if (dirfd == AT_FDCWD) {
            if (*inout_is_sys_caller < 0) {
                *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            }
            if (*inout_is_sys_caller == 1 && strstr(cleaned, "Info.plist") == NULL) {
                return PT_FS_PATH_NORMAL;
            }
        }
        static _Thread_local int tls_rel_resolve = 0;
        if (tls_rel_resolve == 0) {
            tls_rel_resolve = 1;
            char base_dir[PATH_MAX];
            base_dir[0] = '\0';
            if (dirfd >= 0 && dirfd != AT_FDCWD) {
                if (fcntl(dirfd, F_GETPATH, base_dir) == -1) {
                    base_dir[0] = '\0';
                }
            } else {
                int cfd = pt_orig_open_nocancel(".", O_RDONLY | O_DIRECTORY);
                if (cfd < 0) {
                    cfd = pt_orig_open_nocancel(".", O_RDONLY);
                }
                if (cfd >= 0) {
                    if (fcntl(cfd, F_GETPATH, base_dir) == -1) {
                        base_dir[0] = '\0';
                    }
                    close(cfd);
                }
            }
            if (base_dir[0] == '/') {
                const char *base_use = base_dir;
                if (strncasecmp(base_use, "/System/Volumes/Data/", 21) == 0) {
                    base_use += 20;
                }
                char rel_abs[PATH_MAX];
                int n = snprintf(rel_abs, sizeof(rel_abs), "%s/%s",
                                 (strcmp(base_use, "/") == 0) ? "" : base_use, cleaned);
                if (n > 0 && (size_t)n < sizeof(rel_abs)) {
                    const char *resolved_out = NULL;
                    pt_fs_path_disposition_t disp = pt_prepare_fs_path_abs_cached_caller(rel_abs,
                                                                                         caller,
                                                                                         vbuf,
                                                                                         vbuf_size,
                                                                                         &resolved_out,
                                                                                         inout_is_sys_caller,
                                                                                         for_readonly);
                    tls_rel_resolve = 0;
                    if (disp != PT_FS_PATH_NORMAL) {
                        if (resolved_out != rel_abs) {
                            *out_path = resolved_out;
                        }
                        return disp;
                    }
                    if (resolved_out != rel_abs) {
                        *out_path = resolved_out;
                    }
                    return PT_FS_PATH_NORMAL;
                }
            }
            tls_rel_resolve = 0;
        }
    }
    return pt_prepare_fs_path_abs_cached_caller(cleaned, caller, vbuf, vbuf_size, out_path, inout_is_sys_caller, for_readonly);
}

__attribute__((visibility("hidden"))) pt_fs_path_disposition_t pt_prepare_fs_path_cached_caller(const char *raw_path,
                                                                         const void *caller,
                                                                         char *vbuf,
                                                                         size_t vbuf_size,
                                                                         const char **out_path,
                                                                         int *inout_is_sys_caller) {
    return pt_prepare_fs_path_at_cached_caller(AT_FDCWD, raw_path, caller, vbuf, vbuf_size, out_path, inout_is_sys_caller, NO);
}


__attribute__((visibility("hidden"))) int pt_stat_virtual_ancestor(const char *virtual_path,
                                                                   struct stat *buf,
                                                                   const void *caller) {
    pt_ensure_data_container_map();
    const char *backing = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    int rc = stat(backing, buf);
    if (rc == 0 && buf != NULL) {
        pt_sanitize_stat_buf(buf, caller);
        buf->st_mode = (buf->st_mode & ~S_IFMT) | S_IFDIR;
        buf->st_mode &= ~(S_IWUSR | S_IWGRP | S_IWOTH);
        const char *vp = (virtual_path != NULL && virtual_path[0] == '/') ? virtual_path : "/var/mobile";
        if (strncasecmp(vp, "/private/", 9) == 0) {
            vp += 8;
        }
        size_t vlen = strlen(vp);
        while (vlen > 1 && vp[vlen - 1] == '/') {
            vlen--;
        }
        uint64_t h = 14695981039346656037ULL;
        for (size_t i = 0; i < vlen; i++) {
            h ^= (uint64_t)(unsigned char)tolower((unsigned char)vp[i]);
            h *= 1099511628211ULL;
        }
        buf->st_ino = (ino_t)(0x7000000000000000ULL | (h & 0x0FFFFFFFFFFFFFFFULL));
        if (strncasecmp(vp, "/var/containers", 15) == 0 && (vlen == 15 || vp[15] == '/')) {
            buf->st_uid = 0;
            buf->st_gid = 0;
        } else {
            buf->st_uid = 501;
            buf->st_gid = 501;
        }
    }
    return rc;
}
