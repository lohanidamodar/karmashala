/// OSC 133 injection for a WSL pane's own shell, as pure script text. The
/// scripts carry no comments: every byte is base64'd onto an 8191-char line.
library;

/// The bootstrap a WSL pane runs before it becomes a shell. It writes its own
/// rc file: `bash --rcfile` on an unreadable one loses the user's whole config.
String wslIntegrationBootstrap() =>
    '''
__s=\${SHELL:-}
[ -x "\$__s" ] || __s=\$(getent passwd "\$(id -u)" 2>/dev/null | cut -d: -f7)
[ -x "\$__s" ] || __s=/bin/sh
__n=\${__s##*/}
case \$__n in
  bash|zsh) __d=\$(mktemp -d 2>/dev/null) ;;
  *) __d= ;;
esac
[ -n "\$__d" ] && [ -d "\$__d" ] || exec "\$__s" -l
if [ "\$__n" = bash ]; then
  if cat > "\$__d/rc" <<'__K133_BASHRC__'
${bashIntegrationRcFile()}__K133_BASHRC__
  then
    __K133_RC=\$__d
    export __K133_RC
    exec "\$__s" --rcfile "\$__d/rc" -i
  fi
else
  if cat > "\$__d/.zshenv" <<'__K133_ZSHENV__'
${zshIntegrationZshenv()}__K133_ZSHENV__
  then :; else __d=; fi
  if [ -n "\$__d" ] && cat > "\$__d/.zprofile" <<'__K133_ZPROFILE__'
${zshIntegrationZprofile()}__K133_ZPROFILE__
  then :; else __d=; fi
  if [ -n "\$__d" ] && cat > "\$__d/.zshrc" <<'__K133_ZSHRC__'
${zshIntegrationZshrc()}__K133_ZSHRC__
  then
    __K133_ZU=\${ZDOTDIR:-\$HOME}
    __K133_ZD=\$__d
    ZDOTDIR=\$__d
    export __K133_ZU __K133_ZD ZDOTDIR
    exec "\$__s" -l -i
  fi
fi
rm -rf -- "\$__d"
exec "\$__s" -l
''';

/// The bash rcfile. **`--rcfile` applies only to an interactive shell that is
/// not a login shell**, and a WSL pane is one — hence the explicit sourcing.
String bashIntegrationRcFile() => r'''
# Karmashala OSC 133 shell integration. Read once, then deleted.
if [ -r /etc/profile ]; then . /etc/profile; fi
if [ -r "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile"
elif [ -r "$HOME/.bash_login" ]; then . "$HOME/.bash_login"
elif [ -r "$HOME/.profile" ]; then . "$HOME/.profile"
elif [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc"
fi
__k133_precmd() {
  local __k133_s=$?
  if [ -n "${__k133_seen:-}" ]; then printf '\033]133;D;%s\007' "$__k133_s"; fi
  __k133_seen=1
  # OSC 7: no Linux shell reports its folder by itself. A raw % would read as
  # a broken escape.
  printf '\033]7;file://%s\007' "${PWD//\%/%25}"
  printf '\033]133;A\007'
  return $__k133_s
}
__k133_b='\[\033]133;B\007\]'
__k133_ps1() {
  case "${PS1:-}" in
    *"$__k133_b") ;;
    *) PS1="${PS1:-}$__k133_b" ;;
  esac
}
if [ -n "${BASH_VERSINFO:-}" ] && { [ "${BASH_VERSINFO[0]}" -gt 5 ] || \
   { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; }; then
  PROMPT_COMMAND=(__k133_precmd \
    "${PROMPT_COMMAND[@]+"${PROMPT_COMMAND[@]}"}" __k133_ps1)
else
  __k133_pc=${PROMPT_COMMAND:-}
  __k133_post() { eval "$__k133_pc"; __k133_ps1; }
  PROMPT_COMMAND='__k133_precmd;__k133_post'
fi
PS0='\033]133;C\007'"${PS0:-}"
rm -rf -- "${__K133_RC:-}"
unset __K133_RC
''';

/// `$ZDOTDIR/.zshenv` for a zsh pane. zsh resolves `ZDOTDIR` afresh for **each**
/// startup file, so all three are mirrored or the user's own are dropped.
String zshIntegrationZshenv() => _zshMirror('.zshenv');

/// `$ZDOTDIR/.zprofile` for a zsh pane. See [zshIntegrationZshenv].
String zshIntegrationZprofile() => _zshMirror('.zprofile');

String _zshMirror(String name) =>
    '''
ZDOTDIR=\$__K133_ZU
[ -r "\$ZDOTDIR/$name" ] && . "\$ZDOTDIR/$name"
__K133_ZU=\$ZDOTDIR
ZDOTDIR=\$__K133_ZD
''';

/// `$ZDOTDIR/.zshrc` for a zsh pane. `ZDOTDIR` is handed back at the end,
/// because zsh reads `.zlogin` from whatever it says *then*.
String zshIntegrationZshrc() => r'''
# Karmashala OSC 133 shell integration. Read once, then deleted.
ZDOTDIR=$__K133_ZU
[ -r "$ZDOTDIR/.zshrc" ] && . "$ZDOTDIR/.zshrc"
__K133_ZU=$ZDOTDIR
__k133_b=$'%{\033]133;B\a%}'
__k133_precmd() {
  local __k133_s=$?
  if [[ -n ${__k133_seen-} ]]; then printf '\033]133;D;%s\007' "$__k133_s"; fi
  __k133_seen=1
  printf '\033]7;file://%s\007' "${PWD//\%/%25}"
  printf '\033]133;A\007'
  return $__k133_s
}
__k133_preexec() { printf '\033]133;C\007' }
__k133_ps1() {
  [[ ${PS1-} == *"$__k133_b" ]] || PS1=${PS1-}$__k133_b
}
typeset -ga precmd_functions preexec_functions
precmd_functions=(__k133_precmd $precmd_functions __k133_ps1)
preexec_functions=(__k133_preexec $preexec_functions)
ZDOTDIR=$__K133_ZU
command rm -rf -- "$__K133_ZD"
unset __K133_ZD __K133_ZU
''';
