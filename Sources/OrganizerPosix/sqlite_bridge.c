#include "sqlite_bridge.h"

#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int exec_sql(sqlite3 *db, const char *sql) {
    char *err = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
    if (err) {
        sqlite3_free(err);
    }
    return rc;
}

int chanwu_db_open(const char *path, void **out) {
    sqlite3 *db = NULL;
    int rc = sqlite3_open(path, &db);
    if (rc != SQLITE_OK) {
        if (db) {
            sqlite3_close(db);
        }
        return rc;
    }
    exec_sql(db, "PRAGMA journal_mode=WAL;");
    rc = exec_sql(
        db,
        "CREATE TABLE IF NOT EXISTS files ("
        "id TEXT PRIMARY KEY,"
        "file_name TEXT NOT NULL,"
        "original_name TEXT NOT NULL,"
        "kind TEXT NOT NULL,"
        "project_tag TEXT NOT NULL,"
        "modified_at TEXT NOT NULL,"
        "platform TEXT NOT NULL,"
        "publish_status TEXT NOT NULL,"
        "version TEXT NOT NULL,"
        "path TEXT NOT NULL,"
        "content_class TEXT NOT NULL,"
        "published_at TEXT NOT NULL,"
        "bytes INTEGER NOT NULL,"
        "reason TEXT NOT NULL"
        ");"
    );
    if (rc != SQLITE_OK) {
        sqlite3_close(db);
        return rc;
    }
    *out = db;
    return SQLITE_OK;
}

void chanwu_db_close(void *db) {
    if (db) {
        sqlite3_close((sqlite3 *)db);
    }
}

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
) {
    const char *sql =
        "INSERT INTO files (id, file_name, original_name, kind, project_tag, modified_at, platform, publish_status, version, path, content_class, published_at, bytes, reason) "
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14) "
        "ON CONFLICT(id) DO UPDATE SET "
        "file_name=excluded.file_name, original_name=excluded.original_name, kind=excluded.kind, "
        "project_tag=excluded.project_tag, modified_at=excluded.modified_at, platform=excluded.platform, "
        "publish_status=excluded.publish_status, version=excluded.version, path=excluded.path, "
        "content_class=excluded.content_class, published_at=excluded.published_at, bytes=excluded.bytes, reason=excluded.reason;";
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2((sqlite3 *)db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return rc;
    }
    const char *values[] = {
        id, file_name, original_name, kind, project_tag, modified_at, platform,
        publish_status, version, path, content_class, published_at, reason
    };
    for (int index = 0; index < 12; index++) {
        sqlite3_bind_text(stmt, index + 1, values[index] ? values[index] : "", -1, SQLITE_TRANSIENT);
    }
    sqlite3_bind_int64(stmt, 13, bytes);
    sqlite3_bind_text(stmt, 14, reason ? reason : "", -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        return rc;
    }
    return SQLITE_OK;
}

int chanwu_db_remove(void *db, const char *path) {
    const char *sql = "DELETE FROM files WHERE path = ?1;";
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2((sqlite3 *)db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return rc;
    }
    sqlite3_bind_text(stmt, 1, path ? path : "", -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE ? SQLITE_OK : rc;
}

static void append_json_string(char **buffer, size_t *used, size_t *cap, const char *text) {
    const unsigned char *cursor = (const unsigned char *)(text ? text : "");
    size_t extra = 2;
    for (size_t i = 0; cursor[i]; i++) {
        unsigned char c = cursor[i];
        extra += (c == '"' || c == '\\' || c < 0x20) ? 6 : 1;
    }
    if (*used + extra + 1 > *cap) {
        size_t next = (*cap + extra + 64) * 2;
        char *grown = realloc(*buffer, next);
        if (!grown) {
            return;
        }
        *buffer = grown;
        *cap = next;
    }
    (*buffer)[(*used)++] = '"';
    for (size_t i = 0; cursor[i]; i++) {
        unsigned char c = cursor[i];
        if (c == '"' || c == '\\') {
            (*buffer)[(*used)++] = '\\';
            (*buffer)[(*used)++] = (char)c;
        } else if (c < 0x20) {
            int wrote = snprintf(*buffer + *used, 8, "\\u%04x", c);
            if (wrote > 0) {
                *used += (size_t)wrote;
            }
        } else {
            (*buffer)[(*used)++] = (char)c;
        }
    }
    (*buffer)[(*used)++] = '"';
}

int chanwu_db_search(void *db, const char *a, const char *b, const char *c, const char *d, char **json_out) {
    const char *sql =
        "SELECT id, file_name, original_name, kind, project_tag, modified_at, platform, publish_status, version, path, content_class, published_at, bytes, reason "
        "FROM files WHERE "
        "(length(?1) = 0 OR file_name LIKE ?1 ESCAPE '\\' OR original_name LIKE ?1 ESCAPE '\\' OR kind LIKE ?1 ESCAPE '\\' OR project_tag LIKE ?1 ESCAPE '\\' OR platform LIKE ?1 ESCAPE '\\' OR publish_status LIKE ?1 ESCAPE '\\' OR version LIKE ?1 ESCAPE '\\' OR path LIKE ?1 ESCAPE '\\' OR content_class LIKE ?1 ESCAPE '\\' OR reason LIKE ?1 ESCAPE '\\') AND "
        "(length(?2) = 0 OR file_name LIKE ?2 ESCAPE '\\' OR original_name LIKE ?2 ESCAPE '\\' OR kind LIKE ?2 ESCAPE '\\' OR project_tag LIKE ?2 ESCAPE '\\' OR platform LIKE ?2 ESCAPE '\\' OR publish_status LIKE ?2 ESCAPE '\\' OR version LIKE ?2 ESCAPE '\\' OR path LIKE ?2 ESCAPE '\\' OR content_class LIKE ?2 ESCAPE '\\' OR reason LIKE ?2 ESCAPE '\\') AND "
        "(length(?3) = 0 OR file_name LIKE ?3 ESCAPE '\\' OR original_name LIKE ?3 ESCAPE '\\' OR kind LIKE ?3 ESCAPE '\\' OR project_tag LIKE ?3 ESCAPE '\\' OR platform LIKE ?3 ESCAPE '\\' OR publish_status LIKE ?3 ESCAPE '\\' OR version LIKE ?3 ESCAPE '\\' OR path LIKE ?3 ESCAPE '\\' OR content_class LIKE ?3 ESCAPE '\\' OR reason LIKE ?3 ESCAPE '\\') AND "
        "(length(?4) = 0 OR file_name LIKE ?4 ESCAPE '\\' OR original_name LIKE ?4 ESCAPE '\\' OR kind LIKE ?4 ESCAPE '\\' OR project_tag LIKE ?4 ESCAPE '\\' OR platform LIKE ?4 ESCAPE '\\' OR publish_status LIKE ?4 ESCAPE '\\' OR version LIKE ?4 ESCAPE '\\' OR path LIKE ?4 ESCAPE '\\' OR content_class LIKE ?4 ESCAPE '\\' OR reason LIKE ?4 ESCAPE '\\') "
        "ORDER BY modified_at DESC LIMIT 400;";
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2((sqlite3 *)db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return rc;
    }
    const char *terms[4] = {a ? a : "", b ? b : "", c ? c : "", d ? d : ""};
    for (int index = 0; index < 4; index++) {
        sqlite3_bind_text(stmt, index + 1, terms[index], -1, SQLITE_TRANSIENT);
    }
    size_t cap = 4096;
    size_t used = 0;
    char *buffer = malloc(cap);
    if (!buffer) {
        sqlite3_finalize(stmt);
        return SQLITE_NOMEM;
    }
    buffer[used++] = '[';
    int count = 0;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        if (count > 0) {
            buffer[used++] = ',';
        }
        buffer[used++] = '{';
        const char *keys[] = {
            "id", "fileName", "originalName", "kind", "projectTag", "modifiedAt", "platform",
            "publishStatus", "version", "path", "contentClass", "publishedAt", "reason"
        };
        for (int column = 0; column < 12; column++) {
            if (column > 0) {
                buffer[used++] = ',';
            }
            append_json_string(&buffer, &used, &cap, keys[column]);
            buffer[used++] = ':';
            const unsigned char *text = sqlite3_column_text(stmt, column);
            append_json_string(&buffer, &used, &cap, text ? (const char *)text : "");
        }
        buffer[used++] = ',';
        append_json_string(&buffer, &used, &cap, "bytes");
        buffer[used++] = ':';
        int wrote = snprintf(buffer + used, cap - used, "%lld", (long long)sqlite3_column_int64(stmt, 12));
        if (wrote < 0 || (size_t)wrote >= cap - used) {
            break;
        }
        used += (size_t)wrote;
        buffer[used++] = ',';
        append_json_string(&buffer, &used, &cap, "reason");
        buffer[used++] = ':';
        const unsigned char *reason = sqlite3_column_text(stmt, 13);
        append_json_string(&buffer, &used, &cap, reason ? (const char *)reason : "");
        buffer[used++] = '}';
        count++;
        if (used + 8 > cap) {
            char *grown = realloc(buffer, cap * 2);
            if (!grown) {
                break;
            }
            buffer = grown;
            cap *= 2;
        }
    }
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
        free(buffer);
        return rc;
    }
    buffer[used++] = ']';
    buffer[used] = '\0';
    *json_out = buffer;
    return SQLITE_OK;
}

void chanwu_db_free(char *text) {
    free(text);
}
