import Foundation

public enum ShellContextProbe {
    public enum Reason: String, Equatable {
        case program, identity, unavailable, socket

        public var message: String {
            switch self {
            case .program: return "终端正在运行其他程序或嵌套 Shell，目录跟随暂缓。"
            case .identity: return "终端用户身份已变化，目录跟随暂缓。"
            case .unavailable: return "无法确认终端当前环境，目录跟随暂缓。"
            case .socket: return "无法在默认 tmux 服务中确认当前客户端，目录跟随暂缓。"
            }
        }
    }

    public enum Event: Equatable { case original, tmux(String), paused(Reason) }

    public struct Decoder {
        private let token: String
        private var pending = Data()
        public init(token: String) { self.token = token }

        public mutating func feed(_ data: Data) throws -> [Event] {
            var events: [Event] = []
            for byte in data {
                if byte != 10 {
                    pending.append(byte)
                    guard pending.count <= 16_384 else { throw ProfileError("目录观察响应过长。") }
                    continue
                }
                guard let line = String(data: pending, encoding: .utf8) else { throw ProfileError("目录观察响应编码无效。") }
                pending.removeAll(keepingCapacity: true)
                let fields = line.components(separatedBy: "\t")
                guard fields.count >= 2, fields[0] == "NC2", fields[1] == token else { continue }
                if fields.count == 3, fields[2] == "original" { events.append(.original); continue }
                if fields.count == 4, fields[2] == "paused", let reason = Reason(rawValue: fields[3]) {
                    events.append(.paused(reason)); continue
                }
                if fields.count == 4, fields[2] == "tmux",
                   fields[3].range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
                   let path = fields[3].removingPercentEncoding, path.hasPrefix("/"),
                   path.rangeOfCharacter(from: .controlCharacters) == nil {
                    events.append(.tmux(path)); continue
                }
                throw ProfileError("目录观察响应无效。")
            }
            return events
        }
    }

    public static func arguments(profile: ConnectionProfile, controlPath: String, context: ShellContext, token: String) throws -> [String] {
        let profile = try profile.validated()
        var args = ["-F", "/dev/null", "-T", "-p", String(profile.port), "-S", controlPath,
                    "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false",
                    "-o", "ForwardAgent=no", "-o", "ForwardX11=no"]
        if !profile.username.isEmpty { args += ["-l", profile.username] }
        return args + ["--", profile.host, command(context: context, token: token)]
    }

    public static func command(context: ShellContext, token: String) -> String {
        let script = #"""
        __nc2_pid=\#(context.pid)
        __nc2_uid=\#(context.uid)
        __nc2_tty=\#(ShellIntegration.quote(context.tty))
        __nc2_token=\#(ShellIntegration.quote(token))
        __nc2_tmux=\#(ShellIntegration.quote(context.tmuxExecutable ?? "tmux"))
        unset TMUX
        set -f
        __nc2_newline='
        '
        __nc2_emit() {
            printf 'NC2\t%s\t%s' "$__nc2_token" "$1"
            if [ "$#" -eq 2 ]; then printf '\t%s' "$2"; fi
            printf '\n'
        }
        __nc2_foreground() {
            command ps -t "${1#/dev/}" -o pid= -o pgid= -o tpgid= -o uid= -o comm= 2>/dev/null |
                command awk '$2 == $3 && $3 > 0 { n++; if ($1 == $2) { p=$1; u=$4; c=$5; for(i=6;i<=NF;i++) c=c " " $i } }
                    END { if(n == 0) print "unknown"; else if(n != 1 || p == "") print "busy"; else print p "|" u "|" c }'
        }
        __nc2_client() {
            command "$__nc2_tmux" list-clients -F '#{client_tty}|#{pane_id}|#{pane_pid}|#{pane_tty}' 2>/dev/null |
                command awk -F '|' -v tty="$__nc2_tty" '$1 == tty { n++; line=$0 } END { if(n == 1) print line }'
        }
        __nc2_check() {
            __nc2_fg=$(__nc2_foreground "$__nc2_tty")
            case "$__nc2_fg" in unknown) __nc2_emit paused unavailable; return;; busy) __nc2_emit paused program; return;; esac
            __nc2_p=${__nc2_fg%%|*}; __nc2_rest=${__nc2_fg#*|}
            __nc2_u=${__nc2_rest%%|*}; __nc2_c=${__nc2_rest#*|}; __nc2_c=${__nc2_c##*/}
            if [ "$__nc2_u" != "$__nc2_uid" ]; then __nc2_emit paused identity; return; fi
            case "$__nc2_c" in
                bash|zsh|fish|-bash|-zsh|-fish)
                    if [ "$__nc2_p" = "$__nc2_pid" ]; then __nc2_emit original; else __nc2_emit paused program; fi
                    return;;
                tmux|'tmux: client') ;;
                *) __nc2_emit paused program; return;;
            esac
            __nc2_info=$(__nc2_client)
            if [ -z "$__nc2_info" ]; then __nc2_emit paused socket; return; fi
            __nc2_rest=${__nc2_info#*|}; __nc2_pane=${__nc2_rest%%|*}; __nc2_rest=${__nc2_rest#*|}
            __nc2_pane_pid=${__nc2_rest%%|*}; __nc2_pane_tty=${__nc2_rest#*|}
            __nc2_inside=$(__nc2_foreground "$__nc2_pane_tty")
            case "$__nc2_inside" in unknown) __nc2_emit paused unavailable; return;; busy) __nc2_emit paused program; return;; esac
            __nc2_p=${__nc2_inside%%|*}; __nc2_rest=${__nc2_inside#*|}
            __nc2_u=${__nc2_rest%%|*}; __nc2_c=${__nc2_rest#*|}; __nc2_c=${__nc2_c##*/}
            if [ "$__nc2_u" != "$__nc2_uid" ]; then __nc2_emit paused identity; return; fi
            if [ "$__nc2_p" != "$__nc2_pane_pid" ]; then __nc2_emit paused program; return; fi
            case "$__nc2_c" in bash|zsh|fish|-bash|-zsh|-fish) ;; *) __nc2_emit paused program; return;; esac
            if ! __nc2_value=$(command "$__nc2_tmux" display-message -p -t "$__nc2_pane" '#{pane_current_path}' 2>/dev/null && printf '.'); then
                __nc2_emit paused unavailable; return
            fi
            __nc2_value=${__nc2_value%.}; __nc2_path=${__nc2_value%"$__nc2_newline"}
            if [ "$(__nc2_client)" != "$__nc2_info" ] || [ "$(__nc2_foreground "$__nc2_pane_tty")" != "$__nc2_inside" ] ||
               [ "$(__nc2_foreground "$__nc2_tty")" != "$__nc2_fg" ]; then __nc2_emit paused program; return; fi
            __nc2_encoded=$(printf '%s' "$__nc2_path" | command od -An -v -tx1 | command awk '{ for(i=1;i<=NF;i++) printf "%%%s", toupper($i) }')
            __nc2_emit tmux "$__nc2_encoded"
        }
        while IFS= read -r __nc2_tick; do
            [ "$__nc2_tick" = tick ] || exit 1
            __nc2_check
        done
        """#
        return "exec /bin/sh -c " + ShellIntegration.quote(script)
    }
}
