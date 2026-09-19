// Jeansh's check of the Windows command line fix in src/flutter_pty_win.c.
// Windows only, and outside the Flutter build: from a Developer Command Prompt
//
//   cl /nologo /W3 third_party\flutter_pty\test\windows_pty_test.c shell32.lib
//   windows_pty_test.exe            the command line checks alone
//   windows_pty_test.exe Ubuntu     and a real shell in that WSL distro,
//                                   through ConPTY, as the app starts one
//
// It exits 0 when every check holds.
#include "../src/flutter_pty.c"

#include <shellapi.h>

static int failures = 0;

// [arguments], as build_command writes them and Windows reads them back.
static void check_round_trip(char **arguments)
{
    LPWSTR command = build_command(arguments[0], arguments);
    int count = 0;
    LPWSTR *parsed = CommandLineToArgvW(command, &count);

    int expected = 0;
    while (arguments[expected] != NULL)
    {
        expected++;
    }

    int ok = parsed != NULL && count == expected;
    for (int i = 0; ok && i < count; i++)
    {
        LPWSTR want = utf8_to_wide(arguments[i], -1);
        ok = wcscmp(want, parsed[i]) == 0;
        free(want);
    }

    printf("%s  %ls\n", ok ? "ok  " : "FAIL", command);
    if (!ok)
    {
        failures++;
    }
    LocalFree(parsed);
    free(command);
}

static HANDLE exited;
static DWORD exit_code_seen;

static bool post_output(Dart_Port_DL port, Dart_CObject *message)
{
    fwrite(message->value.as_typed_data.values, 1,
           message->value.as_typed_data.length, stdout);
    fflush(stdout);
    return true;
}

static bool post_exit(Dart_Port_DL port, int64_t code)
{
    exit_code_seen = (DWORD)code;
    SetEvent(exited);
    return true;
}

// The distro's shell in a pseudo console, started as LocalTransport starts it,
// told to say where it is and leave.
static void run_wsl(char *distro)
{
    char wsl[MAX_PATH];
    snprintf(wsl, sizeof(wsl), "%s\\System32\\wsl.exe", getenv("SystemRoot"));

    char *arguments[] = {wsl, "-d", distro, "--cd", "~", NULL};

    // The whole environment, as LocalTransport hands it over, and TERM named
    // in WSLENV so it reaches the shell.
    extern char **_environ;
    int count = 0;
    while (_environ[count] != NULL)
    {
        count++;
    }
    char **environment = calloc(count + 3, sizeof(char *));
    int n = 0;
    for (int i = 0; i < count; i++)
    {
        if (_strnicmp(_environ[i], "WSLENV=", 7) != 0 &&
            _strnicmp(_environ[i], "TERM=", 5) != 0)
        {
            environment[n++] = _environ[i];
        }
    }
    environment[n++] = "TERM=xterm-256color";
    environment[n++] = "WSLENV=TERM";

    Dart_PostCObject_DL = post_output;
    Dart_PostInteger_DL = post_exit;
    exited = CreateEvent(NULL, TRUE, FALSE, NULL);

    PtyOptions options = {0};
    options.rows = 25;
    options.cols = 120;
    options.executable = wsl;
    options.arguments = arguments;
    options.environment = environment;
    options.working_directory = getenv("USERPROFILE");

    PtyHandle *pty = pty_create(&options);
    if (pty == NULL)
    {
        printf("FAIL  pty_create: %s\n", pty_error());
        failures++;
        return;
    }

    char *typed = "pwd; uname -a; echo \"TERM=$TERM\"; exit\r";
    Sleep(3000);
    pty_write(pty, typed, (int)strlen(typed));

    if (WaitForSingleObject(exited, 30000) != WAIT_OBJECT_0)
    {
        printf("\nFAIL  the shell did not exit within 30 s\n");
        failures++;
        return;
    }
    printf("\n%s  the shell exited with %lu\n",
           exit_code_seen == 0 ? "ok  " : "FAIL", exit_code_seen);
    if (exit_code_seen != 0)
    {
        failures++;
    }
}

int main(int argc, char **argv)
{
    SetConsoleOutputCP(CP_UTF8);

    check_round_trip((char *[]){"C:\\Windows\\System32\\wsl.exe", "-d", "Ubuntu-22.04", "--cd", "~", NULL});
    check_round_trip((char *[]){"C:\\Program Files\\Git\\bin\\bash.exe", "-l", NULL});
    check_round_trip((char *[]){"prog", "", "a b", "tab\there", NULL});
    check_round_trip((char *[]){"prog", "say \"hi\"", "trailing\\", "dir\\ with space\\", NULL});
    check_round_trip((char *[]){"prog", "a\\\\\"b", "\\\\server\\share", "sh -c 'echo \"$HOME\"'", NULL});
    check_round_trip((char *[]){"prog", "caf\xC3\xA9", "\xE6\x97\xA5\xE6\x9C\xAC", NULL});

    if (argc > 1)
    {
        run_wsl(argv[1]);
    }

    printf("%s\n", failures == 0 ? "all checks hold" : "SOME CHECKS FAILED");
    return failures == 0 ? 0 : 1;
}
