/// OSC 133 injection for a WSL pane's own shell.
///
/// Pure, like `shell_integration.dart`: it produces the text of the scripts and
/// nothing else — nothing here goes near the owner's `~/.bashrc` or `~/.zshrc`,
/// which is precisely what the rcfile mechanism exists for.
///
/// **The scripts carry almost no comments of their own, deliberately.** Every
/// byte is base64'd onto a `cmd.exe` command line that stops at 8191
/// characters, and an apostrophe in a comment costs four.
library;

/// The shell-side bootstrap a WSL pane runs before it becomes a shell.
///
/// It writes its own rc file inside the distribution, because a probe from the
/// launch path could not answer both questions and `bash --rcfile` pointed at
/// an unreadable file starts a shell with **no user configuration at all**.
/// Every path that does not end in a working rc file ends in the plain login
/// shell, and the `mktemp -d` directory removes itself, so nothing is left in
/// `/tmp` and no fixed path exists for anyone to pre-create.
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

/// The bash rcfile, handed to `bash --rcfile`.
///
/// **`--rcfile` applies only to an interactive shell that is not a login
/// shell**, and a WSL pane is one — which is why the script first reads what a
/// login shell would have, in its order. The rest is traps: `PS0` (not a
/// `DEBUG` trap) expands in a subshell, so an empty Enter emits no `C`;
/// `__k133_precmd` is prepended so `$?` is read before the user's hook; `B` is
/// re-appended each prompt, since starship rewrites `PS1`; `PROMPT_COMMAND` is
/// `eval`'d rather than spliced, because `foo;;bar` is a syntax error; and no
/// readline brackets in `PS0`, where bash printed eight stray control bytes per
/// command.
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

/// `$ZDOTDIR/.zshenv` for a zsh pane.
///
/// zsh resolves `ZDOTDIR` afresh for **each** startup file, so pointing it at a
/// directory holding only a `.zshrc` would silently drop the user's `.zshenv`
/// and `.zprofile`. All three are mirrored instead, with `ZDOTDIR` handed back
/// to the user's own directory while their file is sourced and taken again
/// afterwards — so a `.zshenv` that *moves* it is followed, not overruled.
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

/// `$ZDOTDIR/.zshrc` for a zsh pane: the user's, then the hooks, then out of
/// the way.
///
/// `precmd`/`preexec` rather than `PROMPT_COMMAND`/`PS0`, and **`$?` is safe
/// wherever the hook sits**: zsh restores the last status around every one of
/// them. The last three lines hand `ZDOTDIR` back, because zsh reads `.zlogin`
/// from whatever it says *then* — so the rest of startup is the user's own.
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
