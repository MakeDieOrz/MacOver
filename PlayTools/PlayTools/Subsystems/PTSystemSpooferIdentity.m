//
//  PTSystemSpooferIdentity.m
//  PlayTools
//

#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"
#import "PTDyldInternal.h"
#import "PTEntitlementsInternal.h"
#include <grp.h>
#include <notify.h>
#include <pwd.h>
#include <spawn.h>
#include <sys/event.h>
#include <time.h>
#include <utmpx.h>

static int pt_gethostname(char *name, size_t namelen) {
    if (name != NULL && namelen > 0 &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *model = DEVICE_MODEL;
        const char *host = (model != NULL && strncmp(model, "iPad", 4) == 0) ? "iPad" : "iPhone";
        strncpy(name, host, namelen - 1);
        name[namelen - 1] = '\0';
        return 0;
    }
    return gethostname(name, namelen);
}

static pthread_key_t s_pw_tls_key;
static pthread_once_t s_pw_tls_once = PTHREAD_ONCE_INIT;
static void pt_init_pw_tls_key(void) {
    pthread_key_create(&s_pw_tls_key, free);
}

static void pt_fill_mobile_passwd_struct(uid_t uid, gid_t gid, struct passwd *pwd, char *buffer, size_t bufsize) {
    static const char kBlock[] = "mobile\0*\0Mobile User\0/var/mobile\0/usr/sbin/nologin";
    memset(pwd, 0, sizeof(*pwd));
    pwd->pw_uid = uid;
    pwd->pw_gid = gid;
    if (buffer != NULL && bufsize >= sizeof(kBlock)) {
        memcpy(buffer, kBlock, sizeof(kBlock));
        pwd->pw_name = buffer;
        pwd->pw_passwd = buffer + 7;
        pwd->pw_gecos = buffer + 9;
        pwd->pw_dir = buffer + 21;
        pwd->pw_shell = buffer + 33;
    } else {
        pwd->pw_name = (char *)"mobile";
        pwd->pw_passwd = (char *)"*";
        pwd->pw_gecos = (char *)"Mobile User";
        pwd->pw_dir = (char *)"/var/mobile";
        pwd->pw_shell = (char *)"/usr/sbin/nologin";
    }
}

static struct passwd *pt_get_mobile_tls_passwd(uid_t uid, gid_t gid) {
    pthread_once(&s_pw_tls_once, pt_init_pw_tls_key);
    struct passwd *pw_buf = (struct passwd *)pthread_getspecific(s_pw_tls_key);
    if (pw_buf == NULL) {
        pw_buf = (struct passwd *)calloc(1, sizeof(struct passwd));
        if (pw_buf == NULL) {
            return NULL;
        }
        pthread_setspecific(s_pw_tls_key, pw_buf);
    }
    pt_fill_mobile_passwd_struct(uid, gid, pw_buf, NULL, 0);
    return pw_buf;
}

static BOOL pt_matches_host_username(const char *login) {
    if (login == NULL || login[0] == '\0' || strcmp(login, "mobile") == 0) {
        return NO;
    }
    const char *ur = pt_get_host_user_root_cstr();
    if (ur != NULL && strncmp(ur, "/Users/", 7) == 0) {
        const char *u = ur + 7;
        if (u[0] != '\0' && strcmp(login, u) == 0) {
            return YES;
        }
    }
    struct passwd *self_pw = getpwuid(getuid());
    if (self_pw != NULL && self_pw->pw_name != NULL && strcmp(login, self_pw->pw_name) == 0) {
        return YES;
    }
    return NO;
}

__attribute__((visibility("hidden"))) gid_t pt_map_spoofed_gid(gid_t raw_gid) {
    return (pt_is_bypass_enabled() && raw_gid == 20) ? (gid_t)501 : raw_gid;
}

static struct passwd *pt_getpwuid(uid_t uid) {
    struct passwd *real_pw = getpwuid(uid);
    if (real_pw != NULL &&
        (uid == getuid() || uid == 501) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        gid_t mapped_gid = pt_map_spoofed_gid(real_pw->pw_gid);
        struct passwd *pw_buf = pt_get_mobile_tls_passwd(real_pw->pw_uid, mapped_gid);
        if (pw_buf != NULL) {
            pw_buf->pw_change = real_pw->pw_change;
            pw_buf->pw_class = real_pw->pw_class;
            pw_buf->pw_expire = real_pw->pw_expire;
            return pw_buf;
        }
    }
    return real_pw;
}

static int pt_getpwuid_r(uid_t uid, struct passwd *pwd, char *buffer, size_t bufsize, struct passwd **result) {
    int rc = getpwuid_r(uid, pwd, buffer, bufsize, result);
    if (rc == 0 && pwd != NULL && result != NULL && *result != NULL &&
        (uid == getuid() || uid == 501) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        gid_t mapped_gid = pt_map_spoofed_gid(pwd->pw_gid);
        pt_fill_mobile_passwd_struct(pwd->pw_uid, mapped_gid, pwd, buffer, bufsize);
    }
    return rc;
}

static struct passwd *pt_getpwnam(const char *login) {
    if (login != NULL && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strcmp(login, "mobile") == 0) {
            gid_t mapped_gid = pt_map_spoofed_gid(getgid());
            struct passwd *pw_buf = pt_get_mobile_tls_passwd(getuid(), mapped_gid);
            if (pw_buf != NULL) {
                return pw_buf;
            }
        } else if (pt_matches_host_username(login)) {
            return NULL;
        }
    }
    return getpwnam(login);
}

static int pt_getpwnam_r(const char *login, struct passwd *pwd, char *buffer, size_t bufsize, struct passwd **result) {
    if (login != NULL && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strcmp(login, "mobile") == 0) {
            if (pwd == NULL || result == NULL) {
                return EINVAL;
            }
            gid_t mapped_gid = pt_map_spoofed_gid(getgid());
            pt_fill_mobile_passwd_struct(getuid(), mapped_gid, pwd, buffer, bufsize);
            *result = pwd;
            return 0;
        }
        if (pt_matches_host_username(login)) {
            if (result != NULL) {
                *result = NULL;
            }
            return 0;
        }
    }
    return getpwnam_r(login, pwd, buffer, bufsize, result);
}

static char *pt_getlogin(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (char *)"mobile";
    }
    return getlogin();
}

static int pt_getlogin_r(char *buf, size_t bufsize) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (buf == NULL || bufsize < 7) {
            return ERANGE;
        }
        memcpy(buf, "mobile", 7);
        return 0;
    }
    return getlogin_r(buf, bufsize);
}

static NSString *pt_NSUserName(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"mobile";
    }
    return NSUserName();
}

static NSString *pt_NSFullUserName(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"Mobile User";
    }
    return NSFullUserName();
}

static char *pt_user_from_uid(uid_t uid, int nouser) {
    if ((uid == getuid() || uid == 501) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (char *)"mobile";
    }
    return user_from_uid(uid, nouser);
}

__attribute__((visibility("hidden"))) gid_t pt_getgid_with_caller(const void *caller) {
    gid_t gid = getgid();
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        return pt_map_spoofed_gid(gid);
    }
    return gid;
}

static gid_t pt_getgid(void) {
    return pt_getgid_with_caller(__builtin_return_address(0));
}

__attribute__((visibility("hidden"))) gid_t pt_getegid_with_caller(const void *caller) {
    gid_t egid = getegid();
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        return pt_map_spoofed_gid(egid);
    }
    return egid;
}

static gid_t pt_getegid(void) {
    return pt_getegid_with_caller(__builtin_return_address(0));
}

__attribute__((visibility("hidden"))) BOOL pt_is_desktop_supplemental_gid(gid_t g) {
    return pt_is_desktop_supplemental_gid_c(g) ? YES : NO;
}

__attribute__((visibility("hidden"))) int pt_getgroups_with_caller(int gidsetsize, gid_t grouplist[], const void *caller) {
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return getgroups(gidsetsize, grouplist);
    }
    if (gidsetsize < 0) {
        errno = EINVAL;
        return -1;
    }
    gid_t host_groups[64];
    int host_n = getgroups(64, host_groups);
    if (host_n < 0) {
        host_groups[0] = getgid();
        host_n = 1;
    }

    gid_t filtered[64];
    int filtered_n = 0;
    for (int i = 0; i < host_n && filtered_n < 64; i++) {
        gid_t g = host_groups[i];
        if (pt_is_desktop_supplemental_gid(g)) {
            continue;
        }
        if (g == 20) {
            g = 501;
        }
        BOOL dup = NO;
        for (int j = 0; j < filtered_n; j++) {
            if (filtered[j] == g) {
                dup = YES;
                break;
            }
        }
        if (!dup) {
            filtered[filtered_n++] = g;
        }
    }
    if (filtered_n == 0) {
        filtered[0] = 501;
        filtered_n = 1;
    }
    if (gidsetsize == 0) {
        return filtered_n;
    }
    if (gidsetsize < filtered_n) {
        errno = EINVAL;
        return -1;
    }
    if (grouplist == NULL) {
        errno = EFAULT;
        return -1;
    }
    for (int i = 0; i < filtered_n; i++) {
        grouplist[i] = filtered[i];
    }
    return filtered_n;
}

static int pt_getgroups(int gidsetsize, gid_t grouplist[]) {
    return pt_getgroups_with_caller(gidsetsize, grouplist, __builtin_return_address(0));
}

static BOOL pt_is_hidden_macos_group_name(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    if (strncmp(name, "com.apple.sharepoint.", 21) == 0 ||
        strncmp(name, "com.apple.access_", 17) == 0) {
        return YES;
    }
    static const char *const kHiddenGroups[] = {
        "staff", "admin", "everyone", "certusers", "localaccounts",
        "_developer", "_appstore", "_lpadmin", "_lpoperator",
        "_appserverusr", "_appserveradm", "_analyticsusers",
    };
    for (size_t i = 0; i < sizeof(kHiddenGroups) / sizeof(kHiddenGroups[0]); i++) {
        if (strcmp(name, kHiddenGroups[i]) == 0) {
            return YES;
        }
    }
    return NO;
}

static struct group *pt_tls_mobile_group(void) {
    static _Thread_local struct group tls_grp;
    static _Thread_local char tls_name[16];
    static _Thread_local char tls_passwd[4];
    static _Thread_local char *tls_members[2];
    strlcpy(tls_name, "mobile", sizeof(tls_name));
    strlcpy(tls_passwd, "*", sizeof(tls_passwd));
    tls_members[0] = tls_name;
    tls_members[1] = NULL;
    tls_grp.gr_name = tls_name;
    tls_grp.gr_passwd = tls_passwd;
    tls_grp.gr_gid = 501;
    tls_grp.gr_mem = tls_members;
    return &tls_grp;
}

static int pt_fill_mobile_group_r(struct group *grp, char *buf, size_t bufsize, struct group **result) {
    if (result != NULL) {
        *result = NULL;
    }
    if (grp == NULL || buf == NULL) {
        return EINVAL;
    }
    uintptr_t p = (uintptr_t)buf;
    uintptr_t aligned = (p + (sizeof(char *) - 1U)) & ~(uintptr_t)(sizeof(char *) - 1U);
    size_t pad = (size_t)(aligned - p);
    size_t needed = pad + 2U * sizeof(char *) + 7U + 2U;
    if (bufsize < needed) {
        return ERANGE;
    }
    char **mem = (char **)aligned;
    char *gname = (char *)(aligned + 2U * sizeof(char *));
    char *gpass = gname + 7U;
    memcpy(gname, "mobile", 7U);
    memcpy(gpass, "*", 2U);
    mem[0] = gname;
    mem[1] = NULL;
    grp->gr_name = gname;
    grp->gr_passwd = gpass;
    grp->gr_gid = 501;
    grp->gr_mem = mem;
    if (result != NULL) {
        *result = grp;
    }
    return 0;
}

static struct group *pt_getgrgid(gid_t gid) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (gid == 501) {
            return pt_tls_mobile_group();
        }
        if (gid == 20 || pt_is_desktop_supplemental_gid(gid)) {
            return NULL;
        }
    }
    return getgrgid(gid);
}

static int pt_getgrgid_r(gid_t gid, struct group *grp, char *buf, size_t bufsize, struct group **result) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (gid == 501) {
            return pt_fill_mobile_group_r(grp, buf, bufsize, result);
        }
        if (gid == 20 || pt_is_desktop_supplemental_gid(gid)) {
            if (result != NULL) {
                *result = NULL;
            }
            return 0;
        }
    }
    return getgrgid_r(gid, grp, buf, bufsize, result);
}

static struct group *pt_getgrnam(const char *name) {
    if (name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strcmp(name, "mobile") == 0) {
            return pt_tls_mobile_group();
        }
        if (pt_is_hidden_macos_group_name(name)) {
            return NULL;
        }
    }
    return getgrnam(name);
}

static int pt_getgrnam_r(const char *name, struct group *grp, char *buf, size_t bufsize, struct group **result) {
    if (name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strcmp(name, "mobile") == 0) {
            return pt_fill_mobile_group_r(grp, buf, bufsize, result);
        }
        if (pt_is_hidden_macos_group_name(name)) {
            if (result != NULL) {
                *result = NULL;
            }
            return 0;
        }
    }
    return getgrnam_r(name, grp, buf, bufsize, result);
}

extern int pt_orig_getgrouplist(const char *name, int basegid, int *groups, int *ngroups) __asm("_getgrouplist");

static int pt_getgrouplist(const char *name, int basegid, int *groups, int *ngroups) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (ngroups == NULL) {
            errno = EINVAL;
            return -1;
        }
        gid_t mapped = pt_map_spoofed_gid((gid_t)basegid);
        if (pt_is_desktop_supplemental_gid(mapped)) {
            mapped = 501;
        }
        if (*ngroups < 1) {
            *ngroups = 1;
            return -1;
        }
        if (groups == NULL) {
            errno = EFAULT;
            return -1;
        }
        groups[0] = (int)mapped;
        *ngroups = 1;
        return 0;
    }
    return pt_orig_getgrouplist(name, basegid, groups, ngroups);
}

struct utmpx;

static struct utmpx *pt_getutxent(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    typedef struct utmpx *(*GetUtxEntFn)(void);
    static GetUtxEntFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (GetUtxEntFn)dlsym(RTLD_NEXT, "getutxent");
    });
    return (s_orig != NULL) ? s_orig() : NULL;
}

static struct utmpx *pt_getutxid(const struct utmpx *ut) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    typedef struct utmpx *(*GetUtxIdFn)(const struct utmpx *);
    static GetUtxIdFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (GetUtxIdFn)dlsym(RTLD_NEXT, "getutxid");
    });
    return (s_orig != NULL) ? s_orig(ut) : NULL;
}

static struct utmpx *pt_getutxline(const struct utmpx *ut) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    typedef struct utmpx *(*GetUtxLineFn)(const struct utmpx *);
    static GetUtxLineFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (GetUtxLineFn)dlsym(RTLD_NEXT, "getutxline");
    });
    return (s_orig != NULL) ? s_orig(ut) : NULL;
}

__attribute__((visibility("hidden")))
int pt_gethostuuid_with_caller(uuid_t id, const struct timespec *wait, const void *caller) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        errno = EPERM;
        return -1;
    }
    typedef int (*GetHostUuidFn)(uuid_t, const struct timespec *);
    static GetHostUuidFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (GetHostUuidFn)dlsym(RTLD_NEXT, "gethostuuid");
    });
    if (s_orig != NULL) {
        return s_orig(id, wait);
    }
    errno = ENOSYS;
    return -1;
}

static int pt_gethostuuid(uuid_t id, const struct timespec *wait) {
    return pt_gethostuuid_with_caller(id, wait, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_getauid_with_caller(void *auid, const void *caller) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        errno = EPERM;
        return -1;
    }
    typedef int (*GetAuidFn)(void *);
    static GetAuidFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (GetAuidFn)dlsym(RTLD_NEXT, "getauid");
    });
    if (s_orig != NULL) {
        return s_orig(auid);
    }
    errno = ENOSYS;
    return -1;
}

static int pt_getauid(void *auid) {
    return pt_getauid_with_caller(auid, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_getaudit_addr_with_caller(void *auinfo, int length, const void *caller) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        errno = EPERM;
        return -1;
    }
    typedef int (*GetAuditAddrFn)(void *, int);
    static GetAuditAddrFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (GetAuditAddrFn)dlsym(RTLD_NEXT, "getaudit_addr");
    });
    if (s_orig != NULL) {
        return s_orig(auinfo, length);
    }
    errno = ENOSYS;
    return -1;
}

static int pt_getaudit_addr(void *auinfo, int length) {
    return pt_getaudit_addr_with_caller(auinfo, length, __builtin_return_address(0));
}

#ifndef PT_KEVENT_FLAG_IMMEDIATE
#define PT_KEVENT_FLAG_IMMEDIATE 0x000001U
#endif

__attribute__((visibility("hidden"))) int pt_kevent_with_caller(int kq,
                                 const struct kevent *changelist,
                                 int nchanges,
                                 struct kevent *eventlist,
                                 int nevents,
                                 const struct timespec *timeout,
                                 const void *caller) {
    if (changelist != NULL && nchanges > 0 &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        uintptr_t self_pid = (uintptr_t)getpid();
        int blocked = 0;
        for (int i = 0; i < nchanges; i++) {
            if (changelist[i].filter == EVFILT_PROC && changelist[i].ident != self_pid) {
                blocked++;
            }
        }
        if (blocked > 0) {
            if (eventlist == NULL || nevents <= 0) {
                errno = ESRCH;
                return -1;
            }
            int reported = 0;
            struct kevent stack_kept[32];
            struct kevent *kept = stack_kept;
            int kept_cnt = 0;
            int need_kept = nchanges - blocked;
            if (need_kept > (int)(sizeof(stack_kept) / sizeof(stack_kept[0]))) {
                kept = (struct kevent *)malloc((size_t)need_kept * sizeof(struct kevent));
                if (kept == NULL) {
                    errno = ENOMEM;
                    return -1;
                }
            }
            for (int i = 0; i < nchanges; i++) {
                if (changelist[i].filter == EVFILT_PROC && changelist[i].ident != self_pid) {
                    if (reported < nevents) {
                        eventlist[reported] = changelist[i];
                        eventlist[reported].flags = EV_ERROR;
                        eventlist[reported].data = ESRCH;
                        reported++;
                    }
                } else {
                    kept[kept_cnt++] = changelist[i];
                }
            }
            int extra = 0;
            if (kept_cnt > 0 && reported < nevents) {
                int saved_errno = errno;
                struct timespec zero_ts = {0, 0};
                int r = kevent(kq, kept, kept_cnt, eventlist + reported, nevents - reported, &zero_ts);
                if (r < 0) {
                    if (errno == EBADF) {
                        if (kept != stack_kept) {
                            free(kept);
                        }
                        errno = EBADF;
                        return -1;
                    }
                    errno = saved_errno;
                } else if (r > 0) {
                    extra = r;
                }
            } else if (kept_cnt > 0) {
                int saved_errno = errno;
                struct timespec zero_ts = {0, 0};
                int r = kevent(kq, kept, kept_cnt, NULL, 0, &zero_ts);
                if (r < 0) {
                    if (errno == EBADF) {
                        if (kept != stack_kept) {
                            free(kept);
                        }
                        errno = EBADF;
                        return -1;
                    }
                    errno = saved_errno;
                }
            }
            if (kept != stack_kept) {
                free(kept);
            }
            return reported + extra;
        }
    }
    return kevent(kq, changelist, nchanges, eventlist, nevents, timeout);
}

static int pt_kevent(int kq,
                     const struct kevent *changelist,
                     int nchanges,
                     struct kevent *eventlist,
                     int nevents,
                     const struct timespec *timeout) {
    return pt_kevent_with_caller(kq, changelist, nchanges, eventlist, nevents, timeout, __builtin_return_address(0));
}

__attribute__((visibility("hidden"))) int pt_kevent64_with_caller(int kq,
                                   const struct kevent64_s *changelist,
                                   int nchanges,
                                   struct kevent64_s *eventlist,
                                   int nevents,
                                   unsigned int flags,
                                   const struct timespec *timeout,
                                   const void *caller) {
    if (changelist != NULL && nchanges > 0 &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        uint64_t self_pid = (uint64_t)getpid();
        int blocked = 0;
        for (int i = 0; i < nchanges; i++) {
            if (changelist[i].filter == EVFILT_PROC && changelist[i].ident != self_pid) {
                blocked++;
            }
        }
        if (blocked > 0) {
            if (eventlist == NULL || nevents <= 0) {
                errno = ESRCH;
                return -1;
            }
            int reported = 0;
            struct kevent64_s stack_kept[32];
            struct kevent64_s *kept = stack_kept;
            int kept_cnt = 0;
            int need_kept = nchanges - blocked;
            if (need_kept > (int)(sizeof(stack_kept) / sizeof(stack_kept[0]))) {
                kept = (struct kevent64_s *)malloc((size_t)need_kept * sizeof(struct kevent64_s));
                if (kept == NULL) {
                    errno = ENOMEM;
                    return -1;
                }
            }
            for (int i = 0; i < nchanges; i++) {
                if (changelist[i].filter == EVFILT_PROC && changelist[i].ident != self_pid) {
                    if (reported < nevents) {
                        eventlist[reported] = changelist[i];
                        eventlist[reported].flags = EV_ERROR;
                        eventlist[reported].data = ESRCH;
                        reported++;
                    }
                } else {
                    kept[kept_cnt++] = changelist[i];
                }
            }
            int extra = 0;
            if (kept_cnt > 0 && reported < nevents) {
                int saved_errno = errno;
                struct timespec zero_ts = {0, 0};
                int r = kevent64(kq, kept, kept_cnt, eventlist + reported, nevents - reported, flags, &zero_ts);
                if (r < 0) {
                    if (errno == EBADF) {
                        if (kept != stack_kept) {
                            free(kept);
                        }
                        errno = EBADF;
                        return -1;
                    }
                    errno = saved_errno;
                } else if (r > 0) {
                    extra = r;
                }
            } else if (kept_cnt > 0) {
                int saved_errno = errno;
                struct timespec zero_ts = {0, 0};
                int r = kevent64(kq, kept, kept_cnt, NULL, 0, flags, &zero_ts);
                if (r < 0) {
                    if (errno == EBADF) {
                        if (kept != stack_kept) {
                            free(kept);
                        }
                        errno = EBADF;
                        return -1;
                    }
                    errno = saved_errno;
                }
            }
            if (kept != stack_kept) {
                free(kept);
            }
            return reported + extra;
        }
    }
    return kevent64(kq, changelist, nchanges, eventlist, nevents, flags, timeout);
}

static int pt_kevent64(int kq,
                       const struct kevent64_s *changelist,
                       int nchanges,
                       struct kevent64_s *eventlist,
                       int nevents,
                       unsigned int flags,
                       const struct timespec *timeout) {
    return pt_kevent64_with_caller(kq, changelist, nchanges, eventlist, nevents, flags, timeout, __builtin_return_address(0));
}

__attribute__((visibility("hidden"))) int pt_kevent_qos_with_caller(int kq,
                                     const pt_kevent_qos_s *changelist,
                                     int nchanges,
                                     pt_kevent_qos_s *eventlist,
                                     int nevents,
                                     void *data_out,
                                     size_t *data_available,
                                     unsigned int flags,
                                     const void *caller) {
    typedef int (*KeventQosFn)(int, const pt_kevent_qos_s *, int, pt_kevent_qos_s *, int, void *, size_t *, unsigned int);
    static KeventQosFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (KeventQosFn)dlsym(RTLD_NEXT, "kevent_qos");
    });
    if (s_orig == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (changelist != NULL && nchanges > 0 &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        uint64_t self_pid = (uint64_t)getpid();
        int blocked = 0;
        for (int i = 0; i < nchanges; i++) {
            if (changelist[i].filter == EVFILT_PROC && changelist[i].ident != self_pid) {
                blocked++;
            }
        }
        if (blocked > 0) {
            if (eventlist == NULL || nevents <= 0) {
                errno = ESRCH;
                return -1;
            }
            int reported = 0;
            pt_kevent_qos_s stack_kept[32];
            pt_kevent_qos_s *kept = stack_kept;
            int kept_cnt = 0;
            int need_kept = nchanges - blocked;
            if (need_kept > (int)(sizeof(stack_kept) / sizeof(stack_kept[0]))) {
                kept = (pt_kevent_qos_s *)malloc((size_t)need_kept * sizeof(pt_kevent_qos_s));
                if (kept == NULL) {
                    errno = ENOMEM;
                    return -1;
                }
            }
            for (int i = 0; i < nchanges; i++) {
                if (changelist[i].filter == EVFILT_PROC && changelist[i].ident != self_pid) {
                    if (reported < nevents) {
                        eventlist[reported] = changelist[i];
                        eventlist[reported].flags = EV_ERROR;
                        eventlist[reported].data = ESRCH;
                        reported++;
                    }
                } else {
                    kept[kept_cnt++] = changelist[i];
                }
            }
            int extra = 0;
            if (kept_cnt > 0 && reported < nevents) {
                int saved_errno = errno;
                int r = s_orig(kq, kept, kept_cnt, eventlist + reported, nevents - reported,
                               data_out, data_available, flags | PT_KEVENT_FLAG_IMMEDIATE);
                if (r < 0) {
                    if (errno == EBADF) {
                        if (kept != stack_kept) {
                            free(kept);
                        }
                        errno = EBADF;
                        return -1;
                    }
                    errno = saved_errno;
                } else if (r > 0) {
                    extra = r;
                }
            } else if (kept_cnt > 0) {
                int saved_errno = errno;
                int r = s_orig(kq, kept, kept_cnt, NULL, 0, data_out, data_available,
                               flags | PT_KEVENT_FLAG_IMMEDIATE);
                if (r < 0) {
                    if (errno == EBADF) {
                        if (kept != stack_kept) {
                            free(kept);
                        }
                        errno = EBADF;
                        return -1;
                    }
                    errno = saved_errno;
                }
            }
            if (kept != stack_kept) {
                free(kept);
            }
            return reported + extra;
        }
    }
    return s_orig(kq, changelist, nchanges, eventlist, nevents, data_out, data_available, flags);
}

static int pt_kevent_qos(int kq,
                         const pt_kevent_qos_s *changelist,
                         int nchanges,
                         pt_kevent_qos_s *eventlist,
                         int nevents,
                         void *data_out,
                         size_t *data_available,
                         unsigned int flags) {
    return pt_kevent_qos_with_caller(kq, changelist, nchanges, eventlist, nevents,
                                     data_out, data_available, flags, __builtin_return_address(0));
}

#define PT_THERMAL_NOTIFY_TOKEN_CAP 64U
static os_unfair_lock s_thermal_notify_lock = OS_UNFAIR_LOCK_INIT;
static int s_thermal_notify_tokens[PT_THERMAL_NOTIFY_TOKEN_CAP];
static BOOL s_thermal_notify_valid[PT_THERMAL_NOTIFY_TOKEN_CAP];

static void pt_record_thermal_notify_token(int token) {
    os_unfair_lock_lock(&s_thermal_notify_lock);
    int free_idx = -1;
    for (size_t i = 0; i < PT_THERMAL_NOTIFY_TOKEN_CAP; i++) {
        if (s_thermal_notify_valid[i] && s_thermal_notify_tokens[i] == token) {
            os_unfair_lock_unlock(&s_thermal_notify_lock);
            return;
        }
        if (!s_thermal_notify_valid[i] && free_idx < 0) {
            free_idx = (int)i;
        }
    }
    if (free_idx >= 0) {
        s_thermal_notify_tokens[free_idx] = token;
        s_thermal_notify_valid[free_idx] = YES;
    }
    os_unfair_lock_unlock(&s_thermal_notify_lock);
}

static void pt_remove_thermal_notify_token(int token) {
    os_unfair_lock_lock(&s_thermal_notify_lock);
    for (size_t i = 0; i < PT_THERMAL_NOTIFY_TOKEN_CAP; i++) {
        if (s_thermal_notify_valid[i] && s_thermal_notify_tokens[i] == token) {
            s_thermal_notify_valid[i] = NO;
            s_thermal_notify_tokens[i] = 0;
        }
    }
    os_unfair_lock_unlock(&s_thermal_notify_lock);
}

static BOOL pt_is_thermal_notify_token(int token) {
    BOOL found = NO;
    os_unfair_lock_lock(&s_thermal_notify_lock);
    for (size_t i = 0; i < PT_THERMAL_NOTIFY_TOKEN_CAP; i++) {
        if (s_thermal_notify_valid[i] && s_thermal_notify_tokens[i] == token) {
            found = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&s_thermal_notify_lock);
    return found;
}

static uint32_t pt_notify_register_check(const char *name, int *out_token) {
    uint32_t st = notify_register_check(name, out_token);
    if (st == NOTIFY_STATUS_OK && out_token != NULL && name != NULL &&
        strcmp(name, "com.apple.system.thermalpressurelevel") == 0) {
        pt_record_thermal_notify_token(*out_token);
    }
    return st;
}

static uint32_t pt_notify_register_dispatch(const char *name,
                                            int *out_token,
                                            dispatch_queue_t queue,
                                            notify_handler_t handler) {
    uint32_t st = notify_register_dispatch(name, out_token, queue, handler);
    if (st == NOTIFY_STATUS_OK && out_token != NULL && name != NULL &&
        strcmp(name, "com.apple.system.thermalpressurelevel") == 0) {
        pt_record_thermal_notify_token(*out_token);
    }
    return st;
}

static uint32_t pt_notify_cancel(int token) {
    pt_remove_thermal_notify_token(token);
    return notify_cancel(token);
}

static uint32_t pt_notify_get_state(int token, uint64_t *state64) {
    uint32_t st = notify_get_state(token, state64);
    if (st == NOTIFY_STATUS_OK && state64 != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_thermal_notify_token(token)) {
        *state64 = 0ULL;
    }
    return st;
}

static long pt_sysconf(int name) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        switch (name) {
            case _SC_NPROCESSORS_CONF:
            case _SC_NPROCESSORS_ONLN:
                return (long)profile->cores;
            case _SC_PAGESIZE:
                return 16384L;
            case _SC_PHYS_PAGES:
                return (long)(profile->ram_bytes / 16384ULL);
            default:
                break;
        }
    }
    return sysconf(name);
}

static size_t pt_confstr(int name, char *buf, size_t len) {
    size_t ret = confstr(name, buf, len);
    if (ret > 0 && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (name == _CS_PATH) {
            static const char kIosPath[] = "/usr/bin:/bin:/usr/sbin:/sbin";
            if (buf != NULL && len > 0) {
                strlcpy(buf, kIosPath, len);
            }
            return sizeof(kIosPath);
        }
        if (name == _CS_DARWIN_USER_DIR ||
            name == _CS_DARWIN_USER_TEMP_DIR ||
            name == _CS_DARWIN_USER_CACHE_DIR) {
            pt_ensure_data_container_map();
            const char *sub = (name == _CS_DARWIN_USER_TEMP_DIR) ? "/tmp/" :
                              (name == _CS_DARWIN_USER_CACHE_DIR) ? "/Library/Caches/" : "/";
            const char *base_dir = (s_virtual_private_data_len > 0) ? s_virtual_private_data_dir : "/private/var/mobile";
            char vpath[PATH_MAX];
            int n = snprintf(vpath, sizeof(vpath), "%s%s", base_dir, sub);
            if (n > 0 && (size_t)n < sizeof(vpath)) {
                if (buf != NULL && len > 0) {
                    strlcpy(buf, vpath, len);
                }
                return (size_t)n + 1;
            }
            if (buf != NULL && len > 0) {
                char vout[PATH_MAX];
                const char *virt = pt_virtualize_path_for_app(buf, vout, sizeof(vout), NO);
                if (virt != buf) {
                    return strlcpy(buf, virt, len) + 1;
                }
            }
        }
    }
    return ret;
}


__attribute__((visibility("hidden"))) BOOL pt_is_hidden_thread_name(const char *name) {
    return pt_is_hidden_thread_name_cstr(name) ? YES : NO;
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_mach_thread(thread_act_t thr) {
    if (thr == MACH_PORT_NULL) {
        return NO;
    }
    pthread_t pt = pthread_from_mach_thread_np(thr);
    if (pt != NULL) {
        char tname[MAXTHREADNAMESIZE];
        tname[0] = '\0';
        if (pthread_getname_np(pt, tname, sizeof(tname)) == 0 &&
            pt_is_hidden_thread_name(tname)) {
            return YES;
        }
    }
    thread_identifier_info_data_t id_info;
    mach_msg_type_number_t id_cnt = THREAD_IDENTIFIER_INFO_COUNT;
    if (thread_info(thr, THREAD_IDENTIFIER_INFO, (thread_info_t)&id_info, &id_cnt) == KERN_SUCCESS) {
        struct proc_threadinfo pinfo;
        int n = proc_pidinfo(getpid(), PROC_PIDTHREADINFO, id_info.thread_id, &pinfo, (int)sizeof(pinfo));
        if (n > 0 && (size_t)n >= sizeof(pinfo) && pt_is_hidden_thread_name(pinfo.pth_name)) {
            return YES;
        }
    }
    return NO;
}

static kern_return_t pt_task_threads(task_inspect_t target_task,
                                    thread_act_array_t *act_list,
                                    mach_msg_type_number_t *act_listCnt) {
    kern_return_t kr = task_threads(target_task, act_list, act_listCnt);
    if (kr != KERN_SUCCESS || act_list == NULL || *act_list == NULL ||
        act_listCnt == NULL || *act_listCnt == 0) {
        return kr;
    }
    if (target_task != mach_task_self() ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return kr;
    }
    mach_msg_type_number_t orig_cnt = *act_listCnt;
    thread_act_t *orig_list = *act_list;
    thread_act_t stack_kept[256];
    thread_act_t *kept_buf = stack_kept;
    if (orig_cnt > (mach_msg_type_number_t)(sizeof(stack_kept) / sizeof(stack_kept[0]))) {
        kept_buf = (thread_act_t *)malloc((size_t)orig_cnt * sizeof(thread_act_t));
        if (kept_buf == NULL) {
            return kr;
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
        if (kept == 0) {
            vm_deallocate(mach_task_self(), (vm_address_t)orig_list, (vm_size_t)(orig_cnt * sizeof(thread_act_t)));
            *act_list = NULL;
            *act_listCnt = 0;
        } else {
            vm_address_t new_addr = 0;
            if (vm_allocate(mach_task_self(), &new_addr, (vm_size_t)(kept * sizeof(thread_act_t)), VM_FLAGS_ANYWHERE) == KERN_SUCCESS) {
                thread_act_t *new_list = (thread_act_t *)new_addr;
                memcpy(new_list, kept_buf, (size_t)kept * sizeof(thread_act_t));
                vm_deallocate(mach_task_self(), (vm_address_t)orig_list, (vm_size_t)(orig_cnt * sizeof(thread_act_t)));
                *act_list = new_list;
                *act_listCnt = kept;
            } else {
                memcpy(orig_list, kept_buf, (size_t)kept * sizeof(thread_act_t));
                *act_listCnt = kept;
            }
        }
    }
    if (kept_buf != stack_kept) {
        free(kept_buf);
    }
    return KERN_SUCCESS;
}

static int pt_pthread_getname_np(pthread_t thread, char *name, size_t len) {
    int ret = pthread_getname_np(thread, name, len);
    if (ret == 0 && name != NULL && len > 0 &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_thread_name(name)) {
            name[0] = '\0';
        }
    }
    return ret;
}

static kern_return_t pt_thread_info(thread_inspect_t target_act,
                                    thread_flavor_t flavor,
                                    thread_info_t thread_info_out,
                                    mach_msg_type_number_t *thread_info_outCnt) {
    kern_return_t kr = thread_info(target_act, flavor, thread_info_out, thread_info_outCnt);
    if (kr == KERN_SUCCESS &&
        flavor == THREAD_EXTENDED_INFO &&
        thread_info_out != NULL &&
        thread_info_outCnt != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        size_t out_bytes = (size_t)(*thread_info_outCnt) * sizeof(integer_t);
        if (out_bytes >= offsetof(thread_extended_info_data_t, pth_name) +
                         sizeof(((thread_extended_info_data_t *)0)->pth_name)) {
            thread_extended_info_data_t *ext = (thread_extended_info_data_t *)thread_info_out;
            char namebuf[sizeof(ext->pth_name) + 1];
            size_t nlen = strnlen(ext->pth_name, sizeof(ext->pth_name));
            memcpy(namebuf, ext->pth_name, nlen);
            namebuf[nlen] = '\0';
            if (pt_is_hidden_thread_name(namebuf)) {
                memset(ext->pth_name, 0, sizeof(ext->pth_name));
            }
        }
    }
    return kr;
}


static pid_t pt_fork(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PT_DEBUG_TRACE("spoofer", "blocked fork with EPERM");
        errno = EPERM;
        return -1;
    }
    return fork();
}

static pid_t pt_vfork(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = EPERM;
        return -1;
    }
    // Returning from an interposed wrapper after vfork() is undefined behavior on the parent stack.
    return fork();
}

extern FILE *pt_orig_popen_darwin_extsn(const char *, const char *) __asm("_popen$DARWIN_EXTSN");

static FILE *pt_popen(const char *command, const char *mode) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = EPERM;
        return NULL;
    }
    return popen(command, mode);
}

static FILE *pt_popen_darwin_extsn(const char *command, const char *mode) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = EPERM;
        return NULL;
    }
    return pt_orig_popen_darwin_extsn(command, mode);
}

static int pt_posix_spawn(pid_t * restrict pid,
                          const char * restrict path,
                          const posix_spawn_file_actions_t *file_actions,
                          const posix_spawnattr_t * restrict attrp,
                          char *const argv[restrict],
                          char *const envp[restrict]) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PT_DEBUG_TRACE("spoofer", "blocked posix_spawn path=%s", path != NULL ? path : "<null>");
        return EPERM;
    }
    return posix_spawn(pid, path, file_actions, attrp, argv, envp);
}

static int pt_posix_spawnp(pid_t * restrict pid,
                           const char * restrict file,
                           const posix_spawn_file_actions_t *file_actions,
                           const posix_spawnattr_t * restrict attrp,
                           char *const argv[restrict],
                           char *const envp[restrict]) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return EPERM;
    }
    return posix_spawnp(pid, file, file_actions, attrp, argv, envp);
}

extern int pt_orig_system(const char *) __asm("_system");
static int pt_system(const char *command) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (command == NULL) {
            return 0;
        }
        errno = EPERM;
        return -1;
    }
    return pt_orig_system(command);
}

static pid_t pt_getppid(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 1;
    }
    return getppid();
}

static int pt_isatty(int fd) {
    if (fd < 0) {
        errno = EBADF;
        return 0;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        fd >= 0 && fd <= 2) {
        return 0;
    }
    return isatty(fd);
}


__attribute__((visibility("hidden"))) dispatch_once_t thread_sleep_once;
__attribute__((visibility("hidden"))) dispatch_semaphore_t thread_sleep_sem = nil;
__attribute__((visibility("hidden"))) _Atomic int s_block_sleep_spamming_cached = -1;
static pthread_once_t s_sleep_setting_once = PTHREAD_ONCE_INIT;
static _Thread_local uint32_t tls_sleep_counter = 0;
static _Thread_local uint64_t tls_sleep_timestamp = 0;

static void pt_init_sleep_setting(void) {
    @autoreleasepool {
        atomic_store_explicit(&s_block_sleep_spamming_cached,
                              [[PlaySettings shared] blockSleepSpamming] ? 1 : 0,
                              memory_order_release);
    }
}

static int pt_usleep(useconds_t usec) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return usleep(usec);
    }
    if (atomic_load_explicit(&s_pt_loaded, memory_order_acquire) &&
        atomic_load_explicit(&s_block_sleep_spamming_cached, memory_order_acquire) < 0) {
        pthread_once(&s_sleep_setting_once, pt_init_sleep_setting);
    }
    if (atomic_load_explicit(&s_block_sleep_spamming_cached, memory_order_acquire) == 1) {
        dispatch_once(&thread_sleep_once, ^{
            thread_sleep_sem = dispatch_semaphore_create(0);
        });
        if (usec == 100000) {
            uint64_t now = (uint64_t)time(NULL);
            if (now >= tls_sleep_timestamp && (now - tls_sleep_timestamp) < 2) {
                tls_sleep_counter++;
            } else {
                tls_sleep_counter = 1;
            }
            tls_sleep_timestamp = now;
        }
        if (tls_sleep_counter > 100) {
            PT_DEBUG_TRACE("spoofer", "stalled sleep-spamming thread usec=%u count=%u",
                           (unsigned int)usec, tls_sleep_counter);
            dispatch_semaphore_wait(thread_sleep_sem, DISPATCH_TIME_FOREVER);
            dispatch_semaphore_signal(thread_sleep_sem);
            return 0;
        }
    }
    return usleep(usec);
}

#ifndef PT_BOOTSTRAP_UNKNOWN_SERVICE
#define PT_BOOTSTRAP_UNKNOWN_SERVICE 1102
#endif

extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

static kern_return_t pt_bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp) {
    if (service_name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_macos_mach_service(service_name)) {
        if (sp != NULL) {
            *sp = MACH_PORT_NULL;
        }
        return PT_BOOTSTRAP_UNKNOWN_SERVICE;
    }
    return bootstrap_look_up(bp, service_name, sp);
}

static kern_return_t pt_bootstrap_look_up2(mach_port_t bp,
                                           const char *service_name,
                                           mach_port_t *sp,
                                           pid_t target_pid,
                                           uint64_t flags) {
    if (service_name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_macos_mach_service(service_name)) {
        if (sp != NULL) {
            *sp = MACH_PORT_NULL;
        }
        return PT_BOOTSTRAP_UNKNOWN_SERVICE;
    }
    typedef kern_return_t (*BootstrapLookUp2Fn)(mach_port_t, const char *, mach_port_t *, pid_t, uint64_t);
    static BootstrapLookUp2Fn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (BootstrapLookUp2Fn)dlsym(RTLD_NEXT, "bootstrap_look_up2");
    });
    if (s_orig != NULL) {
        return s_orig(bp, service_name, sp, target_pid, flags);
    }
    if (sp != NULL) {
        *sp = MACH_PORT_NULL;
    }
    return PT_BOOTSTRAP_UNKNOWN_SERVICE;
}

static kern_return_t pt_bootstrap_look_up3(mach_port_t bp,
                                           const char *service_name,
                                           mach_port_t *sp,
                                           pid_t target_pid,
                                           const uuid_t instance_id,
                                           uint64_t flags) {
    if (service_name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_macos_mach_service(service_name)) {
        if (sp != NULL) {
            *sp = MACH_PORT_NULL;
        }
        return PT_BOOTSTRAP_UNKNOWN_SERVICE;
    }
    typedef kern_return_t (*BootstrapLookUp3Fn)(mach_port_t, const char *, mach_port_t *, pid_t, const uuid_t, uint64_t);
    static BootstrapLookUp3Fn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (BootstrapLookUp3Fn)dlsym(RTLD_NEXT, "bootstrap_look_up3");
    });
    if (s_orig != NULL) {
        return s_orig(bp, service_name, sp, target_pid, instance_id, flags);
    }
    if (sp != NULL) {
        *sp = MACH_PORT_NULL;
    }
    return PT_BOOTSTRAP_UNKNOWN_SERVICE;
}

static pid_t pt_responsibility_get_pid_responsible_for_pid(pid_t pid) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pid_t self_pid = getpid();
        if (pid == 0 || pid == self_pid) {
            return self_pid;
        }
        errno = ESRCH;
        return -1;
    }
    typedef pid_t (*RespFn)(pid_t);
    static RespFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (RespFn)dlsym(RTLD_NEXT, "responsibility_get_pid_responsible_for_pid");
    });
    if (s_orig != NULL) {
        return s_orig(pid);
    }
    errno = ENOSYS;
    return -1;
}

static void pt_u_getVersion(uint8_t versionArray[4]) {
    if (versionArray != NULL &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        versionArray[0] = 64U;
        versionArray[1] = 2U;
        versionArray[2] = 0U;
        versionArray[3] = 0U;
        return;
    }
    typedef void (*UGetVerFn)(uint8_t[4]);
    static UGetVerFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (UGetVerFn)dlsym(RTLD_NEXT, "u_getVersion");
    });
    if (s_orig != NULL) {
        s_orig(versionArray);
    }
}

static void pt_u_getUnicodeVersion(uint8_t versionArray[4]) {
    if (versionArray != NULL &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        versionArray[0] = 12U;
        versionArray[1] = 1U;
        versionArray[2] = 0U;
        versionArray[3] = 0U;
        return;
    }
    typedef void (*UGetUniVerFn)(uint8_t[4]);
    static UGetUniVerFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (UGetUniVerFn)dlsym(RTLD_NEXT, "u_getUnicodeVersion");
    });
    if (s_orig != NULL) {
        s_orig(versionArray);
    }
}

typedef void (*PTUCharAgeFn)(int32_t, uint8_t[4]);
static PTUCharAgeFn pt_get_real_u_charAge(void) {
    static PTUCharAgeFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (PTUCharAgeFn)dlsym(RTLD_NEXT, "u_charAge");
    });
    return s_orig;
}

static BOOL pt_icu_codepoint_post_unicode_12_1(int32_t c) {
    PTUCharAgeFn fn = pt_get_real_u_charAge();
    if (fn == NULL) {
        return NO;
    }
    uint8_t age[4] = {0, 0, 0, 0};
    fn(c, age);
    return (age[0] > 12U || (age[0] == 12U && age[1] > 1U));
}

static void pt_u_charAge(int32_t c, uint8_t versionArray[4]) {
    PTUCharAgeFn fn = pt_get_real_u_charAge();
    if (fn != NULL) {
        fn(c, versionArray);
    } else if (versionArray != NULL) {
        memset(versionArray, 0, 4U);
    }
    if (versionArray != NULL &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (versionArray[0] > 12U || (versionArray[0] == 12U && versionArray[1] > 1U)) {
            memset(versionArray, 0, 4U);
        }
    }
}

static int8_t pt_u_charType(int32_t c) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return 0; // U_UNASSIGNED
    }
    typedef int8_t (*UCharTypeFn)(int32_t);
    static UCharTypeFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (UCharTypeFn)dlsym(RTLD_NEXT, "u_charType");
    });
    return (s_orig != NULL) ? s_orig(c) : 0;
}

static int8_t pt_u_isdefined(int32_t c) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return 0;
    }
    typedef int8_t (*UIsDefinedFn)(int32_t);
    static UIsDefinedFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (UIsDefinedFn)dlsym(RTLD_NEXT, "u_isdefined");
    });
    return (s_orig != NULL) ? s_orig(c) : 0;
}

static int8_t pt_u_hasBinaryProperty(int32_t c, int32_t which) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return 0;
    }
    typedef int8_t (*UHasBinPropFn)(int32_t, int32_t);
    static UHasBinPropFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (UHasBinPropFn)dlsym(RTLD_NEXT, "u_hasBinaryProperty");
    });
    return (s_orig != NULL) ? s_orig(c, which) : 0;
}

static int32_t pt_u_getIntPropertyValue(int32_t c, int32_t which) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return 0;
    }
    typedef int32_t (*UGetIntPropFn)(int32_t, int32_t);
    static UGetIntPropFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (UGetIntPropFn)dlsym(RTLD_NEXT, "u_getIntPropertyValue");
    });
    return (s_orig != NULL) ? s_orig(c, which) : 0;
}

#define PT_DEFINE_OS_VARIANT_1ARG(name) \
static bool pt_##name(const char *subsystem) { \
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) { \
        return false; \
    } \
    typedef bool (*OsVarFn)(const char *); \
    static OsVarFn s_orig = NULL; \
    static dispatch_once_t s_once; \
    dispatch_once(&s_once, ^{ \
        s_orig = (OsVarFn)dlsym(RTLD_NEXT, #name); \
    }); \
    return (s_orig != NULL) ? s_orig(subsystem) : false; \
}

PT_DEFINE_OS_VARIANT_1ARG(os_variant_has_internal_content)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_has_internal_diagnostics)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_has_internal_ui)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_allows_internal_security_policies)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_has_factory_content)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_is_darwinos)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_is_recovery)

static bool pt_os_variant_check(const char *subsystem, const char *variant) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return false;
    }
    typedef bool (*OsVarCheckFn)(const char *, const char *);
    static OsVarCheckFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (OsVarCheckFn)dlsym(RTLD_NEXT, "os_variant_check");
    });
    return (s_orig != NULL) ? s_orig(subsystem, variant) : false;
}

PT_DLSYM_ONLY("u_getVersion", pt_u_getVersion)
PT_DLSYM_ONLY("u_getUnicodeVersion", pt_u_getUnicodeVersion)
PT_DLSYM_ONLY("u_charAge", pt_u_charAge)
PT_DLSYM_ONLY("u_charType", pt_u_charType)
PT_DLSYM_ONLY("u_isdefined", pt_u_isdefined)
PT_DLSYM_ONLY("u_hasBinaryProperty", pt_u_hasBinaryProperty)
PT_DLSYM_ONLY("u_getIntPropertyValue", pt_u_getIntPropertyValue)
PT_DLSYM_ONLY("os_variant_has_internal_content", pt_os_variant_has_internal_content)
PT_DLSYM_ONLY("os_variant_has_internal_diagnostics", pt_os_variant_has_internal_diagnostics)
PT_DLSYM_ONLY("os_variant_has_internal_ui", pt_os_variant_has_internal_ui)
PT_DLSYM_ONLY("os_variant_allows_internal_security_policies", pt_os_variant_allows_internal_security_policies)
PT_DLSYM_ONLY("os_variant_has_factory_content", pt_os_variant_has_factory_content)
PT_DLSYM_ONLY("os_variant_is_darwinos", pt_os_variant_is_darwinos)
PT_DLSYM_ONLY("os_variant_is_recovery", pt_os_variant_is_recovery)
PT_DLSYM_ONLY("os_variant_check", pt_os_variant_check)
PT_DLSYM_ONLY("bootstrap_look_up2", pt_bootstrap_look_up2)
PT_DLSYM_ONLY("bootstrap_look_up3", pt_bootstrap_look_up3)
PT_DLSYM_ONLY("responsibility_get_pid_responsible_for_pid", pt_responsibility_get_pid_responsible_for_pid)
PT_DLSYM_ONLY("getutxent", pt_getutxent)
PT_DLSYM_ONLY("getutxid", pt_getutxid)
PT_DLSYM_ONLY("getutxline", pt_getutxline)
PT_DLSYM_ONLY("gethostuuid", pt_gethostuuid)
PT_DLSYM_ONLY("getauid", pt_getauid)
PT_DLSYM_ONLY("getaudit_addr", pt_getaudit_addr)
PT_DLSYM_ONLY("kevent_qos", pt_kevent_qos)
PT_INTERPOSE(pt_gethostname, gethostname)
PT_INTERPOSE(pt_getgid, getgid)
PT_INTERPOSE(pt_getegid, getegid)
PT_INTERPOSE(pt_getgroups, getgroups)
PT_INTERPOSE(pt_getpwuid, getpwuid)
PT_INTERPOSE(pt_getpwuid_r, getpwuid_r)
PT_INTERPOSE(pt_getpwnam, getpwnam)
PT_INTERPOSE(pt_getpwnam_r, getpwnam_r)
PT_INTERPOSE(pt_getlogin, getlogin)
PT_INTERPOSE(pt_getlogin_r, getlogin_r)
PT_INTERPOSE(pt_NSUserName, NSUserName)
PT_INTERPOSE(pt_NSFullUserName, NSFullUserName)
PT_INTERPOSE(pt_user_from_uid, user_from_uid)
PT_INTERPOSE(pt_sysconf, sysconf)
PT_INTERPOSE(pt_confstr, confstr)
PT_INTERPOSE(pt_fork, fork)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
PT_INTERPOSE(pt_vfork, vfork)
#pragma clang diagnostic pop
PT_INTERPOSE(pt_popen, popen)
PT_INTERPOSE_NAMED(pt_popen_darwin_extsn, pt_orig_popen_darwin_extsn, "popen$DARWIN_EXTSN")
PT_INTERPOSE(pt_posix_spawn, posix_spawn)
PT_INTERPOSE(pt_posix_spawnp, posix_spawnp)
PT_INTERPOSE_NAMED(pt_system, pt_orig_system, "system")
PT_INTERPOSE(pt_getppid, getppid)
PT_INTERPOSE(pt_isatty, isatty)
PT_INTERPOSE(pt_usleep, usleep)
PT_INTERPOSE(pt_task_threads, task_threads)
PT_INTERPOSE(pt_pthread_getname_np, pthread_getname_np)
PT_INTERPOSE(pt_thread_info, thread_info)
PT_INTERPOSE(pt_getgrgid, getgrgid)
PT_INTERPOSE(pt_getgrgid_r, getgrgid_r)
PT_INTERPOSE(pt_getgrnam, getgrnam)
PT_INTERPOSE(pt_getgrnam_r, getgrnam_r)
PT_INTERPOSE_NAMED(pt_getgrouplist, pt_orig_getgrouplist, "getgrouplist")
PT_INTERPOSE(pt_notify_register_check, notify_register_check)
PT_INTERPOSE(pt_notify_register_dispatch, notify_register_dispatch)
PT_INTERPOSE(pt_notify_cancel, notify_cancel)
PT_INTERPOSE(pt_notify_get_state, notify_get_state)
PT_INTERPOSE(pt_bootstrap_look_up, bootstrap_look_up)
PT_INTERPOSE(pt_kevent, kevent)
PT_INTERPOSE(pt_kevent64, kevent64)
