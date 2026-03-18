#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <limits.h>
#include <errno.h>

/* Check if running inside a non-init user namespace */
static int in_user_ns(void)
{
    FILE *f = fopen("/proc/self/uid_map", "r");
    if (!f) return 0;

    unsigned int inner, count;
    unsigned long long outer;
    int lines = 0, trivial = 0;

    while (fscanf(f, "%u %llu %u", &inner, &outer, &count) == 3) {
        lines++;
        if (inner == 0 && outer == 0 && count >= 1000)
            trivial = 1;
    }
    fclose(f);

    return !(lines == 1 && trivial);
}

/* Read kernel overflow uid (shown for unmapped uids in user ns) */
static unsigned int get_overflow_uid(void)
{
    FILE *f = fopen("/proc/sys/kernel/overflowuid", "r");
    if (!f) return 65534;
    unsigned int uid = 65534;
    if (fscanf(f, "%u", &uid) != 1)
        uid = 65534;
    fclose(f);
    return uid;
}

/* Check if path resides on a read-only mount */
static int on_readonly_mount(const char *path)
{
    struct statvfs sv;
    if (statvfs(path, &sv) != 0) return 0;
    return (sv.f_flag & ST_RDONLY) != 0;
}

static int verify_dir_chain(const char *path, const char *prefix,
                            int userns, unsigned int overflow_uid)
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
            if (!(userns && st.st_uid == overflow_uid
                  && on_readonly_mount(buf))) {
                fprintf(stderr, "verify-lib: %s uid=%d, expected 0\n",
                        buf, st.st_uid);
                return 0;
            }
        }

        if ((st.st_mode & S_IWGRP) && st.st_gid != 0) {
            if (!(userns && st.st_gid == overflow_uid
                  && on_readonly_mount(buf))) {
                fprintf(stderr,
                        "verify-lib: %s group-writable with gid=%d\n",
                        buf, st.st_gid);
                return 0;
            }
        }

        if ((st.st_mode & S_IWOTH) && !(st.st_mode & S_ISVTX)) {
            fprintf(stderr,
                    "verify-lib: %s world-writable without sticky\n",
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
    int userns = in_user_ns();
    unsigned int overflow_uid = get_overflow_uid();

    char *real = realpath(file, NULL);
    if (!real) {
        fprintf(stderr, "verify-lib: cannot resolve %s: %s\n",
                file, strerror(errno));
        return 1;
    }

    if (strncmp(real, prefix, strlen(prefix)) != 0) {
        fprintf(stderr, "verify-lib: %s resolves outside %s\n",
                file, prefix);
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
        if (userns && st.st_uid == overflow_uid
            && st.st_gid == overflow_uid
            && on_readonly_mount(real)) {
            /* unmapped root on ro mount inside user ns */
        } else {
            fprintf(stderr,
                    "verify-lib: %s ownership %d:%d, expected 0:0\n",
                    real, st.st_uid, st.st_gid);
            free(real);
            return 1;
        }
    }

    if (st.st_mode & (S_IWGRP | S_IWOTH)) {
        fprintf(stderr,
                "verify-lib: %s writable by non-root (mode=%04o)\n",
                real, st.st_mode & 07777);
        free(real);
        return 1;
    }

    /*
     * In a non-init user namespace, virtual root (via --map-root-user)
     * can create files that appear uid=0 on writable mounts.
     * Only a read-only mount guarantees the contents were placed by
     * real root and cannot be tampered with from inside the namespace.
     */
    if (userns && !on_readonly_mount(real)) {
        fprintf(stderr,
                "verify-lib: %s on writable mount in user ns\n",
                real);
        free(real);
        return 1;
    }

    if (!verify_dir_chain(real, prefix, userns, overflow_uid)) {
        free(real);
        return 1;
    }

    printf("%s\n", real);
    free(real);
    return 0;
}
