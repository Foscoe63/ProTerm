# SSH Connection Fixes - Complete Summary

## Issues Fixed

### 1. **Legacy SSH Support for Older Devices** (latest fix)
**Problem**: Connecting to older devices (like Cisco ASA5506) which use older SSH algorithms and HMACs (Diffie-Hellman Group 1, AES-CBC, SSH-DSS, HMAC-SHA1) failed because modern OpenSSH disables these by default.

**Solution**: Added legacy algorithms AND HMACs to the SSH command arguments in both direct connections (`ssh user@host`) and saved connections (`SSHArgsBuilder`).
- `KexAlgorithms`: +diffie-hellman-group1-sha1, diffie-hellman-group14-sha1
- `HostKeyAlgorithms`: +ssh-rsa, ssh-dss
- `PubkeyAcceptedKeyTypes`: +ssh-rsa, ssh-dss
- `Ciphers`: +aes128-cbc, 3des-cbc, aes256-cbc, etc.
- `MACs`: +hmac-sha1, hmac-sha1-96, hmac-md5
- `HostKeyAlgorithms`: +ssh-rsa (Note: `ssh-dss` caused syntax errors on modern OpenSSH, so only `ssh-rsa` is enabled)

**Debugging Enabled**: Added `-vv` flag to all SSH connections, which revealed `no matching host key type found`. Enabled explicit `ssh-rsa` support to fix this.

**Files**: `TerminalSession.swift`, `SSHArgsBuilder.swift`


### 2. **Crash on Prebuilt SSH Sessions** ✅ FIXED
**Problem**: Using `DispatchQueue.main.sync` while already on the main thread caused a deadlock.
**Solution**: Changed to use `Task { @MainActor in }` with a semaphore.
**File**: `SSHSessionManager.swift`

### 3. **SSH Password Prompts Not Showing** ✅ FIXED
**Problem**: UI wasn't detecting standard SSH password prompts.
**Solution**: Extended `checkForPasswordPrompt()` to detect `user@host's password:`, `Password:`, etc.
**File**: `TerminalView.swift`

### 4. **Terminal Configuration** ✅ FIXED
**Solution**: Changed to use `cfmakeraw()` for proper SSH terminal handling.
**File**: `PTyWrapper.swift`

## Testing Instructions

### Test 1: Connect to Legacy Device
1. Open ProTerm.
2. Type: `ssh user@legacy-device-ip` (or use a saved connection).
3. **Verify**:
   - Connection should succeed (or at least proceed further).
   - Check Console/Debug output for lines starting with `debug1:`.
   - Any "no matching ..." errors will now be visible in the logs.

## Debugging

If connection still fails, look at the verbose log output:
- `debug1: kex: algorithm: ...`
- `debug1: host key algo: ...`
- `debug1: ciphers ctos: ...`

If you see `Unable to negotiate...`, the missing algorithm will be listed there. Add it to `TerminalSession.swift` (direct) or `SSHArgsBuilder.swift` (saved).
