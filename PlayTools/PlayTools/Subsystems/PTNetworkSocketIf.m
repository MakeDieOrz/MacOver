//
//  PTNetworkSocketIf.m
//  PlayTools
//

#import "PSInternal.h"
#import "PTDetectionRules.h"
#import "PTSystemSpooferInternal.h"
#include <ctype.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_media.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <time.h>

static BOOL pt_should_block_cfstring_host(CFStringRef hostRef) {
    if (hostRef == NULL) return NO;
    char buf[512];
    const char *cstr = CFStringGetCStringPtr(hostRef, kCFStringEncodingUTF8);
    if (cstr == NULL && CFStringGetCString(hostRef, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        cstr = buf;
    }
    return (cstr != NULL && ps_should_block_host_cstr(cstr) != 0);
}

static int pt_getaddrinfo(const char *hostname, const char *servname,
                          const struct addrinfo *hints, struct addrinfo **res) {
    if (hostname != NULL && ps_should_block_host_cstr(hostname)) {
        PT_DEBUG_TRACE("network", "blocked getaddrinfo host=%s", hostname);
        return EAI_NONAME;
    }
    return getaddrinfo(hostname, servname, hints, res);
}

static struct hostent *pt_gethostbyname(const char *name) {
    if (name != NULL && ps_should_block_host_cstr(name)) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    return gethostbyname(name);
}

static struct hostent *pt_gethostbyname2(const char *name, int af) {
    if (name != NULL && ps_should_block_host_cstr(name)) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    return gethostbyname2(name, af);
}

static DNSServiceErrorType pt_DNSServiceGetAddrInfo(
    DNSServiceRef *sdRef,
    DNSServiceFlags flags,
    uint32_t interfaceIndex,
    DNSServiceProtocol protocol,
    const char *hostname,
    DNSServiceGetAddrInfoReply callBack,
    void *context) {
    if (hostname != NULL && ps_should_block_host_cstr(hostname)) {
        return kDNSServiceErr_NoSuchRecord;
    }
    return DNSServiceGetAddrInfo(sdRef, flags, interfaceIndex, protocol, hostname, callBack, context);
}

static CFHostRef pt_CFHostCreateWithName(CFAllocatorRef allocator, CFStringRef hostname) {
    if (pt_should_block_cfstring_host(hostname)) {
        return CFHostCreateWithName(allocator, CFSTR("invalid.invalid."));
    }
    return CFHostCreateWithName(allocator, hostname);
}

static void pt_CFStreamCreatePairWithSocketToHost(
    CFAllocatorRef alloc,
    CFStringRef host,
    UInt32 port,
    CFReadStreamRef *readStream,
    CFWriteStreamRef *writeStream) {
    if (pt_should_block_cfstring_host(host)) {
        CFStreamCreatePairWithSocketToHost(alloc, CFSTR("0.0.0.0"), 1, readStream, writeStream);
        return;
    }
    CFStreamCreatePairWithSocketToHost(alloc, host, port, readStream, writeStream);
}

static NW_RETURNS_RETAINED nw_endpoint_t pt_nw_endpoint_create_host(const char *hostname, const char *port) {
    if (hostname == NULL || port == NULL) {
        return NULL;
    }
    if (ps_should_block_host_cstr(hostname)) {
        PT_DEBUG_TRACE("network", "blocked nw_endpoint host=%s port=%s", hostname, port);
        return nw_endpoint_create_host("0.0.0.0", "1");
    }
    return nw_endpoint_create_host(hostname, port);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static SCNetworkReachabilityRef pt_SCNetworkReachabilityCreateWithName(
    CFAllocatorRef allocator,
    const char *nodename) {
    if (nodename == NULL) {
        return NULL;
    }
    if (ps_should_block_host_cstr(nodename)) {
        return SCNetworkReachabilityCreateWithName(allocator, "invalid.invalid.");
    }
    return SCNetworkReachabilityCreateWithName(allocator, nodename);
}
#pragma clang diagnostic pop


typedef struct {
    BOOL active;
    int dirfd;
    int saved_fd;
    int (*fn_pthread_fchdir)(int);
} pt_unix_fchdir_guard_t;

static int (*pt_get_pthread_fchdir_fn(void))(int) {
    static _Atomic(void *) s_fn = NULL;
    static _Atomic(int) s_inited = 0;
    if (atomic_load_explicit(&s_inited, memory_order_acquire) == 0) {
        void *sym = dlsym(RTLD_DEFAULT, "__pthread_fchdir");
        atomic_store_explicit(&s_fn, sym, memory_order_relaxed);
        atomic_store_explicit(&s_inited, 1, memory_order_release);
        return (int (*)(int))sym;
    }
    return (int (*)(int))atomic_load_explicit(&s_fn, memory_order_relaxed);
}

extern int pt_orig_close_nocancel(int fd) __asm("_close$NOCANCEL");

#define PT_UNIX_REL_SOCK_SLOTS 256U
#define PT_UNIX_SUN_PATH_CAP sizeof(((struct sockaddr_un *)0)->sun_path)

typedef struct {
    BOOL in_use;
    int fd;
    uint64_t sock_ino;
    uint64_t seq;
    BOOL has_local;
    BOOL has_peer;
    char leaf[PT_UNIX_SUN_PATH_CAP];
    char local_path[PT_UNIX_SUN_PATH_CAP];
    char peer_path[PT_UNIX_SUN_PATH_CAP];
} pt_unix_rel_sock_entry_t;

static os_unfair_lock s_unix_rel_sock_lock = OS_UNFAIR_LOCK_INIT;
static pt_unix_rel_sock_entry_t s_unix_rel_sock_table[PT_UNIX_REL_SOCK_SLOTS];
static uint64_t s_unix_rel_sock_seq = 0;
static _Atomic int s_unix_sock_tracked_count = 0;

static uint64_t pt_unix_sock_ino(int fd) {
    struct stat st;
    return (fd >= 0 && fstat(fd, &st) == 0) ? (uint64_t)st.st_ino : 0;
}

static void pt_unix_record_sock_path(int fd, BOOL is_peer, const char *leaf, const char *reported_path) {
    if (fd < 0 || reported_path == NULL || reported_path[0] == '\0') {
        return;
    }
    if (strlen(reported_path) >= PT_UNIX_SUN_PATH_CAP) {
        return;
    }
    uint64_t ino = pt_unix_sock_ino(fd);
    os_unfair_lock_lock(&s_unix_rel_sock_lock);
    pt_unix_rel_sock_entry_t *dst = NULL;
    pt_unix_rel_sock_entry_t *free_slot = NULL;
    pt_unix_rel_sock_entry_t *oldest_slot = &s_unix_rel_sock_table[0];
    for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
        pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[i];
        if (!e->in_use) {
            if (free_slot == NULL) {
                free_slot = e;
            }
            continue;
        }
        if (e->fd == fd) {
            dst = e;
            break;
        }
        if (e->seq < oldest_slot->seq) {
            oldest_slot = e;
        }
    }
    if (dst != NULL) {
        if (ino != 0 && dst->sock_ino != 0 && dst->sock_ino != ino) {
            dst->has_local = NO;
            dst->has_peer = NO;
            dst->leaf[0] = '\0';
            dst->local_path[0] = '\0';
            dst->peer_path[0] = '\0';
        }
    } else {
        dst = (free_slot != NULL) ? free_slot : oldest_slot;
        if (!dst->in_use) {
            atomic_fetch_add_explicit(&s_unix_sock_tracked_count, 1, memory_order_release);
        }
        memset(dst, 0, sizeof(*dst));
        dst->in_use = YES;
        dst->fd = fd;
    }
    dst->sock_ino = ino;
    dst->seq = ++s_unix_rel_sock_seq;
    if (leaf != NULL && leaf[0] != '\0') {
        strlcpy(dst->leaf, leaf, sizeof(dst->leaf));
    }
    if (is_peer) {
        dst->has_peer = YES;
        strlcpy(dst->peer_path, reported_path, sizeof(dst->peer_path));
    } else {
        dst->has_local = YES;
        strlcpy(dst->local_path, reported_path, sizeof(dst->local_path));
    }
    os_unfair_lock_unlock(&s_unix_rel_sock_lock);
}

static void pt_unix_copy_local_for_accept(int listen_fd, int client_fd) {
    if (listen_fd < 0 || client_fd < 0) {
        return;
    }
    uint64_t listen_ino = pt_unix_sock_ino(listen_fd);
    char leaf_buf[PT_UNIX_SUN_PATH_CAP];
    char local_buf[PT_UNIX_SUN_PATH_CAP];
    leaf_buf[0] = '\0';
    local_buf[0] = '\0';
    BOOL found = NO;

    os_unfair_lock_lock(&s_unix_rel_sock_lock);
    const pt_unix_rel_sock_entry_t *best = NULL;
    for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
        const pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[i];
        if (!e->in_use || !e->has_local || e->local_path[0] == '\0') {
            continue;
        }
        if (e->fd == listen_fd && (listen_ino == 0 || e->sock_ino == 0 || e->sock_ino == listen_ino)) {
            best = e;
            break;
        }
        if (listen_ino != 0 && e->sock_ino == listen_ino && (best == NULL || e->seq > best->seq)) {
            best = e;
        }
    }
    if (best != NULL) {
        strlcpy(leaf_buf, best->leaf, sizeof(leaf_buf));
        strlcpy(local_buf, best->local_path, sizeof(local_buf));
        found = YES;
    }
    os_unfair_lock_unlock(&s_unix_rel_sock_lock);

    if (found) {
        pt_unix_record_sock_path(client_fd, NO, leaf_buf, local_buf);
    }
}

static void pt_unix_forget_fd(int fd) {
    if (fd < 0) {
        return;
    }
    os_unfair_lock_lock(&s_unix_rel_sock_lock);
    for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
        pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[i];
        if (e->in_use && e->fd == fd) {
            memset(e, 0, sizeof(*e));
            atomic_fetch_sub_explicit(&s_unix_sock_tracked_count, 1, memory_order_release);
        }
    }
    os_unfair_lock_unlock(&s_unix_rel_sock_lock);
}

__attribute__((visibility("hidden")))
void pt_network_notify_fd_dup(int oldfd, int newfd) {
    if (oldfd < 0 || newfd < 0 || oldfd == newfd) {
        return;
    }
    if (atomic_load_explicit(&s_unix_sock_tracked_count, memory_order_acquire) <= 0) {
        return;
    }
    os_unfair_lock_lock(&s_unix_rel_sock_lock);
    const pt_unix_rel_sock_entry_t *src = NULL;
    pt_unix_rel_sock_entry_t *stale_new = NULL;
    pt_unix_rel_sock_entry_t *free_slot = NULL;
    pt_unix_rel_sock_entry_t *oldest_slot = &s_unix_rel_sock_table[0];
    for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
        pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[i];
        if (!e->in_use) {
            if (free_slot == NULL) {
                free_slot = e;
            }
            continue;
        }
        if (e->fd == oldfd && src == NULL) {
            src = e;
        }
        if (e->fd == newfd && stale_new == NULL) {
            stale_new = e;
        }
        if (e->seq < oldest_slot->seq) {
            oldest_slot = e;
        }
    }
    if (src == NULL) {
        if (stale_new != NULL) {
            memset(stale_new, 0, sizeof(*stale_new));
            atomic_fetch_sub_explicit(&s_unix_sock_tracked_count, 1, memory_order_release);
        }
        os_unfair_lock_unlock(&s_unix_rel_sock_lock);
        return;
    }
    pt_unix_rel_sock_entry_t copy = *src;
    pt_unix_rel_sock_entry_t *dst = (stale_new != NULL) ? stale_new : ((free_slot != NULL) ? free_slot : oldest_slot);
    if (!dst->in_use) {
        atomic_fetch_add_explicit(&s_unix_sock_tracked_count, 1, memory_order_release);
    }
    *dst = copy;
    dst->in_use = YES;
    dst->fd = newfd;
    dst->seq = ++s_unix_rel_sock_seq;
    os_unfair_lock_unlock(&s_unix_rel_sock_lock);
}

static BOOL pt_unix_lookup_sock_path(int fd,
                                     BOOL is_peer,
                                     const char *raw_kernel_path,
                                     char *out_path,
                                     size_t out_cap) {
    if (out_path == NULL || out_cap == 0) {
        return NO;
    }
    uint64_t ino = pt_unix_sock_ino(fd);
    BOOL found = NO;
    os_unfair_lock_lock(&s_unix_rel_sock_lock);
    const pt_unix_rel_sock_entry_t *matched = NULL;
    if (fd >= 0) {
        for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
            const pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[i];
            if (!e->in_use || e->fd != fd) {
                continue;
            }
            if (ino != 0 && e->sock_ino != 0 && e->sock_ino != ino) {
                continue;
            }
            if (is_peer ? e->has_peer : e->has_local) {
                matched = e;
            }
            break;
        }
    }
    if (matched == NULL && ino != 0) {
        for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
            const pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[i];
            if (!e->in_use || e->sock_ino != ino || !(is_peer ? e->has_peer : e->has_local)) {
                continue;
            }
            if (matched == NULL || e->seq > matched->seq) {
                matched = e;
            }
        }
    }
    if (matched == NULL && raw_kernel_path != NULL &&
        strncmp(raw_kernel_path, "./", 2) == 0 && raw_kernel_path[2] != '\0') {
        const char *leaf = raw_kernel_path + 2;
        for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
            const pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[i];
            if (!e->in_use || e->leaf[0] == '\0' || strcmp(e->leaf, leaf) != 0) {
                continue;
            }
            if ((is_peer && e->has_peer) || (!is_peer && e->has_local)) {
                if (matched == NULL || e->seq > matched->seq) {
                    matched = e;
                }
            } else if (is_peer && e->has_local) {
                if (matched == NULL || e->seq > matched->seq) {
                    matched = e;
                }
            }
        }
    }
    if (matched != NULL) {
        const char *val = NULL;
        if (is_peer) {
            val = matched->has_peer ? matched->peer_path : (matched->has_local ? matched->local_path : NULL);
        } else {
            val = matched->has_local ? matched->local_path : NULL;
        }
        if (val != NULL && val[0] != '\0' && strlcpy(out_path, val, out_cap) < out_cap) {
            found = YES;
        }
    }
    os_unfair_lock_unlock(&s_unix_rel_sock_lock);
    return found;
}

static BOOL pt_normalize_relative_path(const char *src, char *dst, size_t dst_size) {
    if (src == NULL || dst == NULL || dst_size < 2 || src[0] == '\0' || src[0] == '/') {
        return NO;
    }
    const char *seg_ptrs[128];
    size_t seg_lens[128];
    size_t depth = 0;

    const char *p = src;
    while (*p != '\0') {
        while (*p == '/') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        const char *start = p;
        while (*p != '\0' && *p != '/') {
            p++;
        }
        size_t len = (size_t)(p - start);
        if (len == 1U && start[0] == '.') {
            continue;
        }
        if (len == 2U && start[0] == '.' && start[1] == '.') {
            if (depth > 0U && !(seg_lens[depth - 1U] == 2U &&
                                seg_ptrs[depth - 1U][0] == '.' &&
                                seg_ptrs[depth - 1U][1] == '.')) {
                depth--;
            } else {
                if (depth >= 128U) {
                    return NO;
                }
                seg_ptrs[depth] = start;
                seg_lens[depth] = len;
                depth++;
            }
            continue;
        }
        if (depth >= 128U) {
            return NO;
        }
        seg_ptrs[depth] = start;
        seg_lens[depth] = len;
        depth++;
    }

    if (depth == 0U) {
        if (dst_size < 2U) {
            return NO;
        }
        dst[0] = '.';
        dst[1] = '\0';
        return YES;
    }

    size_t out = 0U;
    for (size_t i = 0U; i < depth; i++) {
        if (i > 0U) {
            if (out + 1U >= dst_size) {
                return NO;
            }
            dst[out++] = '/';
        }
        if (out + seg_lens[i] >= dst_size) {
            return NO;
        }
        memcpy(dst + out, seg_ptrs[i], seg_lens[i]);
        out += seg_lens[i];
    }
    dst[out] = '\0';
    return YES;
}

static int pt_prepare_unix_sockaddr(const struct sockaddr *address,
                                    socklen_t address_len,
                                    const void *caller,
                                    struct sockaddr_un *out_mapped,
                                    socklen_t *out_len,
                                    pt_unix_fchdir_guard_t *out_guard,
                                    char *out_leaf,
                                    size_t out_leaf_cap,
                                    char *out_virt,
                                    size_t out_virt_cap) {
    if (out_guard != NULL) {
        out_guard->active = NO;
        out_guard->dirfd = -1;
        out_guard->saved_fd = -1;
        out_guard->fn_pthread_fchdir = NULL;
    }
    if (out_leaf != NULL && out_leaf_cap > 0) {
        out_leaf[0] = '\0';
    }
    if (out_virt != NULL && out_virt_cap > 0) {
        out_virt[0] = '\0';
    }
    if (address == NULL ||
        address_len <= (socklen_t)offsetof(struct sockaddr_un, sun_path) ||
        address->sa_family != AF_UNIX) {
        return 0;
    }
    const struct sockaddr_un *un = (const struct sockaddr_un *)address;
    size_t max_sun = (size_t)address_len - offsetof(struct sockaddr_un, sun_path);
    if (max_sun == 0U || un->sun_path[0] == '\0') {
        return 0;
    }
    char raw_path[PATH_MAX];
    size_t copy_len = strnlen(un->sun_path, MIN(max_sun, sizeof(raw_path) - 1U));
    memcpy(raw_path, un->sun_path, copy_len);
    raw_path[copy_len] = '\0';

    BOOL is_relative = (raw_path[0] != '/');
    char norm_rel[PT_UNIX_SUN_PATH_CAP];
    char abs_raw[PATH_MAX];
    const char *fs_input = raw_path;

    if (is_relative) {
        if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
            return 0;
        }
        if (!pt_normalize_relative_path(raw_path, norm_rel, sizeof(norm_rel))) {
            errno = ENAMETOOLONG;
            return -1;
        }
        char cwd_buf[PATH_MAX];
        if (getcwd(cwd_buf, sizeof(cwd_buf)) == NULL || cwd_buf[0] != '/') {
            return 0;
        }
        const char *cwd = cwd_buf;
        if (strncmp(cwd, "/System/Volumes/Data/", 21) == 0) {
            cwd += 20;
        }
        int jn = snprintf(abs_raw, sizeof(abs_raw), "%s/%s",
                          (strcmp(cwd, "/") == 0) ? "" : cwd, raw_path);
        if (jn < 0 || (size_t)jn >= sizeof(abs_raw)) {
            errno = ENAMETOOLONG;
            return -1;
        }
        fs_input = abs_raw;
    }

    char resolved_buf[PATH_MAX];
    const char *resolved = NULL;
    int is_sys = -1;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
        fs_input, caller, resolved_buf, sizeof(resolved_buf), &resolved, &is_sys);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EACCES;
        return -1;
    }
    char norm_resolved_buf[PATH_MAX];
    if (resolved != NULL && resolved[0] == '/' && pt_needs_lexical_norm(resolved)) {
        const char *collapsed = pt_normalize_lexical_path(resolved, norm_resolved_buf, sizeof(norm_resolved_buf));
        if (collapsed == NULL) {
            errno = ENAMETOOLONG;
            return -1;
        }
        resolved = collapsed;
    }
    if (resolved == NULL || (!is_relative && strcmp(resolved, raw_path) == 0)) {
        return 0;
    }
    size_t rlen = strlen(resolved);
    if (rlen < sizeof(out_mapped->sun_path)) {
        if (is_relative && out_virt != NULL && out_virt_cap > 0) {
            strlcpy(out_virt, norm_rel, out_virt_cap);
        }
        memset(out_mapped, 0, sizeof(*out_mapped));
        out_mapped->sun_family = AF_UNIX;
        memcpy(out_mapped->sun_path, resolved, rlen + 1U);
        out_mapped->sun_len = (unsigned char)SUN_LEN(out_mapped);
        *out_len = (socklen_t)sizeof(*out_mapped);
        return 1;
    }
    if (out_guard == NULL) {
        errno = ENAMETOOLONG;
        return -1;
    }
    const char *slash = strrchr(resolved, '/');
    if (slash == NULL || slash[1] == '\0') {
        errno = ENAMETOOLONG;
        return -1;
    }
    size_t parent_len = (size_t)(slash - resolved);
    char parent_dir[PATH_MAX];
    if (parent_len == 0) {
        parent_dir[0] = '/';
        parent_dir[1] = '\0';
    } else if (parent_len < sizeof(parent_dir)) {
        memcpy(parent_dir, resolved, parent_len);
        parent_dir[parent_len] = '\0';
    } else {
        errno = ENAMETOOLONG;
        return -1;
    }
    const char *leaf = slash + 1;
    char rel[sizeof(out_mapped->sun_path)];
    int rn = snprintf(rel, sizeof(rel), "./%s", leaf);
    if (rn < 0 || (size_t)rn >= sizeof(rel)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    int (*fn)(int) = pt_get_pthread_fchdir_fn();
    if (fn == NULL) {
        errno = ENAMETOOLONG;
        return -1;
    }
    int dirfd = pt_orig_open_nocancel(parent_dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd < 0) {
        return -1;
    }
    int saved_fd = pt_orig_open_nocancel(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fn(dirfd) != 0) {
        int saved_err = errno;
        close(dirfd);
        if (saved_fd >= 0) {
            close(saved_fd);
        }
        errno = saved_err;
        return -1;
    }
    out_guard->active = YES;
    out_guard->dirfd = dirfd;
    out_guard->saved_fd = saved_fd;
    out_guard->fn_pthread_fchdir = fn;

    if (out_leaf != NULL && out_leaf_cap > 0) {
        strlcpy(out_leaf, leaf, out_leaf_cap);
    }
    if (out_virt != NULL && out_virt_cap > 0) {
        if (is_relative) {
            strlcpy(out_virt, norm_rel, out_virt_cap);
        } else if ((strncmp(raw_path, "/var/", 5) == 0 || strncmp(raw_path, "/private/var/", 13) == 0) &&
                   strlen(raw_path) < out_virt_cap) {
            strlcpy(out_virt, raw_path, out_virt_cap);
        } else {
            char vbuf[PATH_MAX];
            const char *vp = pt_virtualize_path_for_app(resolved, vbuf, sizeof(vbuf), NO);
            if (vp != NULL && vp[0] == '/' && strlen(vp) < out_virt_cap) {
                strlcpy(out_virt, vp, out_virt_cap);
            }
        }
    }

    memset(out_mapped, 0, sizeof(*out_mapped));
    out_mapped->sun_family = AF_UNIX;
    memcpy(out_mapped->sun_path, rel, (size_t)rn + 1U);
    out_mapped->sun_len = (unsigned char)SUN_LEN(out_mapped);
    *out_len = (socklen_t)sizeof(*out_mapped);
    return 1;
}

static void pt_end_unix_fchdir(pt_unix_fchdir_guard_t *guard) {
    if (guard == NULL || !guard->active) {
        return;
    }
    int saved_errno = errno;
    if (guard->fn_pthread_fchdir != NULL) {
        if (guard->saved_fd >= 0) {
            struct stat st_saved, st_proc;
            BOOL have_saved = (fstat(guard->saved_fd, &st_saved) == 0);
            if (guard->fn_pthread_fchdir(-1) == 0) {
                if (have_saved) {
                    int pfd = pt_orig_open_nocancel(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
                    BOOL match_proc = (pfd >= 0 && fstat(pfd, &st_proc) == 0 &&
                                       st_proc.st_dev == st_saved.st_dev &&
                                       st_proc.st_ino == st_saved.st_ino);
                    if (pfd >= 0) {
                        close(pfd);
                    }
                    if (!match_proc) {
                        (void)guard->fn_pthread_fchdir(guard->saved_fd);
                    }
                }
            } else {
                (void)guard->fn_pthread_fchdir(guard->saved_fd);
            }
        } else {
            (void)guard->fn_pthread_fchdir(-1);
        }
    }
    if (guard->saved_fd >= 0) {
        close(guard->saved_fd);
    }
    if (guard->dirfd >= 0) {
        close(guard->dirfd);
    }
    guard->active = NO;
    guard->dirfd = -1;
    guard->saved_fd = -1;
    errno = saved_errno;
}

static void pt_virtualize_unix_sockaddr_out(int socket_fd,
                                            BOOL is_peer,
                                            struct sockaddr *address,
                                            socklen_t *address_len,
                                            socklen_t caller_cap,
                                            const void *caller) {
    if (address == NULL || address_len == NULL ||
        caller_cap <= (socklen_t)offsetof(struct sockaddr_un, sun_path) ||
        *address_len <= (socklen_t)offsetof(struct sockaddr_un, sun_path) ||
        address->sa_family != AF_UNIX ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return;
    }
    struct sockaddr_un *un = (struct sockaddr_un *)address;
    size_t written = (size_t)MIN(*address_len, caller_cap);
    size_t avail = written - offsetof(struct sockaddr_un, sun_path);
    if (avail == 0 || un->sun_path[0] == '\0') {
        return;
    }
    char raw_path[PATH_MAX];
    size_t n = strnlen(un->sun_path, MIN(avail, sizeof(raw_path) - 1U));
    memcpy(raw_path, un->sun_path, n);
    raw_path[n] = '\0';

    char vbuf[PATH_MAX];
    const char *virt = NULL;
    if (pt_unix_lookup_sock_path(socket_fd, is_peer, raw_path, vbuf, sizeof(vbuf))) {
        virt = vbuf;
    } else if (raw_path[0] == '/') {
        virt = pt_virtualize_path_for_app(raw_path, vbuf, sizeof(vbuf), NO);
    }
    if (virt == NULL || strcmp(virt, raw_path) == 0) {
        return;
    }
    size_t vlen = strlen(virt);
    size_t path_cap = (size_t)caller_cap - offsetof(struct sockaddr_un, sun_path);
    socklen_t needed_len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + vlen + 1U);
    if (needed_len <= caller_cap && vlen + 1U <= path_cap) {
        memcpy(un->sun_path, virt, vlen + 1U);
        un->sun_len = (unsigned char)MIN((size_t)needed_len, (size_t)UCHAR_MAX);
        *address_len = needed_len;
    } else if (avail > 0) {
        size_t copy_n = MIN(vlen, avail - 1U);
        memcpy(un->sun_path, virt, copy_n);
        un->sun_path[copy_n] = '\0';
        un->sun_len = (unsigned char)MIN(written, (size_t)UCHAR_MAX);
    }
}

__attribute__((visibility("hidden")))
int pt_network_bind_with_caller(int socket,
                                const struct sockaddr *address,
                                socklen_t address_len,
                                int raw_syscall_num,
                                const void *caller) {
    struct sockaddr_un mapped;
    socklen_t mapped_len = address_len;
    pt_unix_fchdir_guard_t guard;
    char leaf_buf[sizeof(mapped.sun_path)];
    char virt_buf[sizeof(mapped.sun_path)];
    int prep = pt_prepare_unix_sockaddr(address, address_len, caller,
                                          &mapped, &mapped_len, &guard,
                                          leaf_buf, sizeof(leaf_buf), virt_buf, sizeof(virt_buf));
    if (prep < 0) {
        return -1;
    }
    const struct sockaddr *use_addr = (prep > 0) ? (const struct sockaddr *)&mapped : address;
    socklen_t use_len = (prep > 0) ? mapped_len : address_len;
    int ret = (raw_syscall_num >= 0)
        ? (int)pt_orig_syscall(raw_syscall_num, (uintptr_t)socket, (uintptr_t)use_addr, (uintptr_t)use_len, 0, 0, 0, 0, 0)
        : bind(socket, use_addr, use_len);
    int saved_err = errno;
    pt_end_unix_fchdir(&guard);
    if (ret == 0 && virt_buf[0] != '\0') {
        pt_unix_record_sock_path(socket, NO, leaf_buf, virt_buf);
    }
    errno = saved_err;
    return ret;
}

static int pt_bind(int socket, const struct sockaddr *address, socklen_t address_len) {
    return pt_network_bind_with_caller(socket, address, address_len, -1, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_network_connect_with_caller(int socket,
                                   const struct sockaddr *address,
                                   socklen_t address_len,
                                   int raw_syscall_num,
                                   const void *caller) {
    struct sockaddr_un mapped;
    socklen_t mapped_len = address_len;
    pt_unix_fchdir_guard_t guard;
    char leaf_buf[sizeof(mapped.sun_path)];
    char virt_buf[sizeof(mapped.sun_path)];
    int prep = pt_prepare_unix_sockaddr(address, address_len, caller,
                                          &mapped, &mapped_len, &guard,
                                          leaf_buf, sizeof(leaf_buf), virt_buf, sizeof(virt_buf));
    if (prep < 0) {
        return -1;
    }
    const struct sockaddr *use_addr = (prep > 0) ? (const struct sockaddr *)&mapped : address;
    socklen_t use_len = (prep > 0) ? mapped_len : address_len;
    int ret = (raw_syscall_num >= 0)
        ? (int)pt_orig_syscall(raw_syscall_num, (uintptr_t)socket, (uintptr_t)use_addr, (uintptr_t)use_len, 0, 0, 0, 0, 0)
        : connect(socket, use_addr, use_len);
    int saved_err = errno;
    pt_end_unix_fchdir(&guard);
    if ((ret == 0 || (ret < 0 && saved_err == EINPROGRESS)) && virt_buf[0] != '\0') {
        pt_unix_record_sock_path(socket, YES, leaf_buf, virt_buf);
    }
    errno = saved_err;
    return ret;
}

static int pt_connect(int socket, const struct sockaddr *address, socklen_t address_len) {
    return pt_network_connect_with_caller(socket, address, address_len, -1, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_network_accept_with_caller(int socket,
                                  struct sockaddr * __restrict address,
                                  socklen_t * __restrict address_len,
                                  int raw_syscall_num,
                                  const void *caller) {
    socklen_t caller_cap = (address_len != NULL) ? *address_len : 0;
    int ret = (raw_syscall_num >= 0)
        ? (int)pt_orig_syscall(raw_syscall_num, (uintptr_t)socket, (uintptr_t)address, (uintptr_t)address_len, 0, 0, 0, 0, 0)
        : accept(socket, address, address_len);
    if (ret >= 0) {
        pt_unix_copy_local_for_accept(socket, ret);
        if (address != NULL && address_len != NULL) {
            pt_virtualize_unix_sockaddr_out(ret, YES, address, address_len, caller_cap, caller);
        }
    }
    return ret;
}

static int pt_accept(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len) {
    return pt_network_accept_with_caller(socket, address, address_len, -1, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
ssize_t pt_network_sendto_with_caller(int socket,
                                      const void *buffer,
                                      size_t length,
                                      int flags,
                                      const struct sockaddr *dest_addr,
                                      socklen_t dest_len,
                                      int raw_syscall_num,
                                      const void *caller) {
    struct sockaddr_un mapped;
    socklen_t mapped_len = dest_len;
    pt_unix_fchdir_guard_t guard;
    int prep = pt_prepare_unix_sockaddr(dest_addr, dest_len, caller,
                                          &mapped, &mapped_len, &guard,
                                          NULL, 0, NULL, 0);
    if (prep < 0) {
        return -1;
    }
    const struct sockaddr *use_addr = (prep > 0) ? (const struct sockaddr *)&mapped : dest_addr;
    socklen_t use_len = (prep > 0) ? mapped_len : dest_len;
    ssize_t ret = (raw_syscall_num >= 0)
        ? (ssize_t)pt_orig_syscall(raw_syscall_num, (uintptr_t)socket, (uintptr_t)buffer, (uintptr_t)length, (uintptr_t)flags, (uintptr_t)use_addr, (uintptr_t)use_len, 0, 0)
        : sendto(socket, buffer, length, flags, use_addr, use_len);
    int saved_err = errno;
    pt_end_unix_fchdir(&guard);
    errno = saved_err;
    return ret;
}

static ssize_t pt_sendto(int socket,
                         const void *buffer,
                         size_t length,
                         int flags,
                         const struct sockaddr *dest_addr,
                         socklen_t dest_len) {
    return pt_network_sendto_with_caller(socket, buffer, length, flags, dest_addr, dest_len, -1, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_network_getsockname_with_caller(int socket,
                                       struct sockaddr * __restrict address,
                                       socklen_t * __restrict address_len,
                                       int raw_syscall_num,
                                       const void *caller) {
    if (address == NULL || address_len == NULL) {
        errno = EFAULT;
        return -1;
    }
    socklen_t caller_cap = *address_len;
    int ret = (raw_syscall_num >= 0)
        ? (int)pt_orig_syscall(raw_syscall_num, (uintptr_t)socket, (uintptr_t)address, (uintptr_t)address_len, 0, 0, 0, 0, 0)
        : getsockname(socket, address, address_len);
    if (ret == 0) {
        pt_virtualize_unix_sockaddr_out(socket, NO, address, address_len, caller_cap, caller);
    }
    return ret;
}

static int pt_getsockname(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len) {
    return pt_network_getsockname_with_caller(socket, address, address_len, -1, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_network_getpeername_with_caller(int socket,
                                       struct sockaddr * __restrict address,
                                       socklen_t * __restrict address_len,
                                       int raw_syscall_num,
                                       const void *caller) {
    if (address == NULL || address_len == NULL) {
        errno = EFAULT;
        return -1;
    }
    socklen_t caller_cap = *address_len;
    int ret = (raw_syscall_num >= 0)
        ? (int)pt_orig_syscall(raw_syscall_num, (uintptr_t)socket, (uintptr_t)address, (uintptr_t)address_len, 0, 0, 0, 0, 0)
        : getpeername(socket, address, address_len);
    if (ret == 0) {
        pt_virtualize_unix_sockaddr_out(socket, YES, address, address_len, caller_cap, caller);
    }
    return ret;
}

static int pt_getpeername(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len) {
    return pt_network_getpeername_with_caller(socket, address, address_len, -1, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
void pt_network_notify_fd_close(int fd) {
    if (fd >= 0 && atomic_load_explicit(&s_unix_sock_tracked_count, memory_order_acquire) > 0) {
        pt_unix_forget_fd(fd);
    }
}

static int pt_close(int fd) {
    pt_network_notify_fd_close(fd);
    return close(fd);
}

static int pt_close_nocancel(int fd) {
    pt_network_notify_fd_close(fd);
    return pt_orig_close_nocancel(fd);
}

static int pt_dup(int fd) {
    int ret = dup(fd);
    if (ret >= 0) {
        pt_network_notify_fd_dup(fd, ret);
    }
    return ret;
}

static int pt_dup2(int fd, int fd2) {
    int ret = dup2(fd, fd2);
    if (ret >= 0) {
        pt_network_notify_fd_dup(fd, ret);
    }
    return ret;
}

#define PT_IFADDRS_HEAD_MAP_CAP 64

typedef struct {
    struct ifaddrs *returned_head;
    struct ifaddrs *orig_head;
} pt_ifaddrs_head_entry_t;

static os_unfair_lock s_ifaddrs_lock = OS_UNFAIR_LOCK_INIT;
static pt_ifaddrs_head_entry_t s_ifaddrs_head_map[PT_IFADDRS_HEAD_MAP_CAP];

#define PT_NET_IF_INACTIVE_CACHE_CAP 16U

typedef struct {
    char name[IFNAMSIZ];
    BOOL inactive;
    uint64_t ts_ns;
} pt_net_if_inactive_cache_entry_t;

static os_unfair_lock s_net_if_inactive_lock = OS_UNFAIR_LOCK_INIT;
static pt_net_if_inactive_cache_entry_t s_net_if_inactive_cache[PT_NET_IF_INACTIVE_CACHE_CAP];

static uint64_t pt_net_monotonic_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &ts) == 0) {
        return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
    }
    return 0;
}

static BOOL pt_network_ifname_is_inactive(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    int saved_errno = errno;
    uint64_t now_ns = pt_net_monotonic_ns();
    if (now_ns != 0) {
        os_unfair_lock_lock(&s_net_if_inactive_lock);
        for (size_t i = 0; i < PT_NET_IF_INACTIVE_CACHE_CAP; i++) {
            if (s_net_if_inactive_cache[i].name[0] != '\0' &&
                strcmp(s_net_if_inactive_cache[i].name, name) == 0 &&
                now_ns >= s_net_if_inactive_cache[i].ts_ns &&
                (now_ns - s_net_if_inactive_cache[i].ts_ns) < 1000000000ULL) {
                BOOL cached = s_net_if_inactive_cache[i].inactive;
                os_unfair_lock_unlock(&s_net_if_inactive_lock);
                errno = saved_errno;
                return cached;
            }
        }
        os_unfair_lock_unlock(&s_net_if_inactive_lock);
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        errno = saved_errno;
        return NO;
    }
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, name, sizeof(ifr.ifr_name));
    BOOL inactive = NO;
    BOOL media_active = NO;
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) == 0) {
        short needed = (short)(IFF_UP | IFF_RUNNING);
        if ((ifr.ifr_flags & needed) != needed) {
            inactive = YES;
        }
    }
#ifdef SIOCGIFMEDIA
    if (!inactive) {
        struct ifmediareq ifmr;
        memset(&ifmr, 0, sizeof(ifmr));
        strlcpy(ifmr.ifm_name, name, sizeof(ifmr.ifm_name));
        if (ioctl(fd, SIOCGIFMEDIA, &ifmr) == 0 && (ifmr.ifm_status & IFM_AVALID) != 0) {
            if ((ifmr.ifm_status & IFM_ACTIVE) == 0) {
                inactive = YES;
            } else {
                media_active = YES;
            }
        }
    }
#endif
    if (!inactive && !media_active) {
        struct ifreq aifr;
        memset(&aifr, 0, sizeof(aifr));
        strlcpy(aifr.ifr_name, name, sizeof(aifr.ifr_name));
        BOOL has_routable_ip = NO;
        if (ioctl(fd, SIOCGIFADDR, &aifr) == 0 && aifr.ifr_addr.sa_family == AF_INET) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)&aifr.ifr_addr;
            uint32_t ip = ntohl(sin->sin_addr.s_addr);
            if (ip != 0U && (ip & 0xFFFF0000U) != 0xA9FE0000U) {
                has_routable_ip = YES;
            }
        }
        if (!has_routable_ip) {
            struct ifaddrs *iflist = NULL;
            if (getifaddrs(&iflist) == 0 && iflist != NULL) {
                for (struct ifaddrs *cur = iflist; cur != NULL; cur = cur->ifa_next) {
                    if (cur->ifa_name != NULL &&
                        strcmp(cur->ifa_name, name) == 0 &&
                        cur->ifa_addr != NULL &&
                        cur->ifa_addr->sa_family == AF_INET6) {
                        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)cur->ifa_addr;
                        if (!IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr) &&
                            !IN6_IS_ADDR_UNSPECIFIED(&sin6->sin6_addr) &&
                            !IN6_IS_ADDR_LOOPBACK(&sin6->sin6_addr)) {
                            has_routable_ip = YES;
                            break;
                        }
                    }
                }
                freeifaddrs(iflist);
            }
        }
        if (!has_routable_ip) {
            inactive = YES;
        }
    }
    close(fd);

    if (now_ns != 0) {
        os_unfair_lock_lock(&s_net_if_inactive_lock);
        size_t slot = PT_NET_IF_INACTIVE_CACHE_CAP;
        uint64_t oldest_ts = UINT64_MAX;
        size_t oldest_slot = 0;
        for (size_t i = 0; i < PT_NET_IF_INACTIVE_CACHE_CAP; i++) {
            if (s_net_if_inactive_cache[i].name[0] != '\0' &&
                strcmp(s_net_if_inactive_cache[i].name, name) == 0) {
                slot = i;
                break;
            }
            if (s_net_if_inactive_cache[i].name[0] == '\0' && slot == PT_NET_IF_INACTIVE_CACHE_CAP) {
                slot = i;
            }
            if (s_net_if_inactive_cache[i].ts_ns < oldest_ts) {
                oldest_ts = s_net_if_inactive_cache[i].ts_ns;
                oldest_slot = i;
            }
        }
        if (slot == PT_NET_IF_INACTIVE_CACHE_CAP) {
            slot = oldest_slot;
        }
        strlcpy(s_net_if_inactive_cache[slot].name, name, sizeof(s_net_if_inactive_cache[slot].name));
        s_net_if_inactive_cache[slot].inactive = inactive;
        s_net_if_inactive_cache[slot].ts_ns = now_ns;
        os_unfair_lock_unlock(&s_net_if_inactive_lock);
    }

    errno = saved_errno;
    return inactive;
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_network_ifname(const char *name) {
    if (pt_is_hidden_network_ifname_prefix_cstr(name)) {
        return YES;
    }
    if (pt_is_secondary_en_ifname_cstr(name)) {
        if (pt_network_ifname_is_inactive(name)) {
            return YES;
        }
        // Hide active secondary wired/dock en1+ interfaces when primary en0 is active
        return !pt_network_ifname_is_inactive("en0");
    }
    return NO;
}

static BOOL pt_is_hidden_ifname(const char *name) {
    return pt_is_hidden_network_ifname(name);
}

static BOOL pt_record_ifaddrs_head_remap(struct ifaddrs *returned_head, struct ifaddrs *orig_head) {
    BOOL stored = NO;
    os_unfair_lock_lock(&s_ifaddrs_lock);
    for (size_t i = 0; i < PT_IFADDRS_HEAD_MAP_CAP; i++) {
        if (s_ifaddrs_head_map[i].returned_head == NULL) {
            s_ifaddrs_head_map[i].returned_head = returned_head;
            s_ifaddrs_head_map[i].orig_head = orig_head;
            stored = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&s_ifaddrs_lock);
    return stored;
}

static struct ifaddrs *pt_consume_ifaddrs_head_remap(struct ifaddrs *ifa) {
    struct ifaddrs *orig = ifa;
    os_unfair_lock_lock(&s_ifaddrs_lock);
    for (size_t i = 0; i < PT_IFADDRS_HEAD_MAP_CAP; i++) {
        if (s_ifaddrs_head_map[i].returned_head == ifa) {
            orig = s_ifaddrs_head_map[i].orig_head;
            s_ifaddrs_head_map[i].returned_head = NULL;
            s_ifaddrs_head_map[i].orig_head = NULL;
            break;
        }
    }
    os_unfair_lock_unlock(&s_ifaddrs_lock);
    return orig;
}

static int pt_getifaddrs(struct ifaddrs **ifap) {
    int ret = getifaddrs(ifap);
    if (ret != 0 || ifap == NULL || *ifap == NULL) {
        return ret;
    }
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0;
    }

    struct ifaddrs *orig_head = *ifap;
    struct ifaddrs *new_head = NULL;
    struct ifaddrs *tail = NULL;
    for (struct ifaddrs *cur = orig_head; cur != NULL; cur = cur->ifa_next) {
        if (pt_is_hidden_ifname(cur->ifa_name)) {
            continue;
        }
        if (new_head == NULL) {
            new_head = cur;
        } else {
            tail->ifa_next = cur;
        }
        tail = cur;
    }
    if (tail != NULL) {
        tail->ifa_next = NULL;
    }
    if (new_head == NULL) {
        freeifaddrs(orig_head);
        *ifap = NULL;
        return 0;
    }
    if (new_head != orig_head && !pt_record_ifaddrs_head_remap(new_head, orig_head)) {
        // Restore original chain rather than risking an untracked freeifaddrs pointer.
        struct ifaddrs *kept_tail = orig_head;
        for (struct ifaddrs *cur = orig_head->ifa_next; cur != NULL; cur = cur->ifa_next) {
            if (!pt_is_hidden_ifname(cur->ifa_name)) {
                kept_tail->ifa_next = cur;
                kept_tail = cur;
            }
        }
        kept_tail->ifa_next = NULL;
        *ifap = orig_head;
        return 0;
    }
    *ifap = new_head;
    return 0;
}

static void pt_freeifaddrs(struct ifaddrs *ifa) {
    if (ifa == NULL) {
        return;
    }
    freeifaddrs(pt_consume_ifaddrs_head_remap(ifa));
}

#define PT_IFNI_PTR_CAP 256

static os_unfair_lock s_ifni_lock = OS_UNFAIR_LOCK_INIT;
static struct if_nameindex *s_custom_ifni_ptrs[PT_IFNI_PTR_CAP];

static BOOL pt_record_custom_ifni(struct if_nameindex *ptr) {
    if (ptr == NULL) {
        return NO;
    }
    BOOL stored = NO;
    os_unfair_lock_lock(&s_ifni_lock);
    for (size_t i = 0; i < PT_IFNI_PTR_CAP; i++) {
        if (s_custom_ifni_ptrs[i] == NULL) {
            s_custom_ifni_ptrs[i] = ptr;
            stored = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&s_ifni_lock);
    return stored;
}

static BOOL pt_take_custom_ifni(struct if_nameindex *ptr) {
    if (ptr == NULL) {
        return NO;
    }
    BOOL found = NO;
    os_unfair_lock_lock(&s_ifni_lock);
    for (size_t i = 0; i < PT_IFNI_PTR_CAP; i++) {
        if (s_custom_ifni_ptrs[i] == ptr) {
            s_custom_ifni_ptrs[i] = NULL;
            found = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&s_ifni_lock);
    return found;
}

static struct if_nameindex *pt_if_nameindex(void) {
    struct if_nameindex *orig = if_nameindex();
    if (orig == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return orig;
    }

    size_t total = 0;
    size_t kept = 0;
    size_t str_bytes = 0;
    for (size_t i = 0; orig[i].if_index != 0; i++) {
        total++;
        const char *name = orig[i].if_name;
        if (pt_is_hidden_network_ifname(name)) {
            continue;
        }
        kept++;
        if (name != NULL) {
            str_bytes += strlen(name) + 1U;
        }
    }
    if (kept == total) {
        return orig;
    }

    size_t arr_bytes = (kept + 1U) * sizeof(struct if_nameindex);
    uint8_t *block = (uint8_t *)calloc(1, arr_bytes + str_bytes);
    if (block == NULL) {
        return orig;
    }

    struct if_nameindex *filtered = (struct if_nameindex *)block;
    if (!pt_record_custom_ifni(filtered)) {
        free(block);
        return orig;
    }

    char *str_cur = (char *)(block + arr_bytes);
    char *str_end = (char *)(block + arr_bytes + str_bytes);
    size_t out_idx = 0;
    for (size_t i = 0; orig[i].if_index != 0; i++) {
        const char *name = orig[i].if_name;
        if (pt_is_hidden_network_ifname(name)) {
            continue;
        }
        filtered[out_idx].if_index = orig[i].if_index;
        if (name != NULL) {
            size_t len = strlen(name) + 1U;
            if ((size_t)(str_end - str_cur) >= len) {
                memcpy(str_cur, name, len);
                filtered[out_idx].if_name = str_cur;
                str_cur += len;
            }
        }
        out_idx++;
    }
    filtered[out_idx].if_index = 0;
    filtered[out_idx].if_name = NULL;

    if_freenameindex(orig);
    return filtered;
}

static void pt_if_freenameindex(struct if_nameindex *ptr) {
    if (ptr == NULL) {
        return;
    }
    if (pt_take_custom_ifni(ptr)) {
        free(ptr);
        return;
    }
    if_freenameindex(ptr);
}

static unsigned int pt_if_nametoindex(const char *ifname) {
    unsigned int idx = if_nametoindex(ifname);
    if (idx != 0 &&
        ifname != NULL &&
        pt_is_hidden_network_ifname(ifname) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = ENXIO;
        return 0;
    }
    return idx;
}

static char *pt_if_indextoname(unsigned int ifindex, char *ifname) {
    char *ret = if_indextoname(ifindex, ifname);
    if (ret != NULL &&
        pt_is_hidden_network_ifname(ret) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (ifname != NULL) {
            ifname[0] = '\0';
        }
        errno = ENXIO;
        return NULL;
    }
    return ret;
}

static void pt_filter_ifconf_buffer(struct ifconf *ifc) {
    if (ifc == NULL || !pt_is_valid_user_pointer(ifc) ||
        ifc->ifc_buf == NULL || !pt_is_valid_user_pointer(ifc->ifc_buf) ||
        ifc->ifc_len <= 0) {
        return;
    }
    uint8_t *base = (uint8_t *)ifc->ifc_buf;
    size_t total = (size_t)ifc->ifc_len;
    size_t read_off = 0;
    size_t write_off = 0;
    const size_t min_entry = sizeof(struct ifreq);
    const size_t addr_off = offsetof(struct ifreq, ifr_addr);
    while (read_off + min_entry <= total) {
        const struct ifreq *ifr = (const struct ifreq *)(base + read_off);
        size_t sa_len = (size_t)ifr->ifr_addr.sa_len;
        size_t step = (addr_off + sa_len > min_entry) ? (addr_off + sa_len) : min_entry;
        if (step > total - read_off) {
            size_t rem = total - read_off;
            if (write_off != read_off) {
                memmove(base + write_off, base + read_off, rem);
            }
            write_off += rem;
            break;
        }
        char namebuf[IFNAMSIZ + 1];
        memcpy(namebuf, ifr->ifr_name, IFNAMSIZ);
        namebuf[IFNAMSIZ] = '\0';
        if (!pt_is_hidden_network_ifname(namebuf)) {
            if (write_off != read_off) {
                memmove(base + write_off, base + read_off, step);
            }
            write_off += step;
        }
        read_off += step;
    }
    ifc->ifc_len = (int)write_off;
}

__attribute__((visibility("hidden")))
int pt_network_ioctl_with_caller(int fd, unsigned long request, uintptr_t arg, const void *caller) {
    BOOL has_arg = ((request & (IOC_IN | IOC_OUT)) != 0);
    BOOL filter = (pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(caller));
    if (filter && has_arg && arg != 0 && pt_is_valid_user_pointer((const void *)arg)) {
        if (request == SIOCGIFFLAGS ||
            request == SIOCGIFADDR ||
            request == SIOCGIFNETMASK ||
            request == SIOCGIFBRDADDR ||
            request == SIOCGIFDSTADDR ||
            request == SIOCGIFMTU
#ifdef SIOCGIFINDEX
            || request == SIOCGIFINDEX
#endif
#ifdef SIOCGIFTYPE
            || request == SIOCGIFTYPE
#endif
#ifdef SIOCGIFPHYS
            || request == SIOCGIFPHYS
#endif
#ifdef SIOCGIFMETRIC
            || request == SIOCGIFMETRIC
#endif
#ifdef SIOCGIFVLAN
            || request == SIOCGIFVLAN
#endif
#ifdef SIOCGIFBOND
            || request == SIOCGIFBOND
#endif
#ifdef SIOCGIFDESC
            || request == SIOCGIFDESC
#endif
#ifdef SIOCGIFWAKEFLAGS
            || request == SIOCGIFWAKEFLAGS
#endif
#ifdef SIOCGIFALIFETIME_IN6
            || request == SIOCGIFALIFETIME_IN6
#endif
#ifdef SIOCGIFFUNCTIONALTYPE
            || request == SIOCGIFFUNCTIONALTYPE
#endif
#ifdef SIOCGIFSTATUS
            || request == SIOCGIFSTATUS
#endif
#ifdef SIOCGIFALTMTU
            || request == SIOCGIFALTMTU
#endif
#ifdef SIOCGIFGENERIC
            || request == SIOCGIFGENERIC
#endif
#ifdef SIOCGIFMEDIA
            || request == SIOCGIFMEDIA
#endif
#ifdef SIOCGIFDEVMTU
            || request == SIOCGIFDEVMTU
#endif
#ifdef SIOCGIFCAP
            || request == SIOCGIFCAP
#endif
#ifdef SIOCGIFEFLAGS
            || request == SIOCGIFEFLAGS
#endif
#ifdef SIOCGIFXFLAGS
            || request == SIOCGIFXFLAGS
#endif
#ifdef SIOCGIFXMEDIA
            || request == SIOCGIFXMEDIA
#endif
#ifdef SIOCGIFAFLAG_IN6
            || request == SIOCGIFAFLAG_IN6
#endif
#ifdef SIOCGIFSTAT_IN6
            || request == SIOCGIFSTAT_IN6
#endif
        ) {
            const struct ifreq *ifr = (const struct ifreq *)arg;
            char namebuf[IFNAMSIZ + 1];
            memcpy(namebuf, ifr->ifr_name, IFNAMSIZ);
            namebuf[IFNAMSIZ] = '\0';
            if (pt_is_hidden_network_ifname(namebuf)) {
                errno = ENXIO;
                return -1;
            }
        }
    }
    int ret = has_arg ? ioctl(fd, request, (void *)arg) : ioctl(fd, request);
    if (ret == 0 && filter && arg != 0 && pt_is_valid_user_pointer((const void *)arg)) {
        if (request == SIOCGIFCONF) {
            pt_filter_ifconf_buffer((struct ifconf *)arg);
        }
#if defined(SIOCGIFMEDIA) || defined(SIOCGIFXMEDIA)
        else if (
#ifdef SIOCGIFMEDIA
            request == SIOCGIFMEDIA
#endif
#if defined(SIOCGIFMEDIA) && defined(SIOCGIFXMEDIA)
            ||
#endif
#ifdef SIOCGIFXMEDIA
            request == SIOCGIFXMEDIA
#endif
        ) {
            struct ifmediareq *ifmr = (struct ifmediareq *)arg;
            char namebuf[IFNAMSIZ + 1];
            memcpy(namebuf, ifmr->ifm_name, IFNAMSIZ);
            namebuf[IFNAMSIZ] = '\0';
            if (strcmp(namebuf, "en0") == 0 &&
                (IFM_TYPE(ifmr->ifm_active) == IFM_ETHER || IFM_TYPE(ifmr->ifm_current) == IFM_ETHER)) {
                int wifiMedia = IFM_IEEE80211 | IFM_AUTO;
                ifmr->ifm_current = wifiMedia;
                ifmr->ifm_active = wifiMedia;
                ifmr->ifm_status = IFM_AVALID | IFM_ACTIVE;
                if (ifmr->ifm_ulist != NULL && ifmr->ifm_count > 0 &&
                    pt_is_valid_user_pointer((const void *)ifmr->ifm_ulist)) {
                    int n = (ifmr->ifm_count < 256) ? ifmr->ifm_count : 256;
                    for (int i = 0; i < n; i++) {
                        if (IFM_TYPE(ifmr->ifm_ulist[i]) == IFM_ETHER) {
                            ifmr->ifm_ulist[i] = wifiMedia;
                        }
                    }
                }
            }
        }
#endif
    }
    return ret;
}

static int pt_ioctl(int fd, unsigned long request, ...) {
    uintptr_t arg = 0;
    if ((request & (IOC_IN | IOC_OUT)) != 0) {
        va_list ap;
        va_start(ap, request);
        arg = va_arg(ap, uintptr_t);
        va_end(ap);
    }
    return pt_network_ioctl_with_caller(fd, request, arg, __builtin_return_address(0));
}

static const char *pt_net_get_real_host_short_name(void) {
    static char s_host_short[256];
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        char raw[256] = {0};
        if (gethostname(raw, sizeof(raw) - 1U) == 0 && raw[0] != '\0') {
            raw[sizeof(raw) - 1U] = '\0';
            char *dot = strchr(raw, '.');
            if (dot != NULL) {
                *dot = '\0';
            }
            strlcpy(s_host_short, raw, sizeof(s_host_short));
        }
    });
    return s_host_short;
}

static BOOL pt_net_is_desktop_or_host_rdns_name(const char *host) {
    if (host == NULL || host[0] == '\0') {
        return NO;
    }
    if (strcasecmp(host, "localhost") == 0) {
        return NO;
    }
    const char *real_short = pt_net_get_real_host_short_name();
    if (real_short != NULL && real_short[0] != '\0') {
        size_t rlen = strlen(real_short);
        if (strncasecmp(host, real_short, rlen) == 0 &&
            (host[rlen] == '\0' || host[rlen] == '.')) {
            return YES;
        }
    }
    if (strcasestr(host, "macbook") != NULL ||
        strcasestr(host, "mac-mini") != NULL ||
        strcasestr(host, "macmini") != NULL ||
        strcasestr(host, "mac-studio") != NULL ||
        strcasestr(host, "macstudio") != NULL ||
        strcasestr(host, "mac-pro") != NULL ||
        strcasestr(host, "macpro") != NULL ||
        strcasestr(host, "imac") != NULL ||
        strcasestr(host, "macos") != NULL ||
        strcasestr(host, "playcover") != NULL ||
        strcasestr(host, "macover") != NULL) {
        return YES;
    }
    return NO;
}

static BOOL pt_net_sockaddr_is_loopback(const struct sockaddr *sa) {
    if (sa == NULL) {
        return NO;
    }
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
        return ((ntohl(sin->sin_addr.s_addr) >> 24) == 127U);
    }
    if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)sa;
        return IN6_IS_ADDR_LOOPBACK(&sin6->sin6_addr) ? YES : NO;
    }
    return NO;
}

static const char *pt_net_spoofed_rdns_replacement(const char *orig_host, BOOL is_loopback) {
    if (is_loopback) {
        return "localhost";
    }
    BOOL is_local = NO;
    if (orig_host != NULL) {
        size_t len = strlen(orig_host);
        if (len >= 6U && strcasecmp(orig_host + len - 6U, ".local") == 0) {
            is_local = YES;
        } else if (len >= 7U && strcasecmp(orig_host + len - 7U, ".local.") == 0) {
            is_local = YES;
        }
    }
    BOOL is_ipad = pt_get_spoofed_device_is_ipad();
    if (is_local) {
        return is_ipad ? "iPad.local" : "iPhone.local";
    }
    return is_ipad ? "iPad" : "iPhone";
}

static int pt_getnameinfo(const struct sockaddr *sa,
                          socklen_t salen,
                          char *host,
                          socklen_t hostlen,
                          char *serv,
                          socklen_t servlen,
                          int flags) {
    int ret = getnameinfo(sa, salen, host, hostlen, serv, servlen, flags);
    if (ret == 0 && host != NULL && hostlen > 0 &&
        (flags & NI_NUMERICHOST) == 0 &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        host[hostlen - 1U] = '\0';
        if (pt_net_is_desktop_or_host_rdns_name(host)) {
            const char *repl = pt_net_spoofed_rdns_replacement(host, pt_net_sockaddr_is_loopback(sa));
            strlcpy(host, repl, (size_t)hostlen);
        }
    }
    return ret;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static struct hostent *pt_gethostbyaddr(const void *addr, socklen_t len, int type) {
    struct hostent *he = gethostbyaddr(addr, len, type);
    if (he == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return he;
    }
    BOOL needs_sanitize = pt_net_is_desktop_or_host_rdns_name(he->h_name);
    if (!needs_sanitize && he->h_aliases != NULL) {
        for (char **a = he->h_aliases; *a != NULL; a++) {
            if (pt_net_is_desktop_or_host_rdns_name(*a)) {
                needs_sanitize = YES;
                break;
            }
        }
    }
    if (!needs_sanitize) {
        return he;
    }
    BOOL is_loopback = NO;
    if (addr != NULL) {
        if (type == AF_INET && len >= (socklen_t)sizeof(struct in_addr)) {
            struct in_addr in4;
            memcpy(&in4, addr, sizeof(in4));
            is_loopback = ((ntohl(in4.s_addr) >> 24) == 127U);
        } else if (type == AF_INET6 && len >= (socklen_t)sizeof(struct in6_addr)) {
            struct in6_addr in6;
            memcpy(&in6, addr, sizeof(in6));
            is_loopback = IN6_IS_ADDR_LOOPBACK(&in6) ? YES : NO;
        }
    }
    static _Thread_local struct hostent s_tls_he;
    static _Thread_local char s_tls_name[64];
    static _Thread_local char *s_tls_aliases[1];
    static _Thread_local char *s_tls_addr_list[2];
    static _Thread_local uint8_t s_tls_addr_buf[16];
    const char *repl = pt_net_spoofed_rdns_replacement(he->h_name, is_loopback);
    strlcpy(s_tls_name, repl, sizeof(s_tls_name));
    s_tls_aliases[0] = NULL;
    s_tls_he.h_name = s_tls_name;
    s_tls_he.h_aliases = s_tls_aliases;
    s_tls_he.h_addrtype = he->h_addrtype;
    s_tls_he.h_length = he->h_length;
    if (he->h_addr_list != NULL && he->h_addr_list[0] != NULL &&
        he->h_length > 0 && (size_t)he->h_length <= sizeof(s_tls_addr_buf)) {
        memcpy(s_tls_addr_buf, he->h_addr_list[0], (size_t)he->h_length);
        s_tls_addr_list[0] = (char *)s_tls_addr_buf;
        s_tls_addr_list[1] = NULL;
        s_tls_he.h_addr_list = s_tls_addr_list;
    } else {
        s_tls_addr_list[0] = NULL;
        s_tls_he.h_addr_list = s_tls_addr_list;
    }
    return &s_tls_he;
}
#pragma clang diagnostic pop

PT_INTERPOSE(pt_getaddrinfo, getaddrinfo)
PT_INTERPOSE(pt_getnameinfo, getnameinfo)
PT_INTERPOSE(pt_gethostbyaddr, gethostbyaddr)
PT_INTERPOSE(pt_ioctl, ioctl)
PT_INTERPOSE(pt_gethostbyname, gethostbyname)
PT_INTERPOSE(pt_gethostbyname2, gethostbyname2)
PT_INTERPOSE(pt_DNSServiceGetAddrInfo, DNSServiceGetAddrInfo)
PT_INTERPOSE(pt_CFHostCreateWithName, CFHostCreateWithName)
PT_INTERPOSE(pt_CFStreamCreatePairWithSocketToHost, CFStreamCreatePairWithSocketToHost)
PT_INTERPOSE(pt_nw_endpoint_create_host, nw_endpoint_create_host)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
PT_INTERPOSE(pt_SCNetworkReachabilityCreateWithName, SCNetworkReachabilityCreateWithName)
#pragma clang diagnostic pop
PT_INTERPOSE(pt_bind, bind)
PT_INTERPOSE(pt_connect, connect)
PT_INTERPOSE(pt_accept, accept)
PT_INTERPOSE(pt_sendto, sendto)
PT_INTERPOSE(pt_getsockname, getsockname)
PT_INTERPOSE(pt_getpeername, getpeername)
PT_INTERPOSE(pt_close, close)
PT_INTERPOSE_NAMED(pt_close_nocancel, pt_orig_close_nocancel, "close$NOCANCEL")
PT_INTERPOSE(pt_dup, dup)
PT_INTERPOSE(pt_dup2, dup2)
PT_INTERPOSE(pt_getifaddrs, getifaddrs)
PT_INTERPOSE(pt_freeifaddrs, freeifaddrs)
PT_INTERPOSE(pt_if_nameindex, if_nameindex)
PT_INTERPOSE(pt_if_freenameindex, if_freenameindex)
PT_INTERPOSE(pt_if_nametoindex, if_nametoindex)
PT_INTERPOSE(pt_if_indextoname, if_indextoname)
