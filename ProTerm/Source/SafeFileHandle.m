#include "SafeFileHandle.h"
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h> // forkpty on macOS

int proterm_set_winsize(int fd, unsigned short rows, unsigned short cols) {
  struct winsize ws;
  ws.ws_row = rows;
  ws.ws_col = cols;
  ws.ws_xpixel = 0;
  ws.ws_ypixel = 0;
  return ioctl(fd, TIOCSWINSZ, &ws);
}

int proterm_forkpty_spawn(const char *shell_path, const char *command,
                          int *out_master_fd, unsigned short rows,
                          unsigned short cols) {
  if (!shell_path || !command || !out_master_fd) {
    return -1;
  }

  struct winsize ws;
  ws.ws_row = rows;
  ws.ws_col = cols;
  ws.ws_xpixel = 0;
  ws.ws_ypixel = 0;

  int master_fd = -1;
  pid_t pid = forkpty(&master_fd, NULL, NULL, &ws);
  if (pid < 0) {
    return -1;
  }

  if (pid == 0) {
    // Child: exec shell with -l -c command, inheriting current environment
    // This ensures user's custom PATH (from ~/.zprofile) is available
    extern char **environ;
    execve(shell_path, (char *[]){(char *)shell_path, "-l", "-c", (char *)command, NULL}, environ);
    _exit(127);
  }

  *out_master_fd = master_fd;
  return pid;
}

int proterm_forkpty_exec(const char *command_path, char *const argv[],
                         char *const envv[], int *out_master_fd,
                         unsigned short rows, unsigned short cols) {
  if (!command_path || !argv || !out_master_fd) {
    return -1;
  }

  struct winsize ws;
  ws.ws_row = rows;
  ws.ws_col = cols;
  ws.ws_xpixel = 0;
  ws.ws_ypixel = 0;

  int master_fd = -1;
  pid_t pid = forkpty(&master_fd, NULL, NULL, &ws);
  if (pid < 0) {
    return -1;
  }

  if (pid == 0) {
    // Child: exec shell with command, inheriting current environment
    // This ensures user's custom PATH (from ~/.zshrc, ~/.bashrc, etc.) is available
    extern char **environ;
    execve(command_path, argv, environ);
    _exit(127);
  }

  *out_master_fd = master_fd;
  return pid;
}
