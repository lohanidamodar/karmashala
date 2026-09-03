// Exercises pty_create/pty_destroy against the real native code and reports
// how many file descriptors the process is holding before and after.
//
// A harness rather than a Dart test because the plugin's dylib only exists
// inside a built app bundle — `flutter test` cannot load it. Driven by
// test/tooling/pty_fd_lifecycle_test.dart, which compiles and runs this.
//
// Usage: fd_lifecycle_harness <iterations>
// Prints "before=<n> after=<n>" and exits non-zero if descriptors were leaked.

#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "flutter_pty.h"
#include "include/dart_api_dl.h"

// The plugin posts output and exit codes through these. Nothing is listening
// here, so they are pointed at no-ops: the port machinery is not what is under
// test, the descriptor lifecycle is.
static bool stub_post_cobject(Dart_Port_DL port, Dart_CObject *message)
{
    (void)port;
    (void)message;
    return true;
}

static bool stub_post_integer(Dart_Port_DL port, int64_t message)
{
    (void)port;
    (void)message;
    return true;
}

static int count_open_fds(void)
{
    int open = 0;
    for (int fd = 0; fd < 1024; fd++)
    {
        if (fcntl(fd, F_GETFD) != -1)
        {
            open++;
        }
    }
    return open;
}

static void spawn_and_destroy(void)
{
    char *executable = "/usr/bin/true";
    char *arguments[] = {"/usr/bin/true", NULL};

    PtyOptions options;
    memset(&options, 0, sizeof(options));
    options.rows = 24;
    options.cols = 80;
    options.executable = executable;
    options.arguments = arguments;
    options.environment = NULL;
    options.working_directory = NULL;
    options.stdout_port = 0;
    options.exit_port = 0;
    options.ackRead = false;

    PtyHandle *handle = pty_create(&options);
    if (handle == NULL)
    {
        fprintf(stderr, "pty_create failed\n");
        exit(2);
    }

    pty_destroy(handle);
}

int main(int argc, char **argv)
{
    Dart_PostCObject_DL = stub_post_cobject;
    Dart_PostInteger_DL = stub_post_integer;

    int iterations = argc > 1 ? atoi(argv[1]) : 32;

    // One round first: the very first pty can pull in lazily-opened
    // descriptors that are not per-pty and would read as a leak.
    spawn_and_destroy();
    usleep(200 * 1000);

    int before = count_open_fds();

    for (int i = 0; i < iterations; i++)
    {
        spawn_and_destroy();
    }

    // Teardown finishes on the reader threads, so the count settles a moment
    // after the last destroy. Poll rather than sleep a fixed time.
    int after = before;
    for (int waited = 0; waited < 50; waited++)
    {
        usleep(100 * 1000);
        after = count_open_fds();
        if (after <= before)
        {
            break;
        }
    }

    printf("before=%d after=%d iterations=%d\n", before, after, iterations);

    // Any growth that scales with iterations is the leak. A couple of
    // descriptors of slack absorbs unrelated lazy opens.
    return (after - before) > 2 ? 1 : 0;
}
