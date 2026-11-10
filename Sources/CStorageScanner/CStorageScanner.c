#include "CStorageScanner.h"

#include <errno.h>
#include <fts.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

typedef struct {
    char **paths;
    int64_t *sizes;
    double *mtimes;
    size_t count;
    size_t capacity;
    int has_mtime;
} CMList;

typedef struct CMDirAgg {
    char *path;
    int depth;
    int64_t size;
    struct CMDirAgg *parent;
} CMDirAgg;

static int cm_list_reserve(CMList *list, size_t needed) {
    if (needed <= list->capacity) {
        return 1;
    }
    size_t next = list->capacity == 0 ? 1024 : list->capacity * 2;
    while (next < needed) {
        next *= 2;
    }
    char **paths = (char **)realloc(list->paths, next * sizeof(char *));
    if (!paths) {
        return 0;
    }
    list->paths = paths;
    int64_t *sizes = (int64_t *)realloc(list->sizes, next * sizeof(int64_t));
    if (!sizes) {
        return 0;
    }
    list->sizes = sizes;
    if (list->has_mtime) {
        double *mtimes = (double *)realloc(list->mtimes, next * sizeof(double));
        if (!mtimes) {
            return 0;
        }
        list->mtimes = mtimes;
    }
    list->capacity = next;
    return 1;
}

static int cm_list_append(CMList *list, const char *path, int64_t size, double mtime) {
    if (!cm_list_reserve(list, list->count + 1)) {
        return 0;
    }
    list->paths[list->count] = strdup(path);
    if (!list->paths[list->count]) {
        return 0;
    }
    list->sizes[list->count] = size;
    if (list->has_mtime) {
        list->mtimes[list->count] = mtime;
    }
    list->count += 1;
    return 1;
}

static void cm_list_free(CMList *list) {
    if (!list) {
        return;
    }
    for (size_t i = 0; i < list->count; i++) {
        free(list->paths[i]);
    }
    free(list->paths);
    free(list->sizes);
    free(list->mtimes);
    memset(list, 0, sizeof(*list));
}

static int cm_path_is_excluded(
    const char *path,
    const char *const *prefixes,
    size_t prefix_count,
    const char *const *names,
    size_t name_count
) {
    for (size_t i = 0; i < prefix_count; i++) {
        const char *prefix = prefixes[i];
        size_t length = strlen(prefix);
        if (strncmp(path, prefix, length) == 0 && (path[length] == '\0' || path[length] == '/')) {
            return 1;
        }
    }

    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    for (size_t i = 0; i < name_count; i++) {
        if (strcmp(base, names[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

static int64_t cm_allocated_size(const struct stat *st) {
    int64_t blocks = (int64_t)st->st_blocks * 512;
    if (blocks > 0) {
        return blocks;
    }
    return (int64_t)st->st_size;
}

static double cm_mtime(const struct stat *st) {
    return (double)st->st_mtimespec.tv_sec + (double)st->st_mtimespec.tv_nsec / 1000000000.0;
}

static void cm_free_dir_chain(CMDirAgg *aggregate) {
    // Aggregates at depth <= 2 own their path and are linked to parent.
    // Only free this one; the parent is freed at its own FTS_DP.
    if (!aggregate) {
        return;
    }
    free(aggregate->path);
    free(aggregate);
}

static int cm_scan_root(
    const char *root,
    CMStorageScanResult *result,
    const char *const *prefixes,
    size_t prefix_count,
    const char *const *names,
    size_t name_count,
    int64_t min_file_size,
    int64_t min_dir_size,
    CMScanProgressCallback progress,
    void *context,
    CMList *files,
    CMList *dirs,
    int64_t *scanned,
    int *permission_limited
) {
    char *paths[2] = {(char *)root, NULL};
    FTS *stream = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!stream) {
        *permission_limited = 1;
        return 0;
    }

    CMDirAgg *root_aggregate = NULL;
    struct timespec last_progress = {0, 0};
    FTSENT *entry;

    while ((entry = fts_read(stream)) != NULL) {
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR || entry->fts_info == FTS_NS) {
            *permission_limited = 1;
            continue;
        }

        if (cm_path_is_excluded(entry->fts_path, prefixes, prefix_count, names, name_count)) {
            if (entry->fts_info == FTS_D) {
                fts_set(stream, entry, FTS_SKIP);
            }
            continue;
        }

        if (entry->fts_info == FTS_D) {
            CMDirAgg *aggregate = NULL;
            if (entry->fts_level == 0) {
                aggregate = (CMDirAgg *)calloc(1, sizeof(CMDirAgg));
                if (aggregate) {
                    aggregate->path = strdup(entry->fts_path);
                    aggregate->depth = 0;
                    aggregate->parent = NULL;
                    root_aggregate = aggregate;
                }
            } else if (entry->fts_level <= 2) {
                aggregate = (CMDirAgg *)calloc(1, sizeof(CMDirAgg));
                if (aggregate) {
                    aggregate->path = strdup(entry->fts_path);
                    aggregate->depth = (int)entry->fts_level;
                    aggregate->parent = entry->fts_parent ? (CMDirAgg *)entry->fts_parent->fts_pointer : root_aggregate;
                }
            } else {
                aggregate = entry->fts_parent ? (CMDirAgg *)entry->fts_parent->fts_pointer : NULL;
            }
            entry->fts_pointer = aggregate;
            continue;
        }

        if (entry->fts_info == FTS_F) {
            const struct stat *st = entry->fts_statp;
            if (!st) {
                continue;
            }
            int64_t size = cm_allocated_size(st);
            if (size <= 0) {
                continue;
            }

            *scanned += 1;
            result->total_bytes += size;

            CMDirAgg *aggregate = entry->fts_parent ? (CMDirAgg *)entry->fts_parent->fts_pointer : NULL;
            for (CMDirAgg *current = aggregate; current != NULL; current = current->parent) {
                current->size += size;
            }

            if (size >= min_file_size) {
                if (!cm_list_append(files, entry->fts_path, size, cm_mtime(st))) {
                    fts_close(stream);
                    return 0;
                }
            }

            if (progress && (entry->fts_level >= 0)) {
                struct timespec now;
                clock_gettime(CLOCK_MONOTONIC, &now);
                int64_t elapsed_ns = (int64_t)(now.tv_sec - last_progress.tv_sec) * 1000000000LL
                    + (int64_t)(now.tv_nsec - last_progress.tv_nsec);
                if (last_progress.tv_sec == 0 || elapsed_ns > 90000000LL) {
                    last_progress = now;
                    progress(context, *scanned, entry->fts_path);
                }
            }
            continue;
        }

        if (entry->fts_info == FTS_DP) {
            CMDirAgg *aggregate = (CMDirAgg *)entry->fts_pointer;
            if (!aggregate) {
                continue;
            }
            if (entry->fts_level >= 1 && entry->fts_level <= 2 && aggregate->size >= min_dir_size) {
                if (!cm_list_append(dirs, aggregate->path, aggregate->size, 0)) {
                    fts_close(stream);
                    return 0;
                }
            }
            if (entry->fts_level <= 2) {
                if (entry->fts_level == 0) {
                    root_aggregate = NULL;
                }
                cm_free_dir_chain(aggregate);
                entry->fts_pointer = NULL;
            }
        }
    }

    if (errno != 0) {
        *permission_limited = 1;
    }
    if (root_aggregate) {
        cm_free_dir_chain(root_aggregate);
    }
    fts_close(stream);
    return 1;
}

CMStorageScanResult *cm_storage_scan(
    const char *const *roots,
    size_t root_count,
    const char *const *excluded_prefixes,
    size_t excluded_prefix_count,
    const char *const *excluded_names,
    size_t excluded_name_count,
    int64_t min_file_size,
    int64_t min_dir_size,
    CMScanProgressCallback progress,
    void *context
) {
    CMStorageScanResult *result = (CMStorageScanResult *)calloc(1, sizeof(CMStorageScanResult));
    if (!result) {
        return NULL;
    }

    CMList files = {0};
    files.has_mtime = 1;
    CMList dirs = {0};
    dirs.has_mtime = 0;

    int64_t scanned = 0;
    int permission_limited = 0;

    for (size_t i = 0; i < root_count; i++) {
        if (!cm_scan_root(
                roots[i],
                result,
                excluded_prefixes,
                excluded_prefix_count,
                excluded_names,
                excluded_name_count,
                min_file_size,
                min_dir_size,
                progress,
                context,
                &files,
                &dirs,
                &scanned,
                &permission_limited
            )) {
            result->error_message = strdup("文件系统扫描内存不足");
            break;
        }
    }

    result->scanned_files = scanned;
    result->permission_limited = permission_limited;
    result->file_count = files.count;
    result->file_paths = files.paths;
    result->file_sizes = files.sizes;
    result->file_mtimes = files.mtimes;
    result->dir_count = dirs.count;
    result->dir_paths = dirs.paths;
    result->dir_sizes = dirs.sizes;

    // Ownership of the arrays has moved to the result.
    memset(&files, 0, sizeof(files));
    memset(&dirs, 0, sizeof(dirs));
    return result;
}

void cm_storage_scan_result_free(CMStorageScanResult *result) {
    if (!result) {
        return;
    }
    for (size_t i = 0; i < result->file_count; i++) {
        free(result->file_paths[i]);
    }
    for (size_t i = 0; i < result->dir_count; i++) {
        free(result->dir_paths[i]);
    }
    free(result->file_paths);
    free(result->file_sizes);
    free(result->file_mtimes);
    free(result->dir_paths);
    free(result->dir_sizes);
    free(result->error_message);
    free(result);
}
