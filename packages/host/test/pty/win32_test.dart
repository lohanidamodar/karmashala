import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The half of the Windows pty layer with no operating system behind it.
/// `CreateProcessW` takes one string that every C runtime unpicks again, so a
/// wrong rule splits an argument or breaks somebody else's parser.
void main() {
  group('windows argument quoting', () {
    test(
      'quotes only what needs it, so a space is never a second argument',
      () {
        expect(quoteWindowsArgument('plain'), 'plain');
        expect(quoteWindowsArgument('-d'), '-d');
        expect(quoteWindowsArgument('two words'), '"two words"');
        expect(quoteWindowsArgument('tab\there'), '"tab\there"');
        expect(quoteWindowsArgument('line\nbreak'), '"line\nbreak"');
        expect(quoteWindowsArgument(''), '""');
      },
    );

    test('escapes a quote and the backslashes in front of it', () {
      expect(quoteWindowsArgument(r'say "hi"'), r'"say \"hi\""');
      expect(quoteWindowsArgument(r'a\"b'), r'"a\\\"b"');
    });

    test('leaves an interior backslash alone', () {
      expect(quoteWindowsArgument(r'C:\Users\dlohani'), r'C:\Users\dlohani');
      expect(
        quoteWindowsArgument(r'C:\Program Files\x'),
        r'"C:\Program Files\x"',
      );
    });

    test(
      'doubles a trailing backslash run, which would escape the close quote',
      () {
        expect(quoteWindowsArgument(r'C:\my dir\'), r'"C:\my dir\\"');
        expect(quoteWindowsArgument(r'C:\my dir\\'), r'"C:\my dir\\\\"');
        // Unquoted there is no close quote to escape, so it stays as it is.
        expect(quoteWindowsArgument(r'C:\dir\'), r'C:\dir\');
      },
    );

    test('a command line is the arguments joined by one space', () {
      expect(
        windowsCommandLine(['cmd.exe', '/c', 'echo hello']),
        'cmd.exe /c "echo hello"',
      );
    });

    test(
      'an option reaches a program that reads its command line raw, unquoted',
      () {
        // `wsl.exe` does not strip quotes from its options: quoted, "-d" was
        // taken for the command to run (`zsh:1: command not found: -d`,
        // measured 2026-09-22), so no WSL pane could start in the host.
        expect(
          windowsCommandLine([
            'wsl.exe',
            '-d',
            'archlinux',
            '--cd',
            r'C:\Program Files',
          ]),
          r'wsl.exe -d archlinux --cd "C:\Program Files"',
        );
      },
    );
  });

  test('the pseudoconsole attribute is the number the SDK macro builds', () {
    // Pinned because UpdateProcThreadAttribute accepts a wrong value and it
    // only shows up as a pane that never paints.
    expect(kProcThreadAttributePseudoConsole, 0x00020016);
  });
}
