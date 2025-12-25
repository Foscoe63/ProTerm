#ifndef SAFE_FILE_HANDLE_H
#define SAFE_FILE_HANDLE_H

#include <sys/types.h>

// C-only header for PTY helpers.
// Standard POSIX/BSD types are used for maximum compatibility with Swift.

// Spawn an interactive command attached to a PTY using forkpty.
int proterm_forkpty_spawn(const char *shell_path, const char *command,
                          int *out_master_fd, unsigned short rows,
                          unsigned short cols);

// Direct exec version (no shell)
int proterm_forkpty_exec(const char *command_path, char *const argv[],
                         char *const envv[], int *out_master_fd,
                         unsigned short rows, unsigned short cols);

// Terminal resize helper
int proterm_set_winsize(int fd, unsigned short rows, unsigned short cols);

#endif
