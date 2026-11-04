#include "Nc2ShellAuthSupport.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <libproc.h>
#include <unistd.h>
#include <readpassphrase.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

static void clear_password(void *bytes, size_t count) {
    volatile unsigned char *cursor = bytes;
    while (count--) *cursor++ = 0;
}

static void configure(int descriptor, int timeout_read) {
    int enabled = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    struct timeval timeout = {15, 0};
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    /* 用户解锁钥匙串的时间不受本机响应超时限制；服务端读取请求仍须有界。 */
    if (timeout_read) setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
}

int nc2_auth_socket(const char *path, int server) {
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(address.sun_path)) return -1;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    configure(descriptor, server);
    if (server) {
        if (bind(descriptor, (struct sockaddr *)&address, sizeof(address)) == 0 &&
            chmod(path, 0600) == 0 && listen(descriptor, 4) == 0) return descriptor;
    } else if (connect(descriptor, (struct sockaddr *)&address, sizeof(address)) == 0) return descriptor;
    close(descriptor);
    return -1;
}

int nc2_auth_accept(int socket) {
    int descriptor = accept(socket, NULL, NULL);
    if (descriptor >= 0) configure(descriptor, 1);
    return descriptor;
}

int nc2_auth_peer_is_helper(int socket, pid_t ssh_pid, const char *executable) {
    pid_t pid = 0;
    socklen_t size = sizeof(pid);
    uid_t uid;
    gid_t gid;
    if (ssh_pid <= 0 || getpeereid(socket, &uid, &gid) || uid != getuid() ||
        getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &size)) return 0;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
        info.pbi_ppid != (uint32_t)ssh_pid || info.pbi_uid != getuid()) return 0;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0 || strcmp(path, executable)) return 0;
    if (proc_pidpath(ssh_pid, path, sizeof(path)) <= 0 || strcmp(path, "/usr/bin/ssh")) return 0;
    return pid;
}

int nc2_auth_read(int socket, void *bytes, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t n = read(socket, (char *)bytes + offset, count - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        offset += n;
    }
    return 1;
}

int nc2_auth_write(int socket, const void *bytes, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t n = write(socket, (const char *)bytes + offset, count - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        offset += n;
    }
    return 1;
}

char *nc2_auth_read_tty(const char *prompt) {
    char buffer[1024];
    char *result = NULL;
    if (readpassphrase(prompt, buffer, sizeof(buffer), RPP_REQUIRE_TTY) != NULL) result = strdup(buffer);
    clear_password(buffer, sizeof(buffer));
    return result;
}

void nc2_auth_free_password(char *password) {
    if (password) { clear_password(password, strlen(password)); free(password); }
}
