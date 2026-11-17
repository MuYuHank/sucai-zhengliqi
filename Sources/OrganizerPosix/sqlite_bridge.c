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
        "reason TEXT NOT NULL,"
        "summary TEXT NOT NULL DEFAULT '',"
        "recognized_project TEXT NOT NULL DEFAULT '',"
        "recognition_confidence REAL NOT NULL DEFAULT 0,"
        "recognized_at TEXT NOT NULL DEFAULT '',"
        "recognized_text TEXT NOT NULL DEFAULT ''"
        ");"
    );
    if (rc != SQLITE_OK) {
        sqlite3_close(db);
        return rc;
    }
    /* 旧库没有这些列。已经存在时 ALTER 会失败，忽略即可。 */
    exec_sql(db, "ALTER TABLE files ADD COLUMN summary TEXT NOT NULL DEFAULT '';");
    exec_sql(db, "ALTER TABLE files ADD COLUMN recognized_project TEXT NOT NULL DEFAULT '';");
    exec_sql(db, "ALTER TABLE files ADD COLUMN recognition_confidence REAL NOT NULL DEFAULT 0;");
    exec_sql(db, "ALTER TABLE files ADD COLUMN recognized_at TEXT NOT NULL DEFAULT '';");
    exec_sql(db, "ALTER TABLE files ADD COLUMN recognized_text TEXT NOT NULL DEFAULT '';");
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

int chanwu_db_set_recognition(
    void *db,
    const char *path,
    const char *summary,
    const char *project,
    double confidence,
    const char *recognized_at,
    const char *recognized_text
) {
    const char *sql =
        "UPDATE files SET summary=?1, recognized_project=?2, recognition_confidence=?3, recognized_at=?4, recognized_text=?5 WHERE path=?6;";
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2((sqlite3 *)db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return rc;
    }
    sqlite3_bind_text(stmt, 1, summary ? summary : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, project ? project : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_double(stmt, 3, confidence);
    sqlite3_bind_text(stmt, 4, recognized_at ? recognized_at : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, recognized_text ? recognized_text : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, path ? path : "", -1, SQLITE_TRANSIENT);
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

static int search_rows(void *db, const char *a, const char *b, const char *c, const char *d, int recognition_mode, int limit, char **json_out) {
    const char *sql =
        "SELECT id, file_name, original_name, kind, project_tag, modified_at, platform, publish_status, version, path, content_class, published_at, bytes, reason, summary, recognized_project, recognition_confidence, recognized_at, recognized_text "
        "FROM files WHERE "
        "(length(?1) = 0 OR file_name LIKE ?1 ESCAPE '\\' OR original_name LIKE ?1 ESCAPE '\\' OR kind LIKE ?1 ESCAPE '\\' OR project_tag LIKE ?1 ESCAPE '\\' OR platform LIKE ?1 ESCAPE '\\' OR publish_status LIKE ?1 ESCAPE '\\' OR version LIKE ?1 ESCAPE '\\' OR path LIKE ?1 ESCAPE '\\' OR content_class LIKE ?1 ESCAPE '\\' OR reason LIKE ?1 ESCAPE '\\' OR summary LIKE ?1 ESCAPE '\\' OR recognized_project LIKE ?1 ESCAPE '\\' OR recognized_text LIKE ?1 ESCAPE '\\') AND "
        "(length(?2) = 0 OR file_name LIKE ?2 ESCAPE '\\' OR original_name LIKE ?2 ESCAPE '\\' OR kind LIKE ?2 ESCAPE '\\' OR project_tag LIKE ?2 ESCAPE '\\' OR platform LIKE ?2 ESCAPE '\\' OR publish_status LIKE ?2 ESCAPE '\\' OR version LIKE ?2 ESCAPE '\\' OR path LIKE ?2 ESCAPE '\\' OR content_class LIKE ?2 ESCAPE '\\' OR reason LIKE ?2 ESCAPE '\\' OR summary LIKE ?2 ESCAPE '\\' OR recognized_project LIKE ?2 ESCAPE '\\' OR recognized_text LIKE ?2 ESCAPE '\\') AND "
        "(length(?3) = 0 OR file_name LIKE ?3 ESCAPE '\\' OR original_name LIKE ?3 ESCAPE '\\' OR kind LIKE ?3 ESCAPE '\\' OR project_tag LIKE ?3 ESCAPE '\\' OR platform LIKE ?3 ESCAPE '\\' OR publish_status LIKE ?3 ESCAPE '\\' OR version LIKE ?3 ESCAPE '\\' OR path LIKE ?3 ESCAPE '\\' OR content_class LIKE ?3 ESCAPE '\\' OR reason LIKE ?3 ESCAPE '\\' OR summary LIKE ?3 ESCAPE '\\' OR recognized_project LIKE ?3 ESCAPE '\\' OR recognized_text LIKE ?3 ESCAPE '\\') AND "
        "(length(?4) = 0 OR file_name LIKE ?4 ESCAPE '\\' OR original_name LIKE ?4 ESCAPE '\\' OR kind LIKE ?4 ESCAPE '\\' OR project_tag LIKE ?4 ESCAPE '\\' OR platform LIKE ?4 ESCAPE '\\' OR publish_status LIKE ?4 ESCAPE '\\' OR version LIKE ?4 ESCAPE '\\' OR path LIKE ?4 ESCAPE '\\' OR content_class LIKE ?4 ESCAPE '\\' OR reason LIKE ?4 ESCAPE '\\' OR summary LIKE ?4 ESCAPE '\\' OR recognized_project LIKE ?4 ESCAPE '\\' OR recognized_text LIKE ?4 ESCAPE '\\') "
        "AND ((?5 = 0) OR (?5 = 1 AND recognized_at = '') OR (?5 = 2 AND recognized_at <> '')) "
        "ORDER BY modified_at DESC LIMIT ?6;";
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2((sqlite3 *)db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return rc;
    }
    const char *terms[4] = {a ? a : "", b ? b : "", c ? c : "", d ? d : ""};
    for (int index = 0; index < 4; index++) {
        sqlite3_bind_text(stmt, index + 1, terms[index], -1, SQLITE_TRANSIENT);
    }
    sqlite3_bind_int(stmt, 5, recognition_mode);
    sqlite3_bind_int(stmt, 6, limit > 0 ? limit : 400);
    size_t cap = 65536;
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
        const char *extra_keys[] = {"summary", "recognizedProject", "recognizedAt", "recognizedText"};
        const int extra_columns[] = {14, 15, 17, 18};
        for (int extra = 0; extra < 4; extra++) {
            buffer[used++] = ',';
            append_json_string(&buffer, &used, &cap, extra_keys[extra]);
            buffer[used++] = ':';
            const unsigned char *text = sqlite3_column_text(stmt, extra_columns[extra]);
            append_json_string(&buffer, &used, &cap, text ? (const char *)text : "");
        }
        buffer[used++] = ',';
        append_json_string(&buffer, &used, &cap, "recognitionConfidence");
        buffer[used++] = ':';
        if (used + 64 > cap) {
            char *grown = realloc(buffer, cap * 2);
            if (grown) {
                buffer = grown;
                cap *= 2;
            }
        }
        int confidence_wrote = snprintf(buffer + used, cap - used, "%.6f", sqlite3_column_double(stmt, 16));
        if (confidence_wrote > 0) {
            used += (size_t)confidence_wrote;
        }
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

int chanwu_db_search(void *db, const char *a, const char *b, const char *c, const char *d, char **json_out) {
    return search_rows(db, a, b, c, d, 0, 400, json_out);
}

int chanwu_db_unrecognized(void *db, char **json_out) {
    return search_rows(db, "", "", "", "", 1, 40, json_out);
}

int chanwu_db_recognized(void *db, char **json_out) {
    return search_rows(db, "", "", "", "", 2, 2000, json_out);
}

void chanwu_db_free(char *text) {
    free(text);
}
