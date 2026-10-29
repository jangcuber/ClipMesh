#include <spawn.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
extern char **environ;
static long long milliseconds(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000; }
// Worker-queue only. The helper has a 8-second deadline and bounded anonymous-pipe output.
char *ClipMeshReadClipboard(void) {
    int descriptors[2]; if (pipe(descriptors)) return NULL;
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    char *arguments[] = {"/var/jb/usr/libexec/clipmesh-reader", NULL}; pid_t pid;
    posix_spawnattr_t attributes; posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    int result = posix_spawn(&pid, arguments[0], &actions, &attributes, arguments, environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions); close(descriptors[1]);
    if (result) { close(descriptors[0]); return NULL; }
    fcntl(descriptors[0], F_SETFL, O_NONBLOCK);
    size_t capacity = 8192, used = 0, maximum = 12 * 1048576;
    char *data = malloc(capacity); int failed = data == NULL, ended = 0;
    long long deadline = milliseconds() + 8000;
    while (!failed && !ended) {
        int remaining = (int)(deadline - milliseconds()); if (remaining <= 0) { failed = 1; break; }
        struct pollfd poller = { .fd = descriptors[0], .events = POLLIN | POLLHUP };
        int ready = poll(&poller, 1, remaining);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) { failed = 1; break; }
        if (used + 4097 > capacity) {
            size_t next = capacity * 2; if (next > maximum + 1) next = maximum + 1;
            if (next <= capacity) { failed = 1; break; }
            char *replacement = realloc(data, next); if (!replacement) { failed = 1; break; }
            data = replacement; capacity = next;
        }
        ssize_t count = read(descriptors[0], data + used, capacity - used - 1);
        if (count == 0) ended = 1;
        else if (count > 0) used += (size_t)count;
        else if (errno != EINTR && errno != EAGAIN) failed = 1;
    }
    close(descriptors[0]);
    int status = 0; pid_t waited = waitpid(pid, &status, WNOHANG);
    if (failed || waited == 0) {
        // Once the pipe is drained the child should exit promptly; honor the shared deadline.
        while (!failed && waited == 0 && milliseconds() < deadline) { usleep(1000); waited = waitpid(pid, &status, WNOHANG); }
        if (failed || waited == 0) { kill(pid, SIGKILL); waitpid(pid, &status, 0); failed = 1; }
    }
    if (failed || waited < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || used == 0) { free(data); return NULL; }
    data[used] = 0; return data;
}
