#import <Foundation/Foundation.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <util.h>      // forkpty on macOS
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

NSData* _Nullable safeReadAvailableData(NSFileHandle* handle) {
    @try {
        // availableData should only be called when data is available
        // If it returns empty, that means EOF, so return empty data (not nil)
        // The Swift code will handle empty data appropriately
        NSData* data = [handle availableData];
        return data;
    }
    @catch (NSException* exception) {
        // File descriptor is closed or invalid - return nil to indicate error
        return nil;
    }
}

int proterm_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int proterm_forkpty_spawn(const char* shell_path,
                          const char* command,
                          int* out_master_fd,
                          unsigned short rows,
                          unsigned short cols) {
    if (!shell_path || !command || !out_master_fd) {
        return -1;
    }

    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    // You can optionally configure termios here; leaving NULL lets child set modes.
    int master_fd = -1;
    pid_t pid = forkpty(&master_fd, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }

    if (pid == 0) {
        // Child: exec the shell with -l -c command
        // Use execl to avoid needing an argv array
        // Note: Some shells expect argv[0] to be the shell name
        const char* shell = shell_path;
        // Execute: shell -l -c command
        execl(shell, shell, "-l", "-c", command, (char*)NULL);
        // If exec fails
        _exit(127);
    }

    // Parent: return master fd and child pid
    *out_master_fd = master_fd;
    return pid;
}

