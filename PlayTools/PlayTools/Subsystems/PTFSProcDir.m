//
//  PTFSProcDir.m
//  PlayTools
//

#import "PTFSInternal.h"
#import "PTSystemSpooferInternal.h"
#import "PTDyldInternal.h"
#import "PTKernelABI.h"

__attribute__((visibility("hidden"))) BOOL pt_is_sensitive_unix_socket_path(const char *sun_path, const void *caller) {
    if (sun_path == NULL || sun_path[0] == '\0') {
        return NO;
    }
    if (strstr(sun_path, "/var/folders/") != NULL ||
        strstr(sun_path, "com.apple.launchd") != NULL ||
        strstr(sun_path, "discord-ipc") != NULL ||
        strcasestr(sun_path, "PlayCover") != NULL ||
        strcasestr(sun_path, "PlayTools") != NULL ||
        strcasestr(sun_path, "MacOver") != NULL ||
        strcasestr(sun_path, "app.makedie") != NULL) {
        return YES;
    }
    char vout[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(sun_path, vout, sizeof(vout), YES);
    const char *eff = (virt != NULL) ? virt : sun_path;
    if (strstr(eff, "/Users/") != NULL || pt_is_sensitive_host_fd_path(eff, caller)) {
        return YES;
    }
    return NO;
}

static BOOL pt_sanitize_sockaddr_un_in_place(pt_sockaddr_un_t *sa, const void *caller) {
    if (sa == NULL || sa->sun_path[0] == '\0') {
        return NO;
    }
    char pathbuf[sizeof(sa->sun_path) + 1];
    size_t plen = strnlen(sa->sun_path, sizeof(sa->sun_path));
    memcpy(pathbuf, sa->sun_path, plen);
    pathbuf[plen] = '\0';
    if (pt_is_sensitive_unix_socket_path(pathbuf, caller)) {
        return YES;
    }
    char vout[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(pathbuf, vout, sizeof(vout), YES);
    if (virt != NULL && virt != pathbuf && strcmp(virt, pathbuf) != 0) {
        size_t vlen = strlcpy(sa->sun_path, virt, sizeof(sa->sun_path));
        if (vlen >= sizeof(sa->sun_path)) {
            vlen = sizeof(sa->sun_path) - 1U;
        }
        size_t total = offsetof(pt_sockaddr_un_t, sun_path) + vlen + 1U;
        sa->sun_len = (uint8_t)((total < 255U) ? total : 255U);
    }
    return NO;
}

static int pt_count_hidden_threads_for_self(void) {
    int self_pid = getpid();
    uint64_t stack_tids[512];
    int nbytes = proc_pidinfo(self_pid, PROC_PIDLISTTHREADS, 0, stack_tids, (int)sizeof(stack_tids));
    if (nbytes <= 0) {
        return 0;
    }
    int count = nbytes / (int)sizeof(uint64_t);
    int hidden = 0;
    for (int i = 0; i < count; i++) {
        struct proc_threadinfo ti;
        int tr = proc_pidinfo(self_pid, PROC_PIDTHREADINFO, stack_tids[i], &ti, (int)sizeof(ti));
        if (tr > 0 && (size_t)tr >= sizeof(ti) && pt_is_hidden_thread_name(ti.pth_name)) {
            hidden++;
        }
    }
    return hidden;
}

static BOOL pt_is_hidden_proc_text(const char *s) {
    if (s == NULL || s[0] == '\0') {
        return NO;
    }
    return (strcasestr(s, "PlayCover") != NULL ||
            strcasestr(s, "PlayTools") != NULL ||
            strcasestr(s, "MacOver") != NULL ||
            strstr(s, "/Users/") != NULL);
}

static const char *pt_cached_sanitized_exec_name(void) {
    static char s_exec_name[MAXCOMLEN + 1] = "App";
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *exe = pt_get_main_executable_path();
        const char *base = (exe != NULL) ? strrchr(exe, '/') : NULL;
        base = (base != NULL) ? (base + 1) : exe;
        if (base != NULL && base[0] != '\0' && !pt_is_hidden_proc_text(base)) {
            strlcpy(s_exec_name, base, sizeof(s_exec_name));
        }
    });
    return s_exec_name;
}

static void pt_sanitize_proc_name_buf(char *buf, size_t cap) {
    if (buf == NULL || cap == 0 || buf[0] == '\0') {
        return;
    }
    size_t slen = strnlen(buf, cap);
    if (slen >= cap) {
        buf[cap - 1U] = '\0';
    }
    if (strcasestr(buf, "PlayCover") != NULL ||
        strcasestr(buf, "MacOver") != NULL ||
        strcasestr(buf, "PlayTools") != NULL) {
        strlcpy(buf, pt_cached_sanitized_exec_name(), cap);
    }
}

static void pt_sanitize_vinfo_stat_in_place(struct vinfo_stat *vs) {
    if (vs == NULL || !pt_is_bypass_enabled()) {
        return;
    }
    if (vs->vst_gid == 20U) {
        vs->vst_gid = 501U;
    }
#ifdef SF_RESTRICTED
    vs->vst_flags &= ~(uint32_t)SF_RESTRICTED;
#endif
#ifdef SF_FIRMLINK
    vs->vst_flags &= ~(uint32_t)SF_FIRMLINK;
#endif
}

static int pt_sanitize_proc_fd_or_fileport_buffer(int ret,
                                                   int pid,
                                                   int fd_or_fileport,
                                                   BOOL is_fileport,
                                                   int flavor,
                                                   void *buffer,
                                                   const void *caller,
                                                   BOOL raw_syscall_abi) {
    if (buffer != NULL) {
        if (flavor == PROC_PIDFDVNODEINFO &&
            (size_t)ret >= sizeof(struct vnode_fdinfo)) {
            BOOL sensitive = NO;
            if (is_fileport) {
                struct vnode_fdinfowithpath vp;
                memset(&vp, 0, sizeof(vp));
                int vret = proc_pidfileportinfo(pid, (uint32_t)fd_or_fileport, PROC_PIDFDVNODEPATHINFO, &vp, (int)sizeof(vp));
                if (vret > 0 && (size_t)vret >= sizeof(vp) &&
                    pt_is_sensitive_host_fd_path(vp.pvip.vip_path, caller)) {
                    sensitive = YES;
                }
            } else {
                sensitive = pt_fd_is_sensitive(fd_or_fileport, caller);
            }
            if (sensitive) {
                memset(buffer, 0, sizeof(struct vnode_fdinfo));
                errno = EBADF;
                return raw_syscall_abi ? -1 : 0;
            }
            struct vnode_fdinfo info;
            memcpy(&info, buffer, sizeof(info));
            pt_sanitize_vinfo_stat_in_place(&info.pvi.vi_stat);
            memcpy(buffer, &info, sizeof(info));
        } else if (flavor == PROC_PIDFDVNODEPATHINFO &&
                   (size_t)ret >= sizeof(struct vnode_fdinfowithpath)) {
            struct vnode_fdinfowithpath *info = (struct vnode_fdinfowithpath *)buffer;
            if (pt_is_sensitive_host_fd_path(info->pvip.vip_path, caller)) {
                memset(info, 0, sizeof(struct vnode_fdinfowithpath));
                errno = EBADF;
                return raw_syscall_abi ? -1 : 0;
            }
            char vout[PATH_MAX];
            const char *virt = pt_virtualize_path_for_app(info->pvip.vip_path, vout, sizeof(vout), YES);
            if (virt != info->pvip.vip_path) {
                strlcpy(info->pvip.vip_path, virt, sizeof(info->pvip.vip_path));
            }
            pt_sanitize_vinfo_stat_in_place(&info->pvip.vip_vi.vi_stat);
        } else if (flavor == PROC_PIDFDPSEMINFO &&
                   (size_t)ret >= sizeof(struct psem_fdinfo)) {
            struct psem_fdinfo info;
            memcpy(&info, buffer, sizeof(info));
            info.pseminfo.psem_name[sizeof(info.pseminfo.psem_name) - 1U] = '\0';
            if (pt_is_hidden_proc_text(info.pseminfo.psem_name)) {
                memset(buffer, 0, sizeof(struct psem_fdinfo));
                errno = EBADF;
                return raw_syscall_abi ? -1 : 0;
            }
            pt_sanitize_vinfo_stat_in_place(&info.pseminfo.psem_stat);
            memcpy(buffer, &info, sizeof(info));
        } else if (flavor == PROC_PIDFDPSHMINFO &&
                   (size_t)ret >= sizeof(struct pshm_fdinfo)) {
            struct pshm_fdinfo info;
            memcpy(&info, buffer, sizeof(info));
            info.pshminfo.pshm_name[sizeof(info.pshminfo.pshm_name) - 1U] = '\0';
            if (pt_is_hidden_proc_text(info.pshminfo.pshm_name)) {
                memset(buffer, 0, sizeof(struct pshm_fdinfo));
                errno = EBADF;
                return raw_syscall_abi ? -1 : 0;
            }
            pt_sanitize_vinfo_stat_in_place(&info.pshminfo.pshm_stat);
            memcpy(buffer, &info, sizeof(info));
        } else if (flavor == PROC_PIDFDSOCKETINFO &&
                   pt_is_bypass_enabled() &&
                   (size_t)ret >= sizeof(pt_socket_fdinfo_t)) {
            pt_socket_fdinfo_t sfi;
            memcpy(&sfi, buffer, sizeof(sfi));
            if (sfi.psi.soi_family == AF_UNIX || sfi.psi.soi_kind == SOCKINFO_UN) {
                BOOL drop_a = pt_sanitize_sockaddr_un_in_place(&sfi.psi.soi_proto.pri_un.unsi_addr.ua_sun, caller);
                BOOL drop_c = pt_sanitize_sockaddr_un_in_place(&sfi.psi.soi_proto.pri_un.unsi_caddr.ua_sun, caller);
                if (drop_a || drop_c) {
                    memset(buffer, 0, sizeof(pt_socket_fdinfo_t));
                    errno = EBADF;
                    return raw_syscall_abi ? -1 : 0;
                }
                memcpy(buffer, &sfi, sizeof(sfi));
            }
        }
    }
    return ret;
}

static int pt_fs_proc_pidfdinfo_ex(int pid,
                                     int fd,
                                     int flavor,
                                     void *buffer,
                                     int buffersize,
                                     const void *caller,
                                     BOOL raw_syscall_abi) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pid != 0 && pid != getpid()) {
        errno = ESRCH;
        return raw_syscall_abi ? -1 : 0;
    }
    int saved_errno = errno;
    errno = 0;
    int ret = proc_pidfdinfo(pid, fd, flavor, buffer, buffersize);
    int call_errno = errno;
    if (ret < 0 || call_errno != 0) {
        errno = (call_errno != 0) ? call_errno : ESRCH;
        return raw_syscall_abi ? -1 : 0;
    }
    if (ret == 0) {
        errno = saved_errno;
        return 0;
    }
    if (!is_sys) {
        int san_ret = pt_sanitize_proc_fd_or_fileport_buffer(
            ret, pid, fd, NO, flavor, buffer, caller, raw_syscall_abi);
        if (san_ret != ret) {
            return san_ret;
        }
    }
    errno = saved_errno;
    return ret;
}

extern int proc_pidfileportinfo(int pid, uint32_t fileport, int flavor, void *buffer, int buffersize);

static int pt_fs_proc_pidfileportinfo_ex(int pid,
                                         uint32_t fileport,
                                         int flavor,
                                         void *buffer,
                                         int buffersize,
                                         const void *caller,
                                         BOOL raw_syscall_abi) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pid != 0 && pid != getpid()) {
        errno = ESRCH;
        return raw_syscall_abi ? -1 : 0;
    }
    int saved_errno = errno;
    errno = 0;
    int ret = proc_pidfileportinfo(pid, fileport, flavor, buffer, buffersize);
    int call_errno = errno;
    if (ret < 0 || call_errno != 0) {
        errno = (call_errno != 0) ? call_errno : ESRCH;
        return raw_syscall_abi ? -1 : 0;
    }
    if (ret == 0) {
        errno = saved_errno;
        return 0;
    }
    if (!is_sys) {
        int san_ret = pt_sanitize_proc_fd_or_fileport_buffer(
            ret, pid, (int)fileport, YES, flavor, buffer, caller, raw_syscall_abi);
        if (san_ret != ret) {
            return san_ret;
        }
    }
    errno = saved_errno;
    return ret;
}

__attribute__((visibility("hidden")))
int pt_fs_proc_pidfileportinfo_syscall_with_caller(int pid,
                                                   uint32_t fileport,
                                                   int flavor,
                                                   void *buffer,
                                                   int buffersize,
                                                   const void *caller) {
    return pt_fs_proc_pidfileportinfo_ex(pid, fileport, flavor, buffer, buffersize, caller, YES);
}

static int pt_proc_pidfileportinfo(int pid, uint32_t fileport, int flavor, void *buffer, int buffersize) {
    return pt_fs_proc_pidfileportinfo_ex(pid, fileport, flavor, buffer, buffersize, __builtin_return_address(0), NO);
}

__attribute__((visibility("hidden")))
int pt_fs_proc_pidfdinfo_syscall_with_caller(int pid, int fd, int flavor, void *buffer, int buffersize, const void *caller) {
    return pt_fs_proc_pidfdinfo_ex(pid, fd, flavor, buffer, buffersize, caller, YES);
}

static int pt_proc_pidfdinfo(int pid, int fd, int flavor, void *buffer, int buffersize) {
    return pt_fs_proc_pidfdinfo_ex(pid, fd, flavor, buffer, buffersize, __builtin_return_address(0), NO);
}

static void pt_sanitize_vnode_vip_path(char *vip_path, size_t cap, const void *caller, const char *fallback) {
    if (cap == 0 || vip_path[0] == '\0') {
        return;
    }
    if (pt_is_hidden_dyld_image_name(vip_path) ||
        pt_is_sensitive_host_fd_path(vip_path, caller)) {
        strlcpy(vip_path, fallback, cap);
        return;
    }
    char vout[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(vip_path, vout, sizeof(vout), YES);
    if (virt != vip_path) {
        strlcpy(vip_path, virt, cap);
    } else {
        const char *san = pt_sanitize_image_path_for_app(vip_path);
        if (san != vip_path) {
            strlcpy(vip_path, san, cap);
        }
    }
}


static int pt_proc_regionfilename(int pid, uint64_t address, void *buffer, uint32_t buffersize) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pid != 0 && pid != getpid()) {
        errno = ESRCH;
        return 0;
    }
    int ret = proc_regionfilename(pid, address, buffer, buffersize);
    if (ret > 0 && buffer != NULL && buffersize > 1 && !is_sys) {
        char *pbuf = (char *)buffer;
        if (pt_should_hide_dyld_image(pbuf) ||
            pt_is_sensitive_host_fd_path(pbuf, caller)) {
            const char *fb = pt_fallback_system_image_path();
            size_t n = strlcpy(pbuf, fb, (size_t)buffersize);
            return (n < (size_t)buffersize) ? (int)n : (int)(buffersize - 1);
        }
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(pbuf, vout, sizeof(vout), YES);
        const char *san = (virt != pbuf) ? virt : pt_sanitize_image_path_for_app(pbuf);
        if (san != pbuf) {
            size_t n = strlcpy(pbuf, san, (size_t)buffersize);
            return (n < (size_t)buffersize) ? (int)n : (int)(buffersize - 1);
        }
    }
    return ret;
}

__attribute__((visibility("hidden")))
BOOL pt_fs_probe_hidden_region_path(uintptr_t addr, const void *caller) {
    if (addr == 0) {
        return NO;
    }
    int saved_errno = errno;
    struct proc_regionwithpathinfo probe_rp;
    memset(&probe_rp, 0, sizeof(probe_rp));
    int pr = proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, (uint64_t)addr, &probe_rp, (int)sizeof(probe_rp));
    errno = saved_errno;
    if (pr >= (int)sizeof(probe_rp) && probe_rp.prp_vip.vip_path[0] != '\0' &&
        (pt_should_hide_dyld_image(probe_rp.prp_vip.vip_path) ||
         pt_is_sensitive_host_fd_path(probe_rp.prp_vip.vip_path, caller))) {
        return YES;
    }
    return NO;
}

static int pt_fs_proc_pidinfo_ex(int pid,
                                     int flavor,
                                     uint64_t arg,
                                     void *buffer,
                                     int buffersize,
                                     const void *caller,
                                     BOOL raw_syscall_abi) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    int self_pid = getpid();
    if (!is_sys && pid != 0 && pid != self_pid) {
        errno = ESRCH;
        return raw_syscall_abi ? -1 : 0;
    }
    int saved_errno = errno;
    errno = 0;
    int ret = -1;
    int call_errno = 0;
    BOOL bypass_active = pt_is_bypass_enabled();
    if (!is_sys && bypass_active &&
        (flavor == PROC_PIDREGIONINFO ||
         flavor == PROC_PIDREGIONPATHINFO ||
         flavor == PROC_PIDREGIONPATHINFO2 ||
         flavor == PROC_PIDREGIONPATHINFO3)) {
        uint64_t query_arg = arg;
        BOOL exhausted = YES;
        for (int skip = 0; skip < 4096; skip++) {
            errno = 0;
            ret = proc_pidinfo(pid, flavor, query_arg, buffer, buffersize);
            call_errno = errno;
            if (ret <= 0 || call_errno != 0 || buffer == NULL) {
                exhausted = NO;
                break;
            }
            uint64_t raddr = 0;
            uint64_t rsize = 0;
            uint32_t rprot = 0;
            BOOL path_hidden = NO;
            if (flavor == PROC_PIDREGIONINFO && (size_t)ret >= sizeof(struct proc_regioninfo)) {
                struct proc_regioninfo rinfo;
                memcpy(&rinfo, buffer, sizeof(rinfo));
                raddr = rinfo.pri_address;
                rsize = rinfo.pri_size;
                rprot = rinfo.pri_protection;
                if (rsize >= sizeof(struct mach_header_64) &&
                    (rprot & VM_PROT_READ) != 0 &&
                    dyld_image_header_containing_address((const void *)(uintptr_t)raddr) == NULL) {
                    if (pt_fs_probe_hidden_region_path((uintptr_t)raddr, caller)) {
                        path_hidden = YES;
                    }
                }
            } else if (flavor != PROC_PIDREGIONINFO && (size_t)ret >= sizeof(struct proc_regionwithpathinfo)) {
                struct proc_regionwithpathinfo rpinfo;
                memcpy(&rpinfo, buffer, sizeof(rpinfo));
                raddr = rpinfo.prp_prinfo.pri_address;
                rsize = rpinfo.prp_prinfo.pri_size;
                rprot = rpinfo.prp_prinfo.pri_protection;
                if (rpinfo.prp_vip.vip_path[0] != '\0' &&
                    (pt_should_hide_dyld_image(rpinfo.prp_vip.vip_path) ||
                     pt_is_sensitive_host_fd_path(rpinfo.prp_vip.vip_path, caller))) {
                    path_hidden = YES;
                }
            } else {
                exhausted = NO;
                break;
            }
            BOOL hide_region = (rsize > 0) &&
                (path_hidden ||
                 pt_is_hidden_vm_region_range((uintptr_t)raddr, (uintptr_t)rsize) ||
                 pt_is_hidden_unregistered_macho_region((uintptr_t)raddr, (uintptr_t)rsize, (vm_prot_t)rprot));
            if (!hide_region) {
                exhausted = NO;
                break;
            }
            if (raddr > UINT64_MAX - rsize || raddr + rsize <= query_arg) {
                errno = ESRCH;
                return raw_syscall_abi ? -1 : 0;
            }
            query_arg = raddr + rsize;
        }
        if (exhausted) {
            errno = ESRCH;
            return raw_syscall_abi ? -1 : 0;
        }
    } else {
        ret = proc_pidinfo(pid, flavor, arg, buffer, buffersize);
        call_errno = errno;
    }
    BOOL failed = (ret < 0 || call_errno != 0);
    if (failed) {
        errno = call_errno;
        return raw_syscall_abi ? -1 : ret;
    }
    if (ret == 0 && flavor != PROC_PIDPATHINFO) {
        errno = saved_errno;
        return 0;
    }
    if (buffer == NULL || is_sys) {
        errno = saved_errno;
        return ret;
    }
    switch (flavor) {
        case PROC_PIDVNODEPATHINFO:
            if ((size_t)ret >= sizeof(struct proc_vnodepathinfo)) {
                struct proc_vnodepathinfo vinfo;
                memcpy(&vinfo, buffer, sizeof(vinfo));
                const char *vh = pt_get_virtual_home_cstr();
                const char *fb = (vh != NULL) ? vh : "/";
                pt_sanitize_vnode_vip_path(vinfo.pvi_cdir.vip_path, sizeof(vinfo.pvi_cdir.vip_path), caller, fb);
                pt_sanitize_vnode_vip_path(vinfo.pvi_rdir.vip_path, sizeof(vinfo.pvi_rdir.vip_path), caller, "/");
                pt_sanitize_vinfo_stat_in_place(&vinfo.pvi_cdir.vip_vi.vi_stat);
                pt_sanitize_vinfo_stat_in_place(&vinfo.pvi_rdir.vip_vi.vi_stat);
                memcpy(buffer, &vinfo, sizeof(vinfo));
            }
            break;

        case PROC_PIDLISTFDS:
            if ((size_t)ret >= sizeof(struct proc_fdinfo)) {
                int count = ret / (int)sizeof(struct proc_fdinfo);
                struct proc_fdinfo *fds = (struct proc_fdinfo *)buffer;
                int kept = 0;
                for (int i = 0; i < count; i++) {
                    if (fds[i].proc_fdtype == PROX_FDTYPE_VNODE) {
                        struct vnode_fdinfowithpath vfi;
                        int vret = proc_pidfdinfo(self_pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &vfi, (int)sizeof(vfi));
                        if (vret > 0 && (size_t)vret >= sizeof(vfi) &&
                            pt_is_sensitive_host_fd_path(vfi.pvip.vip_path, caller)) {
                            continue;
                        }
                    } else if (bypass_active && fds[i].proc_fdtype == PROX_FDTYPE_SOCKET) {
                        pt_socket_fdinfo_t sfi;
                        memset(&sfi, 0, sizeof(sfi));
                        int sret = proc_pidfdinfo(self_pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &sfi, (int)sizeof(sfi));
                        if (sret > 0 && (size_t)sret >= sizeof(sfi) &&
                            (sfi.psi.soi_family == AF_UNIX || sfi.psi.soi_kind == SOCKINFO_UN)) {
                            char pa[sizeof(sfi.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) + 1];
                            char pc[sizeof(sfi.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path) + 1];
                            size_t la = strnlen(sfi.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path, sizeof(pa) - 1U);
                            size_t lc = strnlen(sfi.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path, sizeof(pc) - 1U);
                            memcpy(pa, sfi.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path, la);
                            pa[la] = '\0';
                            memcpy(pc, sfi.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path, lc);
                            pc[lc] = '\0';
                            if (pt_is_sensitive_unix_socket_path(pa, caller) ||
                                pt_is_sensitive_unix_socket_path(pc, caller)) {
                                continue;
                            }
                        }
                    }
                    if (kept != i) {
                        fds[kept] = fds[i];
                    }
                    kept++;
                }
                ret = kept * (int)sizeof(struct proc_fdinfo);
            }
            break;

        case PROC_PIDLISTFILEPORTS:
            if ((size_t)ret >= sizeof(struct proc_fileportinfo)) {
                int count = ret / (int)sizeof(struct proc_fileportinfo);
                struct proc_fileportinfo *ports = (struct proc_fileportinfo *)buffer;
                int kept = 0;
                for (int i = 0; i < count; i++) {
                    if (ports[i].proc_fdtype == PROX_FDTYPE_VNODE) {
                        struct vnode_fdinfowithpath vfi;
                        int vret = proc_pidfileportinfo(self_pid, ports[i].proc_fileport, PROC_PIDFDVNODEPATHINFO, &vfi, (int)sizeof(vfi));
                        if (vret > 0 && (size_t)vret >= sizeof(vfi) &&
                            pt_is_sensitive_host_fd_path(vfi.pvip.vip_path, caller)) {
                            continue;
                        }
                    } else if (bypass_active && ports[i].proc_fdtype == PROX_FDTYPE_SOCKET) {
                        pt_socket_fdinfo_t sfi;
                        memset(&sfi, 0, sizeof(sfi));
                        int sret = proc_pidfileportinfo(self_pid, ports[i].proc_fileport, PROC_PIDFDSOCKETINFO, &sfi, (int)sizeof(sfi));
                        if (sret > 0 && (size_t)sret >= sizeof(sfi) &&
                            (sfi.psi.soi_family == AF_UNIX || sfi.psi.soi_kind == SOCKINFO_UN)) {
                            char pa[sizeof(sfi.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) + 1];
                            char pc[sizeof(sfi.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path) + 1];
                            size_t la = strnlen(sfi.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path, sizeof(pa) - 1U);
                            size_t lc = strnlen(sfi.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path, sizeof(pc) - 1U);
                            memcpy(pa, sfi.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path, la);
                            pa[la] = '\0';
                            memcpy(pc, sfi.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path, lc);
                            pc[lc] = '\0';
                            if (pt_is_sensitive_unix_socket_path(pa, caller) ||
                                pt_is_sensitive_unix_socket_path(pc, caller)) {
                                continue;
                            }
                        }
                    }
                    if (kept != i) {
                        ports[kept] = ports[i];
                    }
                    kept++;
                }
                ret = kept * (int)sizeof(struct proc_fileportinfo);
            }
            break;

        case PROC_PIDLISTTHREADS:
            if (bypass_active && (size_t)ret >= sizeof(uint64_t)) {
                int count = ret / (int)sizeof(uint64_t);
                uint64_t *tids = (uint64_t *)buffer;
                int kept = 0;
                for (int i = 0; i < count; i++) {
                    struct proc_threadinfo ti;
                    int tr = proc_pidinfo(self_pid, PROC_PIDTHREADINFO, tids[i], &ti, (int)sizeof(ti));
                    if (tr > 0 && (size_t)tr >= sizeof(ti) && pt_is_hidden_thread_name(ti.pth_name)) {
                        continue;
                    }
                    if (kept != i) {
                        tids[kept] = tids[i];
                    }
                    kept++;
                }
                ret = kept * (int)sizeof(uint64_t);
            }
            break;

        case PROC_PIDTHREADINFO:
        case PROC_PIDTHREADID64INFO:
            if (bypass_active && (size_t)ret >= sizeof(struct proc_threadinfo)) {
                struct proc_threadinfo *ti = (struct proc_threadinfo *)buffer;
                if (pt_is_hidden_thread_name(ti->pth_name)) {
                    memset(ti->pth_name, 0, sizeof(ti->pth_name));
                }
            }
            break;

        case PROC_PIDTHREADPATHINFO:
            if ((size_t)ret >= sizeof(struct proc_threadwithpathinfo)) {
                struct proc_threadwithpathinfo tpi;
                memcpy(&tpi, buffer, sizeof(tpi));
                if (bypass_active && pt_is_hidden_thread_name(tpi.pt.pth_name)) {
                    memset(tpi.pt.pth_name, 0, sizeof(tpi.pt.pth_name));
                }
                pt_sanitize_vnode_vip_path(tpi.pvip.vip_path,
                                           sizeof(tpi.pvip.vip_path),
                                           caller,
                                           pt_fallback_system_image_path());
                pt_sanitize_vinfo_stat_in_place(&tpi.pvip.vip_vi.vi_stat);
                memcpy(buffer, &tpi, sizeof(tpi));
            }
            break;

        case PROC_PIDTBSDINFO:
            if ((size_t)ret >= sizeof(struct proc_bsdinfo)) {
                struct proc_bsdinfo *binfo = (struct proc_bsdinfo *)buffer;
                binfo->pbi_flags &= ~(uint32_t)PROC_FLAG_TRACED;
                binfo->pbi_ppid = 1;
                if (bypass_active) {
                    if (binfo->pbi_gid == 20U) {
                        binfo->pbi_gid = 501U;
                    }
                    if (binfo->pbi_rgid == 20U) {
                        binfo->pbi_rgid = 501U;
                    }
                    if (binfo->pbi_svgid == 20U) {
                        binfo->pbi_svgid = 501U;
                    }
                    pt_sanitize_proc_name_buf(binfo->pbi_comm, sizeof(binfo->pbi_comm));
                    pt_sanitize_proc_name_buf(binfo->pbi_name, sizeof(binfo->pbi_name));
                }
            }
            break;

        case PROC_PIDTASKINFO:
            if (bypass_active && (size_t)ret >= sizeof(struct proc_taskinfo)) {
                struct proc_taskinfo *pti = (struct proc_taskinfo *)buffer;
                int hidden = pt_count_hidden_threads_for_self();
                if (hidden > 0 && pti->pti_threadnum > 1) {
                    int adj = pti->pti_threadnum - hidden;
                    pti->pti_threadnum = (adj >= 1) ? adj : 1;
                }
            }
            break;

        case PROC_PIDTASKALLINFO:
            if ((size_t)ret >= sizeof(struct proc_taskallinfo)) {
                struct proc_taskallinfo *tinfo = (struct proc_taskallinfo *)buffer;
                tinfo->pbsd.pbi_flags &= ~(uint32_t)PROC_FLAG_TRACED;
                tinfo->pbsd.pbi_ppid = 1;
                if (bypass_active) {
                    if (tinfo->pbsd.pbi_gid == 20U) {
                        tinfo->pbsd.pbi_gid = 501U;
                    }
                    if (tinfo->pbsd.pbi_rgid == 20U) {
                        tinfo->pbsd.pbi_rgid = 501U;
                    }
                    if (tinfo->pbsd.pbi_svgid == 20U) {
                        tinfo->pbsd.pbi_svgid = 501U;
                    }
                    pt_sanitize_proc_name_buf(tinfo->pbsd.pbi_comm, sizeof(tinfo->pbsd.pbi_comm));
                    pt_sanitize_proc_name_buf(tinfo->pbsd.pbi_name, sizeof(tinfo->pbsd.pbi_name));
                    int hidden = pt_count_hidden_threads_for_self();
                    if (hidden > 0 && tinfo->ptinfo.pti_threadnum > 1) {
                        int adj = tinfo->ptinfo.pti_threadnum - hidden;
                        tinfo->ptinfo.pti_threadnum = (adj >= 1) ? adj : 1;
                    }
                }
            }
            break;

        case PROC_PIDT_SHORTBSDINFO:
            if ((size_t)ret >= sizeof(struct proc_bsdshortinfo)) {
                struct proc_bsdshortinfo *sinfo = (struct proc_bsdshortinfo *)buffer;
                sinfo->pbsi_flags &= ~(uint32_t)PROC_FLAG_TRACED;
                sinfo->pbsi_ppid = 1;
                if (bypass_active) {
                    if (sinfo->pbsi_gid == 20U) {
                        sinfo->pbsi_gid = 501U;
                    }
                    if (sinfo->pbsi_rgid == 20U) {
                        sinfo->pbsi_rgid = 501U;
                    }
                    if (sinfo->pbsi_svgid == 20U) {
                        sinfo->pbsi_svgid = 501U;
                    }
                    pt_sanitize_proc_name_buf(sinfo->pbsi_comm, sizeof(sinfo->pbsi_comm));
                }
            }
            break;

        case PROC_PIDREGIONPATHINFO:
        case PROC_PIDREGIONPATHINFO2:
        case PROC_PIDREGIONPATHINFO3:
            if ((size_t)ret >= sizeof(struct proc_regionwithpathinfo)) {
                struct proc_regionwithpathinfo rinfo;
                memcpy(&rinfo, buffer, sizeof(rinfo));
                pt_sanitize_vnode_vip_path(rinfo.prp_vip.vip_path,
                                           sizeof(rinfo.prp_vip.vip_path),
                                           caller,
                                           pt_fallback_system_image_path());
                pt_sanitize_vinfo_stat_in_place(&rinfo.prp_vip.vip_vi.vi_stat);
                memcpy(buffer, &rinfo, sizeof(rinfo));
            }
            break;

        case PROC_PIDUNIQIDENTIFIERINFO:
            if (bypass_active && (size_t)ret >= sizeof(struct proc_uniqidentifierinfo)) {
                struct proc_uniqidentifierinfo *uinfo = (struct proc_uniqidentifierinfo *)buffer;
                uinfo->p_puniqueid = 1ULL;
            }
            break;

        case PROC_PIDPATHINFO:
            if (buffersize > 1) {
                char *pbuf = (char *)buffer;
                pbuf[buffersize - 1] = '\0';
                char vout[PATH_MAX];
                const char *virt = pt_virtualize_path_for_app(pbuf, vout, sizeof(vout), YES);
                if (virt != pbuf) {
                    strlcpy(pbuf, virt, (size_t)buffersize);
                }
                if (pt_is_sensitive_host_fd_path(pbuf, caller)) {
                    pbuf[0] = '\0';
                    errno = ESRCH;
                    return raw_syscall_abi ? -1 : 0;
                }
                errno = saved_errno;
                return 0;
            }
            break;

        default:
            break;
    }
    errno = saved_errno;
    return ret;
}

__attribute__((visibility("hidden")))
int pt_fs_proc_pidinfo_with_caller(int pid, int flavor, uint64_t arg, void *buffer, int buffersize, const void *caller) {
    return pt_fs_proc_pidinfo_ex(pid, flavor, arg, buffer, buffersize, caller, NO);
}

__attribute__((visibility("hidden")))
int pt_fs_proc_pidinfo_syscall_with_caller(int pid, int flavor, uint64_t arg, void *buffer, int buffersize, const void *caller) {
    return pt_fs_proc_pidinfo_ex(pid, flavor, arg, buffer, buffersize, caller, YES);
}

static int pt_proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize) {
    return pt_fs_proc_pidinfo_with_caller(pid, flavor, arg, buffer, buffersize, __builtin_return_address(0));
}

static int pt_fs_proc_listpids_ex(uint32_t type,
                                  uint32_t typeinfo,
                                  void *buffer,
                                  int buffersize,
                                  const void *caller,
                                  BOOL raw_syscall_abi) {
    if (!pt_is_effective_system_or_playtools_caller(caller)) {
        if (type == PROC_ALL_PIDS || typeinfo == 0 || (uid_t)typeinfo == getuid() || typeinfo == 501U) {
            if (buffer == NULL || buffersize <= 0) {
                return (int)sizeof(int);
            }
            if (buffersize < (int)sizeof(int)) {
                return 0;
            }
            *(int *)buffer = getpid();
            return (int)sizeof(int);
        }
        return 0;
    }
    int saved_errno = errno;
    errno = 0;
    int ret = proc_listpids(type, typeinfo, buffer, buffersize);
    int call_errno = errno;
    if (ret < 0 || call_errno != 0) {
        errno = call_errno;
        return raw_syscall_abi ? -1 : ret;
    }
    errno = saved_errno;
    return ret;
}

__attribute__((visibility("hidden")))
int pt_fs_proc_listpids_syscall_with_caller(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize, const void *caller) {
    return pt_fs_proc_listpids_ex(type, typeinfo, buffer, buffersize, caller, YES);
}

static int pt_proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize) {
    return pt_fs_proc_listpids_ex(type, typeinfo, buffer, buffersize, __builtin_return_address(0), NO);
}

static int pt_proc_listallpids(void *buffer, int buffersize) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (buffer == NULL || buffersize <= 0) {
            return (int)sizeof(int);
        }
        if (buffersize < (int)sizeof(int)) {
            return 0;
        }
        *(int *)buffer = getpid();
        return (int)sizeof(int);
    }
    return proc_listallpids(buffer, buffersize);
}

static int pt_proc_name(int pid, void *buffer, uint32_t buffersize) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (pid != 0 && pid != getpid() && !is_sys) {
        errno = ESRCH;
        return 0;
    }
    int r = proc_name(pid, buffer, buffersize);
    if (r > 0 && !is_sys && pt_is_bypass_enabled() && buffer != NULL && buffersize > 1U) {
        char *cbuf = (char *)buffer;
        pt_sanitize_proc_name_buf(cbuf, (size_t)buffersize);
        return (int)strlen(cbuf);
    }
    return r;
}

extern int pt_orig_proc_pidpath_audittoken(audit_token_t *audittoken, void *buffer, uint32_t buffersize) __asm__("_proc_pidpath_audittoken") __attribute__((weak_import));

static int pt_proc_pidpath_audittoken(audit_token_t *audittoken, void *buffer, uint32_t buffersize) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pt_is_bypass_enabled()) {
        if (audittoken == NULL || (pid_t)audittoken->val[5] != getpid()) {
            errno = ESRCH;
            return 0;
        }
    }
    if (&pt_orig_proc_pidpath_audittoken == NULL) {
        errno = ENOSYS;
        return 0;
    }
    int r = pt_orig_proc_pidpath_audittoken(audittoken, buffer, buffersize);
    if (r > 0 && !is_sys && buffer != NULL && buffersize > 1U) {
        char *pbuf = (char *)buffer;
        pbuf[buffersize - 1U] = '\0';
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(pbuf, vout, sizeof(vout), YES);
        const char *san = (virt != pbuf) ? virt : pt_sanitize_image_path_for_app(pbuf);
        if (san != pbuf) {
            strlcpy(pbuf, san, (size_t)buffersize);
        }
        if (pt_is_sensitive_host_fd_path(pbuf, caller)) {
            pbuf[0] = '\0';
            errno = ESRCH;
            return 0;
        }
        return (int)strlen(pbuf);
    }
    return r;
}

static int pt_proc_listpidspath(uint32_t type,
                                uint32_t typeinfo,
                                const char *path,
                                uint32_t pathflags,
                                void *buffer,
                                int buffersize) {
    const void *caller = __builtin_return_address(0);
    if (pt_is_effective_system_or_playtools_caller(caller)) {
        return proc_listpidspath(type, typeinfo, path, pathflags, buffer, buffersize);
    }
    if (path != NULL && path[0] != '\0') {
        char vbuf[PATH_MAX];
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, caller, vbuf, sizeof(vbuf), &path);
        if (disp == PT_FS_PATH_HIDDEN) {
            return 0;
        }
        if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
            if (buffer == NULL || buffersize <= 0) {
                return (int)sizeof(int);
            }
            if (buffersize < (int)sizeof(int)) {
                return 0;
            }
            *(int *)buffer = getpid();
            return (int)sizeof(int);
        }
    }
    int cap_bytes = (buffer != NULL && buffersize > 0) ? buffersize : 0;
    int stack_pids[256];
    int *tmp = stack_pids;
    int tmp_cap = (int)sizeof(stack_pids);
    if (cap_bytes > tmp_cap) {
        tmp = (int *)malloc((size_t)cap_bytes);
        if (tmp == NULL) {
            return 0;
        }
        tmp_cap = cap_bytes;
    }
    int ret = proc_listpidspath(type, typeinfo, path, pathflags, tmp, tmp_cap);
    if (ret <= 0) {
        if (tmp != stack_pids) {
            free(tmp);
        }
        return ret;
    }
    int self_pid = getpid();
    int cnt = ret / (int)sizeof(int);
    BOOL found = NO;
    for (int i = 0; i < cnt; i++) {
        if (tmp[i] == self_pid) {
            found = YES;
            break;
        }
    }
    if (tmp != stack_pids) {
        free(tmp);
    }
    if (!found) {
        return 0;
    }
    if (buffer == NULL || buffersize <= 0) {
        return (int)sizeof(int);
    }
    if (buffersize < (int)sizeof(int)) {
        return 0;
    }
    *(int *)buffer = self_pid;
    return (int)sizeof(int);
}

extern int pt_orig_proc_pidoriginatorinfo(int, void *, int) __asm__("_proc_pidoriginatorinfo") __attribute__((weak_import));
extern int pt_orig_proc_listchildpids(pid_t, void *, int) __asm__("_proc_listchildpids") __attribute__((weak_import));
extern int pt_orig_proc_listpgrppids(pid_t, void *, int) __asm__("_proc_listpgrppids") __attribute__((weak_import));
extern int pt_orig_proc_pid_rusage(int, int, void *) __asm__("_proc_pid_rusage") __attribute__((weak_import));

static int pt_proc_pidoriginatorinfo(int flavor, void *buffer, int buffersize) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = ESRCH;
        return 0;
    }
    if (&pt_orig_proc_pidoriginatorinfo != NULL) {
        return pt_orig_proc_pidoriginatorinfo(flavor, buffer, buffersize);
    }
    errno = ENOSYS;
    return 0;
}

static int pt_proc_listchildpids(pid_t ppid, void *buffer, int buffersize) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0;
    }
    if (&pt_orig_proc_listchildpids != NULL) {
        return pt_orig_proc_listchildpids(ppid, buffer, buffersize);
    }
    return 0;
}

static int pt_proc_listpgrppids(pid_t pgrpid, void *buffer, int buffersize) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pgrpid == getpgrp()) {
            if (buffer == NULL || buffersize <= 0) {
                return (int)sizeof(int);
            }
            if (buffersize < (int)sizeof(int)) {
                return 0;
            }
            *(int *)buffer = getpid();
            return (int)sizeof(int);
        }
        return 0;
    }
    if (&pt_orig_proc_listpgrppids != NULL) {
        return pt_orig_proc_listpgrppids(pgrpid, buffer, buffersize);
    }
    return 0;
}

static int pt_proc_pid_rusage(int pid, int flavor, void *buffer) {
    if (pid != 0 && pid != getpid() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = ESRCH;
        return -1;
    }
    if (&pt_orig_proc_pid_rusage != NULL) {
        return pt_orig_proc_pid_rusage(pid, flavor, buffer);
    }
    errno = ENOSYS;
    return -1;
}

extern DIR *__opendir2(const char *name, int flags);

static DIR *pt_opendir(const char *name) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(name, __builtin_return_address(0), vbuf, sizeof(vbuf), &name);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return NULL;
    }
    return opendir(name);
}

static DIR *pt_opendir2(const char *name, int flags) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(name, __builtin_return_address(0), vbuf, sizeof(vbuf), &name);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return NULL;
    }
    return __opendir2(name, flags);
}

static DIR *pt_fdopendir(int fd) {
    if (fd < 0) {
        errno = EBADF;
        return NULL;
    }
    if (pt_fd_is_sensitive(fd, __builtin_return_address(0))) {
        errno = EBADF;
        return NULL;
    }
    return fdopendir(fd);
}



__attribute__((visibility("hidden"))) BOOL pt_path_equals_real_data_root(const char *path) {
    if (path == NULL || path[0] != '/') {
        return NO;
    }
    pt_ensure_data_container_map();
    if (s_real_data_container_len == 0) {
        return NO;
    }
    if (strncmp(path, "/System/Volumes/Data/", 21) == 0) {
        path += 20;
    }
    size_t len = strlen(path);
    while (len > 1 && path[len - 1] == '/') {
        len--;
    }
    if (len >= PATH_MAX) {
        return NO;
    }
    char clean_path[PATH_MAX];
    memcpy(clean_path, path, len);
    clean_path[len] = '\0';
    const char *suf = pt_match_prefix_modulo_private(clean_path, s_real_data_container_dir, s_real_data_container_len);
    return (suf != NULL && suf[0] == '\0');
}

static BOOL pt_dir_fd_is_real_data_root(DIR *dirp) {
    if (dirp == NULL) {
        return NO;
    }
    int fd = dirfd(dirp);
    if (fd < 0) {
        return NO;
    }
    char dp[PATH_MAX];
    if (fcntl(fd, F_GETPATH, dp) == -1) {
        return NO;
    }
    return pt_path_equals_real_data_root(dp);
}

static BOOL pt_dirname_is_real_data_root(const char *dirname) {
    if (dirname == NULL || dirname[0] != '/') {
        return NO;
    }
    char lex_buf[PATH_MAX];
    const char *norm = dirname;
    if (pt_needs_lexical_norm(norm)) {
        const char *collapsed = pt_normalize_lexical_path(norm, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            norm = collapsed;
        }
    }
    return pt_path_equals_real_data_root(norm);
}

__attribute__((visibility("hidden"))) BOOL pt_should_hide_dirent(const char *d_name,
                                  uint8_t d_type,
                                  const void *caller,
                                  int *inout_is_sys_caller,
                                  int *inout_in_data_root,
                                  DIR *dirp_for_lazy_check,
                                  int dirfd_for_check,
                                  const char *dirname_for_lazy_check) {
    if (d_name == NULL || d_name[0] == '\0' || !pt_is_bypass_enabled()) {
        return NO;
    }
    if (strcmp(d_name, ".") == 0 || strcmp(d_name, "..") == 0) {
        return NO;
    }
    if (*inout_is_sys_caller < 0) {
        *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    if (*inout_is_sys_caller == 1) {
        return NO;
    }
    if (pt_is_hidden_dirent_name(d_name)) {
        return YES;
    }

    char dp[PATH_MAX];
    const char *dir_path = dirname_for_lazy_check;
    if (dir_path == NULL) {
        int saved_err = errno;
        int dfd = (dirp_for_lazy_check != NULL) ? dirfd(dirp_for_lazy_check) : dirfd_for_check;
        if (dfd >= 0 && fcntl(dfd, F_GETPATH, dp) != -1) {
            dir_path = dp;
        }
        errno = saved_err;
    }
    if (dir_path != NULL && dir_path[0] == '/') {
        if (strncasecmp(dir_path, "/System/Volumes/Data/", 21) == 0) {
            dir_path += 20;
        }
        char full_path[PATH_MAX];
        int fn = (strcmp(dir_path, "/") == 0)
            ? snprintf(full_path, sizeof(full_path), "/%s", d_name)
            : snprintf(full_path, sizeof(full_path), "%s/%s", dir_path, d_name);
        if (fn > 0 && (size_t)fn < sizeof(full_path)) {
            char lex_buf[PATH_MAX];
            const char *norm = full_path;
            if (pt_needs_lexical_norm(norm)) {
                const char *collapsed = pt_normalize_lexical_path(norm, lex_buf, sizeof(lex_buf));
                if (collapsed != NULL) {
                    norm = collapsed;
                }
            }
            if (pt_is_hidden_normalized_path_cached_caller(norm, caller, inout_is_sys_caller)) {
                return YES;
            }
        }
    }

    if (pt_is_macos_data_root_symlink_name(d_name)) {
        if (*inout_in_data_root < 0) {
            BOOL in_root = NO;
            if (dirp_for_lazy_check != NULL) {
                in_root = pt_dir_fd_is_real_data_root(dirp_for_lazy_check);
            } else if (dirname_for_lazy_check != NULL) {
                in_root = pt_dirname_is_real_data_root(dirname_for_lazy_check);
            } else if (dir_path != NULL) {
                in_root = pt_dirname_is_real_data_root(dir_path);
            }
            *inout_in_data_root = in_root ? 1 : 0;
        }
        if (*inout_in_data_root == 1) {
            if (strcasecmp(d_name, "Desktop") == 0) {
                return YES;
            } else if (d_type == DT_LNK) {
                return YES;
            } else if (d_type == DT_UNKNOWN) {
                struct stat st;
                int dfd = (dirp_for_lazy_check != NULL) ? dirfd(dirp_for_lazy_check) : dirfd_for_check;
                if (dfd >= 0) {
                    if (fstatat(dfd, d_name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode)) {
                        return YES;
                    }
                } else if (dirname_for_lazy_check != NULL) {
                    char full[PATH_MAX];
                    int n = snprintf(full, sizeof(full), "%s/%s", dirname_for_lazy_check, d_name);
                    if (n > 0 && (size_t)n < sizeof(full) && lstat(full, &st) == 0 && S_ISLNK(st.st_mode)) {
                        return YES;
                    }
                }
            }
        }
    }
    return NO;
}

extern ssize_t pt_orig_getdirentries64(int fd, void *buf, size_t bufsize, off_t *position) __asm("___getdirentries64") __attribute__((weak_import));

__attribute__((visibility("hidden")))
ssize_t pt_fs_getdirentries64_syscall_with_caller(int fd, void *buf, size_t bufsize, off_t *position, const void *caller) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (is_sys || !pt_is_bypass_enabled()) {
        return pt_orig_getdirentries64(fd, buf, bufsize, position);
    }
    char dirpath[PATH_MAX];
    dirpath[0] = '\0';
    int saved_errno = errno;
    if (fd >= 0 && fcntl(fd, F_GETPATH, dirpath) != -1 && pt_is_sensitive_host_fd_path(dirpath, caller)) {
        errno = EBADF;
        return -1;
    }
    errno = saved_errno;
    int is_sys_int = 0;
    int in_data_root = (dirpath[0] != '\0') ? (pt_path_equals_real_data_root(dirpath) ? 1 : 0) : -1;
    for (int guard = 0; guard < 256; guard++) {
        ssize_t nbytes = pt_orig_getdirentries64(fd, buf, bufsize, position);
        if (nbytes <= 0 || buf == NULL) {
            return nbytes;
        }
        uint8_t *base = (uint8_t *)buf;
        size_t total = (size_t)nbytes;
        size_t read_off = 0;
        size_t write_off = 0;
        while (read_off + offsetof(struct dirent, d_name) < total) {
            const struct dirent *ent = (const struct dirent *)(base + read_off);
            uint16_t reclen = ent->d_reclen;
            if (reclen < offsetof(struct dirent, d_name) || read_off + reclen > total) {
                size_t rem = total - read_off;
                if (write_off != read_off) {
                    memmove(base + write_off, base + read_off, rem);
                }
                write_off += rem;
                break;
            }
            char namebuf[NAME_MAX + 1];
            size_t max_name = (size_t)reclen - offsetof(struct dirent, d_name);
            size_t nlen = (ent->d_namlen < max_name) ? (size_t)ent->d_namlen : max_name;
            if (nlen >= sizeof(namebuf)) {
                nlen = sizeof(namebuf) - 1U;
            }
            memcpy(namebuf, ent->d_name, nlen);
            namebuf[nlen] = '\0';
            if (!pt_should_hide_dirent(namebuf, ent->d_type, caller, &is_sys_int, &in_data_root,
                                       NULL, fd, (dirpath[0] != '\0') ? dirpath : NULL)) {
                if (write_off != read_off) {
                    memmove(base + write_off, base + read_off, reclen);
                }
                write_off += reclen;
            }
            read_off += reclen;
        }
        if (write_off > 0) {
            return (ssize_t)write_off;
        }
    }
    return 0;
}

static ssize_t pt_getdirentries64(int fd, void *buf, size_t bufsize, off_t *position) {
    return pt_fs_getdirentries64_syscall_with_caller(fd, buf, bufsize, position, __builtin_return_address(0));
}

extern int pt_orig_getdirentries(int fd, char *buf, int nbytes, long *basep) __asm("_getdirentries");

typedef struct __attribute__((packed)) {
    uint32_t d_ino;
    uint16_t d_reclen;
    uint8_t  d_type;
    uint8_t  d_namlen;
} pt_legacy_dirent_hdr_t;

__attribute__((visibility("hidden")))
ssize_t pt_fs_getdirentries_syscall_with_caller(int fd, void *buf, size_t bufsize, long *basep, const void *caller) {
    int cap_bytes = (bufsize > (size_t)INT_MAX) ? INT_MAX : (int)bufsize;
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (is_sys || !pt_is_bypass_enabled()) {
        return (ssize_t)pt_orig_getdirentries(fd, (char *)buf, cap_bytes, basep);
    }
    char dirpath[PATH_MAX];
    dirpath[0] = '\0';
    int saved_errno = errno;
    if (fd >= 0 && fcntl(fd, F_GETPATH, dirpath) != -1 && pt_is_sensitive_host_fd_path(dirpath, caller)) {
        errno = EBADF;
        return -1;
    }
    errno = saved_errno;
    int is_sys_int = 0;
    int in_data_root = (dirpath[0] != '\0') ? (pt_path_equals_real_data_root(dirpath) ? 1 : 0) : -1;
    for (int guard = 0; guard < 256; guard++) {
        int nbytes = pt_orig_getdirentries(fd, (char *)buf, cap_bytes, basep);
        if (nbytes <= 0 || buf == NULL) {
            return (ssize_t)nbytes;
        }
        uint8_t *base = (uint8_t *)buf;
        size_t total = (size_t)nbytes;
        size_t read_off = 0;
        size_t write_off = 0;
        const size_t hdr_sz = sizeof(pt_legacy_dirent_hdr_t);
        while (read_off + hdr_sz < total) {
            pt_legacy_dirent_hdr_t hdr;
            memcpy(&hdr, base + read_off, hdr_sz);
            uint16_t reclen = hdr.d_reclen;
            if (reclen < hdr_sz || read_off + reclen > total) {
                size_t rem = total - read_off;
                if (write_off != read_off) {
                    memmove(base + write_off, base + read_off, rem);
                }
                write_off += rem;
                break;
            }
            char namebuf[NAME_MAX + 1];
            size_t max_name = (size_t)reclen - hdr_sz;
            size_t nlen = (hdr.d_namlen < max_name) ? (size_t)hdr.d_namlen : max_name;
            if (nlen >= sizeof(namebuf)) {
                nlen = sizeof(namebuf) - 1U;
            }
            memcpy(namebuf, base + read_off + hdr_sz, nlen);
            namebuf[nlen] = '\0';
            if (!pt_should_hide_dirent(namebuf, hdr.d_type, caller, &is_sys_int, &in_data_root,
                                       NULL, fd, (dirpath[0] != '\0') ? dirpath : NULL)) {
                if (write_off != read_off) {
                    memmove(base + write_off, base + read_off, reclen);
                }
                write_off += reclen;
            }
            read_off += reclen;
        }
        if (write_off > 0) {
            return (ssize_t)write_off;
        }
    }
    return 0;
}

static int pt_getdirentries(int fd, char *buf, int nbytes, long *basep) {
    size_t sz = (nbytes > 0) ? (size_t)nbytes : 0U;
    return (int)pt_fs_getdirentries_syscall_with_caller(fd, buf, sz, basep, __builtin_return_address(0));
}

static struct dirent *pt_readdir(DIR *dirp) {
    const void *caller = __builtin_return_address(0);
    struct dirent *entry = readdir(dirp);
    int is_sys_caller = -1;
    int in_data_root = -1;
    while (entry != NULL &&
           pt_should_hide_dirent(entry->d_name, entry->d_type, caller, &is_sys_caller, &in_data_root, dirp, -1, NULL)) {
        entry = readdir(dirp);
    }
    return entry;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int pt_readdir_r(DIR *dirp, struct dirent *entry, struct dirent **result) {
    const void *caller = __builtin_return_address(0);
    int rc = readdir_r(dirp, entry, result);
    int is_sys_caller = -1;
    int in_data_root = -1;
    while (rc == 0 && result != NULL && *result != NULL &&
           pt_should_hide_dirent((*result)->d_name, (*result)->d_type, caller, &is_sys_caller, &in_data_root, dirp, -1, NULL)) {
        rc = readdir_r(dirp, entry, result);
    }
    return rc;
}
#pragma clang diagnostic pop

static int pt_finish_scandir_results(struct dirent ***namelist,
                                     int count,
                                     const char *resolved_dirname,
                                     int dirfd_for_check,
                                     int (*select_fn)(const struct dirent *),
                                     int (*compar_fn)(const struct dirent **, const struct dirent **),
                                     int (^select_blk)(const struct dirent *),
                                     int (^compar_blk)(const struct dirent **, const struct dirent **),
                                     const void *caller,
                                     int is_sys_caller) {
    if (count < 0 || namelist == NULL || *namelist == NULL) {
        return count;
    }
    struct dirent **list = *namelist;
    int in_data_root = -1;
    int dst = 0;
    for (int i = 0; i < count; i++) {
        struct dirent *ent = list[i];
        if (ent == NULL) {
            continue;
        }
        if (pt_should_hide_dirent(ent->d_name, ent->d_type, caller, &is_sys_caller,
                                  &in_data_root, NULL, dirfd_for_check, resolved_dirname)) {
            free(ent);
            continue;
        }
        if (select_fn != NULL && !select_fn(ent)) {
            free(ent);
            continue;
        }
        if (select_blk != NULL && !select_blk(ent)) {
            free(ent);
            continue;
        }
        list[dst++] = ent;
    }
    if (dst > 1) {
        if (compar_fn != NULL) {
            qsort_b(list, (size_t)dst, sizeof(struct dirent *), ^int(const void *a, const void *b) {
                return compar_fn((const struct dirent **)a, (const struct dirent **)b);
            });
        } else if (compar_blk != NULL) {
            qsort_b(list, (size_t)dst, sizeof(struct dirent *), ^int(const void *a, const void *b) {
                return compar_blk((const struct dirent **)a, (const struct dirent **)b);
            });
        }
    }
    return dst;
}

static int pt_scandir(const char *dirname,
                      struct dirent ***namelist,
                      int (*select_fn)(const struct dirent *),
                      int (*compar_fn)(const struct dirent **, const struct dirent **)) {
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(dirname, caller, vbuf, sizeof(vbuf), &dirname, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (is_sys_caller < 0) {
        is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    BOOL app_bypass = (is_sys_caller == 0 && pt_is_bypass_enabled());
    int count = scandir(dirname, namelist, app_bypass ? NULL : select_fn, app_bypass ? NULL : compar_fn);
    if (!app_bypass) {
        return count;
    }
    return pt_finish_scandir_results(namelist, count, dirname, -1, select_fn, compar_fn, nil, nil, caller, is_sys_caller);
}

static int pt_scandir_b(const char *dirname,
                        struct dirent ***namelist,
                        int (^select_blk)(const struct dirent *),
                        int (^compar_blk)(const struct dirent **, const struct dirent **)) {
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(dirname, caller, vbuf, sizeof(vbuf), &dirname, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (is_sys_caller < 0) {
        is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    BOOL app_bypass = (is_sys_caller == 0 && pt_is_bypass_enabled());
    int count = scandir_b(dirname, namelist, app_bypass ? nil : select_blk, app_bypass ? nil : compar_blk);
    if (!app_bypass) {
        return count;
    }
    return pt_finish_scandir_results(namelist, count, dirname, -1, NULL, NULL, select_blk, compar_blk, caller, is_sys_caller);
}

static int pt_scandirat(int dirfd,
                        const char *dirname,
                        struct dirent ***namelist,
                        int (*select_fn)(const struct dirent *),
                        int (*compar_fn)(const struct dirent **, const struct dirent **)) {
    const void *caller = __builtin_return_address(0);
    if (pt_fd_is_sensitive(dirfd, caller)) {
        errno = EBADF;
        return -1;
    }
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_cached_caller(dirfd, dirname, caller, vbuf, sizeof(vbuf), &dirname, &is_sys_caller, NO);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (is_sys_caller < 0) {
        is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    BOOL app_bypass = (is_sys_caller == 0 && pt_is_bypass_enabled());
    int count = scandirat(dirfd, dirname, namelist, app_bypass ? NULL : select_fn, app_bypass ? NULL : compar_fn);
    if (!app_bypass) {
        return count;
    }
    return pt_finish_scandir_results(namelist, count, (dirname != NULL && dirname[0] == '/') ? dirname : NULL, dirfd,
                                     select_fn, compar_fn, nil, nil, caller, is_sys_caller);
}

static int pt_scandirat_b(int dirfd,
                          const char *dirname,
                          struct dirent ***namelist,
                          int (^select_blk)(const struct dirent *),
                          int (^compar_blk)(const struct dirent **, const struct dirent **)) {
    const void *caller = __builtin_return_address(0);
    if (pt_fd_is_sensitive(dirfd, caller)) {
        errno = EBADF;
        return -1;
    }
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_cached_caller(dirfd, dirname, caller, vbuf, sizeof(vbuf), &dirname, &is_sys_caller, NO);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (is_sys_caller < 0) {
        is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    BOOL app_bypass = (is_sys_caller == 0 && pt_is_bypass_enabled());
    int count = scandirat_b(dirfd, dirname, namelist, app_bypass ? nil : select_blk, app_bypass ? nil : compar_blk);
    if (!app_bypass) {
        return count;
    }
    return pt_finish_scandir_results(namelist, count, (dirname != NULL && dirname[0] == '/') ? dirname : NULL, dirfd,
                                     NULL, NULL, select_blk, compar_blk, caller, is_sys_caller);
}

static int pt_fdscandir(int dirfd,
                        struct dirent ***namelist,
                        int (*select_fn)(const struct dirent *),
                        int (*compar_fn)(const struct dirent **, const struct dirent **)) {
    const void *caller = __builtin_return_address(0);
    if (pt_fd_is_sensitive(dirfd, caller)) {
        errno = EBADF;
        return -1;
    }
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    BOOL app_bypass = (!is_sys && pt_is_bypass_enabled());
    int count = fdscandir(dirfd, namelist, app_bypass ? NULL : select_fn, app_bypass ? NULL : compar_fn);
    if (!app_bypass) {
        return count;
    }
    return pt_finish_scandir_results(namelist, count, NULL, dirfd, select_fn, compar_fn, nil, nil, caller, 0);
}

static int pt_fdscandir_b(int dirfd,
                          struct dirent ***namelist,
                          int (^select_blk)(const struct dirent *),
                          int (^compar_blk)(const struct dirent **, const struct dirent **)) {
    const void *caller = __builtin_return_address(0);
    if (pt_fd_is_sensitive(dirfd, caller)) {
        errno = EBADF;
        return -1;
    }
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    BOOL app_bypass = (!is_sys && pt_is_bypass_enabled());
    int count = fdscandir_b(dirfd, namelist, app_bypass ? nil : select_blk, app_bypass ? nil : compar_blk);
    if (!app_bypass) {
        return count;
    }
    return pt_finish_scandir_results(namelist, count, NULL, dirfd, NULL, NULL, select_blk, compar_blk, caller, 0);
}

static int pt_mkdir(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EEXIST;
        return -1;
    }
    return mkdir(path, mode);
}

__attribute__((visibility("hidden"))) BOOL pt_prepare_fs_path_for_modify(int dirfd,
                                                 const char *raw_path,
                                                 const void *caller,
                                                 char *vbuf,
                                                 size_t vbuf_size,
                                                 const char **out_path,
                                                 int ancestor_errno) {
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at(dirfd, raw_path, caller, vbuf, vbuf_size, out_path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NO;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = ancestor_errno;
        return NO;
    }
    return YES;
}

static int pt_mkdirat(int fd, const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EEXIST;
        return -1;
    }
    return mkdirat(fd, path, mode);
}

static int pt_mkpath_np(const char *path, mode_t omode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return 0;
    }
    return mkpath_np(path, omode);
}

static int pt_mkpathat_np(int dfd, const char *path, mode_t omode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at(dfd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return 0;
    }
    return mkpathat_np(dfd, path, omode);
}

static int pt_rmdir(const char *path) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return rmdir(path);
}

PT_INTERPOSE(pt_proc_pidfdinfo, proc_pidfdinfo)
PT_INTERPOSE(pt_proc_pidfileportinfo, proc_pidfileportinfo)
PT_INTERPOSE(pt_proc_pidinfo, proc_pidinfo)
PT_INTERPOSE(pt_proc_listpids, proc_listpids)
PT_INTERPOSE(pt_proc_listallpids, proc_listallpids)
PT_INTERPOSE(pt_proc_listpidspath, proc_listpidspath)
PT_INTERPOSE(pt_proc_name, proc_name)
PT_INTERPOSE(pt_proc_regionfilename, proc_regionfilename)
PT_INTERPOSE_WEAK_NAMED(pt_proc_pidpath_audittoken, pt_orig_proc_pidpath_audittoken, "proc_pidpath_audittoken")
PT_INTERPOSE(pt_opendir, opendir)
PT_INTERPOSE(pt_opendir2, __opendir2)
PT_INTERPOSE(pt_fdopendir, fdopendir)
PT_INTERPOSE(pt_readdir, readdir)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
PT_INTERPOSE(pt_readdir_r, readdir_r)
#pragma clang diagnostic pop
PT_INTERPOSE(pt_scandir, scandir)
PT_INTERPOSE(pt_scandir_b, scandir_b)
PT_INTERPOSE(pt_scandirat, scandirat)
PT_INTERPOSE(pt_scandirat_b, scandirat_b)
PT_INTERPOSE(pt_fdscandir, fdscandir)
PT_INTERPOSE(pt_fdscandir_b, fdscandir_b)
PT_INTERPOSE(pt_mkdir, mkdir)
PT_INTERPOSE(pt_mkdirat, mkdirat)
PT_INTERPOSE(pt_mkpath_np, mkpath_np)
PT_INTERPOSE(pt_mkpathat_np, mkpathat_np)
PT_INTERPOSE(pt_rmdir, rmdir)

PT_INTERPOSE_WEAK_NAMED(pt_getdirentries64, pt_orig_getdirentries64, "__getdirentries64")
PT_INTERPOSE_WEAK_NAMED(pt_proc_pidoriginatorinfo, pt_orig_proc_pidoriginatorinfo, "proc_pidoriginatorinfo")
PT_INTERPOSE_WEAK_NAMED(pt_proc_listchildpids, pt_orig_proc_listchildpids, "proc_listchildpids")
PT_INTERPOSE_WEAK_NAMED(pt_proc_listpgrppids, pt_orig_proc_listpgrppids, "proc_listpgrppids")
PT_INTERPOSE_WEAK_NAMED(pt_proc_pid_rusage, pt_orig_proc_pid_rusage, "proc_pid_rusage")
PT_INTERPOSE_NAMED(pt_getdirentries, pt_orig_getdirentries, "getdirentries")
