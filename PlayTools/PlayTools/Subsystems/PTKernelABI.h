//
//  PTKernelABI.h
//  PlayTools
//
//  Kernel proc_info and Unix socket ABI structures and layout assertions.
//

#ifndef PTKernelABI_h
#define PTKernelABI_h

#include <netinet/in.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/types.h>

#if __has_include(<libproc.h>)
#include <libproc.h>
#else
#ifndef PROC_ALL_PIDS
#define PROC_ALL_PIDS 1
#endif
#ifndef PROC_PIDLISTFDS
#define PROC_PIDLISTFDS 1
#endif
#ifndef PROC_PIDTASKALLINFO
#define PROC_PIDTASKALLINFO 2
#endif
#ifndef PROC_PIDFDVNODEPATHINFO
#define PROC_PIDFDVNODEPATHINFO 2
#endif
#ifndef PROC_PIDTBSDINFO
#define PROC_PIDTBSDINFO 3
#endif
#ifndef PROC_PIDREGIONPATHINFO
#define PROC_PIDREGIONPATHINFO 8
#endif
#ifndef PROC_PIDVNODEPATHINFO
#define PROC_PIDVNODEPATHINFO 9
#endif
#ifndef PROC_PIDPATHINFO
#define PROC_PIDPATHINFO 11
#endif
#ifndef PROC_PIDT_SHORTBSDINFO
#define PROC_PIDT_SHORTBSDINFO 13
#endif
#ifndef PROC_FLAG_TRACED
#define PROC_FLAG_TRACED 2
#endif
#ifndef PROX_FDTYPE_VNODE
#define PROX_FDTYPE_VNODE 1
#endif
#ifndef PROX_FDTYPE_SOCKET
#define PROX_FDTYPE_SOCKET 2
#endif
#ifndef PROC_PIDFDSOCKETINFO
#define PROC_PIDFDSOCKETINFO 3
#endif
#ifndef PROC_PIDTASKINFO
#define PROC_PIDTASKINFO 4
#endif
#ifndef SOCKINFO_UN
#define SOCKINFO_UN 3
#endif
#ifndef MAXCOMLEN
#define MAXCOMLEN 16
#endif

struct proc_fdinfo {
    int32_t  proc_fd;
    uint32_t proc_fdtype;
};

struct proc_fileinfo {
    uint32_t fi_openflags;
    uint32_t fi_status;
    off_t    fi_offset;
    int32_t  fi_type;
    uint32_t fi_guardflags;
};

struct vinfo_stat {
    uint32_t vst_dev;
    uint16_t vst_mode;
    uint16_t vst_nlink;
    uint64_t vst_ino;
    uid_t    vst_uid;
    gid_t    vst_gid;
    int64_t  vst_atime;
    int64_t  vst_atimensec;
    int64_t  vst_mtime;
    int64_t  vst_mtimensec;
    int64_t  vst_ctime;
    int64_t  vst_ctimensec;
    int64_t  vst_birthtime;
    int64_t  vst_birthtimensec;
    off_t    vst_size;
    int64_t  vst_blocks;
    int32_t  vst_blksize;
    uint32_t vst_flags;
    uint32_t vst_gen;
    uint32_t vst_rdev;
    int64_t  vst_qspare[2];
};

struct vnode_info {
    struct vinfo_stat vi_stat;
    int               vi_type;
    int               vi_pad;
    fsid_t            vi_fsid;
};

struct vnode_info_path {
    struct vnode_info vip_vi;
    char              vip_path[MAXPATHLEN];
};

struct vnode_fdinfowithpath {
    struct proc_fileinfo   pfi;
    struct vnode_info_path pvip;
};

struct proc_vnodepathinfo {
    struct vnode_info_path pvi_cdir;
    struct vnode_info_path pvi_rdir;
};

struct proc_bsdinfo {
    uint32_t pbi_flags;
    uint32_t pbi_status;
    uint32_t pbi_xstatus;
    uint32_t pbi_pid;
    uint32_t pbi_ppid;
    uid_t    pbi_uid;
    gid_t    pbi_gid;
    uid_t    pbi_ruid;
    gid_t    pbi_rgid;
    uid_t    pbi_svuid;
    gid_t    pbi_svgid;
    uint32_t rfu_1;
    char     pbi_comm[MAXCOMLEN];
    char     pbi_name[2 * MAXCOMLEN];
    uint32_t pbi_nfiles;
    uint32_t pbi_pgid;
    uint32_t pbi_pjobc;
    uint32_t e_tdev;
    uint32_t e_tpgid;
    int32_t  pbi_nice;
    uint64_t pbi_start_tvsec;
    uint64_t pbi_start_tvusec;
};

struct proc_bsdshortinfo {
    uint32_t pbsi_pid;
    uint32_t pbsi_ppid;
    uint32_t pbsi_pgid;
    uint32_t pbsi_status;
    char     pbsi_comm[MAXCOMLEN];
    uint32_t pbsi_flags;
    uid_t    pbsi_uid;
    gid_t    pbsi_gid;
    uid_t    pbsi_ruid;
    gid_t    pbsi_rgid;
    uid_t    pbsi_svuid;
    gid_t    pbsi_svgid;
    uint32_t pbsi_rfu;
};

struct proc_taskinfo {
    uint64_t pti_virtual_size;
    uint64_t pti_resident_size;
    uint64_t pti_total_user;
    uint64_t pti_total_system;
    uint64_t pti_threads_user;
    uint64_t pti_threads_system;
    int32_t  pti_policy;
    int32_t  pti_faults;
    int32_t  pti_pageins;
    int32_t  pti_cow_faults;
    int32_t  pti_messages_sent;
    int32_t  pti_messages_received;
    int32_t  pti_syscalls_mach;
    int32_t  pti_syscalls_unix;
    int32_t  pti_csw;
    int32_t  pti_threadnum;
    int32_t  pti_numrunning;
    int32_t  pti_priority;
};

struct proc_taskallinfo {
    struct proc_bsdinfo  pbsd;
    struct proc_taskinfo ptinfo;
};

struct proc_regioninfo {
    uint32_t pri_protection;
    uint32_t pri_max_protection;
    uint32_t pri_inheritance;
    uint32_t pri_flags;
    uint64_t pri_offset;
    uint32_t pri_behavior;
    uint32_t pri_user_wired_count;
    uint32_t pri_user_tag;
    uint32_t pri_pages_resident;
    uint32_t pri_pages_shared_now_private;
    uint32_t pri_pages_swapped_out;
    uint32_t pri_pages_dirtied;
    uint32_t pri_ref_count;
    uint32_t pri_shadow_depth;
    uint32_t pri_share_mode;
    uint32_t pri_private_pages_resident;
    uint32_t pri_shared_pages_resident;
    uint32_t pri_obj_id;
    uint32_t pri_depth;
    uint64_t pri_address;
    uint64_t pri_size;
};

struct proc_regionwithpathinfo {
    struct proc_regioninfo prp_prinfo;
    struct vnode_info_path prp_vip;
};

#ifndef PROC_PIDTHREADINFO
#define PROC_PIDTHREADINFO 5
#endif
#ifndef PROC_PIDTHREADPATHINFO
#define PROC_PIDTHREADPATHINFO 10
#endif
#ifndef PROC_PIDTHREADID64INFO
#define PROC_PIDTHREADID64INFO 15
#endif
#ifndef PROC_PIDUNIQIDENTIFIERINFO
#define PROC_PIDUNIQIDENTIFIERINFO 17
#endif
#ifndef PROC_PIDREGIONPATHINFO2
#define PROC_PIDREGIONPATHINFO2 22
#endif
#ifndef PROC_PIDREGIONPATHINFO3
#define PROC_PIDREGIONPATHINFO3 23
#endif
#ifndef MAXTHREADNAMESIZE
#define MAXTHREADNAMESIZE 64
#endif

struct proc_threadinfo {
    uint64_t pth_user_time;
    uint64_t pth_system_time;
    int32_t  pth_cpu_usage;
    int32_t  pth_policy;
    int32_t  pth_run_state;
    int32_t  pth_flags;
    int32_t  pth_sleep_time;
    int32_t  pth_curpri;
    int32_t  pth_priority;
    int32_t  pth_maxpriority;
    char     pth_name[MAXTHREADNAMESIZE];
};

struct proc_threadwithpathinfo {
    struct proc_threadinfo pt;
    struct vnode_info_path pvip;
};

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int proc_pidfdinfo(int pid, int fd, int flavor, void *buffer, int buffersize);
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int proc_regionfilename(int pid, uint64_t address, void *buffer, uint32_t buffersize);
#endif

#ifndef PROX_FDTYPE_SOCKET
#define PROX_FDTYPE_SOCKET 2
#endif
#ifndef PROC_PIDFDSOCKETINFO
#define PROC_PIDFDSOCKETINFO 3
#endif
#ifndef SOCKINFO_IN
#define SOCKINFO_IN 1
#endif
#ifndef SOCKINFO_TCP
#define SOCKINFO_TCP 2
#endif
#ifndef SOCKINFO_UN
#define SOCKINFO_UN 3
#endif
#ifndef INI_IPV4
#define INI_IPV4 0x1
#endif
#ifndef INI_IPV6
#define INI_IPV6 0x2
#endif

struct proc_uniqidentifierinfo {
    uint8_t  p_uuid[16];
    uint64_t p_uniqueid;
    uint64_t p_puniqueid;
    int32_t  p_idversion;
    uint32_t p_reserve2;
    uint64_t p_reserve3;
    uint64_t p_reserve4;
};

typedef struct {
    uint32_t sbi_cc;
    uint32_t sbi_hiwat;
    uint32_t sbi_mbcnt;
    uint32_t sbi_mbmax;
    uint32_t sbi_lowat;
    short    sbi_flags;
    short    sbi_timeo;
} pt_sockbuf_info_t;

typedef struct {
    uint32_t       i46a_pad32[3];
    struct in_addr i46a_addr4;
} pt_in4in6_addr_t;

typedef struct {
    int      insi_fport;
    int      insi_lport;
    uint64_t insi_gencnt;
    uint32_t insi_flags;
    uint32_t insi_flow;
    uint8_t  insi_vflag;
    uint8_t  insi_ip_ttl;
    uint32_t rfu_1;
    union {
        pt_in4in6_addr_t ina_46;
        struct in6_addr  ina_6;
    } insi_faddr;
    union {
        pt_in4in6_addr_t ina_46;
        struct in6_addr  ina_6;
    } insi_laddr;
    struct {
        unsigned char in4_tos;
    } insi_v4;
    struct {
        uint8_t  in6_hlim;
        int      in6_cksum;
        uint16_t in6_ifindex;
        int16_t  in6_hops;
    } insi_v6;
} pt_in_sockinfo_t;

typedef struct {
    pt_in_sockinfo_t tcpsi_ini;
    int              tcpsi_state;
    int              tcpsi_timer[4];
    int              tcpsi_mss;
    uint32_t         tcpsi_flags;
    uint32_t         rfu_1;
    uint64_t         tcpsi_tp;
} pt_tcp_sockinfo_t;

typedef struct {
    uint8_t  sun_len;
    uint8_t  sun_family;
    char     sun_path[104];
} pt_sockaddr_un_t;

typedef struct {
    uint64_t unsi_conn_so;
    uint64_t unsi_conn_pcb;
    union {
        pt_sockaddr_un_t ua_sun;
        char             ua_dummy[255];
    } unsi_addr;
    union {
        pt_sockaddr_un_t ua_sun;
        char             ua_dummy[255];
    } unsi_caddr;
} pt_un_sockinfo_t;

typedef struct {
    struct vinfo_stat soi_stat;
    uint64_t          soi_so;
    uint64_t          soi_pcb;
    int               soi_type;
    int               soi_protocol;
    int               soi_family;
    short             soi_options;
    short             soi_linger;
    short             soi_state;
    short             soi_qlen;
    short             soi_incqlen;
    short             soi_qlimit;
    short             soi_timeo;
    uint16_t          soi_error;
    uint32_t          soi_oobmark;
    pt_sockbuf_info_t soi_rcv;
    pt_sockbuf_info_t soi_snd;
    int               soi_kind;
    uint32_t          rfu_1;
    union {
        pt_in_sockinfo_t  pri_in;
        pt_tcp_sockinfo_t pri_tcp;
        pt_un_sockinfo_t  pri_un;
        uint8_t           pri_raw[528];
    } soi_proto;
} pt_socket_info_t;

typedef struct {
    struct proc_fileinfo pfi;
    pt_socket_info_t     psi;
} pt_socket_fdinfo_t;

_Static_assert(sizeof(pt_in_sockinfo_t) == 80, "pt_in_sockinfo_t size mismatch");
_Static_assert(offsetof(pt_in_sockinfo_t, insi_vflag) == 24, "pt_in_sockinfo_t insi_vflag offset mismatch");
_Static_assert(offsetof(pt_in_sockinfo_t, insi_faddr) == 32, "pt_in_sockinfo_t insi_faddr offset mismatch");
_Static_assert(offsetof(pt_in_sockinfo_t, insi_laddr) == 48, "pt_in_sockinfo_t insi_laddr offset mismatch");
_Static_assert(sizeof(pt_tcp_sockinfo_t) == 120, "pt_tcp_sockinfo_t size mismatch");
_Static_assert(sizeof(pt_sockbuf_info_t) == 24, "pt_sockbuf_info_t size mismatch");
_Static_assert(sizeof(pt_un_sockinfo_t) == 528, "pt_un_sockinfo_t size mismatch");
_Static_assert(sizeof(pt_socket_info_t) == 768, "pt_socket_info_t size mismatch");
_Static_assert(sizeof(pt_socket_fdinfo_t) == 792, "pt_socket_fdinfo_t size mismatch");

#ifndef PROC_PIDTHREADINFO
#define PROC_PIDTHREADINFO 5
#endif
#ifndef PROC_PIDLISTTHREADS
#define PROC_PIDLISTTHREADS 6
#endif
#ifndef PROC_PIDTHREADPATHINFO
#define PROC_PIDTHREADPATHINFO 10
#endif
#ifndef PROC_PIDTHREADID64INFO
#define PROC_PIDTHREADID64INFO 15
#endif
#ifndef PROC_PIDUNIQIDENTIFIERINFO
#define PROC_PIDUNIQIDENTIFIERINFO 17
#endif
#ifndef PROC_PIDREGIONPATHINFO2
#define PROC_PIDREGIONPATHINFO2 22
#endif
#ifndef PROC_PIDREGIONPATHINFO3
#define PROC_PIDREGIONPATHINFO3 23
#endif

_Static_assert(sizeof(struct proc_fdinfo) == 8, "proc_fdinfo ABI size mismatch");
_Static_assert(sizeof(struct vnode_fdinfowithpath) == 1200, "vnode_fdinfowithpath ABI size mismatch");
_Static_assert(offsetof(struct vnode_fdinfowithpath, pvip.vip_path) == 176, "vnode_fdinfowithpath vip_path offset mismatch");
_Static_assert(sizeof(struct proc_vnodepathinfo) == 2352, "proc_vnodepathinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_vnodepathinfo, pvi_cdir.vip_path) == 152, "proc_vnodepathinfo pvi_cdir offset mismatch");
_Static_assert(offsetof(struct proc_vnodepathinfo, pvi_rdir.vip_path) == 1328, "proc_vnodepathinfo pvi_rdir offset mismatch");
_Static_assert(sizeof(struct proc_bsdinfo) == 136, "proc_bsdinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_bsdinfo, pbi_flags) == 0, "proc_bsdinfo pbi_flags offset mismatch");
_Static_assert(offsetof(struct proc_bsdinfo, pbi_pid) == 12, "proc_bsdinfo pbi_pid offset mismatch");
_Static_assert(offsetof(struct proc_bsdinfo, pbi_ppid) == 16, "proc_bsdinfo pbi_ppid offset mismatch");
_Static_assert(sizeof(struct proc_bsdshortinfo) == 64, "proc_bsdshortinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_bsdshortinfo, pbsi_pid) == 0, "proc_bsdshortinfo pbsi_pid offset mismatch");
_Static_assert(offsetof(struct proc_bsdshortinfo, pbsi_ppid) == 4, "proc_bsdshortinfo pbsi_ppid offset mismatch");
_Static_assert(offsetof(struct proc_bsdshortinfo, pbsi_flags) == 32, "proc_bsdshortinfo pbsi_flags offset mismatch");
_Static_assert(sizeof(struct proc_taskinfo) == 96, "proc_taskinfo ABI size mismatch");
_Static_assert(sizeof(struct proc_taskallinfo) == 232, "proc_taskallinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_taskallinfo, pbsd) == 0, "proc_taskallinfo pbsd offset mismatch");
_Static_assert(sizeof(struct proc_regioninfo) == 96, "proc_regioninfo ABI size mismatch");
_Static_assert(sizeof(struct proc_regionwithpathinfo) == 1272, "proc_regionwithpathinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_regionwithpathinfo, prp_vip.vip_path) == 248, "proc_regionwithpathinfo vip_path offset mismatch");
_Static_assert(sizeof(struct proc_threadinfo) == 112, "proc_threadinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_threadinfo, pth_name) == 48, "proc_threadinfo pth_name offset mismatch");
_Static_assert(sizeof(struct proc_threadwithpathinfo) == 1288, "proc_threadwithpathinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_threadwithpathinfo, pvip.vip_path) == 264, "proc_threadwithpathinfo vip_path offset mismatch");
_Static_assert(sizeof(struct proc_uniqidentifierinfo) == 56, "proc_uniqidentifierinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_uniqidentifierinfo, p_puniqueid) == 24, "proc_uniqidentifierinfo p_puniqueid offset mismatch");

#endif /* PTKernelABI_h */
