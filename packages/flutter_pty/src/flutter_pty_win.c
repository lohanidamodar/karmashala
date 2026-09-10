#include <stdio.h>
#include <Windows.h>

#include "flutter_pty.h"

#include "include/dart_api.h"
#include "include/dart_api_dl.h"
#include "include/dart_native_api.h"

static LPWSTR build_command(char *executable, char **arguments)
{
    int command_length = 0;

    if (executable != NULL)
    {
        command_length += (int)strlen(executable);
    }

    if (arguments != NULL)
    {
        int i = 0;

        while (arguments[i] != NULL)
        {
            command_length += (int)strlen(arguments[i]) + 1;
            i++;
        }
    }

    LPWSTR command = malloc((command_length + 1) * sizeof(WCHAR));

    if (command != NULL)
    {
        int i = 0;

        if (executable != NULL)
        {
            int j = 0;

            while (executable[j] != 0)
            {
                command[i] = (WCHAR)executable[j];
                i++;
                j++;
            }
        }

        if (arguments != NULL)
        {
            int j = 0;

            while (arguments[j] != NULL)
            {
                command[i++] = ' ';

                int k = 0;

                while (arguments[j][k] != 0)
                {
                    command[i] = (WCHAR)arguments[j][k];
                    i++;
                    k++;
                }

                j++;
            }
        }

        command[i] = 0;
    }

    return command;
}

static LPWSTR build_environment(char **environment)
{
    LPWSTR environment_block = NULL;
    int environment_block_length = 0;

    if (environment != NULL)
    {
        int i = 0;

        while (environment[i] != NULL)
        {
            environment_block_length += (int)strlen(environment[i]) + 1;
            i++;
        }
    }

    environment_block = malloc((environment_block_length + 1) * sizeof(WCHAR));

    if (environment_block != NULL)
    {
        int i = 0;

        if (environment != NULL)
        {
            int j = 0;

            while (environment[j] != NULL)
            {
                int k = 0;

                while (environment[j][k] != 0)
                {
                    environment_block[i] = (WCHAR)environment[j][k];
                    i++;
                    k++;
                }

                environment_block[i++] = 0;

                j++;
            }
        }

        environment_block[i] = 0;
    }

    return environment_block;
}

static LPWSTR build_working_directory(char *working_directory)
{
    if (working_directory == NULL)
    {
        return NULL;
    }

    int working_directory_length = (int)strlen(working_directory);

    LPWSTR working_directory_block = malloc((working_directory_length + 1) * sizeof(WCHAR));

    if (working_directory_block == NULL)
    {
        return NULL;
    }

    int i = 0;

    while (working_directory[i] != 0)
    {
        working_directory_block[i] = (WCHAR)working_directory[i++];
    }

    working_directory_block[i] = 0;

    return working_directory_block;
}

typedef struct ReadLoopOptions
{
    HANDLE fd;

    Dart_Port port;

    HANDLE hMutex;

    BOOL ackRead;

} ReadLoopOptions;

static DWORD WINAPI read_loop(LPVOID arg)
{
    ReadLoopOptions *options = (ReadLoopOptions *)arg;

    char buffer[1024];

    while (1)
    {
        DWORD readlen = 0;

        if (options->ackRead)
        {
            WaitForSingleObject(options->hMutex, INFINITE);
        }

        BOOL ok = ReadFile(options->fd, buffer, sizeof(buffer), &readlen, NULL);

        if (!ok)
        {
            break;
        }

        if (readlen <= 0)
        {
            break;
        }

        Dart_CObject result;
        result.type = Dart_CObject_kTypedData;
        result.value.as_typed_data.type = Dart_TypedData_kUint8;
        result.value.as_typed_data.length = readlen;
        result.value.as_typed_data.values = (uint8_t *)buffer;

        Dart_PostCObject_DL(options->port, &result);
    }

    // Upstream returned without freeing: one allocation per pane, never
    // reclaimed. See VENDORED.md.
    free(options);

    return 0;
}

static void start_read_thread(HANDLE fd, Dart_Port port, HANDLE mutex, BOOL ackRead)
{
    ReadLoopOptions *options = malloc(sizeof(ReadLoopOptions));

    options->fd = fd;
    options->port = port;
    options->hMutex = mutex;
    options->ackRead = ackRead;

    DWORD thread_id;

    HANDLE thread = CreateThread(NULL, 0, read_loop, options, 0, &thread_id);

    if (thread == NULL)
    {
        free(options);
    }
    else
    {
        // Not a cancel: this drops our reference so the kernel can reclaim the
        // thread when it returns. Nothing ever joins it. Win32's pthread_detach.
        CloseHandle(thread);
    }
}

typedef struct WaitExitOptions
{
    HANDLE pid;

    Dart_Port port;

    HANDLE hMutex;
} WaitExitOptions;

static DWORD WINAPI wait_exit_thread(LPVOID arg)
{
    WaitExitOptions *options = (WaitExitOptions *)arg;

    DWORD exit_code = 0;

    WaitForSingleObject(options->pid, INFINITE);

    GetExitCodeProcess(options->pid, &exit_code);

    CloseHandle(options->pid);
    CloseHandle(options->hMutex);

    Dart_PostInteger_DL(options->port, exit_code);

    free(options);

    return 0;
}

static void start_wait_exit_thread(HANDLE pid, Dart_Port port, HANDLE mutex)
{
    WaitExitOptions *options = malloc(sizeof(WaitExitOptions));

    options->pid = pid;
    options->port = port;
    options->hMutex = mutex;

    DWORD thread_id;

    HANDLE thread = CreateThread(NULL, 0, wait_exit_thread, options, 0, &thread_id);

    if (thread == NULL)
    {
        free(options);
    }
    else
    {
        CloseHandle(thread);
    }
}

typedef struct PtyHandle
{
    PHANDLE inputWriteSide;

    PHANDLE outputReadSide;

    HPCON hPty;

    DWORD dwProcessId;

    BOOL ackRead;

    HANDLE hMutex;

} PtyHandle;

char *error_message = NULL;

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options)
{
    HANDLE inputReadSide = NULL;
    HANDLE inputWriteSide = NULL;

    HANDLE outputReadSide = NULL;
    HANDLE outputWriteSide = NULL;

    if (!CreatePipe(&inputReadSide, &inputWriteSide, NULL, 0))
    {
        error_message = "Failed to create input pipe";
        return NULL;
    }

    if (!CreatePipe(&outputReadSide, &outputWriteSide, NULL, 0))
    {
        error_message = "Failed to create output pipe";
        return NULL;
    }

    COORD size;

    size.X = options->cols;
    size.Y = options->rows;

    HPCON hPty;

    HRESULT result = CreatePseudoConsole(size, inputReadSide, outputWriteSide, 0, &hPty);

    if (FAILED(result))
    {
        error_message = "Failed to create pseudo console";
        return NULL;
    }

    STARTUPINFOEX startupInfo;

    ZeroMemory(&startupInfo, sizeof(startupInfo));
    startupInfo.StartupInfo.cb = sizeof(startupInfo);

    startupInfo.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startupInfo.StartupInfo.hStdInput = NULL;
    startupInfo.StartupInfo.hStdOutput = NULL;
    startupInfo.StartupInfo.hStdError = NULL;

    SIZE_T bytesRequired;
    InitializeProcThreadAttributeList(NULL, 1, 0, &bytesRequired);
    startupInfo.lpAttributeList = (PPROC_THREAD_ATTRIBUTE_LIST)malloc(bytesRequired);

    BOOL ok = InitializeProcThreadAttributeList(startupInfo.lpAttributeList, 1, 0, &bytesRequired);

    if (!ok)
    {
        error_message = "Failed to initialize proc thread attribute list";
        return NULL;
    }

    ok = UpdateProcThreadAttribute(startupInfo.lpAttributeList,
                                   0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   hPty,
                                   sizeof(hPty),
                                   NULL,
                                   NULL);

    if (!ok)
    {
        error_message = "Failed to update proc thread attribute list";
        return NULL;
    }

    LPWSTR command = build_command(options->executable, options->arguments);

    LPWSTR environment_block = build_environment(options->environment);

    LPWSTR working_directory = build_working_directory(options->working_directory);

    PROCESS_INFORMATION processInfo;
    ZeroMemory(&processInfo, sizeof(processInfo));

    // DIVERGENCE (Karmashala): upstream 0.4.2's `Sleep(1000)`, restored after it
    // was removed and shipped in 1.10.0. Removing it froze the app hard enough
    // to need Task Manager, and the mechanism is not the spawn -- it is the
    // *resize*. `terminal.onResize` calls `pty_resize` -> `ResizePseudoConsole`
    // synchronously on the UI isolate, and the first one fires as soon as the
    // pane lays out. Against a conhost that has not finished coming up that
    // call does not return, so the isolate never produces another frame.
    //
    // So the second is not protecting the spawn, which is why removing it
    // looked safe: `CreatePseudoConsole` really has returned a valid HPCON and
    // the reader threads really do start later. It is protecting every
    // *subsequent* ConPTY call from reaching an uninitialised conhost, and a
    // blind sleep is a bad way to do that. The honest fix is to stop making
    // blocking ConPTY calls from the UI isolate at all, or to gate the first
    // resize on evidence the child is actually up; until one of those exists
    // and is verified against a real ConPTY, the second stays.
    //
    // Verify with `powershell tool/live_tests.ps1 -Family wsl` before touching
    // this again -- `live_pane_resize_test.dart` is the case that matters.
    Sleep(1000);

    ok = CreateProcessW(NULL,
                        command,
                        NULL,
                        NULL,
                        FALSE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                        environment_block,
                        working_directory,
                        &startupInfo.StartupInfo,
                        &processInfo);

    if (command != NULL)
    {
        free(command);
    }

    if (environment_block != NULL)
    {
        free(environment_block);
    }

    if (working_directory != NULL)
    {
        free(working_directory);
    }

    if (!ok)
    {
        error_message = "Failed to create process";
        DWORD error = GetLastError();
        printf("error no: %d\n", error);
        return NULL;
    }

    // free(startupInfo.lpAttributeList);

    // CloseHandle(processInfo.hThread);

    HANDLE mutex = CreateSemaphore(
        NULL, // default security attributes
        1,    // initial count
        1,    // maximum count
        NULL);

    start_read_thread(outputReadSide, options->stdout_port, mutex, options->ackRead);

    start_wait_exit_thread(processInfo.hProcess, options->exit_port, mutex);

    PtyHandle *pty = malloc(sizeof(PtyHandle));

    if (pty == NULL)
    {
        error_message = "Failed to allocate pty handle";
        return NULL;
    }

    pty->inputWriteSide = inputWriteSide;
    pty->outputReadSide = outputReadSide;
    pty->hPty = hPty;
    pty->dwProcessId = processInfo.dwProcessId;
    pty->ackRead = options->ackRead;
    pty->hMutex = mutex;

    return pty;
}

FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length)
{
    DWORD bytesWritten;

    WriteFile(handle->inputWriteSide, buffer, length, &bytesWritten, NULL);

    FlushFileBuffers(handle->inputWriteSide);

    return;
}

FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle)
{
    if (handle->ackRead)
    {
        ReleaseSemaphore(handle->hMutex, 1, NULL);
    }
}

FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols)
{
    COORD size;

    size.X = cols;
    size.Y = rows;

    return ResizePseudoConsole(handle->hPty, size);
}

FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle)
{
    return (int)handle->dwProcessId;
}

// Releases the pseudoconsole, the output pipe and the handle itself. Runs on a
// detached worker thread, and that is the whole point of it existing.
//
// `ClosePseudoConsole` does not return until the console host behind the pty
// has gone, and that host is a child of *this* process rather than of the
// shell -- so killing the pane's process tree does not settle it, and a child
// that ignores the kill (a WSL session whose Linux side keeps running is the
// ordinary case) holds it open indefinitely. On 2026-09-10 that call was on
// the stack of the app's blocked main thread in a minidump of a hang the owner
// had to end from Task Manager. A synchronous call that never returns takes
// the isolate with it, so no Dart-side timeout can rescue it either.
//
// Nothing joins this thread: the caller is told the pty is gone the moment
// `pty_destroy` returns, and whatever the console host does afterwards is
// between it and the OS.
static DWORD WINAPI close_console_thread(LPVOID arg)
{
    PtyHandle *handle = (PtyHandle *)arg;

    if (handle->hPty != NULL)
    {
        ClosePseudoConsole(handle->hPty);
        handle->hPty = NULL;
    }

    // After the console, never before. The reader thread is blocked in
    // `ReadFile` on this exact handle, and closing it from another thread
    // leaves that read holding a handle *value* the kernel is free to reissue
    // to the next opener -- the Win32 shape of the fd-recycling hazard the
    // POSIX half of this plugin carries a self-pipe to avoid. Waiting for
    // `ClosePseudoConsole` first is what makes the reader's exit the ordinary
    // case rather than a race, and costs nothing now that no isolate is
    // waiting for any of it.
    if (handle->outputReadSide != NULL)
    {
        CloseHandle(handle->outputReadSide);
        handle->outputReadSide = NULL;
    }

    free(handle);

    return 0;
}

// Releases the pty. **Returns immediately**; see close_console_thread for what
// finishes afterwards and why it cannot be done here.
//
// The handle must not be used afterwards -- ownership passes to the worker.
FFI_PLUGIN_EXPORT void pty_destroy(PtyHandle *handle)
{
    if (handle == NULL)
    {
        return;
    }

    // Safe on this thread, and worth doing here rather than on the worker:
    // nothing blocks on the input write side, closing it gives the child EOF
    // on its stdin, one more reason for it to leave -- and it is released now
    // rather than whenever the console host finally goes.
    if (handle->inputWriteSide != NULL)
    {
        CloseHandle(handle->inputWriteSide);
        handle->inputWriteSide = NULL;
    }

    HANDLE thread = CreateThread(NULL, 0, close_console_thread, handle, 0, NULL);

    if (thread == NULL)
    {
        // No worker to hand it to. The console, the output pipe and the handle
        // are left to the OS, which reclaims all three when the process ends --
        // deliberately, and not a fallback to closing it here. Blocking the
        // calling thread is the failure this function exists to prevent, and a
        // machine too short of resources to start a thread is the last place to
        // do it.
        return;
    }

    // Not a cancel: this drops our reference so the kernel can reclaim the
    // thread when it returns. Nothing ever joins it. Win32's pthread_detach.
    CloseHandle(thread);
}

FFI_PLUGIN_EXPORT char *pty_error()
{
    return error_message;
}
