import Foundation

enum ShellPrompt {
    // 只调整标准路径占位符；不替换终端输出，也不改写服务器启动文件。
    static let command = #"""
    if [ -n "${BASH_VERSION-}" ]; then
        if (( BASH_VERSINFO[0] >= 4 )); then
            if (PROMPT_DIRTRIM=2) 2>/dev/null; then export PROMPT_DIRTRIM=2; fi
        elif shopt -q promptvars && [[ "${PS1-}" != *'$('* && "${PS1-}" != *'`'* ]]; then
            __nc2_prompt_path() {
                local __nc2_display="$PWD" __nc2_relative="${PWD#/}" __nc2_parent
                case "$PWD" in
                    "$HOME") builtin printf '~'; return ;;
                    "$HOME"/*) __nc2_relative=${PWD#"$HOME"/}; __nc2_display="~/$__nc2_relative" ;;
                esac
                case "$__nc2_relative" in
                    */*/*)
                        __nc2_parent=${__nc2_relative%/*}
                        builtin printf '.../%s/%s' "${__nc2_parent##*/}" "${__nc2_relative##*/}"
                        ;;
                    *) builtin printf '%s' "$__nc2_display" ;;
                esac
            }
            __nc2_prompt_input=${PS1-}; __nc2_prompt_output=''
            __nc2_prompt_backslash=$(builtin printf '\134')
            while [ -n "$__nc2_prompt_input" ]; do
                __nc2_prompt_char=${__nc2_prompt_input%"${__nc2_prompt_input#?}"}
                __nc2_prompt_input=${__nc2_prompt_input#?}
                if [ "$__nc2_prompt_char" = "$__nc2_prompt_backslash" ] && [ -n "$__nc2_prompt_input" ]; then
                    __nc2_prompt_next=${__nc2_prompt_input%"${__nc2_prompt_input#?}"}
                    __nc2_prompt_input=${__nc2_prompt_input#?}
                    if [ "$__nc2_prompt_next" = w ]; then
                        __nc2_prompt_output="$__nc2_prompt_output"'$(__nc2_prompt_status=$?; if declare -F __nc2_prompt_path >/dev/null; then __nc2_prompt_path; else printf "%s" "$PWD"; fi; exit "$__nc2_prompt_status")'
                    else
                        __nc2_prompt_output="$__nc2_prompt_output$__nc2_prompt_backslash$__nc2_prompt_next"
                    fi
                else
                    __nc2_prompt_output="$__nc2_prompt_output$__nc2_prompt_char"
                fi
            done
            PS1=$__nc2_prompt_output
            unset __nc2_prompt_input __nc2_prompt_output __nc2_prompt_char __nc2_prompt_next __nc2_prompt_backslash
        fi
    elif [ -n "${ZSH_VERSION-}" ] && [[ -o promptpercent && "${PS1-}" != *'$('* && "${PS1-}" != *'`'* ]]; then
        __nc2_prompt_input=${PS1-}; __nc2_prompt_output=''
        while [ -n "$__nc2_prompt_input" ]; do
            __nc2_prompt_char=${__nc2_prompt_input%"${__nc2_prompt_input#?}"}
            __nc2_prompt_input=${__nc2_prompt_input#?}
            if [ "$__nc2_prompt_char" = '%' ] && [ -n "$__nc2_prompt_input" ]; then
                __nc2_prompt_next=${__nc2_prompt_input%"${__nc2_prompt_input#?}"}
                __nc2_prompt_input=${__nc2_prompt_input#?}
                if [ "$__nc2_prompt_next" = '~' ]; then
                    __nc2_prompt_output="$__nc2_prompt_output"'%(3~|.../%2~|%~)'
                else
                    __nc2_prompt_output="$__nc2_prompt_output%$__nc2_prompt_next"
                fi
            else
                __nc2_prompt_output="$__nc2_prompt_output$__nc2_prompt_char"
            fi
        done
        PS1=$__nc2_prompt_output
        unset __nc2_prompt_input __nc2_prompt_output __nc2_prompt_char __nc2_prompt_next
    fi
    """#
}
