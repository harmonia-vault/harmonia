# 非交互 shell 只加载一次，不改变其提示符配置。
case $- in
  *i*) ;;
  *)
    [ ! -r "$__HARMONIA_FILE" ] || . "$__HARMONIA_FILE"
    return
    ;;
esac

if [ -n "${BASH_VERSION-}" ]; then
  if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )); then
    printf '%s\n' 'Harmonia 需要 Bash 5.1 或以上版本，请升级 Bash。' >&2
    return 1
  fi
elif [ -n "${ZSH_VERSION-}" ]; then
  autoload -Uz is-at-least
  if ! is-at-least 5.0; then
    printf '%s\n' 'Harmonia 需要 Zsh 5.0 或以上版本，请升级 Zsh。' >&2
    return 1
  fi
else
  printf '%s\n' 'Harmonia 支持 Bash 和 Zsh，请使用其中一种终端。' >&2
  return 1
fi

# 原状态仅属于当前 shell，重复加载时不能重新捕获已注入的值。
if [ -z "${__HARMONIA_READY-}" ]; then
  typeset -gA __HARMONIA_ORIGINAL
  __HARMONIA_ORIGINAL=()
  __HARMONIA_SNAPSHOT=''
  __HARMONIA_READY=1
fi

__HARMONIA_refresh() {
  local __HARMONIA_status=$?
  local __HARMONIA_content='' __HARMONIA_line __HARMONIA_name __HARMONIA_decl
  local -a __HARMONIA_names __HARMONIA_previous
  local -A __HARMONIA_next
  __HARMONIA_names=()
  __HARMONIA_previous=()
  __HARMONIA_next=()
  if [ -n "${ZSH_VERSION-}" ]; then
    emulate -L zsh
  fi

  if [[ -e "$__HARMONIA_FILE" ]]; then
    [[ -r "$__HARMONIA_FILE" ]] || return "$__HARMONIA_status"
    __HARMONIA_content=$(< "$__HARMONIA_FILE") || return "$__HARMONIA_status"
  fi
  [[ "$__HARMONIA_content" != "$__HARMONIA_SNAPSHOT" ]] || return "$__HARMONIA_status"

  # 名单在固定的第二行；值可以跨行，不能逐行搜索 export 来猜测变量名。
  if [[ -n "$__HARMONIA_content" ]]; then
    __HARMONIA_line=${__HARMONIA_content#*$'\n'}
    __HARMONIA_line=${__HARMONIA_line%%$'\n'*}
    [[ "$__HARMONIA_line" == '# keys:'* ]] || return "$__HARMONIA_status"
    __HARMONIA_line=${__HARMONIA_line#\# keys:}
    if [[ -n "$__HARMONIA_line" ]]; then
      if [ -n "${BASH_VERSION-}" ]; then
        IFS=' ' read -r -a __HARMONIA_names <<< "$__HARMONIA_line"
      else
        IFS=' ' read -r -A __HARMONIA_names <<< "$__HARMONIA_line"
      fi
    fi
  fi

  for __HARMONIA_name in "${__HARMONIA_names[@]}"; do
    [[ "$__HARMONIA_name" == [a-zA-Z_]* && "$__HARMONIA_name" != *[^a-zA-Z0-9_]* ]] || return "$__HARMONIA_status"
    [[ "$__HARMONIA_name" != __[Hh][Aa][Rr][Mm][Oo][Nn][Ii][Aa]_* ]] || return "$__HARMONIA_status"
    __HARMONIA_next[$__HARMONIA_name]=1
  done

  if [ -n "${BASH_VERSION-}" ]; then
    __HARMONIA_previous=("${!__HARMONIA_ORIGINAL[@]}")
  else
    __HARMONIA_previous=("${(@k)__HARMONIA_ORIGINAL}")
  fi
  for __HARMONIA_name in "${__HARMONIA_previous[@]}"; do
    if [[ -z "${__HARMONIA_next[$__HARMONIA_name]-}" ]]; then
      __HARMONIA_decl=${__HARMONIA_ORIGINAL[$__HARMONIA_name]}
      unset -v "$__HARMONIA_name"
      if [[ -n "$__HARMONIA_decl" ]]; then
        # 在函数内恢复全局声明，同时恢复原有的导出属性。
        if [ -n "${BASH_VERSION-}" ]; then
          eval "builtin declare -g ${__HARMONIA_decl#declare }"
        elif [[ "$__HARMONIA_decl" == 'export '* ]]; then
          eval "typeset -gx ${__HARMONIA_decl#export }"
        else
          eval "typeset -g ${__HARMONIA_decl#typeset }"
        fi
      fi
      unset "__HARMONIA_ORIGINAL[$__HARMONIA_name]"
    fi
  done
  for __HARMONIA_name in "${__HARMONIA_names[@]}"; do
    if [[ -z "${__HARMONIA_ORIGINAL[$__HARMONIA_name]+present}" ]]; then
      if [ -n "${BASH_VERSION-}" ]; then
        __HARMONIA_decl=$(builtin declare -p -- "$__HARMONIA_name" 2>/dev/null) || __HARMONIA_decl=''
      else
        __HARMONIA_decl=$(builtin typeset -p "$__HARMONIA_name" 2>/dev/null) || __HARMONIA_decl=''
      fi
      __HARMONIA_ORIGINAL[$__HARMONIA_name]=$__HARMONIA_decl
    fi
  done
  # 只执行生成器已安全引用的同一份快照，避免原子替换期间混读两版内容。
  if eval "$__HARMONIA_content"; then
    __HARMONIA_SNAPSHOT=$__HARMONIA_content
  fi
  return "$__HARMONIA_status"
}

if [ -n "${BASH_VERSION-}" ]; then
  # 字符串形式作为一个完整元素保留，数组形式保留全部元素及原顺序。
  if [[ " ${PROMPT_COMMAND[*]-} " != *' __HARMONIA_refresh '* ]]; then
    PROMPT_COMMAND=(__HARMONIA_refresh "${PROMPT_COMMAND[@]}")
  fi
else
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd __HARMONIA_refresh
fi
__HARMONIA_refresh
