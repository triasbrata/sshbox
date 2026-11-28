#ifndef RUNNER_RUNNER_LOG_H_
#define RUNNER_RUNNER_LOG_H_

#include <execinfo.h>
#include <fcntl.h>
#include <glib.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// A log the runner writes itself, to runner.log beside window.txt in the data
// folder, one line at a time through write(2), so a process that ends without
// a word leaves how far it got: what the runner did to each window, and how
// the process ended, by exit or by a signal with its backtrace. Never anything
// a user typed or saw.
static int runner_log_fd = -1;

static void runner_log_open() {
  if (runner_log_fd >= 0) return;
  g_autofree gchar* dir =
      g_build_filename(g_get_user_data_dir(), APPLICATION_ID, nullptr);
  g_mkdir_with_parents(dir, 0700);
  g_autofree gchar* path = g_build_filename(dir, "runner.log", nullptr);
  runner_log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
}

static void runner_log(const char* format, ...) {
  if (runner_log_fd < 0) return;
  char text[400];
  va_list args;
  va_start(args, format);
  vsnprintf(text, sizeof(text), format, args);
  va_end(args);
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  struct tm tm;
  localtime_r(&now.tv_sec, &tm);
  char line[480];
  int n = snprintf(line, sizeof(line), "%02d:%02d:%02d.%03ld [%d] %s\n",
                   tm.tm_hour, tm.tm_min, tm.tm_sec, now.tv_nsec / 1000000,
                   getpid(), text);
  if (n > 0) {
    if (n >= (int)sizeof(line)) n = sizeof(line) - 1;
    ssize_t ignored = write(runner_log_fd, line, n);
    (void)ignored;
  }
}

static void runner_log_signal(int signal_number) {
  // Only what is safe in a handler: write(2) and backtrace_symbols_fd.
  const char* name = signal_number == SIGSEGV   ? "SIGSEGV"
                     : signal_number == SIGABRT ? "SIGABRT"
                     : signal_number == SIGBUS  ? "SIGBUS"
                     : signal_number == SIGFPE  ? "SIGFPE"
                     : signal_number == SIGILL  ? "SIGILL"
                                                : "signal";
  if (runner_log_fd >= 0) {
    ssize_t ignored = write(runner_log_fd, "fatal signal: ", 14);
    ignored = write(runner_log_fd, name, strlen(name));
    ignored = write(runner_log_fd, "\n", 1);
    (void)ignored;
    void* frames[40];
    int count = backtrace(frames, 40);
    backtrace_symbols_fd(frames, count, runner_log_fd);
  }
  signal(signal_number, SIG_DFL);
  raise(signal_number);
}

static void runner_log_exit() { runner_log("atexit: process exiting"); }

static void runner_log_start() {
  runner_log_open();
  runner_log("---- start");
  const int signals[] = {SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL};
  for (int s : signals) signal(s, runner_log_signal);
  atexit(runner_log_exit);
}

#endif  // RUNNER_RUNNER_LOG_H_
