/// OSC 133 injection for a WSL pane's own shell.
///
/// Pure, like `shell_integration.dart`: it produces the text of the scripts and
/// nothing else. Nothing here reads or writes a file on the user's machine, and
/// in particular nothing goes near the owner's `~/.bashrc` or `~/.zshrc` — the
/// rcfile mechanism exists precisely so that never happens.
///
/// **The scripts carry almost no comments of their own, deliberately.** Every
/// byte is base64'd onto a `cmd.exe` command line that stops at 8191
/// characters, and an apostrophe in a comment costs four. The reasoning lives
/// in the doc comments here, where it is also readable.
library;

/// The shell-side bootstrap a WSL pane runs before it becomes a shell.
///
/// **This is what unparked the rcfile.** The bash script below was written and
/// verified in Loop 32 and then deferred, because *delivering* it into a
/// distribution meant an async probe on the pane-launch path answering two
/// questions — is the login shell really bash, and can it read the file — and
/// `bash --rcfile` pointed at an unreadable file starts a shell with **no user
/// configuration at all**, which is far worse than no feature.
///
/// Both questions are answered here instead, by the payload, inside the
/// distribution, at no cost to the launch: it reads the login shell out of the
/// environment and writes the rc file itself, so a file it just wrote is a file
/// it can read. Every path that does not end in a working rc file ends in
/// `exec "$__s" -l`, which is the pane this app opened before shell integration
/// existed.
///
/// It rides the launch form already in use — the
/// `cmd.exe /c wsl.exe -d … -- eval $(echo '…'|base64 -d)` line `wrapForPty`
/// encodes. The command line's shape does not change; only what it carries.
///
/// `mktemp -d` gives a fresh 0700 directory per pane, and each rc script
/// removes that directory as its last statement. Unlinking a file another
/// process holds open is safe on Linux, so the shell finishes reading the rc it
/// was handed; nothing is left in `/tmp`, and no fixed path exists for anyone
/// else to pre-create.
///
/// A distribution whose login shell is neither bash nor zsh launches exactly as
/// it did before and emits nothing. That case is reported rather than probed
/// for: `CommandRunOutcome.markersSeen` is the honest answer, and a probe on
/// the launch path is the cost this design exists to avoid.
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
/// shell**, and a WSL pane is a login shell — which is why the script starts by
/// reading what a login shell would have read, in a login shell's own order,
/// before defining anything. Nothing of the user's is replaced. `.bashrc` is
/// last and only as an `elif`: a login shell would not read it, but a home with
/// nothing else must not lose its configuration.
///
/// Kept from Loop 32's verified script:
///
/// * **`PS0` rather than a `DEBUG` trap for `C`.** `PS0` is expanded after a
///   command is read and before it runs, which is exactly `C`, and it replaces
///   ~40 lines of trap arming, chaining and re-adoption. It expands in a
///   subshell, which is why an empty Enter emits `A … D` with no `C` and
///   `CommandBlockTracker` discards blocks that never started;
/// * **`__k133_precmd` prepended**, so `$?` is read before any hook of the
///   user's can move it, and returned so their hook still sees it.
///
/// Added here:
///
/// * **`B`, from a hook appended *after* the user's.** A prompt framework that
///   rewrites `PS1` in `PROMPT_COMMAND` (starship, oh-my-bash) would drop a
///   marker appended once at startup, so it is re-appended each prompt, guarded
///   by a suffix test so it cannot accumulate;
/// * **`eval` of a scalar `PROMPT_COMMAND` inside a wrapper** rather than
///   splicing it into a `;`-joined string. Loop 32 could prepend safely because
///   the user's value landed last, where bash tolerates a trailing separator;
///   appending after it cannot, and `foo;;bar` is a syntax error. `eval` needs
///   no normalisation and takes a trailing `;`, `;\t` or `&` alike;
/// * **no `\[`/`\]` in `PS0`.** They are readline's non-printing brackets and
///   only `PS1` strips them; in `PS0` bash printed a literal SOH and STX around
///   every `C` — measured, eight stray control bytes per command.
///
/// **Measured 2026-09-09 against bash 5.3.15 under a real pty.** `true`,
/// `false`, empty Enter: `A B C D;0  A B C D;1  A B D;1`. Across a scalar
/// `PROMPT_COMMAND` and one with a trailing `;`, `;   `, `;\t` or `&`; an array
/// one; `set -u` with and without a hook; a framework that rewrites `PS1`; a
/// user `PS0`; a user `PS1`; and no configuration at all — the marker stream is
/// identical in all thirteen, the user's hook fires once per prompt and sees
/// the real `$?` (`0 0 1 1`), and no `unbound variable`, syntax error or
/// `command not found` appears. Under `set -e` the shell exits on `false`
/// exactly as it does without any of this.
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
/// and `.zprofile`. All three are mirrored instead: `ZDOTDIR` is handed back to
/// the user's own directory while their file is sourced — their file may well
/// reference it — and taken again afterwards. A user whose `.zshenv` *moves*
/// `ZDOTDIR` (a `~/.config/zsh` layout) is followed rather than overruled,
/// because the value they left is where the next file is read from.
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
/// wherever the hook sits.** Measured 2026-09-09 against zsh 5.9.2: zsh calls
/// the bare `precmd` function *before* `precmd_functions`, and restores the
/// last status around every one of them — so a user hook that runs `false`
/// cannot cost us the exit code the way bash's would. The marks are emitted
/// first anyway, so nothing a user hook prints lands inside a command block.
///
/// The last three lines are what makes this borrowed rather than taken: zsh
/// reads `.zlogin` and `.zlogout` from whatever `ZDOTDIR` says *then*, so
/// handing it back here means the rest of startup — and every nested zsh — is
/// the user's own. The temporary directory goes with it. `ZDOTDIR` stays
/// exported and set to `$HOME` for a user who had none, which reads the same
/// way to everything except `[[ -v ZDOTDIR ]]`.
///
/// Measured the same day, `true`, `false`, empty Enter, `echo hi`:
/// `A B C D;0  A B C D;1  A B D;1  A B C D;0` — the stream bash produces — with
/// a user `precmd`, a user `PS1`, and a user `.zshenv` that relocates
/// `ZDOTDIR`, and with nothing left in `/tmp` in any case.
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
