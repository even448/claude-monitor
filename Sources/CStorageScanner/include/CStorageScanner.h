#ifndef CM_STORAGE_SCANNER_H
#define CM_STORAGE_SCANNER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*CMScanProgressCallback)(void *context, int64_t scanned_files, const char *path);

typedef struct CMStorageScanResult {
    char **file_paths;
    int64_t *file_sizes;
    double *file_mtimes;
    size_t file_count;

    char **dir_paths;
    int64_t *dir_sizes;
    size_t dir_count;

    int64_t total_bytes;
    int64_t scanned_files;
    int permission_limited;
    char *error_message;
} CMStorageScanResult;

/// Fast physical filesystem walk based on fts(3).
///
/// - Collects regular files >= min_file_size.
/// - Collects directory aggregate sizes for relative depth 1 and 2 >= min_dir_size.
/// - Does not cross mount points and never follows symlinks.
/// - progress is called periodically from the scanning thread.
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
);

void cm_storage_scan_result_free(CMStorageScanResult *result);

#ifdef __cplusplus
}
#endif

#endif
