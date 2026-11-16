#ifndef CHANWU_POSIX_BRIDGE_H
#define CHANWU_POSIX_BRIDGE_H

#include <stdint.h>

typedef struct ChanwuFileInfo {
    int64_t is_link;
    int64_t is_dir;
    int64_t size;
    int64_t mtime;
    uint64_t dev;
} ChanwuFileInfo;

int32_t chanwu_lstat(const char *path, ChanwuFileInfo *out);
int32_t chanwu_stat_dev(const char *path, uint64_t *dev);
int32_t chanwu_rename(const char *from, const char *to);
int32_t chanwu_exdev(void);

#endif
