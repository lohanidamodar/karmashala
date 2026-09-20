import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The half of the Windows pty layer with no operating system behind it.
/// `CreateProcessW` takes one string that every C runtime unpicks again, so a
/// wrong rule splits an argument or breaks somebody else's parser.
void main() {
  group('windows argument quoting', () {
    test('always quotes, so a space is never a second argument', () {
      expect(quoteWindowsArgument('plain'), '"plain"');
      expect(quoteWindowsArgument('two words'), '"two words"');
      expect(quoteWindowsArgument(''), '""');
    });

    test('escapes a quote and the backslashes in front of it', () {
      expect(quoteWindowsArgument(r'say "hi"'), r'"say \"hi\""');
      expect(quoteWindowsArgument(r'a\"b'), r'"a\\\"b"');
    });

    test('leaves an interior backslash alone', () {
      expect(quoteWindowsArgument(r'C:\Users\dlohani'), r'"C:\Users\dlohani"');
    });

    test(
      'doubles a trailing backslash run, which would escape the close quote',
      () {
        expect(quoteWindowsArgument(r'C:\dir\'), r'"C:\dir\\"');
        expect(quoteWindowsArgument(r'C:\dir\\'), r'"C:\dir\\\\"');
      },
    );

    test('a command line is the arguments joined by one space', () {
      expect(
        windowsCommandLine(['cmd.exe', '/c', 'echo hello']),
        '"cmd.exe" "/c" "echo hello"',
      );
    });
  });

  test('the pseudoconsole attribute is the number the SDK macro builds', () {
    // Pinned because UpdateProcThreadAttribute accepts a wrong value and it
    // only shows up as a pane that never paints.
    expect(kProcThreadAttributePseudoConsole, 0x00020016);
  });
}
