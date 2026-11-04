#include <sys/types.h>
#include <stddef.h>
int nc2_auth_socket(const char *path, int server);
int nc2_auth_accept(int socket);
/* 返回已核验的 helper PID；任一条件失败返回 0。 */
int nc2_auth_peer_is_helper(int socket, pid_t ssh_pid, const char *executable);
int nc2_auth_read(int socket, void *bytes, size_t count);
int nc2_auth_write(int socket, const void *bytes, size_t count);
char *nc2_auth_read_tty(const char *prompt);
void nc2_auth_free_password(char *password);
