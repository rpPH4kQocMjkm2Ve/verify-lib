/* src/verify-lib.c */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <limits.h>
#include <errno.h>

static int verify_dir_chain(const char *path, const char *prefix)
{
    char buf[PATH_MAX];
    struct stat st;
    size_t prefix_len = strlen(prefix);

    if (strnlen(path, PATH_MAX) >= PATH_MAX)
        return 0;

    strncpy(buf, path, PATH_MAX - 1);
    buf[PATH_MAX - 1] = '\0';

    while (strlen(buf) >= prefix_len) {
        if (lstat(buf, &st) != 0) {
            fprintf(stderr, "verify-lib: cannot stat %s: %s\n",
                    buf, strerror(errno));
            return 0;
        }

        if (st.st_uid != 0) {
            fprintf(stderr, "verify-lib: %s uid=%d, expected 0\n",
                    buf, st.st_uid);
            return 0;
        }

        if ((st.st_mode & S_IWGRP) && st.st_gid != 0) {
            fprintf(stderr, "verify-lib: %s group-writable with gid=%d\n",
                    buf, st.st_gid);
            return 0;
        }

        if ((st.st_mode & S_IWOTH) && !(st.st_mode & S_ISVTX)) {
            fprintf(stderr, "verify-lib: %s world-writable without sticky\n",
                    buf);
            return 0;
        }

        char *slash = strrchr(buf, '/');
        if (!slash || slash == buf)
            break;
        *slash = '\0';
    }

    return 1;
}

int main(int argc, char *argv[])
{
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: verify-lib <file> [prefix]\n");
        return 1;
    }

    const char *file = argv[1];
    const char *prefix = argc == 3 ? argv[2] : "/usr/lib/";

    char *real = realpath(file, NULL);
    if (!real) {
        fprintf(stderr, "verify-lib: cannot resolve %s: %s\n",
                file, strerror(errno));
        return 1;
    }

    if (strncmp(real, prefix, strlen(prefix)) != 0) {
        fprintf(stderr, "verify-lib: %s resolves outside %s\n", file, prefix);
        free(real);
        return 1;
    }

    struct stat st;
    if (lstat(real, &st) != 0) {
        fprintf(stderr, "verify-lib: cannot stat %s: %s\n",
                real, strerror(errno));
        free(real);
        return 1;
    }

    if (!S_ISREG(st.st_mode)) {
        fprintf(stderr, "verify-lib: %s not a regular file\n", real);
        free(real);
        return 1;
    }

    if (st.st_uid != 0 || st.st_gid != 0) {
        fprintf(stderr, "verify-lib: %s ownership %d:%d, expected 0:0\n",
                real, st.st_uid, st.st_gid);
        free(real);
        return 1;
    }

    if (st.st_mode & (S_IWGRP | S_IWOTH)) {
        fprintf(stderr, "verify-lib: %s writable by non-root (mode=%04o)\n",
                real, st.st_mode & 07777);
        free(real);
        return 1;
    }

    if (!verify_dir_chain(real, prefix)) {
        free(real);
        return 1;
    }

    printf("%s\n", real);
    free(real);
    return 0;
}
