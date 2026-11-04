import Foundation

public enum ShellIntegration {
    public static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    public static func bootstrapCommand(token: String) -> String {
        let hook = command(token: token)
        // --rcfile 同时兼容 macOS Bash 3.2 与新版 Bash；按登录顺序加载既有配置。
        let bash = #"""
        __nc2_init="${BASH_SOURCE[0]}"
        command rm -f -- "$__nc2_init"
        command rmdir -- "${__nc2_init%/*}" 2>/dev/null
        unset __nc2_init
        if [ -r /etc/profile ]; then builtin source /etc/profile; fi
        for __nc2_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [ -r "$__nc2_profile" ]; then builtin source "$__nc2_profile"; break; fi
        done
        unset __nc2_profile
        """# + "\n" + hook + "\n"

        // 只包装 .zshenv，立即恢复目录，让系统历史、键盘配置及后续启动文件走原生流程。
        let zshenv = #"""
        typeset -g __nc2_init="$ZDOTDIR"
        if [[ "${NC2_ZDOTDIR_SET-}" == x ]]; then export ZDOTDIR="$NC2_OLD_ZDOTDIR"; else unset ZDOTDIR; fi
        unset NC2_ZDOTDIR_SET NC2_OLD_ZDOTDIR
        command rm -f -- "$__nc2_init/.zshenv"
        command rmdir -- "$__nc2_init" 2>/dev/null
        unset __nc2_init
        if [[ -r "${ZDOTDIR-$HOME}/.zshenv" ]]; then builtin source "${ZDOTDIR-$HOME}/.zshenv"; fi
        __nc2_activate() {
            precmd_functions=(${precmd_functions:#__nc2_activate})
        """# + "\n" + hook + "\n" + #"""
            unfunction __nc2_activate
        }
        typeset -ga precmd_functions
        precmd_functions+=(__nc2_activate)
        """# + "\n"

        let script = #"""
        __nc2_shell=${SHELL:-/bin/sh}
        case "${__nc2_shell##*/}" in
            fish) exec "$__nc2_shell" -l -i --init-command \#(quote(fishCommand(token: token))) ;;
            bash|zsh) ;;
            *) printf 'Nc2Shell: automatic directory following requires Bash, Zsh or Fish.\n' >&2; exec "$__nc2_shell" -l ;;
        esac
        __nc2_umask=$(umask)
        umask 077
        __nc2_dir=$(mktemp -d "${TMPDIR:-/tmp}/nc2shell-init.XXXXXXXX") || {
            umask "$__nc2_umask"
            printf 'Nc2Shell: directory integration unavailable; starting a normal shell.\n' >&2
            exec "$__nc2_shell" -l
        }
        __nc2_fallback() {
            rm -f -- "$__nc2_dir/bash" "$__nc2_dir/.zshenv"
            rmdir -- "$__nc2_dir" 2>/dev/null
            umask "$__nc2_umask"
            printf 'Nc2Shell: directory integration unavailable; starting a normal shell.\n' >&2
            exec "$__nc2_shell" -l
        }
        case "${__nc2_shell##*/}" in
            bash)
                printf '%s' \#(quote(bash)) > "$__nc2_dir/bash" || __nc2_fallback
                umask "$__nc2_umask"
                exec "$__nc2_shell" --rcfile "$__nc2_dir/bash" -i
                ;;
            zsh)
                printf '%s' \#(quote(zshenv)) > "$__nc2_dir/.zshenv" || __nc2_fallback
                umask "$__nc2_umask"
                NC2_ZDOTDIR_SET=${ZDOTDIR+x} NC2_OLD_ZDOTDIR=${ZDOTDIR-} ZDOTDIR="$__nc2_dir" exec "$__nc2_shell" -l -i
                ;;
        esac
        """#
        // SSH 会通过账户 Shell 执行这一条命令；其余启动逻辑统一交给 POSIX sh 解析。
        return "exec /bin/sh -c " + quote(script)
    }

    public static func fishCommand(token: String) -> String {
        // 事件钩子与用户 fish_prompt 共存；Fish 自带 URL 编码按 UTF-8 处理真实 PWD。
        #"""
        set -l __nc2_tty (command tty 2>/dev/null)
        if string match -qr '^/dev/' -- "$__nc2_tty"
            printf '\e]7;file://context-%s/%s/%s%s' \#(quote(token)) "$fish_pid" (command id -u) "$__nc2_tty"
            set -l __nc2_tmux (command -s tmux)
            if string match -qr '^/' -- "$__nc2_tmux"
                printf '?tmux=%s' (string escape --style=url -- "$__nc2_tmux")
            end
            printf '\a'
        end
        set -e __nc2_tty
        function __nc2_report --on-event fish_prompt
            set -l __nc2_status $status
            printf '\e]7;file://%s%s\a' \#(quote(token)) (string escape --style=url -- "$PWD")
            return $__nc2_status
        end
        __nc2_report
        """#
    }

    public static func command(token: String) -> String {
        // 同一份函数兼容 Bash/Zsh；按字节编码避免空格、中文、#、% 破坏 OSC7 URL。
        let function = #"__nc2_report() { local __nc2_status=${1:-$?}; local LC_ALL=C __nc2_path="$PWD" __nc2_out='' __nc2_c __nc2_hex; while [ -n "$__nc2_path" ]; do __nc2_c="${__nc2_path%"${__nc2_path#?}"}"; __nc2_path="${__nc2_path#?}"; case "$__nc2_c" in [a-zA-Z0-9/._~-]) __nc2_out="$__nc2_out$__nc2_c" ;; *) printf -v __nc2_hex '%d' "'$__nc2_c"; printf -v __nc2_hex '%%%02X' "$((__nc2_hex & 255))"; __nc2_out="$__nc2_out$__nc2_hex" ;; esac; done; printf '\033]7;file://%s%s\007' "# + quote(token) + #" "$__nc2_out"; return "$__nc2_status"; }"#
        // 导出的 PROMPT_COMMAND 会进入 tmux 子 Shell，但函数不会；缺少函数时也保持原命令状态。
        let bashHook = #"__nc2_prompt_status=$?; if declare -F __nc2_report >/dev/null; then __nc2_report "$__nc2_prompt_status"; else (exit "$__nc2_prompt_status"); fi"#
        // 不覆盖已有 PROMPT_COMMAND；放在前面并返回原状态，已有提示符仍能读取 $?。
        // 交互配置可能才把 tmux 加入 PATH；只传已解析的外部程序路径，不让观察通道重读配置。
        let context = #"""
        __nc2_tty=$(command tty 2>/dev/null)
        case "$__nc2_tty" in /dev/*)
            printf '\033]7;file://context-%s/%s/%s%s' \#(quote(token)) "$$" "$(command id -u)" "$__nc2_tty"
            if [ -n "${ZSH_VERSION-}" ]; then __nc2_tmux=$(whence -p tmux); else __nc2_tmux=$(type -P tmux); fi
            case "$__nc2_tmux" in /*)
                printf '?tmux='
                printf '%s' "$__nc2_tmux" | command od -An -v -tx1 | command awk '{ for(i=1;i<=NF;i++) printf "%%%s", toupper($i) }'
                ;;
            esac
            printf '\007'
            ;;
        esac
        unset __nc2_tty __nc2_tmux;
        """#
        return ShellPrompt.command + "\n" + "if [ -n \"${BASH_VERSION-}${ZSH_VERSION-}\" ]; then " + function + #"; if [ -n "${ZSH_VERSION-}" ]; then typeset -ga precmd_functions; if (( ! ${precmd_functions[(Ie)__nc2_report]} )); then precmd_functions=(__nc2_report "${precmd_functions[@]}"); fi; elif [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then if [[ " ${PROMPT_COMMAND[*]} " != *'__nc2_report'* ]]; then PROMPT_COMMAND=(\#(quote(bashHook)) "${PROMPT_COMMAND[@]}"); fi; elif [[ "${PROMPT_COMMAND-}" != *'__nc2_report'* ]]; then PROMPT_COMMAND=\#(quote(bashHook))"${PROMPT_COMMAND:+; $PROMPT_COMMAND}"; fi; "# + context + #"__nc2_report; else printf 'Nc2Shell: directory following requires Bash or Zsh.\n'; fi"#
    }
}
