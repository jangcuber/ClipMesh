#include <spawn.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <time.h>
extern char **environ;
typedef struct { pid_t pid; int input; int output; } MeshProcess;
void *ClipMeshTransportStart(const char *executable, const char *configuration) {
    int input[2], output[2];
    if (pipe(input)) return NULL;
    if (pipe(output)) { close(input[0]); close(input[1]); return NULL; }
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, input[1]);
    posix_spawn_file_actions_addclose(&actions, output[0]);
    posix_spawn_file_actions_addclose(&actions, input[0]);
    posix_spawn_file_actions_addclose(&actions, output[1]);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    char *args[] = {(char *)executable, "transport", "--config", (char *)configuration, NULL};
    pid_t pid;
    posix_spawnattr_t attributes; posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    int result = posix_spawn(&pid, args[0], &actions, &attributes, args, environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(input[0]); close(output[1]);
    if (result) { close(input[1]); close(output[0]); return NULL; }
    MeshProcess *process = calloc(1, sizeof(MeshProcess));
    if (!process) { kill(pid, SIGKILL); close(input[1]); close(output[0]); waitpid(pid, NULL, 0); return NULL; }
    process->pid = pid; process->input = input[1]; process->output = output[0];
    fcntl(process->output, F_SETFL, O_NONBLOCK);
    fcntl(process->input, F_SETFL, O_NONBLOCK);
    // A terminated child must not send SIGPIPE into SpringBoard.
    fcntl(process->input, F_SETNOSIGPIPE, 1);
    return process;
}
int ClipMeshTransportFD(void *raw) { return ((MeshProcess *)raw)->output; }
int ClipMeshTransportWrite(void *raw, const char *bytes, size_t count) {
    MeshProcess *process = raw; size_t used = 0;
    struct timespec start; clock_gettime(CLOCK_MONOTONIC, &start);
    long long deadline = start.tv_sec * 1000LL + start.tv_nsec / 1000000 + 15000;
    // Bounded waits occur on a dedicated utility queue, never SpringBoard's main queue.
    while (used < count) {
        struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
        long long remaining = deadline - (now.tv_sec * 1000LL + now.tv_nsec / 1000000);
        if (remaining <= 0) return -1;
        struct pollfd p = {.fd = process->input, .events = POLLOUT};
        int ready = poll(&p, 1, remaining < 1000 ? (int)remaining : 1000);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0 || !(p.revents & POLLOUT)) return -1;
        ssize_t wrote = write(process->input, bytes + used, count - used);
        if (wrote > 0) used += (size_t)wrote;
        else if (wrote < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        else return -1;
    }
    return 0;
}
void ClipMeshTransportStop(void *raw) {
    if (!raw) return;
    MeshProcess *process = raw;
    close(process->input); close(process->output);
    kill(process->pid, SIGTERM);
    // Never block the main thread or leak a zombie. The child can take time to close QUIC.
    int status; pid_t done = 0;
    for (int i = 0; i < 100 && done == 0; i++) { done = waitpid(process->pid, &status, WNOHANG); if (done == 0) usleep(10000); }
    if (done == 0) { kill(process->pid, SIGKILL); waitpid(process->pid, &status, 0); }
    free(process);
}
