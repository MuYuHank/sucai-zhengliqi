#ifndef CHANWU_SQLITE_BRIDGE_H
#define CHANWU_SQLITE_BRIDGE_H

#include <stdint.h>

int chanwu_db_open(const char *path, void **out);
void chanwu_db_close(void *db);
int chanwu_db_upsert(
    void *db,
    const char *id,
    const char *file_name,
    const char *original_name,
    const char *kind,
    const char *project_tag,
    const char *modified_at,
    const char *platform,
    const char *publish_status,
    const char *version,
    const char *path,
    const char *content_class,
    const char *published_at,
    int64_t bytes,
    const char *reason
);
int chanwu_db_remove(void *db, const char *path);
int chanwu_db_set_recognition(
    void *db,
    const char *path,
    const char *summary,
    const char *project,
    double confidence,
    const char *recognized_at,
    const char *recognized_text
);
int chanwu_db_search(void *db, const char *a, const char *b, const char *c, const char *d, char **json_out);
int chanwu_db_unrecognized(void *db, char **json_out);
int chanwu_db_recognized(void *db, char **json_out);
void chanwu_db_free(char *text);

#endif
