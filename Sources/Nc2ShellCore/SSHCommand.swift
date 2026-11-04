import Foundation

public enum SSHCommand {
    // askpass 没有认证类型字段；禁用任意服务端挑战，账号密码只交给标准 password 方法。
    public static let rememberedPasswordOptions = [
        "-o", "KbdInteractiveAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
        "-o", "PreferredAuthentications=publickey,password", "-o", "PasswordAuthentication=yes"
    ]
    public static func automaticReconnectOptions(usingRememberedPassword: Bool) -> [String] {
        ["-o", "StrictHostKeyChecking=yes", "-o", "KbdInteractiveAuthentication=no",
         "-o", "BatchMode=\(usingRememberedPassword ? "no" : "yes")"]
    }
    public static func arguments(profile: ConnectionProfile, controlPath: String) throws -> [String] {
        let profile = try profile.validated()
        var args = [
            "-tt", "-p", String(profile.port),
            "-o", "StrictHostKeyChecking=ask",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ForkAfterAuthentication=no",
            "-S", controlPath
        ]
        if !profile.username.isEmpty { args += ["-l", profile.username] }
        if !profile.identityFile.isEmpty {
            args += ["-i", (profile.identityFile as NSString).expandingTildeInPath]
        }
        // argv 边界和选项终止符防止主机输入被解释成额外命令。
        return args + ["--", profile.host]
    }
}
