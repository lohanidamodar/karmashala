#ifndef FLUTTER_PTY_H_
#define FLUTTER_PTY_H_

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

#if defined(__linux__) || defined(__GLIBC__) || defined(__GNU__)
#define _GNU_SOURCE /* GNU glibc grantpt() prototypes */
#endif

#include "include/dart_api_dl.h"

typedef struct PtyOptions
{
    int rows;

    int cols;

    char *executable;

    char **arguments;

    char **environment;

    char *working_directory;

    Dart_Port stdout_port;

    Dart_Port exit_port;

    bool ackRead;

} PtyOptions;

typedef struct PtyHandle PtyHandle;

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options);

FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length);

FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle);

FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols);

FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle);

// Releases the pty and everything behind it: the descriptor, the reader
// thread's allocation, and the handle. Idempotent; the handle must not be used
// afterwards. Added by this fork -- upstream has no way to release a pty, so a
// finished pane stranded a descriptor and a thread for the life of the process.
//
// **Returns immediately on every platform, and on Windows that is a contract
// rather than an observation.** Releasing a Windows pty means
// `ClosePseudoConsole`, which does not return until the console host has gone,
// and the host does not go while the child tree it is attached to lives -- so
// on Windows this hands the release to a detached worker thread and comes
// back. A caller may call it from a UI thread, an isolate that must keep
// producing frames, or a shutdown step with a budget; none of them will wait
// for a process. What the worker has not finished when the process ends is
// left to the OS, which is the right answer at that point anyway.
FFI_PLUGIN_EXPORT void pty_destroy(PtyHandle *handle);

FFI_PLUGIN_EXPORT char *pty_error(void);

#endif