// Times pty_destroy against a real ConPTY whose child will not let its console
// host go, and reports how long the release actually took afterwards.
//
// A harness rather than a Dart test because the plugin's DLL only exists inside
// a built app -- `flutter test` cannot load it, the same reason
// fd_lifecycle_harness.c exists on the POSIX side. Driven by
// test/tooling/pty_destroy_timing_test.dart, which compiles and runs this.
//
// Two modes in one executable, so there is only one thing to build:
//
//   --child   Installs a console control handler that swallows CTRL_CLOSE_EVENT
//             and sleeps inside it, then sleeps again. Closing a pseudoconsole
//             asks the attached clients to leave and waits for them, so this is
//             the harness's stand-in for the case the fix exists for: a pane
//             whose child ignores the kill (a WSL session whose Linux side
//             keeps running was the one in the 2026-09-10 minidump). Windows
//             ends a process a few seconds after CTRL_CLOSE_EVENT regardless,
//             which is what bounds the run.
//
//   default   Creates a pty running this same executable with --child, times
//             pty_destroy, then waits to see when the child finally goes.
//
// Prints "destroy_ms=<n> child_gone_ms=<n|-1>" and exits non-zero if
// pty_destroy took kMaxDestroyMs or more -- the whole contract being that it
// returns rather than waiting for any of that.
//
// Usage: conpty_destroy_harness [--child]

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <Windows.h>

#include "flutter_pty.h"
#include "include/dart_api_dl.h"

// pty_destroy must come back at once. Generous by three orders of magnitude
// against the failure it guards -- which is not "slow" but "never".
#define kMaxDestroyMs 100

// How long the parent waits to see the child go before giving up on the
// question and killing it. The interesting reading is that this is far larger
// than destroy_ms, which is the release outliving the call that asked for it.
#define kChildWaitMs 10000

// The plugin posts output and exit codes through these. Nothing is listening
// here, so they are pointed at no-ops: the port machinery is not what is under
// test, the teardown's timing is.
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

static BOOL WINAPI swallow_console_close(DWORD type)
{
    if (type == CTRL_CLOSE_EVENT || type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT)
    {
        // TRUE says "handled", and blocking here is what actually holds the
        // console host open. The system ends this process anyway once its own
        // grace period runs out, so nothing here can outlive the test by much.
        Sleep(20000);
        return TRUE;
    }

    return FALSE;
}

static int run_child(void)
{
    SetConsoleCtrlHandler(swallow_console_close, TRUE);

    printf("child up\n");
    fflush(stdout);

    // A self-bound, so a harness that is killed mid-run leaves nothing behind
    // for more than this.
    Sleep(30000);

    return 0;
}

static double elapsed_ms(LARGE_INTEGER from, LARGE_INTEGER to, LARGE_INTEGER frequency)
{
    return (double)(to.QuadPart - from.QuadPart) * 1000.0 / (double)frequency.QuadPart;
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "--child") == 0)
    {
        return run_child();
    }

    Dart_PostCObject_DL = stub_post_cobject;
    Dart_PostInteger_DL = stub_post_integer;

    char self[MAX_PATH];

    if (GetModuleFileNameA(NULL, self, MAX_PATH) == 0)
    {
        fprintf(stderr, "cannot find my own path\n");
        return 2;
    }

    // `build_command` concatenates the executable and argv with spaces and
    // quotes nothing, so a path with a space in it would spawn the wrong thing.
    // The runner builds somewhere without one; say so rather than misreport.
    if (strchr(self, ' ') != NULL)
    {
        fprintf(stderr, "harness path contains a space: %s\n", self);
        return 2;
    }

    char *arguments[] = {"--child", NULL};

    // `build_environment` turns a NULL list into a block holding a single null,
    // which `CreateProcessW` rejects with ERROR_INVALID_PARAMETER -- a real
    // block ends in two. The app always passes an environment (see
    // `_ptyEnvironment`), so this is the harness matching its caller rather
    // than working around anything. SystemRoot is the one a Windows child
    // genuinely cannot start without.
    char system_root[MAX_PATH + 16];
    const char *root = getenv("SystemRoot");
    snprintf(system_root, sizeof(system_root), "SystemRoot=%s",
             root != NULL ? root : "C:\\Windows");

    char *environment[] = {system_root, NULL};

    PtyOptions options;
    memset(&options, 0, sizeof(options));
    options.rows = 24;
    options.cols = 80;
    options.executable = self;
    options.arguments = arguments;
    options.environment = environment;
    options.working_directory = NULL;
    options.stdout_port = 0;
    options.exit_port = 0;
    options.ackRead = false;

    PtyHandle *handle = pty_create(&options);

    if (handle == NULL)
    {
        fprintf(stderr, "pty_create failed: %s\n", pty_error());
        return 2;
    }

    // Long enough for the child to have installed its handler. `pty_create`
    // already sleeps a second of its own waiting for conhost.
    Sleep(1500);

    // Read before the destroy: afterwards the handle belongs to the worker.
    int pid = pty_getpid(handle);
    HANDLE child = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);

    LARGE_INTEGER frequency;
    LARGE_INTEGER before;
    LARGE_INTEGER after;
    QueryPerformanceFrequency(&frequency);

    QueryPerformanceCounter(&before);
    pty_destroy(handle);
    QueryPerformanceCounter(&after);

    double destroy_ms = elapsed_ms(before, after, frequency);

    // How long the release the worker is doing actually takes. A number far
    // larger than destroy_ms is the deferral, observed rather than argued.
    double child_gone_ms = -1.0;

    if (child != NULL)
    {
        DWORD waited = WaitForSingleObject(child, kChildWaitMs);

        if (waited == WAIT_OBJECT_0)
        {
            LARGE_INTEGER gone;
            QueryPerformanceCounter(&gone);
            child_gone_ms = elapsed_ms(before, gone, frequency);
        }
        else
        {
            // Still there. Nothing this harness starts may outlive it.
            HANDLE victim = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)pid);

            if (victim != NULL)
            {
                TerminateProcess(victim, 1);
                CloseHandle(victim);
            }
        }

        CloseHandle(child);
    }

    printf("destroy_ms=%.1f child_gone_ms=%.1f\n", destroy_ms, child_gone_ms);
    fflush(stdout);

    return destroy_ms >= (double)kMaxDestroyMs ? 1 : 0;
}
