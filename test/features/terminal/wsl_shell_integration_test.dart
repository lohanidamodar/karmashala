import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'package:karmashala_terminal_core/profiles.dart';

const _wsl = TerminalProfile(
  id: 'wsl:Ubuntu',
  label: 'Ubuntu (WSL)',
  shell: TerminalShell.wsl,
  wslDistribution: 'Ubuntu',
);

/// The POSIX command `encodedPosixShellCommand` hid inside its base64 token.
String _decodePayload(List<String> arguments) {
  final line = arguments[1];
  final blob = RegExp(r"echo '([A-Za-z0-9+/=]+)'").firstMatch(line);
  expect(blob, isNotNull, reason: 'no base64 payload in: $line');
  return utf8.decode(base64Decode(blob!.group(1)!));
}

void main() {
  final bootstrap = wslIntegrationBootstrap();
  final rc = bashIntegrationRcFile();
  final zshrc = zshIntegrationZshrc();
  final zshenv = zshIntegrationZshenv();
  final zprofile = zshIntegrationZprofile();
  final all = {
    'bootstrap': bootstrap,
    'bash rc': rc,
    '.zshrc': zshrc,
    '.zshenv': zshenv,
    '.zprofile': zprofile,
  };

  group('the scripts are shell-safe text', () {
    test('no carriage return anywhere', () {
      // A CR reaches the distribution as part of the line and breaks every
      // statement it lands on. `core.autocrlf=input` keeps the source LF; this
      // is what notices if that ever stops being true.
      for (final entry in all.entries) {
        expect(entry.value, isNot(contains('\r')), reason: entry.key);
      }
    });

    test('nothing collides with a heredoc delimiter', () {
      // Each rc script is carried inside a quoted heredoc. A line equal to the
      // delimiter would end it early and put the rest on the command line.
      for (final delimiter in const [
        '__K133_BASHRC__',
        '__K133_ZSHENV__',
        '__K133_ZPROFILE__',
        '__K133_ZSHRC__',
      ]) {
        expect(bootstrap.split('\n').where((l) => l == delimiter).length, 1);
      }
    });

    test('every payload ends in a newline, so the delimiter starts a line', () {
      for (final script in [rc, zshrc, zshenv, zprofile]) {
        expect(script, endsWith('\n'));
      }
    });
  });

  group('wslIntegrationBootstrap', () {
    test('falls back to the plain login shell on every failing path', () {
      // The reason the rcfile could be unparked: a launch that cannot be
      // instrumented must land on the pane this app always opened, not on a
      // shell with no user configuration.
      expect(bootstrap, contains(r'exec "$__s" -l'));
      expect(
        RegExp(r'exec "\$__s" -l$', multiLine: true).allMatches(
          bootstrap,
        ).length,
        2,
        reason: 'one for an unusable temp dir, one for a shell we cannot '
            'instrument or a write that failed',
      );
    });

    test('reads the login shell rather than assuming one', () {
      expect(bootstrap, contains(r'__s=${SHELL:-}'));
      expect(bootstrap, contains('getent passwd'));
      expect(bootstrap, contains(r'__s=/bin/sh'));
    });

    test('only bash and zsh are instrumented', () {
      expect(bootstrap, contains('bash|zsh) __d=\$(mktemp -d'));
    });

    test('the temp directory is private and per-pane', () {
      // mktemp -d is 0700 and unpredictable, so there is no fixed path for
      // anyone else to pre-create and no race between two panes.
      expect(bootstrap, contains('mktemp -d'));
      expect(bootstrap, isNot(contains('/tmp/karmashala')));
    });

    test('bash is started interactive and NOT login', () {
      // --rcfile is ignored by a login shell, which is why the rc file does the
      // login shell's own reading itself.
      expect(bootstrap, contains(r'exec "$__s" --rcfile "$__d/rc" -i'));
    });

    test('zsh is started through ZDOTDIR, login and interactive', () {
      expect(bootstrap, contains(r'ZDOTDIR=$__d'));
      expect(bootstrap, contains(r'export __K133_ZU __K133_ZD ZDOTDIR'));
      expect(bootstrap, contains(r'exec "$__s" -l -i'));
    });

    test('the user\'s own ZDOTDIR is remembered before it is taken', () {
      expect(bootstrap, contains(r'__K133_ZU=${ZDOTDIR:-$HOME}'));
    });
  });

  group('bashIntegrationRcFile', () {
    test('reads the user\'s configuration before defining anything', () {
      final profile = rc.indexOf(r'$HOME/.bash_profile');
      final ours = rc.indexOf('__k133_precmd()');
      expect(profile, greaterThan(-1));
      expect(profile, lessThan(ours));
    });

    test('reproduces the login shell\'s own reading order', () {
      final order = [
        '/etc/profile',
        r'$HOME/.bash_profile',
        r'$HOME/.bash_login',
        r'$HOME/.profile',
        r'$HOME/.bashrc',
      ].map(rc.indexOf).toList();
      expect(order, orderedEquals(List.of(order)..sort()));
      // .bashrc last, and only as an elif: a login shell would not read it, but
      // a home with nothing else must not lose its configuration.
      expect(rc, contains('elif [ -r "\$HOME/.bashrc" ]'));
    });

    test('never writes to anything of the user\'s', () {
      for (final script in [rc, zshrc, zshenv, zprofile]) {
        expect(script, isNot(contains(r'> "$HOME')));
        expect(script, isNot(contains(r'>> "$HOME')));
        expect(script, isNot(contains('~/.')));
      }
    });

    test('emits all four markers', () {
      expect(rc, contains(r'133;A'));
      expect(rc, contains(r'133;B'));
      expect(rc, contains(r'133;C'));
      expect(rc, contains(r'133;D;%s'));
    });

    test(r'captures $? as the first statement of the hook', () {
      final body = rc.split('__k133_precmd() {')[1];
      final first = body
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty);
      expect(first, r'local __k133_s=$?');
    });

    test('hands the status back for the user\'s own hooks', () {
      expect(rc, contains(r'return $__k133_s'));
    });

    test('prepends the marker hook and appends the PS1 one', () {
      // $? has to be read before any hook of the user's can move it; PS1 has to
      // be patched after a framework that rewrites it in PROMPT_COMMAND.
      final array = rc.split('PROMPT_COMMAND=(')[1].split(')')[0];
      expect(array.indexOf('__k133_precmd'), 0);
      expect(
        array.indexOf('__k133_ps1'),
        greaterThan(array.indexOf(r'${PROMPT_COMMAND[@]')),
      );
    });

    test('evals a scalar PROMPT_COMMAND instead of splicing it', () {
      // `foo;;bar` is a syntax error, and a user hook may end in a separator.
      expect(rc, contains(r'eval "$__k133_pc"'));
    });

    test('emits no D before the first prompt', () {
      final body = rc.split('__k133_precmd() {')[1];
      expect(
        body.indexOf('__k133_seen'),
        lessThan(body.indexOf('133;D;')),
      );
    });

    test('takes C from PS0, with no readline brackets', () {
      expect(rc, contains(r"PS0='\033]133;C\007'"));
      // Only PS1 strips \[ \]; in PS0 bash prints them as SOH and STX.
      expect(rc, isNot(contains(r"PS0='\[")));
    });

    test('preserves a user PS0', () {
      expect(rc, contains(r'"${PS0:-}"'));
    });

    test('removes its own directory as its last statement', () {
      expect(rc.trimRight(), endsWith('unset __K133_RC'));
      expect(rc, contains(r'rm -rf -- "${__K133_RC:-}"'));
    });
  });

  group('the zsh ZDOTDIR', () {
    test('mirrors all three startup files the user has', () {
      // ZDOTDIR is resolved afresh for each of them, so a directory with only a
      // .zshrc silently drops the user's .zshenv and .zprofile.
      expect(zshenv, contains(r'. "$ZDOTDIR/.zshenv"'));
      expect(zprofile, contains(r'. "$ZDOTDIR/.zprofile"'));
      expect(zshrc, contains(r'. "$ZDOTDIR/.zshrc"'));
    });

    test('follows a user file that moves ZDOTDIR', () {
      for (final script in [zshenv, zprofile]) {
        final source = script.indexOf(r'. "$ZDOTDIR/');
        final remember = script.indexOf(r'__K133_ZU=$ZDOTDIR');
        final take = script.indexOf(r'ZDOTDIR=$__K133_ZD');
        expect(source, lessThan(remember));
        expect(remember, lessThan(take));
      }
    });

    test('sources the user\'s .zshrc before defining anything', () {
      expect(
        zshrc.indexOf(r'. "$ZDOTDIR/.zshrc"'),
        lessThan(zshrc.indexOf('__k133_precmd()')),
      );
    });

    test('emits all four markers', () {
      expect(zshrc, contains(r'133;A'));
      expect(zshrc, contains(r'133;B'));
      expect(zshrc, contains(r'133;C'));
      expect(zshrc, contains(r'133;D;%s'));
    });

    test('C comes from preexec and D;code from precmd', () {
      expect(zshrc, contains('__k133_preexec() { printf '));
      expect(zshrc.split('__k133_preexec() {')[1], contains('133;C'));
    });

    test('gives ZDOTDIR back and deletes itself last', () {
      // .zlogin, .zlogout and every nested zsh are the user's again from there.
      final tail = zshrc.trimRight().split('\n');
      expect(tail[tail.length - 3], r'ZDOTDIR=$__K133_ZU');
      expect(tail[tail.length - 2], r'command rm -rf -- "$__K133_ZD"');
      expect(tail.last, r'unset __K133_ZD __K133_ZU');
    });

    test('declares the hook arrays before prepending to them', () {
      expect(
        zshrc.indexOf('typeset -ga precmd_functions preexec_functions'),
        lessThan(zshrc.indexOf('precmd_functions=(')),
      );
    });
  });

  group('the WSL launch carries it', () {
    test('integration off is byte-identical to what always shipped', () {
      final off = ptyLaunchFor(_wsl, workingDirectory: r'C:\repo');
      expect(off.executable, 'cmd.exe');
      expect(off.arguments, [
        '/c',
        r'wsl.exe -d Ubuntu --cd C:\repo',
      ]);
    });

    test('integration on keeps the command line shape and changes the payload', () {
      final on = ptyLaunchFor(
        _wsl,
        workingDirectory: r'C:\repo',
        shellIntegration: true,
      );
      expect(on.executable, 'cmd.exe');
      expect(on.arguments.first, '/c');
      expect(
        on.arguments[1],
        startsWith(r'wsl.exe -d Ubuntu --cd C:\repo -- eval '),
        reason: 'the same cmd.exe /c wsl.exe … -- form every agent launch uses',
      );
    });

    test('the payload is the bootstrap, run by sh', () {
      final on = ptyLaunchFor(_wsl, shellIntegration: true);
      expect(
        _decodePayload(on.arguments),
        "exec '/bin/sh' '-c' '${wslIntegrationBootstrap().replaceAll("'", r"'\''")}'",
      );
    });

    test('nothing of the payload is on the command line for a parser to eat', () {
      final on = ptyLaunchFor(_wsl, shellIntegration: true);
      final line = on.arguments[1];
      expect(line, isNot(contains('\n')));
      expect(line, isNot(contains('%')));
      expect(line, isNot(contains(r'$HOME')));
    });

    test('a user variable still crosses, and is still named in WSLENV', () {
      final on = ptyLaunchFor(
        _wsl,
        shellIntegration: true,
        environment: const {'API_BASE': 'https://x/y'},
      );
      expect(on.environment['API_BASE'], 'https://x/y');
      expect(on.environment['WSLENV'], 'API_BASE/u');
    });

    test('the whole line fits inside what cmd.exe will parse', () {
      // A `cmd.exe /c` command line stops at 8191 characters and base64 is four
      // bytes for three, so the scripts carry their reasoning in Dart rather
      // than in shell comments. This is the headroom that buys.
      final on = ptyLaunchFor(
        _wsl,
        workingDirectory: r'C:\Users\someone\projects\a\deep\worktree',
        shellIntegration: true,
      );
      expect(on.arguments[1].length, lessThan(5000));
    });

    test('cmd.exe is untouched with integration on', () {
      final cmd = ptyLaunchFor(
        TerminalProfile.commandPrompt,
        shellIntegration: true,
      );
      expect(cmd.executable, 'cmd.exe');
      expect(cmd.arguments, isEmpty);
      expect(shellSupportsIntegration(TerminalShell.commandPrompt), isFalse);
    });
  });
}
