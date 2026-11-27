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

static int pt_getgroups_darwin_extsn(int gidsetsize, gid_t grouplist[]) {
    return pt_getgroups_with_caller(gidsetsize, grouplist, __builtin_return_address(0));
}

extern int32_t pt_orig_getgrouplist_2(const char *name, gid_t basegid, gid_t **groups) __asm__("_getgrouplist_2") __attribute__((weak_import));
extern char *pt_orig_group_from_gid(gid_t gid, int nogroup) __asm__("_group_from_gid") __attribute__((weak_import));
extern struct passwd *pt_orig_getpwent(void) __asm__("_getpwent") __attribute__((weak_import));
extern struct group *pt_orig_getgrent(void) __asm__("_getgrent") __attribute__((weak_import));
extern void pt_orig_setgrent(void) __asm__("_setgrent") __attribute__((weak_import));
extern void pt_orig_endgrent(void) __asm__("_endgrent") __attribute__((weak_import));
extern struct passwd *pt_orig_getpwuuid(uuid_t uu) __asm__("_getpwuuid") __attribute__((weak_import));
extern int pt_orig_getpwuuid_r(uuid_t uu, struct passwd *pwd, char *buf, size_t bufsize, struct passwd **result) __asm__("_getpwuuid_r") __attribute__((weak_import));
extern struct group *pt_orig_getgruuid(uuid_t uu) __asm__("_getgruuid") __attribute__((weak_import));
extern int pt_orig_getgruuid_r(uuid_t uu, struct group *grp, char *buf, size_t bufsize, struct group **result) __asm__("_getgruuid_r") __attribute__((weak_import));

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

static int32_t pt_getgrouplist_2(const char *name, gid_t basegid, gid_t **groups) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (groups == NULL) {
            errno = EINVAL;
            return -1;
        }
        gid_t mapped = pt_map_spoofed_gid(basegid);
        if (pt_is_desktop_supplemental_gid(mapped)) {
            mapped = 501;
        }
        gid_t *out = (gid_t *)malloc(sizeof(gid_t));
        if (out == NULL) {
            errno = ENOMEM;
            return -1;
        }
        out[0] = mapped;
        *groups = out;
        return 1;
    }
    if (&pt_orig_getgrouplist_2 != NULL) {
        return pt_orig_getgrouplist_2(name, basegid, groups);
    }
    errno = ENOSYS;
    return -1;
}

static char *pt_group_from_gid(gid_t gid, int nogroup) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (gid == 501) {
            return (char *)"mobile";
        }
        if (gid == 20 || pt_is_desktop_supplemental_gid(gid)) {
            if (nogroup != 0) {
                return NULL;
            }
            static _Thread_local char tls_num[16];
            snprintf(tls_num, sizeof(tls_num), "%u", (unsigned int)gid);
            return tls_num;
        }
    }
    return (&pt_orig_group_from_gid != NULL) ? pt_orig_group_from_gid(gid, nogroup) : NULL;
}

static struct passwd *pt_getpwent(void) {
    if (&pt_orig_getpwent == NULL) {
        return NULL;
    }
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_orig_getpwent();
    }
    uid_t self_uid = getuid();
    for (int guard = 0; guard < 1024; guard++) {
        struct passwd *pw = pt_orig_getpwent();
        if (pw == NULL) {
            return NULL;
        }
        if (pw->pw_uid == self_uid || pw->pw_uid == 501) {
            return pt_get_mobile_tls_passwd(pw->pw_uid, pt_map_spoofed_gid(pw->pw_gid));
        }
        if (pt_matches_host_username(pw->pw_name) ||
            (pw->pw_dir != NULL && strncmp(pw->pw_dir, "/Users/", 7) == 0)) {
            continue;
        }
        return pw;
    }
    return NULL;
}

static _Thread_local bool s_tls_emitted_mobile_grent = false;

static void pt_setgrent(void) {
    s_tls_emitted_mobile_grent = false;
    if (&pt_orig_setgrent != NULL) {
        pt_orig_setgrent();
    }
}

static void pt_endgrent(void) {
    s_tls_emitted_mobile_grent = false;
    if (&pt_orig_endgrent != NULL) {
        pt_orig_endgrent();
    }
}

static struct group *pt_getgrent(void) {
    if (&pt_orig_getgrent == NULL) {
        return NULL;
    }
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_orig_getgrent();
    }
    for (int guard = 0; guard < 1024; guard++) {
        struct group *gr = pt_orig_getgrent();
        if (gr == NULL) {
            return NULL;
        }
        if (gr->gr_gid == 501) {
            s_tls_emitted_mobile_grent = true;
            return pt_tls_mobile_group();
        }
        if (gr->gr_gid == 20) {
            if (!s_tls_emitted_mobile_grent) {
                s_tls_emitted_mobile_grent = true;
                return pt_tls_mobile_group();
            }
            continue;
        }
        if (pt_is_desktop_supplemental_gid(gr->gr_gid) ||
            pt_is_hidden_macos_group_name(gr->gr_name)) {
            continue;
        }
        return gr;
    }
    return NULL;
}

static struct passwd *pt_getpwuuid(uuid_t uu) {
    if (&pt_orig_getpwuuid == NULL) {
        return NULL;
    }
    struct passwd *pw = pt_orig_getpwuuid(uu);
    if (pw != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pw->pw_uid == getuid() || pw->pw_uid == 501) {
            return pt_get_mobile_tls_passwd(pw->pw_uid, pt_map_spoofed_gid(pw->pw_gid));
        }
        if (pt_matches_host_username(pw->pw_name)) {
            return NULL;
        }
    }
    return pw;
}

static int pt_getpwuuid_r(uuid_t uu, struct passwd *pwd, char *buffer, size_t bufsize, struct passwd **result) {
    if (&pt_orig_getpwuuid_r == NULL) {
        return ENOSYS;
    }
    int rc = pt_orig_getpwuuid_r(uu, pwd, buffer, bufsize, result);
    if (rc == 0 && pwd != NULL && result != NULL && *result != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pwd->pw_uid == getuid() || pwd->pw_uid == 501) {
            pt_fill_mobile_passwd_struct(pwd->pw_uid, pt_map_spoofed_gid(pwd->pw_gid), pwd, buffer, bufsize);
        } else if (pt_matches_host_username(pwd->pw_name)) {
            *result = NULL;
        }
    }
    return rc;
}

static struct group *pt_getgruuid(uuid_t uu) {
    if (&pt_orig_getgruuid == NULL) {
        return NULL;
    }
    struct group *gr = pt_orig_getgruuid(uu);
    if (gr != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (gr->gr_gid == 501) {
            return pt_tls_mobile_group();
        }
        if (gr->gr_gid == 20 ||
            pt_is_desktop_supplemental_gid(gr->gr_gid) ||
            pt_is_hidden_macos_group_name(gr->gr_name)) {
            return NULL;
        }
    }
    return gr;
}

static int pt_getgruuid_r(uuid_t uu, struct group *grp, char *buffer, size_t bufsize, struct group **result) {
    if (&pt_orig_getgruuid_r == NULL) {
        return ENOSYS;
    }
    int rc = pt_orig_getgruuid_r(uu, grp, buffer, bufsize, result);
    if (rc == 0 && grp != NULL && result != NULL && *result != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (grp->gr_gid == 501) {
            return pt_fill_mobile_group_r(grp, buffer, bufsize, result);
        }
        if (grp->gr_gid == 20 ||
            pt_is_desktop_supplemental_gid(grp->gr_gid) ||
            pt_is_hidden_macos_group_name(grp->gr_name)) {
            *result = NULL;
        }
    }
    return rc;
}

struct utmpx;
extern struct utmpx *pt_orig_getutxent(void) __asm__("_getutxent") __attribute__((weak_import));
extern struct utmpx *pt_orig_getutxid(const struct utmpx *) __asm__("_getutxid") __attribute__((weak_import));
extern struct utmpx *pt_orig_getutxline(const struct utmpx *) __asm__("_getutxline") __attribute__((weak_import));
extern int pt_orig_gethostuuid(uuid_t, const struct timespec *) __asm__("_gethostuuid") __attribute__((weak_import));
extern int pt_orig_getauid(void *) __asm__("_getauid") __attribute__((weak_import));
extern int pt_orig_getaudit_addr(void *, int) __asm__("_getaudit_addr") __attribute__((weak_import));

static struct utmpx *pt_getutxent(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return (&pt_orig_getutxent != NULL) ? pt_orig_getutxent() : NULL;
}

static struct utmpx *pt_getutxid(const struct utmpx *ut) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return (&pt_orig_getutxid != NULL) ? pt_orig_getutxid(ut) : NULL;
}

static struct utmpx *pt_getutxline(const struct utmpx *ut) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return (&pt_orig_getutxline != NULL) ? pt_orig_getutxline(ut) : NULL;
}

__attribute__((visibility("hidden")))
int pt_gethostuuid_with_caller(uuid_t id, const struct timespec *wait, const void *caller) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        errno = EPERM;
        return -1;
    }
    if (&pt_orig_gethostuuid != NULL) {
        return pt_orig_gethostuuid(id, wait);
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
    if (&pt_orig_getauid != NULL) {
        return pt_orig_getauid(auid);
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
    if (&pt_orig_getaudit_addr != NULL) {
        return pt_orig_getaudit_addr(auinfo, length);
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

extern int pt_orig_kevent_qos(int kq,
                              const pt_kevent_qos_s *changelist,
                              int nchanges,
                              pt_kevent_qos_s *eventlist,
                              int nevents,
                              void *data_out,
                              size_t *data_available,
                              unsigned int flags) __asm__("_kevent_qos") __attribute__((weak_import));

__attribute__((visibility("hidden"))) int pt_kevent_qos_with_caller(int kq,
                                     const pt_kevent_qos_s *changelist,
                                     int nchanges,
                                     pt_kevent_qos_s *eventlist,
                                     int nevents,
                                     void *data_out,
                                     size_t *data_available,
                                     unsigned int flags,
                                     const void *caller) {
    if (&pt_orig_kevent_qos == NULL) {
        errno = ENOSYS;
        return -1;
    }
    int (*const s_orig)(int, const pt_kevent_qos_s *, int, pt_kevent_qos_s *, int, void *, size_t *, unsigned int) = pt_orig_kevent_qos;
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

extern int pt_orig_kevent_id(uint64_t id,
                             const pt_kevent_qos_s *changelist,
                             int nchanges,
                             pt_kevent_qos_s *eventlist,
                             int nevents,
                             void *data_out,
                             size_t *data_available,
                             unsigned int flags) __asm__("_kevent_id") __attribute__((weak_import));

__attribute__((visibility("hidden"))) int pt_kevent_id_with_caller(uint64_t id,
                                                                   const pt_kevent_qos_s *changelist,
                                                                   int nchanges,
                                                                   pt_kevent_qos_s *eventlist,
                                                                   int nevents,
                                                                   void *data_out,
                                                                   size_t *data_available,
                                                                   unsigned int flags,
                                                                   const void *caller) {
    if (&pt_orig_kevent_id == NULL) {
        errno = ENOSYS;
        return -1;
    }
    int (*const s_orig)(uint64_t, const pt_kevent_qos_s *, int, pt_kevent_qos_s *, int, void *, size_t *, unsigned int) = pt_orig_kevent_id;
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
                int r = s_orig(id, kept, kept_cnt, eventlist + reported, nevents - reported,
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
                int r = s_orig(id, kept, kept_cnt, NULL, 0, data_out, data_available,
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
    return s_orig(id, changelist, nchanges, eventlist, nevents, data_out, data_available, flags);
}

static int pt_kevent_id(uint64_t id,
                        const pt_kevent_qos_s *changelist,
                        int nchanges,
                        pt_kevent_qos_s *eventlist,
                        int nevents,
                        void *data_out,
                        size_t *data_available,
                        unsigned int flags) {
    return pt_kevent_id_with_caller(id, changelist, nchanges, eventlist, nevents,
                                    data_out, data_available, flags, __builtin_return_address(0));
}

__attribute__((visibility("hidden"))) int pt_getrlimit_with_caller(int resource, struct rlimit *rlp, const void *caller) {
    int r = getrlimit(resource, rlp);
    if (r == 0 && rlp != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        if (resource == RLIMIT_NOFILE) {
            if (rlp->rlim_cur > 10240ULL) {
                rlp->rlim_cur = 10240ULL;
            }
            if (rlp->rlim_max != RLIM_INFINITY && rlp->rlim_max > 10240ULL) {
                rlp->rlim_max = 10240ULL;
            }
        } else if (resource == RLIMIT_NPROC) {
            if (rlp->rlim_cur > 1000ULL) {
                rlp->rlim_cur = 1000ULL;
            }
            if (rlp->rlim_max != RLIM_INFINITY && rlp->rlim_max > 1000ULL) {
                rlp->rlim_max = 1000ULL;
            }
        }
    }
    return r;
}

static int pt_getrlimit(int resource, struct rlimit *rlp) {
    return pt_getrlimit_with_caller(resource, rlp, __builtin_return_address(0));
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

static uint32_t pt_notify_register_signal(const char *name, int sig, int *out_token) {
    uint32_t st = notify_register_signal(name, sig, out_token);
    if (st == NOTIFY_STATUS_OK && out_token != NULL && name != NULL &&
        strcmp(name, "com.apple.system.thermalpressurelevel") == 0) {
        pt_record_thermal_notify_token(*out_token);
    }
    return st;
}

static uint32_t pt_notify_register_mach_port(const char *name, mach_port_t *notify_port, int flags, int *out_token) {
    uint32_t st = notify_register_mach_port(name, notify_port, flags, out_token);
    if (st == NOTIFY_STATUS_OK && out_token != NULL && name != NULL &&
        strcmp(name, "com.apple.system.thermalpressurelevel") == 0) {
        pt_record_thermal_notify_token(*out_token);
    }
    return st;
}

static uint32_t pt_notify_register_file_descriptor(const char *name, int *notify_fd, int flags, int *out_token) {
    uint32_t st = notify_register_file_descriptor(name, notify_fd, flags, out_token);
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
            case _SC_OPEN_MAX:
                return 10240L;
            case _SC_CHILD_MAX:
                return 1000L;
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
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *service_name, mach_port_t *sp);
extern kern_return_t bootstrap_status(mach_port_t bp, const char *service_name, int *service_active);

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

static kern_return_t pt_bootstrap_check_in(mach_port_t bp, const char *service_name, mach_port_t *sp) {
    if (service_name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_macos_mach_service(service_name)) {
        if (sp != NULL) {
            *sp = MACH_PORT_NULL;
        }
        return PT_BOOTSTRAP_UNKNOWN_SERVICE;
    }
    return bootstrap_check_in(bp, service_name, sp);
}

static kern_return_t pt_bootstrap_status(mach_port_t bp, const char *service_name, int *service_active) {
    if (service_name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_macos_mach_service(service_name)) {
        if (service_active != NULL) {
            *service_active = 0;
        }
        return PT_BOOTSTRAP_UNKNOWN_SERVICE;
    }
    return bootstrap_status(bp, service_name, service_active);
}

extern kern_return_t pt_orig_bootstrap_look_up2(mach_port_t, const char *, mach_port_t *, pid_t, uint64_t) __asm__("_bootstrap_look_up2") __attribute__((weak_import));
extern kern_return_t pt_orig_bootstrap_look_up3(mach_port_t, const char *, mach_port_t *, pid_t, const uuid_t, uint64_t) __asm__("_bootstrap_look_up3") __attribute__((weak_import));
extern kern_return_t pt_orig_bootstrap_look_up_per_user(mach_port_t, const char *, uid_t, mach_port_t *) __asm__("_bootstrap_look_up_per_user") __attribute__((weak_import));
extern pid_t pt_orig_responsibility_get_pid_responsible_for_pid(pid_t) __asm__("_responsibility_get_pid_responsible_for_pid") __attribute__((weak_import));
extern int pt_orig_responsibility_get_responsible_for_pid(pid_t pid, pid_t *out_pid, char *out_path, size_t *out_path_size) __asm__("_responsibility_get_responsible_for_pid") __attribute__((weak_import));
extern int64_t pt_orig_responsibility_get_uniqueid_responsible_for_pid(pid_t) __asm__("_responsibility_get_uniqueid_responsible_for_pid") __attribute__((weak_import));

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
    if (&pt_orig_bootstrap_look_up2 != NULL) {
        return pt_orig_bootstrap_look_up2(bp, service_name, sp, target_pid, flags);
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
    if (&pt_orig_bootstrap_look_up3 != NULL) {
        return pt_orig_bootstrap_look_up3(bp, service_name, sp, target_pid, instance_id, flags);
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
    if (&pt_orig_responsibility_get_pid_responsible_for_pid != NULL) {
        return pt_orig_responsibility_get_pid_responsible_for_pid(pid);
    }
    errno = ENOSYS;
    return -1;
}

static kern_return_t pt_bootstrap_look_up_per_user(mach_port_t bp,
                                                   const char *service_name,
                                                   uid_t target_user,
                                                   mach_port_t *sp) {
    if (service_name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_macos_mach_service(service_name)) {
        if (sp != NULL) {
            *sp = MACH_PORT_NULL;
        }
        return PT_BOOTSTRAP_UNKNOWN_SERVICE;
    }
    if (&pt_orig_bootstrap_look_up_per_user != NULL) {
        return pt_orig_bootstrap_look_up_per_user(bp, service_name, target_user, sp);
    }
    if (sp != NULL) {
        *sp = MACH_PORT_NULL;
    }
    return PT_BOOTSTRAP_UNKNOWN_SERVICE;
}

static int pt_responsibility_get_responsible_for_pid(pid_t pid,
                                                    pid_t *out_pid,
                                                    char *out_path,
                                                    size_t *out_path_size) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (out_path_size != NULL) {
            if (!pt_is_valid_user_pointer(out_path_size) || *out_path_size == 0) {
                errno = EINVAL;
                return -1;
            }
        }
        pid_t self_pid = getpid();
        if (pid != 0 && pid != self_pid) {
            errno = ESRCH;
            return -1;
        }
        if (out_pid != NULL && pt_is_valid_user_pointer(out_pid)) {
            *out_pid = self_pid;
        }
        if (out_path != NULL && out_path_size != NULL && *out_path_size > 0 && pt_is_valid_user_pointer(out_path)) {
            const char *exe = pt_get_main_executable_path();
            char vout[PATH_MAX];
            const char *san = (exe != NULL) ? pt_virtualize_path_for_app(exe, vout, sizeof(vout), YES) : "/";
            strlcpy(out_path, (san != NULL) ? san : "/", *out_path_size);
        }
        return 0;
    }
    if (&pt_orig_responsibility_get_responsible_for_pid != NULL) {
        return pt_orig_responsibility_get_responsible_for_pid(pid, out_pid, out_path, out_path_size);
    }
    errno = ENOSYS;
    return -1;
}

static int64_t pt_responsibility_get_uniqueid_responsible_for_pid(pid_t pid) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pid_t self_pid = getpid();
        if (pid == 0 || pid == self_pid) {
            return (int64_t)self_pid;
        }
        errno = ESRCH;
        return -1;
    }
    if (&pt_orig_responsibility_get_uniqueid_responsible_for_pid != NULL) {
        return pt_orig_responsibility_get_uniqueid_responsible_for_pid(pid);
    }
    errno = ENOSYS;
    return -1;
}

static void *pt_responsibility_get_attribution_for_audittoken(const audit_token_t *token,
                                                              const void *a1,
                                                              const void *a2,
                                                              const void *a3,
                                                              const void *a4) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = ESRCH;
        return NULL;
    }
    typedef void *(*fn_t)(const audit_token_t *, const void *, const void *, const void *, const void *);
    fn_t orig = (fn_t)dlsym(RTLD_NEXT, "responsibility_get_attribution_for_audittoken");
    return orig ? orig(token, a1, a2, a3, a4) : NULL;
}

static int pt_responsibility_get_responsible_audit_token_for_audit_token(const audit_token_t *in_token,
                                                                         audit_token_t *out_token) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pid_t self_pid = getpid();
        if (in_token == NULL || out_token == NULL || (pid_t)in_token->val[5] != self_pid) {
            errno = ESRCH;
            return -1;
        }
        *out_token = *in_token;
        if (out_token->val[2] == 20U) {
            out_token->val[2] = 501U;
        }
        if (out_token->val[4] == 20U) {
            out_token->val[4] = 501U;
        }
        return 0;
    }
    typedef int (*fn_t)(const audit_token_t *, audit_token_t *);
    fn_t orig = (fn_t)dlsym(RTLD_NEXT, "responsibility_get_responsible_audit_token_for_audit_token");
    return orig ? orig(in_token, out_token) : -1;
}

extern void pt_orig_u_getVersion(uint8_t[4]) __asm__("_u_getVersion") __attribute__((weak_import));
extern void pt_orig_u_getUnicodeVersion(uint8_t[4]) __asm__("_u_getUnicodeVersion") __attribute__((weak_import));
extern void pt_orig_u_charAge(int32_t, uint8_t[4]) __asm__("_u_charAge") __attribute__((weak_import));
extern int8_t pt_orig_u_charType(int32_t) __asm__("_u_charType") __attribute__((weak_import));
extern int8_t pt_orig_u_isdefined(int32_t) __asm__("_u_isdefined") __attribute__((weak_import));
extern int8_t pt_orig_u_hasBinaryProperty(int32_t, int32_t) __asm__("_u_hasBinaryProperty") __attribute__((weak_import));
extern int32_t pt_orig_u_getIntPropertyValue(int32_t, int32_t) __asm__("_u_getIntPropertyValue") __attribute__((weak_import));
extern int32_t pt_orig_u_charName(int32_t, int32_t, char *, int32_t, int32_t *) __asm__("_u_charName") __attribute__((weak_import));
extern int8_t pt_orig_u_isalpha(int32_t) __asm__("_u_isalpha") __attribute__((weak_import));
extern int8_t pt_orig_u_isprint(int32_t) __asm__("_u_isprint") __attribute__((weak_import));
extern double pt_orig_u_getNumericValue(int32_t) __asm__("_u_getNumericValue") __attribute__((weak_import));

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
    if (&pt_orig_u_getVersion != NULL) {
        pt_orig_u_getVersion(versionArray);
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
    if (&pt_orig_u_getUnicodeVersion != NULL) {
        pt_orig_u_getUnicodeVersion(versionArray);
    }
}

static BOOL pt_icu_codepoint_post_unicode_12_1(int32_t c) {
    if (&pt_orig_u_charAge == NULL) {
        return NO;
    }
    uint8_t age[4] = {0, 0, 0, 0};
    pt_orig_u_charAge(c, age);
    return pt_is_icu_age_post_13_7_c(age[0], age[1]) ? YES : NO;
}

static void pt_u_charAge(int32_t c, uint8_t versionArray[4]) {
    if (&pt_orig_u_charAge != NULL) {
        pt_orig_u_charAge(c, versionArray);
    } else if (versionArray != NULL) {
        memset(versionArray, 0, 4U);
    }
    if (versionArray != NULL &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_icu_age_post_13_7_c(versionArray[0], versionArray[1])) {
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
    return (&pt_orig_u_charType != NULL) ? pt_orig_u_charType(c) : 0;
}

static int8_t pt_u_isdefined(int32_t c) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return 0;
    }
    return (&pt_orig_u_isdefined != NULL) ? pt_orig_u_isdefined(c) : 0;
}

static int8_t pt_u_hasBinaryProperty(int32_t c, int32_t which) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return 0;
    }
    return (&pt_orig_u_hasBinaryProperty != NULL) ? pt_orig_u_hasBinaryProperty(c, which) : 0;
}

static int32_t pt_u_getIntPropertyValue(int32_t c, int32_t which) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return 0;
    }
    return (&pt_orig_u_getIntPropertyValue != NULL) ? pt_orig_u_getIntPropertyValue(c, which) : 0;
}

static int32_t pt_u_charName(int32_t code, int32_t nameChoice, char *buffer, int32_t bufferLength, int32_t *pErrorCode) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(code)) {
        if (buffer != NULL && bufferLength > 0) {
            buffer[0] = '\0';
        }
        if (pErrorCode != NULL) {
            *pErrorCode = 0;
        }
        return 0;
    }
    return (&pt_orig_u_charName != NULL) ? pt_orig_u_charName(code, nameChoice, buffer, bufferLength, pErrorCode) : 0;
}

static int8_t pt_u_isalpha(int32_t c) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return 0;
    }
    return (&pt_orig_u_isalpha != NULL) ? pt_orig_u_isalpha(c) : 0;
}

static int8_t pt_u_isprint(int32_t c) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return 0;
    }
    return (&pt_orig_u_isprint != NULL) ? pt_orig_u_isprint(c) : 0;
}

static double pt_u_getNumericValue(int32_t c) {
    if (pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_icu_codepoint_post_unicode_12_1(c)) {
        return -123456789.0; // U_NO_NUMERIC_VALUE
    }
    return (&pt_orig_u_getNumericValue != NULL) ? pt_orig_u_getNumericValue(c) : -123456789.0;
}

#define PT_DEFINE_OS_VARIANT_1ARG(name) \
extern bool pt_orig_##name(const char *subsystem) __asm__("_" #name) __attribute__((weak_import)); \
static bool pt_##name(const char *subsystem) { \
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) { \
        return false; \
    } \
    return (&pt_orig_##name != NULL) ? pt_orig_##name(subsystem) : false; \
}

PT_DEFINE_OS_VARIANT_1ARG(os_variant_has_internal_content)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_has_internal_diagnostics)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_has_internal_ui)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_allows_internal_security_policies)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_has_factory_content)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_is_darwinos)
PT_DEFINE_OS_VARIANT_1ARG(os_variant_is_recovery)

extern bool pt_orig_os_variant_check(const char *subsystem, const char *variant) __asm__("_os_variant_check") __attribute__((weak_import));

static bool pt_os_variant_check(const char *subsystem, const char *variant) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return false;
    }
    return (&pt_orig_os_variant_check != NULL) ? pt_orig_os_variant_check(subsystem, variant) : false;
}

extern char *pt_orig_os_variant_copy_description(const char *subsystem) __asm__("_os_variant_copy_description") __attribute__((weak_import));
extern bool pt_orig_os_variant_allows_security_research(const char *subsystem) __asm__("_os_variant_allows_security_research") __attribute__((weak_import));
extern bool pt_orig_os_variant_uses_ephemeral_storage(const char *subsystem) __asm__("_os_variant_uses_ephemeral_storage") __attribute__((weak_import));

static char *pt_os_variant_copy_description(const char *subsystem) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return strdup("");
    }
    return (&pt_orig_os_variant_copy_description != NULL) ? pt_orig_os_variant_copy_description(subsystem) : NULL;
}

static bool pt_os_variant_allows_security_research(const char *subsystem) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return false;
    }
    return (&pt_orig_os_variant_allows_security_research != NULL) ? pt_orig_os_variant_allows_security_research(subsystem) : false;
}

static bool pt_os_variant_uses_ephemeral_storage(const char *subsystem) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return false;
    }
    return (&pt_orig_os_variant_uses_ephemeral_storage != NULL) ? pt_orig_os_variant_uses_ephemeral_storage(subsystem) : false;
}

static bool pt_os_variant_is_basesystem(const char *subsystem) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return false;
    }
    typedef bool (*fn_t)(const char *);
    fn_t orig = (fn_t)dlsym(RTLD_NEXT, "os_variant_is_basesystem");
    return orig ? orig(subsystem) : false;
}

PT_INTERPOSE_WEAK_NAMED(pt_u_getVersion, pt_orig_u_getVersion, "u_getVersion")
PT_INTERPOSE_WEAK_NAMED(pt_u_getUnicodeVersion, pt_orig_u_getUnicodeVersion, "u_getUnicodeVersion")
PT_INTERPOSE_WEAK_NAMED(pt_u_charAge, pt_orig_u_charAge, "u_charAge")
PT_INTERPOSE_WEAK_NAMED(pt_u_charType, pt_orig_u_charType, "u_charType")
PT_INTERPOSE_WEAK_NAMED(pt_u_isdefined, pt_orig_u_isdefined, "u_isdefined")
PT_INTERPOSE_WEAK_NAMED(pt_u_hasBinaryProperty, pt_orig_u_hasBinaryProperty, "u_hasBinaryProperty")
PT_INTERPOSE_WEAK_NAMED(pt_u_getIntPropertyValue, pt_orig_u_getIntPropertyValue, "u_getIntPropertyValue")
PT_INTERPOSE_WEAK_NAMED(pt_u_charName, pt_orig_u_charName, "u_charName")
PT_INTERPOSE_WEAK_NAMED(pt_u_isalpha, pt_orig_u_isalpha, "u_isalpha")
PT_INTERPOSE_WEAK_NAMED(pt_u_isprint, pt_orig_u_isprint, "u_isprint")
PT_INTERPOSE_WEAK_NAMED(pt_u_getNumericValue, pt_orig_u_getNumericValue, "u_getNumericValue")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_has_internal_content, pt_orig_os_variant_has_internal_content, "os_variant_has_internal_content")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_has_internal_diagnostics, pt_orig_os_variant_has_internal_diagnostics, "os_variant_has_internal_diagnostics")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_has_internal_ui, pt_orig_os_variant_has_internal_ui, "os_variant_has_internal_ui")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_allows_internal_security_policies, pt_orig_os_variant_allows_internal_security_policies, "os_variant_allows_internal_security_policies")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_has_factory_content, pt_orig_os_variant_has_factory_content, "os_variant_has_factory_content")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_is_darwinos, pt_orig_os_variant_is_darwinos, "os_variant_is_darwinos")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_is_recovery, pt_orig_os_variant_is_recovery, "os_variant_is_recovery")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_check, pt_orig_os_variant_check, "os_variant_check")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_copy_description, pt_orig_os_variant_copy_description, "os_variant_copy_description")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_allows_security_research, pt_orig_os_variant_allows_security_research, "os_variant_allows_security_research")
PT_INTERPOSE_WEAK_NAMED(pt_os_variant_uses_ephemeral_storage, pt_orig_os_variant_uses_ephemeral_storage, "os_variant_uses_ephemeral_storage")
PT_DLSYM_ONLY("os_variant_is_basesystem", pt_os_variant_is_basesystem)
PT_INTERPOSE_WEAK_NAMED(pt_bootstrap_look_up2, pt_orig_bootstrap_look_up2, "bootstrap_look_up2")
PT_INTERPOSE_WEAK_NAMED(pt_bootstrap_look_up3, pt_orig_bootstrap_look_up3, "bootstrap_look_up3")
PT_INTERPOSE_WEAK_NAMED(pt_bootstrap_look_up_per_user, pt_orig_bootstrap_look_up_per_user, "bootstrap_look_up_per_user")
PT_INTERPOSE_WEAK_NAMED(pt_responsibility_get_pid_responsible_for_pid, pt_orig_responsibility_get_pid_responsible_for_pid, "responsibility_get_pid_responsible_for_pid")
PT_INTERPOSE_WEAK_NAMED(pt_responsibility_get_responsible_for_pid, pt_orig_responsibility_get_responsible_for_pid, "responsibility_get_responsible_for_pid")
PT_INTERPOSE_WEAK_NAMED(pt_responsibility_get_uniqueid_responsible_for_pid, pt_orig_responsibility_get_uniqueid_responsible_for_pid, "responsibility_get_uniqueid_responsible_for_pid")
PT_DLSYM_ONLY("responsibility_get_attribution_for_audittoken", pt_responsibility_get_attribution_for_audittoken)
PT_DLSYM_ONLY("responsibility_get_responsible_audit_token_for_audit_token", pt_responsibility_get_responsible_audit_token_for_audit_token)
PT_INTERPOSE_WEAK_NAMED(pt_getutxent, pt_orig_getutxent, "getutxent")
PT_INTERPOSE_WEAK_NAMED(pt_getutxid, pt_orig_getutxid, "getutxid")
PT_INTERPOSE_WEAK_NAMED(pt_getutxline, pt_orig_getutxline, "getutxline")
PT_INTERPOSE_WEAK_NAMED(pt_gethostuuid, pt_orig_gethostuuid, "gethostuuid")
PT_INTERPOSE_WEAK_NAMED(pt_getauid, pt_orig_getauid, "getauid")
PT_INTERPOSE_WEAK_NAMED(pt_getaudit_addr, pt_orig_getaudit_addr, "getaudit_addr")
PT_INTERPOSE_WEAK_NAMED(pt_kevent_qos, pt_orig_kevent_qos, "kevent_qos")
PT_INTERPOSE_WEAK_NAMED(pt_kevent_id, pt_orig_kevent_id, "kevent_id")
PT_INTERPOSE(pt_gethostname, gethostname)
PT_INTERPOSE(pt_getgid, getgid)
PT_INTERPOSE(pt_getegid, getegid)
PT_INTERPOSE(pt_getgroups, getgroups)
PT_DLSYM_ONLY("getgroups$DARWIN_EXTSN", pt_getgroups_darwin_extsn)
PT_INTERPOSE_WEAK_NAMED(pt_getgrouplist_2, pt_orig_getgrouplist_2, "getgrouplist_2")
PT_INTERPOSE_WEAK_NAMED(pt_group_from_gid, pt_orig_group_from_gid, "group_from_gid")
PT_INTERPOSE_WEAK_NAMED(pt_getpwent, pt_orig_getpwent, "getpwent")
PT_INTERPOSE_WEAK_NAMED(pt_getgrent, pt_orig_getgrent, "getgrent")
PT_INTERPOSE_WEAK_NAMED(pt_setgrent, pt_orig_setgrent, "setgrent")
PT_INTERPOSE_WEAK_NAMED(pt_endgrent, pt_orig_endgrent, "endgrent")
PT_INTERPOSE_WEAK_NAMED(pt_getpwuuid, pt_orig_getpwuuid, "getpwuuid")
PT_INTERPOSE_WEAK_NAMED(pt_getpwuuid_r, pt_orig_getpwuuid_r, "getpwuuid_r")
PT_INTERPOSE_WEAK_NAMED(pt_getgruuid, pt_orig_getgruuid, "getgruuid")
PT_INTERPOSE_WEAK_NAMED(pt_getgruuid_r, pt_orig_getgruuid_r, "getgruuid_r")
PT_INTERPOSE(pt_getrlimit, getrlimit)
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
PT_INTERPOSE(pt_notify_register_signal, notify_register_signal)
PT_INTERPOSE(pt_notify_register_mach_port, notify_register_mach_port)
PT_INTERPOSE(pt_notify_register_file_descriptor, notify_register_file_descriptor)
PT_INTERPOSE(pt_notify_cancel, notify_cancel)
PT_INTERPOSE(pt_notify_get_state, notify_get_state)
PT_INTERPOSE(pt_bootstrap_look_up, bootstrap_look_up)
PT_INTERPOSE(pt_bootstrap_check_in, bootstrap_check_in)
PT_INTERPOSE(pt_bootstrap_status, bootstrap_status)
PT_INTERPOSE(pt_kevent, kevent)
PT_INTERPOSE(pt_kevent64, kevent64)
