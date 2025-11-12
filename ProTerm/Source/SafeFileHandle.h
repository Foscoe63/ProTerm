#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSData* _Nullable safeReadAvailableData(NSFileHandle* handle);

// C shim for variadic-unavailable ioctl(TIOCSWINSZ)
// Returns 0 on success, -1 on failure (errno set by ioctl)
int proterm_set_winsize(int fd, unsigned short rows, unsigned short cols);

// Spawn an interactive command attached to a PTY using forkpty.
// Returns child PID on success (>= 1) and sets *out_master_fd to the master PTY fd.
// Returns -1 on failure; *out_master_fd is undefined on failure.
int proterm_forkpty_spawn(const char* shell_path,
                          const char* command,
                          int* out_master_fd,
                          unsigned short rows,
                          unsigned short cols);

NS_ASSUME_NONNULL_END

