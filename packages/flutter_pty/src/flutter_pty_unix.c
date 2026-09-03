
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

#include "forkpty.h"
#include "flutter_pty.h"

#include "include/dart_api.h"
#include "include/dart_api_dl.h"
#include "include/dart_native_api.h"

typedef struct PtyHandle
{
    int ptm;

    int pid;

    pthread_mutex_t mutex;

    bool ackRead;

    // --- vendored fork: lifecycle. See VENDORED.md. ---

    // Guards `ptm`, `wake`, `destroyed` and `reader_alive`. Deliberately not
    // `mutex`, which belongs to the ackRead flow control and is held across the
    // read thread's blocking read — taking it here would deadlock.
    pthread_mutex_t lifecycle;

    // Self-pipe used to wake the read thread out of poll(). Closing `ptm` to
    // wake it instead would be a use-after-free on the descriptor *number*: the
    // kernel can hand the same int to another thread's open() before the
    // blocked read returns, and the read would then land on that file.
    int wake[2];

    // pty_destroy has been called; whoever finishes last frees the handle.
    bool destroyed;

    // The read thread has not returned yet.
    bool reader_alive;

} PtyHandle;

typedef struct ReadLoopOptions
{
    // The pty this loop reads. Owned by `handle`; kept here so the hot path
    // does not have to dereference through the handle on every read.
    int fd;

    struct PtyHandle *handle;

    pthread_mutex_t *mutex;

    Dart_Port port;

    bool waitForReadAck;

} ReadLoopOptions;

char *error_message = NULL;

// Frees a handle nobody can reach any more. Callers must hold no lock.
static void destroy_handle(PtyHandle *handle)
{
    if (handle->ptm >= 0)
    {
        close(handle->ptm);
    }
    if (handle->wake[0] >= 0)
    {
        close(handle->wake[0]);
    }
    if (handle->wake[1] >= 0)
    {
        close(handle->wake[1]);
    }
    pthread_mutex_destroy(&handle->mutex);
    pthread_mutex_destroy(&handle->lifecycle);
    free(handle);
}

static void *read_loop(void *arg)
{
    ReadLoopOptions *options = (ReadLoopOptions *)arg;
    PtyHandle *handle = options->handle;

    char buffer[1024];

    // Two sources: the pty, and pty_destroy's wake pipe. Upstream blocked
    // directly in read(), which is why there was no way to stop this thread
    // short of the child exiting -- and why the descriptor outlived the pane.
    struct pollfd fds[2];
    fds[0].fd = options->fd;
    fds[0].events = POLLIN;
    fds[1].fd = handle->wake[0];
    fds[1].events = POLLIN;

    while (1)
    {
        if (options->waitForReadAck)
        {
            // if we are in ack mode then we get a mutex here that is
            // freed again once the chunk of data has been processed
            pthread_mutex_lock(options->mutex);
        }

        int ready = poll(fds, 2, -1);

        if (ready < 0)
        {
            if (errno == EINTR)
            {
                // Not an error: retry. Unlock first, the next iteration locks.
                if (options->waitForReadAck)
                {
                    pthread_mutex_unlock(options->mutex);
                }
                continue;
            }
            break;
        }

        // Asked to stop. Checked before the pty so a destroy during a burst of
        // output still ends the thread promptly.
        if (fds[1].revents != 0)
        {
            break;
        }

        if ((fds[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) == 0)
        {
            if (options->waitForReadAck)
            {
                pthread_mutex_unlock(options->mutex);
            }
            continue;
        }

        ssize_t n = read(options->fd, buffer, sizeof(buffer));

        if (n < 0)
        {
            // TODO: handle error
            break;
        }

        if (n == 0)
        {
            break;
        }

        Dart_CObject result;
        result.type = Dart_CObject_kTypedData;
        result.value.as_typed_data.type = Dart_TypedData_kUint8;
        result.value.as_typed_data.length = n;
        result.value.as_typed_data.values = (uint8_t *)buffer;

        Dart_PostCObject_DL(options->port, &result);
    }

    // Held if we broke out mid-iteration; released before the mutex is
    // destroyed under us.
    if (options->waitForReadAck)
    {
        pthread_mutex_unlock(options->mutex);
    }

    // This thread owns the pty descriptor's lifetime: closing it here is what
    // stops a finished pane from stranding one. Upstream returned without
    // closing anything, which is the leak this fork exists to fix -- ~1 fd and
    // one never-freed ReadLoopOptions per pane, for the life of the process.
    pthread_mutex_lock(&handle->lifecycle);
    handle->reader_alive = false;
    if (handle->ptm >= 0)
    {
        close(handle->ptm);
        handle->ptm = -1;
    }
    if (handle->wake[0] >= 0)
    {
        close(handle->wake[0]);
        handle->wake[0] = -1;
    }
    bool orphaned = handle->destroyed;
    pthread_mutex_unlock(&handle->lifecycle);

    free(options);

    // pty_destroy already ran and left the handle to us.
    if (orphaned)
    {
        destroy_handle(handle);
    }

    return NULL;
}

static void start_read_thread(PtyHandle *handle, Dart_Port port, bool waitForReadAck)
{
    ReadLoopOptions *options = malloc(sizeof(ReadLoopOptions));

    options->fd = handle->ptm;

    options->handle = handle;

    options->port = port;

    options->mutex = &handle->mutex;

    options->waitForReadAck = waitForReadAck;

    pthread_t _thread;

    if (pthread_create(&_thread, NULL, &read_loop, options) == 0)
    {
        // Nothing ever joins this thread, so without detaching it the kernel
        // keeps its stack and descriptor alive after it returns -- a second
        // per-pane leak alongside the descriptor.
        pthread_detach(_thread);
    }
    else
    {
        pthread_mutex_lock(&handle->lifecycle);
        handle->reader_alive = false;
        pthread_mutex_unlock(&handle->lifecycle);
        free(options);
    }
}

typedef struct WaitExitOptions
{
    int pid;

    Dart_Port port;

} WaitExitOptions;

static void *wait_exit_thread(void *arg)
{
    WaitExitOptions *options = (WaitExitOptions *)arg;

    int status;

    waitpid(options->pid, &status, 0);

    if (WIFEXITED(status))
    {
        Dart_PostInteger_DL(options->port, WEXITSTATUS(status));
    }
    else if (WIFSIGNALED(status))
    {
        Dart_PostInteger_DL(options->port, -WTERMSIG(status));
    }

    // Upstream returned without freeing: one small allocation per pane, never
    // reclaimed.
    free(options);

    return NULL;
}

static void start_wait_exit_thread(int pid, Dart_Port port)
{
    WaitExitOptions *options = malloc(sizeof(WaitExitOptions));

    options->pid = pid;

    options->port = port;

    pthread_t _thread;

    if (pthread_create(&_thread, NULL, &wait_exit_thread, options) == 0)
    {
        pthread_detach(_thread);
    }
    else
    {
        free(options);
    }
}

static void set_environment(char **environment)
{
    if (environment == NULL)
    {
        return;
    }

    while (*environment != NULL)
    {
        putenv(*environment);
        environment++;
    }
}

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options)
{
    struct winsize ws;

    ws.ws_row = options->rows;
    ws.ws_col = options->cols;

    int ptm;

    int pid = pty_forkpty(&ptm, NULL, NULL, &ws);

    if (pid < 0)
    {
        error_message = "pty_forkpty failed";
        perror("pty_forkpty");
        return NULL;
    }

    if (pid == 0)
    {
        set_environment(options->environment);

        if (options->working_directory != NULL && strlen(options->working_directory) > 0)
        {
            chdir(options->working_directory);
        }

        int ok = execvp(options->executable, options->arguments);

        if (ok < 0)
        {
            perror("execvp");
        }

        // Upstream fell through here, so a child whose exec failed carried on
        // running the *parent's* code — allocating a handle, starting threads
        // and returning into the Flutter engine as a forked copy. A pane
        // pointed at a shell that is not installed is an ordinary user error,
        // not a reason to have two engines.
        _exit(127);
    }

    PtyHandle *handle = (PtyHandle *)malloc(sizeof(PtyHandle));

    handle->ptm = ptm;
    handle->pid = pid;
    pthread_mutex_init(&handle->mutex, NULL);
    handle->ackRead = options->ackRead;

    pthread_mutex_init(&handle->lifecycle, NULL);
    handle->destroyed = false;
    handle->reader_alive = true;
    if (pipe(handle->wake) != 0)
    {
        // Without the wake pipe the reader can still be ended by the child
        // exiting, so a pty that cannot get two descriptors is degraded rather
        // than fatal -- pty_destroy just cannot cut it short.
        handle->wake[0] = -1;
        handle->wake[1] = -1;
    }

    start_read_thread(handle, options->stdout_port, options->ackRead);

    start_wait_exit_thread(pid, options->exit_port);

    return handle;
}

FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length)
{
    pthread_mutex_lock(&handle->lifecycle);
    if (handle->ptm >= 0)
    {
        ssize_t written = write(handle->ptm, buffer, length);
        (void)written;
    }
    pthread_mutex_unlock(&handle->lifecycle);
}

FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle)
{
    if (handle->ackRead)
    {
        // frees the mutex so that the next chunk of data can be read
        pthread_mutex_unlock(&handle->mutex);
    }
}

FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols)
{
    struct winsize ws;

    ws.ws_row = rows;
    ws.ws_col = cols;

    pthread_mutex_lock(&handle->lifecycle);
    int result = handle->ptm >= 0 ? ioctl(handle->ptm, TIOCSWINSZ, &ws) : -1;
    pthread_mutex_unlock(&handle->lifecycle);

    return result;
}

FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle)
{
    return handle->pid;
}

// Releases the pty. Idempotent, and safe to call whether or not the child has
// already exited -- whichever of this and the read thread finishes last frees
// the handle, so neither can leave the other with a dangling pointer.
//
// After this returns the handle must not be used again.
FFI_PLUGIN_EXPORT void pty_destroy(PtyHandle *handle)
{
    if (handle == NULL)
    {
        return;
    }

    pthread_mutex_lock(&handle->lifecycle);

    if (handle->destroyed)
    {
        pthread_mutex_unlock(&handle->lifecycle);
        return;
    }

    handle->destroyed = true;
    bool reader_alive = handle->reader_alive;

    if (handle->wake[1] >= 0)
    {
        if (reader_alive)
        {
            ssize_t poked = write(handle->wake[1], "x", 1);
            (void)poked;
        }
        close(handle->wake[1]);
        handle->wake[1] = -1;
    }

    pthread_mutex_unlock(&handle->lifecycle);

    // The read thread frees the handle when it wakes; freeing it here would
    // pull the lifecycle mutex out from under it.
    if (!reader_alive)
    {
        destroy_handle(handle);
    }
}

FFI_PLUGIN_EXPORT char *pty_error(void)
{
    return NULL;
}
