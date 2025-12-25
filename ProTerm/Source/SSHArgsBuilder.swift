import Foundation

struct SSHArgsBuilder {
    struct Options {
        var host: String
        var user: String?
        var port: Int?
        var identityFile: String?
        var password: String?
        var strictHostKeyChecking: Bool = false
        var serverAliveInterval: Int = 60
        var serverAliveCountMax: Int = 3
        var connectTimeout: Int = 30
        var preferredAuthentications: String = "password,publickey,keyboard-interactive"
    }

    struct Command {
        var execPath: String
        var args: [String]
    }

    func build(_ opts: Options) -> Command {
        var execPath = "/usr/bin/ssh"
        var args: [String] = []

        // Force PTY allocation and interactive mode
        args.append("-tt")
        args += ["-o", "ServerAliveInterval=\(opts.serverAliveInterval)"]
        args += ["-o", "ServerAliveCountMax=\(opts.serverAliveCountMax)"]
        args += ["-o", "BatchMode=no"]
        args += ["-o", "NumberOfPasswordPrompts=3"]
        args += ["-o", "ConnectTimeout=\(opts.connectTimeout)"]
        args += ["-o", "PreferredAuthentications=\(opts.preferredAuthentications)"]

        // Enable legacy support for older devices (Cisco, etc.)
        // These options append (+) to the default list rather than replacing it
        args += ["-o", "KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1"]
        args += ["-o", "HostKeyAlgorithms=+ssh-rsa"]
        // Note: PubkeyAcceptedKeyTypes with + syntax is only supported in OpenSSH 8.5+.
        // args += ["-o", "PubkeyAcceptedKeyTypes=+ssh-rsa,ssh-dss"]
        args += ["-o", "Ciphers=+aes128-cbc,3des-cbc,aes256-cbc,aes128-ctr,aes192-ctr,aes256-ctr"]
        args += ["-o", "MACs=+hmac-sha1,hmac-sha1-96,hmac-md5"]

        // Host key checking
        args += ["-o", "StrictHostKeyChecking=\(opts.strictHostKeyChecking ? "yes" : "no")"]

        if let p = opts.port, p != 22 { args += ["-p", String(p)] }

        if let key = opts.identityFile, !key.isEmpty, FileManager.default.fileExists(atPath: key) {
            args += ["-i", key]
        }

        if let user = opts.user, !user.isEmpty {
            args += ["-l", user]
        }

        // If password provided, prefer sshpass when present
        if let pwd = opts.password {
            let candidates = [
                "/opt/homebrew/bin/sshpass",
                "/usr/local/bin/sshpass",
                "/usr/bin/sshpass",
            ]
            if let sshpass = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                execPath = sshpass
                args.append(contentsOf: ["-p", pwd, "ssh"])
            }
        }

        args.append(opts.host)
        
        // Verbose logging removed for clean output

        return Command(execPath: execPath, args: args)
    }
}
