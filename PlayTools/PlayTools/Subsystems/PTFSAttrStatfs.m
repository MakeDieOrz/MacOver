//
//  PTFSAttrStatfs.m
//  PlayTools
//

#import "PTFSInternal.h"
#import "PTSystemSpooferInternal.h"

typedef struct {
    uint32_t bit;
    size_t sz;
} pt_attr_bit_size_t;

static void pt_attr_walk_group(uint32_t mask,
                               const pt_attr_bit_size_t *table,
                               size_t table_len,
                               uint64_t options,
                               BOOL is_common,
                               size_t *inout_off,
                               uint32_t target_bit,
                               BOOL is_target_group,
                               size_t rec_len,
                               size_t *out_found_off,
                               BOOL *out_found) {
    for (size_t i = 0; i < table_len; i++) {
        uint32_t bit = table[i].bit;
        if (is_target_group && bit == target_bit) {
            if ((mask & bit) != 0 && *inout_off + table[i].sz <= rec_len) {
                *out_found_off = *inout_off;
                *out_found = YES;
            }
            return;
        }
        if ((mask & bit) != 0) {
            size_t sz = table[i].sz;
            if (is_common && bit == 0x00100000U && (options & FSOPT_ATTR_CMN_EXTENDED) == 0) {
                sz = sizeof(attrreference_t);
            }
            *inout_off += sz;
        }
    }
}

typedef enum {
    PT_ATTR_GROUP_COMMON = 0,
    PT_ATTR_GROUP_VOL = 1,
    PT_ATTR_GROUP_DIR = 2,
    PT_ATTR_GROUP_FILE = 3,
    PT_ATTR_GROUP_FORK = 4,
} pt_attr_group_t;

static size_t pt_attr_offset_in_record(const struct attrlist *req,
                                        const char *rec_ptr,
                                        uint32_t rec_len,
                                        uint64_t options,
                                        pt_attr_group_t target_group,
                                        uint32_t target_bit,
                                        BOOL *out_present) {
    *out_present = NO;
    if (req == NULL || rec_ptr == NULL || rec_len < sizeof(uint32_t)) {
        return 0;
    }
    size_t off = sizeof(uint32_t);
    uint32_t cmn_mask = req->commonattr;
    uint32_t vol_mask = req->volattr;
    uint32_t dir_mask = req->dirattr;
    uint32_t file_mask = req->fileattr;
    uint32_t fork_mask = req->forkattr;
    if ((req->commonattr & ATTR_CMN_RETURNED_ATTRS) != 0) {
        if (off + sizeof(attribute_set_t) > rec_len) {
            return 0;
        }
        const attribute_set_t *ret_attrs = (const attribute_set_t *)(rec_ptr + off);
        cmn_mask = ret_attrs->commonattr;
        vol_mask = ret_attrs->volattr;
        dir_mask = ret_attrs->dirattr;
        file_mask = ret_attrs->fileattr;
        fork_mask = ret_attrs->forkattr;
        off += sizeof(attribute_set_t);
    }
    cmn_mask &= ~(uint32_t)ATTR_CMN_RETURNED_ATTRS;
    vol_mask &= ~(uint32_t)ATTR_VOL_INFO;

    uint32_t target_mask = 0;
    switch (target_group) {
        case PT_ATTR_GROUP_COMMON: target_mask = cmn_mask; break;
        case PT_ATTR_GROUP_VOL:    target_mask = vol_mask; break;
        case PT_ATTR_GROUP_DIR:    target_mask = dir_mask; break;
        case PT_ATTR_GROUP_FILE:   target_mask = file_mask; break;
        case PT_ATTR_GROUP_FORK:   target_mask = fork_mask; break;
    }
    if ((target_mask & target_bit) == 0) {
        return 0;
    }

    static const pt_attr_bit_size_t kCmnLayout[] = {
        { ATTR_CMN_ERROR,              sizeof(uint32_t) },
        { ATTR_CMN_NAME,               sizeof(attrreference_t) },
        { ATTR_CMN_DEVID,              sizeof(dev_t) },
        { ATTR_CMN_FSID,               sizeof(fsid_t) },
        { ATTR_CMN_OBJTYPE,            sizeof(fsobj_type_t) },
        { ATTR_CMN_OBJTAG,             sizeof(fsobj_tag_t) },
        { ATTR_CMN_OBJID,              sizeof(fsobj_id_t) },
        { ATTR_CMN_OBJPERMANENTID,     sizeof(fsobj_id_t) },
        { ATTR_CMN_PAROBJID,           sizeof(fsobj_id_t) },
        { ATTR_CMN_SCRIPT,             sizeof(text_encoding_t) },
        { ATTR_CMN_CRTIME,             sizeof(struct timespec) },
        { ATTR_CMN_MODTIME,            sizeof(struct timespec) },
        { ATTR_CMN_CHGTIME,            sizeof(struct timespec) },
        { ATTR_CMN_ACCTIME,            sizeof(struct timespec) },
        { ATTR_CMN_BKUPTIME,           sizeof(struct timespec) },
        { ATTR_CMN_FNDRINFO,           32 },
        { ATTR_CMN_OWNERID,            sizeof(uid_t) },
        { ATTR_CMN_GRPID,              sizeof(gid_t) },
        { ATTR_CMN_ACCESSMASK,         sizeof(uint32_t) },
        { ATTR_CMN_FLAGS,              sizeof(uint32_t) },
        { ATTR_CMN_GEN_COUNT,          sizeof(uint32_t) },
        { ATTR_CMN_DOCUMENT_ID,        sizeof(uint32_t) },
        { ATTR_CMN_USERACCESS,         sizeof(uint32_t) },
        { ATTR_CMN_EXTENDED_SECURITY,  sizeof(attrreference_t) },
        { ATTR_CMN_UUID,               sizeof(guid_t) },
        { ATTR_CMN_GRPUUID,            sizeof(guid_t) },
        { ATTR_CMN_FILEID,             sizeof(uint64_t) },
        { ATTR_CMN_PARENTID,           sizeof(uint64_t) },
        { ATTR_CMN_FULLPATH,           sizeof(attrreference_t) },
        { ATTR_CMN_ADDEDTIME,          sizeof(struct timespec) },
        { ATTR_CMN_DATA_PROTECT_FLAGS, sizeof(uint32_t) },
    };
    static const pt_attr_bit_size_t kVolLayout[] = {
        { ATTR_VOL_FSTYPE,           sizeof(uint32_t) },
        { ATTR_VOL_SIGNATURE,        sizeof(uint32_t) },
        { ATTR_VOL_SIZE,             sizeof(off_t) },
        { ATTR_VOL_SPACEFREE,        sizeof(off_t) },
        { ATTR_VOL_SPACEAVAIL,       sizeof(off_t) },
        { ATTR_VOL_MINALLOCATION,    sizeof(off_t) },
        { ATTR_VOL_ALLOCATIONCLUMP,  sizeof(off_t) },
        { ATTR_VOL_IOBLOCKSIZE,      sizeof(uint32_t) },
        { ATTR_VOL_OBJCOUNT,         sizeof(uint32_t) },
        { ATTR_VOL_FILECOUNT,        sizeof(uint32_t) },
        { ATTR_VOL_DIRCOUNT,         sizeof(uint32_t) },
        { ATTR_VOL_MAXOBJCOUNT,      sizeof(uint32_t) },
        { ATTR_VOL_MOUNTPOINT,       sizeof(attrreference_t) },
        { ATTR_VOL_NAME,             sizeof(attrreference_t) },
        { ATTR_VOL_MOUNTFLAGS,       sizeof(uint32_t) },
        { ATTR_VOL_MOUNTEDDEVICE,    sizeof(attrreference_t) },
        { ATTR_VOL_ENCODINGSUSED,    sizeof(uint64_t) },
        { ATTR_VOL_CAPABILITIES,     sizeof(vol_capabilities_attr_t) },
        { ATTR_VOL_UUID,             sizeof(uuid_t) },
        { ATTR_VOL_MOUNTEXTFLAGS,    sizeof(uint32_t) },
        { ATTR_VOL_FSTYPENAME,       sizeof(attrreference_t) },
        { ATTR_VOL_FSSUBTYPE,        sizeof(uint32_t) },
        { ATTR_VOL_OWNER,            sizeof(uid_t) },
        { ATTR_VOL_SPACEUSED,        sizeof(off_t) },
        { ATTR_VOL_QUOTA_SIZE,       sizeof(off_t) },
        { ATTR_VOL_RESERVED_SIZE,    sizeof(off_t) },
        { ATTR_VOL_ATTRIBUTES,       sizeof(vol_attributes_attr_t) },
    };
    static const pt_attr_bit_size_t kDirLayout[] = {
        { ATTR_DIR_LINKCOUNT,   sizeof(uint32_t) },
        { ATTR_DIR_ENTRYCOUNT,  sizeof(uint32_t) },
        { ATTR_DIR_MOUNTSTATUS, sizeof(uint32_t) },
        { ATTR_DIR_ALLOCSIZE,   sizeof(off_t) },
        { ATTR_DIR_IOBLOCKSIZE, sizeof(uint32_t) },
        { ATTR_DIR_DATALENGTH,  sizeof(off_t) },
    };
    static const pt_attr_bit_size_t kFileLayout[] = {
        { ATTR_FILE_LINKCOUNT,     sizeof(uint32_t) },
        { ATTR_FILE_TOTALSIZE,     sizeof(off_t) },
        { ATTR_FILE_ALLOCSIZE,     sizeof(off_t) },
        { ATTR_FILE_IOBLOCKSIZE,   sizeof(uint32_t) },
        { ATTR_FILE_CLUMPSIZE,     sizeof(uint32_t) },
        { ATTR_FILE_DEVTYPE,       sizeof(uint32_t) },
        { ATTR_FILE_FILETYPE,      sizeof(uint32_t) },
        { ATTR_FILE_FORKCOUNT,     sizeof(uint32_t) },
        { ATTR_FILE_FORKLIST,      sizeof(attrreference_t) },
        { ATTR_FILE_DATALENGTH,    sizeof(off_t) },
        { ATTR_FILE_DATAALLOCSIZE, sizeof(off_t) },
        { ATTR_FILE_DATAEXTENTS,   sizeof(extentrecord) },
        { ATTR_FILE_RSRCLENGTH,    sizeof(off_t) },
        { ATTR_FILE_RSRCALLOCSIZE, sizeof(off_t) },
        { ATTR_FILE_RSRCEXTENTS,   sizeof(extentrecord) },
    };
    static const pt_attr_bit_size_t kForkLayout[] = {
        { ATTR_CMNEXT_RELPATH,        sizeof(attrreference_t) },
        { ATTR_CMNEXT_PRIVATESIZE,    sizeof(off_t) },
        { ATTR_CMNEXT_LINKID,         sizeof(uint64_t) },
        { ATTR_CMNEXT_NOFIRMLINKPATH, sizeof(attrreference_t) },
    };

    size_t found_off = 0;
    BOOL found = NO;
    pt_attr_walk_group(cmn_mask, kCmnLayout, sizeof(kCmnLayout) / sizeof(kCmnLayout[0]),
                       options, YES, &off, target_bit, target_group == PT_ATTR_GROUP_COMMON,
                       rec_len, &found_off, &found);
    if (target_group == PT_ATTR_GROUP_COMMON) {
        *out_present = found;
        return found_off;
    }
    if (vol_mask != 0) {
        pt_attr_walk_group(vol_mask, kVolLayout, sizeof(kVolLayout) / sizeof(kVolLayout[0]),
                           options, NO, &off, target_bit, target_group == PT_ATTR_GROUP_VOL,
                           rec_len, &found_off, &found);
    }
    if (target_group == PT_ATTR_GROUP_VOL) {
        *out_present = found;
        return found_off;
    }
    pt_attr_walk_group(dir_mask, kDirLayout, sizeof(kDirLayout) / sizeof(kDirLayout[0]),
                       options, NO, &off, target_bit, target_group == PT_ATTR_GROUP_DIR,
                       rec_len, &found_off, &found);
    if (target_group == PT_ATTR_GROUP_DIR) {
        *out_present = found;
        return found_off;
    }
    pt_attr_walk_group(file_mask, kFileLayout, sizeof(kFileLayout) / sizeof(kFileLayout[0]),
                       options, NO, &off, target_bit, target_group == PT_ATTR_GROUP_FILE,
                       rec_len, &found_off, &found);
    if (target_group == PT_ATTR_GROUP_FILE) {
        *out_present = found;
        return found_off;
    }
    pt_attr_walk_group(fork_mask, kForkLayout, sizeof(kForkLayout) / sizeof(kForkLayout[0]),
                       options, NO, &off, target_bit, target_group == PT_ATTR_GROUP_FORK,
                       rec_len, &found_off, &found);
    *out_present = found;
    return found_off;
}

static size_t pt_attr_cmn_offset_in_record(const struct attrlist *req,
                                            const char *rec_ptr,
                                            uint32_t rec_len,
                                            uint64_t options,
                                            uint32_t target_bit,
                                            BOOL *out_present) {
    return pt_attr_offset_in_record(req, rec_ptr, rec_len, options,
                                    PT_ATTR_GROUP_COMMON, target_bit, out_present);
}

static const char *pt_host_root_mntfromname(void) {
    static char s_root_dev[MFSTYPENAMELEN + MAXPATHLEN];
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        struct statfs st;
        if (statfs("/", &st) == 0) {
            strlcpy(s_root_dev, st.f_mntfromname, sizeof(s_root_dev));
        }
    });
    return s_root_dev;
}

static const char *pt_host_root_vol_name(void) {
    static char s_root_vol[NAME_MAX + 1];
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        struct attrlist al;
        memset(&al, 0, sizeof(al));
        al.bitmapcount = ATTR_BIT_MAP_COUNT;
        al.volattr = ATTR_VOL_INFO | ATTR_VOL_NAME;
        struct {
            uint32_t length;
            attrreference_t name_ref;
            char name_buf[NAME_MAX + 1];
        } __attribute__((packed)) vbuf;
        memset(&vbuf, 0, sizeof(vbuf));
        if (getattrlist("/", &al, &vbuf, sizeof(vbuf), 0) == 0 &&
            vbuf.name_ref.attr_dataoffset > 0 &&
            vbuf.name_ref.attr_length > 0) {
            uintptr_t start = (uintptr_t)&vbuf.name_ref + (uintptr_t)vbuf.name_ref.attr_dataoffset;
            uintptr_t end = (uintptr_t)&vbuf + sizeof(vbuf);
            if (start >= (uintptr_t)&vbuf && start < end) {
                size_t avail = (size_t)(end - start);
                size_t n = (vbuf.name_ref.attr_length < avail) ? (size_t)vbuf.name_ref.attr_length : avail;
                if (n >= sizeof(s_root_vol)) {
                    n = sizeof(s_root_vol) - 1U;
                }
                memcpy(s_root_vol, (const void *)start, n);
                s_root_vol[n] = '\0';
            }
        }
    });
    return s_root_vol;
}

static BOOL pt_dev_matches_root_volume(const char *dev, const char *root_dev) {
    if (dev == NULL || dev[0] == '\0' || root_dev == NULL || root_dev[0] == '\0') {
        return NO;
    }
    if (strcmp(dev, root_dev) == 0) {
        return YES;
    }
    const char *at = strchr(root_dev, '@');
    if (at != NULL) {
        size_t base_len = (size_t)(at - root_dev);
        if (base_len > 0 && strncmp(dev, root_dev, base_len) == 0 &&
            (dev[base_len] == '\0' || dev[base_len] == '@')) {
            return YES;
        }
    }
    return NO;
}

static void pt_write_attr_ref_replacement(char *rec_ptr,
                                          size_t max_rec_cap,
                                          attrreference_t *ref,
                                          uintptr_t str_start,
                                          size_t avail_str,
                                          BOOL can_grow_record,
                                          const char *replacement,
                                          BOOL is_mountpoint) {
    if (replacement == NULL) {
        return;
    }
    uint32_t rec_len = *(uint32_t *)rec_ptr;
    size_t old_len = (size_t)ref->attr_length;
    if (old_len > avail_str) {
        old_len = avail_str;
    }
    size_t vlen = strlen(replacement) + 1U;
    if (vlen <= (size_t)ref->attr_length && vlen <= avail_str) {
        memcpy((void *)str_start, replacement, vlen);
        if (old_len > vlen) {
            memset((uint8_t *)str_start + vlen, 0, old_len - vlen);
        }
        ref->attr_length = (uint32_t)vlen;
        return;
    }
    if (can_grow_record) {
        size_t padded = (vlen + 3U) & ~3U;
        if ((size_t)rec_len + padded <= max_rec_cap) {
            if (old_len > 0) {
                memset((void *)str_start, 0, old_len);
            }
            char *dst = rec_ptr + rec_len;
            memset(dst, 0, padded);
            memcpy(dst, replacement, vlen);
            ref->attr_dataoffset = (int32_t)(dst - (char *)ref);
            ref->attr_length = (uint32_t)vlen;
            *(uint32_t *)rec_ptr = rec_len + (uint32_t)padded;
            return;
        }
    }
    if (!is_mountpoint && strncmp(replacement, "/private/var/", 13) == 0) {
        const char *short_virt = replacement + 8;
        size_t slen = strlen(short_virt) + 1U;
        if (slen <= (size_t)ref->attr_length && slen <= avail_str) {
            memcpy((void *)str_start, short_virt, slen);
            if (old_len > slen) {
                memset((uint8_t *)str_start + slen, 0, old_len - slen);
            }
            ref->attr_length = (uint32_t)slen;
            return;
        }
    }
    if (is_mountpoint && avail_str >= 2 && ref->attr_length >= 2) {
        memcpy((void *)str_start, "/", 2);
        if (old_len > 2) {
            memset((uint8_t *)str_start + 2, 0, old_len - 2);
        }
        ref->attr_length = 2;
        return;
    }
    if (strncmp(replacement, "/dev/disk0s1", 12) == 0) {
        static const char kShortDev[] = "/dev/disk0s1";
        size_t dlen = sizeof(kShortDev);
        if (dlen <= (size_t)ref->attr_length && dlen <= avail_str) {
            memcpy((void *)str_start, kShortDev, dlen);
            if (old_len > dlen) {
                memset((uint8_t *)str_start + dlen, 0, old_len - dlen);
            }
            ref->attr_length = (uint32_t)dlen;
            return;
        }
    }
    if (avail_str > 0) {
        if (old_len > 0) {
            memset((void *)str_start, 0, old_len);
        } else {
            *(char *)str_start = '\0';
        }
        ref->attr_length = 1;
    }
}

static void pt_sanitize_attr_path_ref(const struct attrlist *alist,
                                      char *rec_ptr,
                                      size_t max_rec_cap,
                                      uint64_t options,
                                      BOOL can_grow_record,
                                      pt_attr_group_t group,
                                      uint32_t bit,
                                      BOOL is_mountpoint,
                                      const char *override_path,
                                      const void *caller) {
    uint32_t rec_len = *(uint32_t *)rec_ptr;
    if (rec_len < sizeof(uint32_t) || (size_t)rec_len > max_rec_cap) {
        return;
    }
    BOOL has_attr = NO;
    size_t attr_off = pt_attr_offset_in_record(alist, rec_ptr, rec_len, options, group, bit, &has_attr);
    if (!has_attr || attr_off + sizeof(attrreference_t) > rec_len) {
        return;
    }
    attrreference_t *ref = (attrreference_t *)(rec_ptr + attr_off);
    if (ref->attr_dataoffset <= 0 || ref->attr_length == 0) {
        return;
    }
    uintptr_t str_start = (uintptr_t)ref + (uintptr_t)ref->attr_dataoffset;
    uintptr_t rec_end = (uintptr_t)rec_ptr + (uintptr_t)rec_len;
    if (str_start < (uintptr_t)rec_ptr || str_start >= rec_end) {
        return;
    }
    size_t avail_str = (size_t)(rec_end - str_start);
    if (override_path != NULL) {
        pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                      can_grow_record, override_path, is_mountpoint);
        return;
    }
    char orig_copy[PATH_MAX];
    size_t copy_n = (ref->attr_length < avail_str) ? (size_t)ref->attr_length : avail_str;
    if (copy_n >= sizeof(orig_copy)) {
        copy_n = sizeof(orig_copy) - 1;
    }
    memcpy(orig_copy, (const void *)str_start, copy_n);
    orig_copy[copy_n] = '\0';

    if (group == PT_ATTR_GROUP_VOL && bit == ATTR_VOL_NAME) {
        const char *root_vol = pt_host_root_vol_name();
        BOOL is_root_vol = (strcmp(orig_copy, "System") == 0 ||
                            (root_vol[0] != '\0' && strcmp(orig_copy, root_vol) == 0));
        if (!is_root_vol && (alist->volattr & ATTR_VOL_MOUNTPOINT) != 0) {
            BOOL has_mp = NO;
            size_t mp_off = pt_attr_offset_in_record(alist, rec_ptr, rec_len, options,
                                                     PT_ATTR_GROUP_VOL, ATTR_VOL_MOUNTPOINT, &has_mp);
            if (has_mp && mp_off + sizeof(attrreference_t) <= rec_len) {
                const attrreference_t *mpref = (const attrreference_t *)(rec_ptr + mp_off);
                uintptr_t mp_start = (uintptr_t)mpref + (uintptr_t)mpref->attr_dataoffset;
                if (mpref->attr_dataoffset > 0 && mp_start >= (uintptr_t)rec_ptr && mp_start + 2U <= rec_end) {
                    const char *mp_s = (const char *)mp_start;
                    if (mp_s[0] == '/' && mp_s[1] == '\0') {
                        is_root_vol = YES;
                    }
                }
            }
        }
        const char *vol_name = is_root_vol ? "System" : "Data";
        if (strcmp(orig_copy, vol_name) != 0) {
            pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                          can_grow_record, vol_name, NO);
        }
        return;
    }

    if (group == PT_ATTR_GROUP_VOL && bit == ATTR_VOL_MOUNTEDDEVICE) {
        const char *root_dev = pt_host_root_mntfromname();
        const char *dev_name = pt_dev_matches_root_volume(orig_copy, root_dev)
            ? "/dev/disk0s1s1"
            : "/dev/disk0s1s2";
        if (strcmp(orig_copy, dev_name) != 0) {
            pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                          can_grow_record, dev_name, NO);
        }
        return;
    }

    if (is_mountpoint) {
        if (strcmp(orig_copy, "/System/Volumes/Data") == 0 ||
            strncmp(orig_copy, "/Volumes/", 9) == 0 ||
            strncmp(orig_copy, "/Users/", 7) == 0) {
            pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                          can_grow_record, "/private/var", YES);
        } else if (strncmp(orig_copy, "/System/Volumes/Data/", 21) == 0) {
            pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                          can_grow_record, orig_copy + 20, YES);
        }
        return;
    }

    if (group == PT_ATTR_GROUP_COMMON && bit == ATTR_CMN_NAME) {
        const char *user_root = pt_get_host_user_root_cstr();
        const char *host_user = (user_root != NULL && strncmp(user_root, "/Users/", 7) == 0) ? (user_root + 7) : NULL;
        if (pt_is_hidden_dirent_name(orig_copy) ||
            (host_user != NULL && host_user[0] != '\0' && strcmp(orig_copy, host_user) == 0)) {
            pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                          can_grow_record, "mobile", NO);
        }
        return;
    }

    if (group == PT_ATTR_GROUP_FORK && bit == ATTR_CMNEXT_RELPATH) {
        char with_slash[PATH_MAX];
        const char *probe = orig_copy;
        if (orig_copy[0] != '/') {
            snprintf(with_slash, sizeof(with_slash), "/%s", orig_copy);
            probe = with_slash;
        }
        if (pt_is_sensitive_host_fd_path(probe, caller)) {
            if (avail_str > 0) {
                size_t old_len = (size_t)ref->attr_length;
                if (old_len > avail_str) old_len = avail_str;
                if (old_len > 0) {
                    memset((void *)str_start, 0, old_len);
                } else {
                    *(char *)str_start = '\0';
                }
                ref->attr_length = 1;
            }
            return;
        }
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(probe, vout, sizeof(vout), YES);
        if (virt != probe) {
            const char *rel_virt = (virt[0] == '/') ? (virt + 1) : virt;
            pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                          can_grow_record, rel_virt, NO);
        }
        return;
    }

    if (pt_is_sensitive_host_fd_path(orig_copy, caller)) {
        if (avail_str > 0) {
            size_t old_len = (size_t)ref->attr_length;
            if (old_len > avail_str) {
                old_len = avail_str;
            }
            if (old_len > 0) {
                memset((void *)str_start, 0, old_len);
            } else {
                *(char *)str_start = '\0';
            }
            ref->attr_length = 1;
        }
        return;
    }
    char vout[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(orig_copy, vout, sizeof(vout), YES);
    if (virt != orig_copy) {
        pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                      can_grow_record, virt, NO);
    }
}

static void pt_sanitize_attr_scalars_in_record(const struct attrlist *alist,
                                               char *rec_ptr,
                                               size_t max_rec_cap,
                                               uint64_t options,
                                               int fd_for_dp,
                                               const char *path_for_dp,
                                               BOOL is_synth_sysver) {
    if (alist == NULL || rec_ptr == NULL || max_rec_cap < sizeof(uint32_t) || !pt_is_bypass_enabled()) {
        return;
    }
    uint32_t rec_len = *(uint32_t *)rec_ptr;
    if (rec_len < sizeof(uint32_t) || (size_t)rec_len > max_rec_cap) {
        return;
    }
    if ((alist->commonattr & ATTR_CMN_OWNERID) != 0 && is_synth_sysver) {
        BOOL present = NO;
        size_t off = pt_attr_offset_in_record(alist, rec_ptr, rec_len, options,
                                              PT_ATTR_GROUP_COMMON, ATTR_CMN_OWNERID, &present);
        if (present && off + sizeof(uid_t) <= rec_len) {
            uid_t u = 0;
            memcpy(rec_ptr + off, &u, sizeof(u));
        }
    }
    if ((alist->commonattr & ATTR_CMN_GRPID) != 0) {
        BOOL present = NO;
        size_t off = pt_attr_offset_in_record(alist, rec_ptr, rec_len, options,
                                              PT_ATTR_GROUP_COMMON, ATTR_CMN_GRPID, &present);
        if (present && off + sizeof(gid_t) <= rec_len) {
            gid_t g = 0;
            memcpy(&g, rec_ptr + off, sizeof(g));
            if (is_synth_sysver) {
                g = 0;
                memcpy(rec_ptr + off, &g, sizeof(g));
            } else if (g == 20) {
                g = 501;
                memcpy(rec_ptr + off, &g, sizeof(g));
            }
        }
    }
    if ((alist->commonattr & ATTR_CMN_FLAGS) != 0) {
        BOOL present = NO;
        size_t off = pt_attr_offset_in_record(alist, rec_ptr, rec_len, options,
                                              PT_ATTR_GROUP_COMMON, ATTR_CMN_FLAGS, &present);
        if (present && off + sizeof(uint32_t) <= rec_len) {
            uint32_t fl = 0;
            memcpy(&fl, rec_ptr + off, sizeof(fl));
#ifdef SF_RESTRICTED
            fl &= ~(uint32_t)SF_RESTRICTED;
#endif
#ifdef SF_FIRMLINK
            fl &= ~(uint32_t)SF_FIRMLINK;
#endif
            memcpy(rec_ptr + off, &fl, sizeof(fl));
        }
    }
    if ((alist->commonattr & ATTR_CMN_FNDRINFO) != 0) {
        BOOL present = NO;
        size_t off = pt_attr_offset_in_record(alist, rec_ptr, rec_len, options,
                                              PT_ATTR_GROUP_COMMON, ATTR_CMN_FNDRINFO, &present);
        if (present && off + 32U <= rec_len) {
            memset(rec_ptr + off, 0, 32U);
        }
    }
    if ((alist->commonattr & ATTR_CMN_DATA_PROTECT_FLAGS) != 0) {
        BOOL present = NO;
        size_t off = pt_attr_offset_in_record(alist, rec_ptr, rec_len, options,
                                              PT_ATTR_GROUP_COMMON, ATTR_CMN_DATA_PROTECT_FLAGS, &present);
        if (present && off + sizeof(uint32_t) <= rec_len) {
            uint32_t dp = 0;
            memcpy(&dp, rec_ptr + off, sizeof(dp));
            if (dp == 0U) {
                int recorded = 0;
                if (fd_for_dp >= 0) {
                    recorded = pt_lookup_fd_dpclass(fd_for_dp);
                } else if (path_for_dp != NULL && path_for_dp[0] != '\0') {
                    struct stat st;
                    int saved_errno = errno;
                    if (((options & FSOPT_NOFOLLOW) ? lstat(path_for_dp, &st) : stat(path_for_dp, &st)) == 0) {
                        recorded = pt_lookup_stat_dpclass(st.st_dev, st.st_ino);
                    }
                    errno = saved_errno;
                }
                dp = (recorded > 0) ? (uint32_t)recorded : 3U;
                memcpy(rec_ptr + off, &dp, sizeof(dp));
            }
        }
    }
#ifdef VOL_CAP_FMT_CASE_SENSITIVE
    if ((alist->volattr & ATTR_VOL_CAPABILITIES) != 0) {
        BOOL present = NO;
        size_t off = pt_attr_offset_in_record(alist, rec_ptr, rec_len, options,
                                              PT_ATTR_GROUP_VOL, ATTR_VOL_CAPABILITIES, &present);
        if (present && off + sizeof(vol_capabilities_attr_t) <= rec_len) {
            vol_capabilities_attr_t caps;
            memcpy(&caps, rec_ptr + off, sizeof(caps));
            caps.capabilities[VOL_CAPABILITIES_FORMAT] |= VOL_CAP_FMT_CASE_SENSITIVE;
            caps.valid[VOL_CAPABILITIES_FORMAT] |= VOL_CAP_FMT_CASE_SENSITIVE;
            memcpy(rec_ptr + off, &caps, sizeof(caps));
        }
    }
#endif
}

static void pt_sanitize_attr_fullpath_in_record(const struct attrlist *alist,
                                                char *rec_ptr,
                                                size_t max_rec_cap,
                                                uint64_t options,
                                                BOOL can_grow_record,
                                                int fd_for_dp,
                                                const char *path_for_dp,
                                                BOOL is_synth_sysver,
                                                const void *caller) {
    if (alist == NULL || rec_ptr == NULL || max_rec_cap < sizeof(uint32_t)) {
        return;
    }
    pt_sanitize_attr_scalars_in_record(alist, rec_ptr, max_rec_cap, options, fd_for_dp, path_for_dp, is_synth_sysver);
    if ((alist->commonattr & ATTR_CMN_NAME) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_COMMON, ATTR_CMN_NAME, NO,
                                  is_synth_sysver ? "SystemVersion.plist" : NULL, caller);
    }
    if ((alist->commonattr & ATTR_CMN_FULLPATH) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_COMMON, ATTR_CMN_FULLPATH, NO,
                                  is_synth_sysver ? "/System/Library/CoreServices/SystemVersion.plist" : NULL, caller);
    }
    if ((alist->volattr & ATTR_VOL_MOUNTPOINT) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_VOL, ATTR_VOL_MOUNTPOINT, YES,
                                  is_synth_sysver ? "/" : NULL, caller);
    }
    if ((alist->volattr & ATTR_VOL_NAME) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_VOL, ATTR_VOL_NAME, NO,
                                  is_synth_sysver ? "System" : NULL, caller);
    }
    if ((alist->volattr & ATTR_VOL_MOUNTEDDEVICE) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_VOL, ATTR_VOL_MOUNTEDDEVICE, NO,
                                  is_synth_sysver ? "/dev/disk0s1s1" : NULL, caller);
    }
    if ((alist->forkattr & ATTR_CMNEXT_RELPATH) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_FORK, ATTR_CMNEXT_RELPATH, NO,
                                  is_synth_sysver ? "System/Library/CoreServices/SystemVersion.plist" : NULL, caller);
    }
    if ((alist->forkattr & ATTR_CMNEXT_NOFIRMLINKPATH) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_FORK, ATTR_CMNEXT_NOFIRMLINKPATH, NO,
                                  is_synth_sysver ? "/System/Library/CoreServices/SystemVersion.plist" : NULL, caller);
    }
}

static void pt_sanitize_attr_virtual_ancestor_record(const struct attrlist *alist,
                                                     char *rec_ptr,
                                                     size_t max_rec_cap,
                                                     uint64_t options,
                                                     BOOL can_grow_record,
                                                     const char *ancestor_path,
                                                     const void *caller) {
    if (alist == NULL || rec_ptr == NULL || max_rec_cap < sizeof(uint32_t) || ancestor_path == NULL) {
        return;
    }
    pt_sanitize_attr_scalars_in_record(alist, rec_ptr, max_rec_cap, options, -1, NULL, NO);
    const char *base = strrchr(ancestor_path, '/');
    const char *name_override = (base != NULL && base[1] != '\0') ? (base + 1) : "/";
    if ((alist->commonattr & ATTR_CMN_NAME) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_COMMON, ATTR_CMN_NAME, NO, name_override, caller);
    }
    if ((alist->commonattr & ATTR_CMN_FULLPATH) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_COMMON, ATTR_CMN_FULLPATH, NO, ancestor_path, caller);
    }
    if ((alist->volattr & ATTR_VOL_MOUNTPOINT) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_VOL, ATTR_VOL_MOUNTPOINT, YES, "/private/var", caller);
    }
    if ((alist->volattr & ATTR_VOL_NAME) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_VOL, ATTR_VOL_NAME, NO, "Data", caller);
    }
    if ((alist->volattr & ATTR_VOL_MOUNTEDDEVICE) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_VOL, ATTR_VOL_MOUNTEDDEVICE, NO, "/dev/disk0s1s2", caller);
    }
    if ((alist->forkattr & ATTR_CMNEXT_RELPATH) != 0) {
        const char *rel_anc = (ancestor_path[0] == '/') ? (ancestor_path + 1) : ancestor_path;
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_FORK, ATTR_CMNEXT_RELPATH, NO, rel_anc, caller);
    }
    if ((alist->forkattr & ATTR_CMNEXT_NOFIRMLINKPATH) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_FORK, ATTR_CMNEXT_NOFIRMLINKPATH, NO, ancestor_path, caller);
    }
}

__attribute__((visibility("hidden")))
int pt_fs_getattrlist_with_caller(const char *path,
                                  void *attrList,
                                  void *attrBuf,
                                  size_t attrBufSize,
                                  unsigned int options,
                                  const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    const char *ancestor_override = NULL;
    const char *query_path = resolved;
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        ancestor_override = (resolved != NULL) ? resolved : "/private/var/mobile";
        pt_ensure_data_container_map();
        query_path = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    }
    int ret = getattrlist(query_path, attrList, attrBuf, attrBufSize, options);
    if (ret == 0 && attrList != NULL && attrBuf != NULL && attrBufSize >= sizeof(uint32_t) &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        if (ancestor_override != NULL) {
            pt_sanitize_attr_virtual_ancestor_record((const struct attrlist *)attrList,
                                                     (char *)attrBuf,
                                                     attrBufSize,
                                                     (uint64_t)options,
                                                     (options & FSOPT_REPORT_FULLSIZE) == 0,
                                                     ancestor_override,
                                                     caller);
        } else {
            BOOL is_sysver = pt_is_synth_system_version_path(query_path);
            pt_sanitize_attr_fullpath_in_record((const struct attrlist *)attrList,
                                                (char *)attrBuf,
                                                attrBufSize,
                                                (uint64_t)options,
                                                (options & FSOPT_REPORT_FULLSIZE) == 0,
                                                -1,
                                                query_path,
                                                is_sysver,
                                                caller);
        }
    }
    return ret;
}

static int pt_getattrlist(const char *path, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options) {
    return pt_fs_getattrlist_with_caller(path, attrList, attrBuf, attrBufSize, options, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_fgetattrlist_with_caller(int fd,
                                   void *attrList,
                                   void *attrBuf,
                                   size_t attrBufSize,
                                   unsigned int options,
                                   const void *caller) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    int ret = fgetattrlist(fd, attrList, attrBuf, attrBufSize, options);
    if (ret == 0 && attrList != NULL && attrBuf != NULL && attrBufSize >= sizeof(uint32_t) && !is_sys) {
        BOOL is_sysver = NO;
        struct stat st;
        int saved_errno = errno;
        if (fstat(fd, &st) == 0 && pt_is_synth_system_version_stat(st.st_dev, st.st_ino)) {
            is_sysver = YES;
        }
        errno = saved_errno;
        pt_sanitize_attr_fullpath_in_record((const struct attrlist *)attrList,
                                            (char *)attrBuf,
                                            attrBufSize,
                                            (uint64_t)options,
                                            (options & FSOPT_REPORT_FULLSIZE) == 0,
                                            fd,
                                            NULL,
                                            is_sysver,
                                            caller);
    }
    return ret;
}

static int pt_fgetattrlist(int fd, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options) {
    return pt_fs_fgetattrlist_with_caller(fd, attrList, attrBuf, attrBufSize, options, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_getattrlistat_with_caller(int fd,
                                    const char *path,
                                    void *attrList,
                                    void *attrBuf,
                                    size_t attrBufSize,
                                    unsigned long options,
                                    const void *caller) {
    if (pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_ro(fd, path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    int ret = -1;
    const char *ancestor_override = NULL;
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        ancestor_override = (resolved != NULL) ? resolved : "/private/var/mobile";
        pt_ensure_data_container_map();
        const char *proxy = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
        ret = getattrlist(proxy, attrList, attrBuf, attrBufSize, (unsigned int)options);
    } else {
        ret = getattrlistat(fd, resolved, attrList, attrBuf, attrBufSize, options);
    }
    if (ret == 0 && attrList != NULL && attrBuf != NULL && attrBufSize >= sizeof(uint32_t) &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        if (ancestor_override != NULL) {
            pt_sanitize_attr_virtual_ancestor_record((const struct attrlist *)attrList,
                                                     (char *)attrBuf,
                                                     attrBufSize,
                                                     (uint64_t)options,
                                                     (options & FSOPT_REPORT_FULLSIZE) == 0,
                                                     ancestor_override,
                                                     caller);
        } else {
            BOOL is_sysver = pt_is_synth_system_version_path(resolved);
            pt_sanitize_attr_fullpath_in_record((const struct attrlist *)attrList,
                                                (char *)attrBuf,
                                                attrBufSize,
                                                (uint64_t)options,
                                                (options & FSOPT_REPORT_FULLSIZE) == 0,
                                                -1,
                                                (resolved != NULL && resolved[0] == '/') ? resolved : NULL,
                                                is_sysver,
                                                caller);
        }
    }
    return ret;
}

static int pt_getattrlistat(int fd, const char *path, void *attrList, void *attrBuf, size_t attrBufSize, unsigned long options) {
    return pt_fs_getattrlistat_with_caller(fd, path, attrList, attrBuf, attrBufSize, options, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_getattrlistbulk_with_caller(int dirfd,
                                      void *attrList,
                                      void *attrBuf,
                                      size_t attrBufSize,
                                      uint64_t options,
                                      const void *caller) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (is_sys) {
        return getattrlistbulk(dirfd, attrList, attrBuf, attrBufSize, options);
    }
    char dirpath[PATH_MAX];
    dirpath[0] = '\0';
    if (dirfd >= 0 && fcntl(dirfd, F_GETPATH, dirpath) != -1 && pt_is_sensitive_host_fd_path(dirpath, caller)) {
        errno = ENOENT;
        return -1;
    }
    int is_sys_int = 0;
    int in_data_root = (dirpath[0] != '\0') ? (pt_path_equals_real_data_root(dirpath) ? 1 : 0) : -1;
    const struct attrlist *alist = (const struct attrlist *)attrList;

    for (;;) {
        int count = getattrlistbulk(dirfd, attrList, attrBuf, attrBufSize, options);
        if (count <= 0 || attrBuf == NULL || alist == NULL) {
            return count;
        }
        char *read_ptr = (char *)attrBuf;
        char *write_ptr = (char *)attrBuf;
        char *buf_end = (char *)attrBuf + attrBufSize;
        int kept = 0;

        for (int i = 0; i < count && read_ptr + sizeof(uint32_t) <= buf_end; i++) {
            uint32_t rec_len = *(uint32_t *)read_ptr;
            if (rec_len < sizeof(uint32_t) || read_ptr + rec_len > buf_end) {
                break;
            }
            BOOL hide = NO;
            BOOL has_name = NO;
            size_t name_off = pt_attr_cmn_offset_in_record(alist, read_ptr, rec_len, options, ATTR_CMN_NAME, &has_name);
            if (has_name && name_off + sizeof(attrreference_t) <= rec_len) {
                const attrreference_t *nref = (const attrreference_t *)(read_ptr + name_off);
                uintptr_t nstart = (uintptr_t)nref + (uintptr_t)nref->attr_dataoffset;
                uintptr_t nend = (uintptr_t)read_ptr + (uintptr_t)rec_len;
                if (nref->attr_dataoffset > 0 && nstart >= (uintptr_t)read_ptr && nstart < nend) {
                    char nbuf[NAME_MAX + 1];
                    size_t nmax = (size_t)(nend - nstart);
                    size_t nc = (nref->attr_length < nmax) ? (size_t)nref->attr_length : nmax;
                    if (nc >= sizeof(nbuf)) nc = sizeof(nbuf) - 1;
                    memcpy(nbuf, (const void *)nstart, nc);
                    nbuf[nc] = '\0';
                    if (pt_should_hide_dirent(nbuf, DT_UNKNOWN, caller, &is_sys_int, &in_data_root, NULL, dirfd, (dirpath[0] != '\0') ? dirpath : NULL)) {
                        hide = YES;
                    }
                }
            }
            if (!hide) {
                pt_sanitize_attr_fullpath_in_record(alist, read_ptr, rec_len, options, NO, -1, NULL, NO, caller);
                if (write_ptr != read_ptr) {
                    memmove(write_ptr, read_ptr, rec_len);
                }
                write_ptr += rec_len;
                kept++;
            }
            read_ptr += rec_len;
        }
        if (kept > 0) {
            return kept;
        }
    }
}

static int pt_getattrlistbulk(int dirfd, void *attrList, void *attrBuf, size_t attrBufSize, uint64_t options) {
    return pt_fs_getattrlistbulk_with_caller(dirfd, attrList, attrBuf, attrBufSize, options, __builtin_return_address(0));
}

static int pt_setattrlist(const char *path, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return setattrlist(path, attrList, attrBuf, attrBufSize, options);
}

static int pt_fsetattrlist(int fd, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options) {
    if (pt_fd_is_sensitive(fd, __builtin_return_address(0))) {
        errno = EACCES;
        return -1;
    }
    return fsetattrlist(fd, attrList, attrBuf, attrBufSize, options);
}

static int pt_setattrlistat(int dirfd,
                            const char *path,
                            void *attrList,
                            void *attrBuf,
                            size_t attrBufSize,
                            uint32_t options) {
    const void *caller = __builtin_return_address(0);
    if (pt_fd_is_sensitive(dirfd, caller)) {
        errno = EACCES;
        return -1;
    }
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(dirfd, path, caller, vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return setattrlistat(dirfd, path, attrList, attrBuf, attrBufSize, options);
}

extern int pt_orig_getdirentriesattr(int, void *, void *, size_t, void *, void *, void *, unsigned long)
    __asm__("_getdirentriesattr") __attribute__((weak_import));

static int pt_getdirentriesattr(int fd,
                                 void *attrlist,
                                 void *attrbuf,
                                 size_t attrbufsize,
                                 void *count,
                                 void *basep,
                                 void *newstate,
                                 unsigned long options) {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        errno = ENOTSUP;
        return -1;
    }
    if (&pt_orig_getdirentriesattr != NULL) {
        return pt_orig_getdirentriesattr(fd, attrlist, attrbuf, attrbufsize, count, basep, newstate, options);
    }
    errno = ENOSYS;
    return -1;
}

__attribute__((visibility("hidden")))
long pt_fs_pathconf_with_caller(const char *path, int name, const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        pt_ensure_data_container_map();
        resolved = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    }
    long ret = pathconf(resolved, name);
#ifdef _PC_CASE_SENSITIVE
    if (ret >= 0 && name == _PC_CASE_SENSITIVE &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        return 1L;
    }
#endif
    return ret;
}

static long pt_pathconf(const char *path, int name) {
    return pt_fs_pathconf_with_caller(path, name, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
long pt_fs_fpathconf_with_caller(int fd, int name, const void *caller) {
    if (fd < 0) {
        errno = EBADF;
        return -1;
    }
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    long ret = fpathconf(fd, name);
#ifdef _PC_CASE_SENSITIVE
    if (ret >= 0 && name == _PC_CASE_SENSITIVE && !is_sys && pt_is_bypass_enabled()) {
        return 1L;
    }
#endif
    return ret;
}

static long pt_fpathconf(int fd, int name) {
    return pt_fs_fpathconf_with_caller(fd, name, __builtin_return_address(0));
}

__attribute__((visibility("hidden"))) void pt_sanitize_statfs_entry(struct statfs *buf, const void *caller, int *inout_is_sys) {
    if (buf == NULL) {
        return;
    }
    if (*inout_is_sys < 0) {
        *inout_is_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    if (*inout_is_sys != 0) {
        return;
    }
    if (strcmp(buf->f_mntonname, "/System/Volumes/Data") == 0 ||
        strncmp(buf->f_mntonname, "/Volumes/", 9) == 0 ||
        strncmp(buf->f_mntonname, "/Users/", 7) == 0 ||
        strncmp(buf->f_mntonname, "/System/Volumes/Data/Users/", 27) == 0) {
        strlcpy(buf->f_mntonname, "/private/var", sizeof(buf->f_mntonname));
        strlcpy(buf->f_mntfromname, "/dev/disk0s1s2", sizeof(buf->f_mntfromname));
    } else if (strncmp(buf->f_mntonname, "/System/Volumes/Data/", 21) == 0) {
        char stripped[MFSTYPENAMELEN + MAXPATHLEN];
        strlcpy(stripped, buf->f_mntonname + 20, sizeof(stripped));
        strlcpy(buf->f_mntonname, stripped, sizeof(buf->f_mntonname));
    }
    if (strcmp(buf->f_mntonname, "/") == 0) {
        strlcpy(buf->f_mntfromname, "/dev/disk0s1s1", sizeof(buf->f_mntfromname));
    } else if (strcmp(buf->f_mntonname, "/private/var") == 0) {
        strlcpy(buf->f_mntfromname, "/dev/disk0s1s2", sizeof(buf->f_mntfromname));
    }
}

static BOOL pt_should_hide_mount_entry(const struct statfs *buf) {
    if (buf == NULL) {
        return NO;
    }
    return (strcmp(buf->f_mntonname, "/") != 0 &&
            strcmp(buf->f_mntonname, "/System/Volumes/Data") != 0 &&
            strcmp(buf->f_mntonname, "/private/var") != 0 &&
            strcmp(buf->f_mntonname, "/private/var/mobile") != 0);
}

__attribute__((visibility("hidden"))) int pt_filter_statfs_array(struct statfs *buf, int count, const void *caller) {
    if (count <= 0 || buf == NULL || !pt_is_bypass_enabled()) {
        return count;
    }
    int is_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    if (is_sys != 0) {
        return count;
    }
    int kept = 0;
    for (int i = 0; i < count; i++) {
        if (pt_should_hide_mount_entry(&buf[i])) {
            continue;
        }
        pt_sanitize_statfs_entry(&buf[i], caller, &is_sys);
        if (kept != i) {
            buf[kept] = buf[i];
        }
        kept++;
    }
    return kept;
}

__attribute__((visibility("hidden")))
int pt_fs_statfs_with_caller(const char *path, struct statfs *buf, const void *caller) {
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller_ro(path, caller, vbuf, sizeof(vbuf), &path, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    const char *query_path = path;
    BOOL is_synth_sysver = NO;
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        pt_ensure_data_container_map();
        query_path = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    } else if (pt_is_synth_system_version_path(path)) {
        if (is_sys_caller < 0) {
            is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
        }
        if (is_sys_caller == 0 && pt_is_bypass_enabled()) {
            query_path = "/";
            is_synth_sysver = YES;
        }
    }
    int ret = statfs(query_path, buf);
    if (ret == 0 && buf != NULL) {
        pt_sanitize_statfs_entry(buf, caller, &is_sys_caller);
        if (is_synth_sysver && is_sys_caller == 0) {
            buf->f_flags |= (uint32_t)(MNT_RDONLY | MNT_ROOTFS);
        }
    }
    return ret;
}

PT_INTERPOSE(pt_getattrlist, getattrlist)
PT_INTERPOSE(pt_fgetattrlist, fgetattrlist)
PT_INTERPOSE(pt_getattrlistat, getattrlistat)
PT_INTERPOSE(pt_getattrlistbulk, getattrlistbulk)
PT_INTERPOSE(pt_setattrlist, setattrlist)
PT_INTERPOSE(pt_fsetattrlist, fsetattrlist)
PT_INTERPOSE(pt_setattrlistat, setattrlistat)
PT_INTERPOSE_WEAK_NAMED(pt_getdirentriesattr, pt_orig_getdirentriesattr, "getdirentriesattr")
PT_INTERPOSE(pt_pathconf, pathconf)
PT_INTERPOSE(pt_fpathconf, fpathconf)
