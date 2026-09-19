#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <Windows.h>

#include "flutter_pty.h"

#include "include/dart_api.h"
#include "include/dart_api_dl.h"
#include "include/dart_native_api.h"

// Jeansh: build_command, build_environment and build_working_directory replace
// 0.4.2's, which wrote the executable into the command line twice
// (arguments[0] is the executable already, as execvp wants it on Unix),
// quoted nothing, and widened UTF-8 a byte at a time. So `wsl.exe -d Ubuntu`
// reached wsl.exe as `wsl.exe wsl.exe -d Ubuntu`, which it took for a Linux
// command to run. Upstream: TerminalStudio/flutter_pty issue 19 and pull
// request 22, neither merged.

// UTF-8 as UTF-16, newly allocated. [length] bytes of it, or up to its NUL
// when -1; NULs inside are kept, which an environment block is made of.
static LPWSTR utf8_to_wide(const char *text, int length)
{
    int wide_length = MultiByteToWideChar(CP_UTF8, 0, text, length, NULL, 0);

    if (wide_length <= 0)
    {
        return NULL;
    }

    LPWSTR wide = malloc(wide_length * sizeof(WCHAR));

    if (wide != NULL)
    {
        MultiByteToWideChar(CP_UTF8, 0, text, length, wide, wide_length);
    }

    return wide;
}

// Writes [argument] at [out] the way the Microsoft C runtime and
// CommandLineToArgvW read it back as one argument, and returns the end.
// Writes at most 2 * strlen(argument) + 2 bytes.
static char *append_quoted(char *out, const char *argument)
{
    if (*argument != 0 && strpbrk(argument, " \t\n\v\"") == NULL)
    {
        size_t length = strlen(argument);
        memcpy(out, argument, length);
        return out + length;
    }

    *out++ = '"';

    for (const char *p = argument;; p++)
    {
        size_t backslashes = 0;

        while (*p == '\\')
        {
            p++;
            backslashes++;
        }

        if (*p == 0)
        {
            // Doubled, so the closing quote stays a quote.
            for (size_t i = 0; i < backslashes * 2; i++)
            {
                *out++ = '\\';
            }
            break;
        }

        if (*p == '"')
        {
            // Doubled, and one more for the quote itself.
            for (size_t i = 0; i < backslashes * 2 + 1; i++)
            {
                *out++ = '\\';
            }
        }
        else
        {
            for (size_t i = 0; i < backslashes; i++)
            {
                *out++ = '\\';
            }
        }

        *out++ = *p;
    }

    *out++ = '"';

    return out;
}

// The command line for CreateProcessW: every one of [arguments], the first of
// which is the executable, each quoted as it needs.
static LPWSTR build_command(char *executable, char **arguments)
{
    char *fallback[] = {executable, NULL};
    char **argv = arguments != NULL && arguments[0] != NULL ? arguments : fallback;

    size_t size = 1;

    for (int i = 0; argv[i] != NULL; i++)
    {
        size += 2 * strlen(argv[i]) + 3;
    }

    char *line = malloc(size);

    if (line == NULL)
    {
        return NULL;
    }

    char *out = line;

    for (int i = 0; argv[i] != NULL; i++)
    {
        if (i > 0)
        {
            *out++ = ' ';
        }
        out = append_quoted(out, argv[i]);
    }

    *out = 0;

    LPWSTR command = utf8_to_wide(line, -1);

    free(line);

    return command;
}

// `NAME=value` strings, each ending in a NUL, and one more NUL after the last.
static LPWSTR build_environment(char **environment)
{
    if (environment == NULL)
    {
        return NULL;
    }

    size_t size = 1;

    for (int i = 0; environment[i] != NULL; i++)
    {
        size += strlen(environment[i]) + 1;
    }

    char *block = malloc(size);

    if (block == NULL)
    {
        return NULL;
    }

    char *out = block;

    for (int i = 0; environment[i] != NULL; i++)
    {
        size_t length = strlen(environment[i]) + 1;
        memcpy(out, environment[i], length);
        out += length;
    }

    *out = 0;

    LPWSTR wide = utf8_to_wide(block, (int)size);

    free(block);

    return wide;
}

static LPWSTR build_working_directory(char *working_directory)
{
    if (working_directory == NULL)
    {
        return NULL;
    }

    return utf8_to_wide(working_directory, -1);
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

FFI_PLUGIN_EXPORT char *pty_error()
{
    return error_message;
}
