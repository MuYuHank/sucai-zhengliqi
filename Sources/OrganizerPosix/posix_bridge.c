#include "posix_bridge.h"

#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>

int32_t chanwu_lstat(const char *path, ChanwuFileInfo *out) {
    struct stat info;
    if (lstat(path, &info) != 0) {
        return errno;
    }
    out->is_link = S_ISLNK(info.st_mode) ? 1 : 0;
    out->is_dir = S_ISDIR(info.st_mode) ? 1 : 0;
    out->size = (int64_t)info.st_size;
    out->mtime = (int64_t)info.st_mtime;
    out->dev = (uint64_t)info.st_dev;
    return 0;
}

int32_t chanwu_stat_dev(const char *path, uint64_t *dev) {
    struct stat info;
    if (stat(path, &info) != 0) {
        return errno;
    }
    *dev = (uint64_t)info.st_dev;
    return 0;
}

int32_t chanwu_rename(const char *from, const char *to) {
    if (rename(from, to) == 0) {
        return 0;
    }
    return errno;
}

int32_t chanwu_exdev(void) {
    return EXDEV;
}
