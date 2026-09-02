import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';

/// Which separator a path in an environment is built with.
///
/// Three callers each hard-coded the Windows context — the account reader, the
/// usage reader and the store scanner. On a Mac that turned `/Users/me/.codex`
/// into `/Users/me\auth.json`, a file that cannot exist, so a signed-in account
/// reported itself signed out and usage could never be read. The failure is
/// silent, which is why the rule lives in one tested place now.
void main() {
  group('storePathContextFor', () {
    test('a POSIX host builds POSIX paths', () {
      expect(
        storePathContextFor(
          EnvironmentKind.localPosix,
        ).join('/Users/me/.codex', 'auth.json'),
        '/Users/me/.codex/auth.json',
      );
    });

    test('a Windows host builds Windows paths', () {
      expect(
        storePathContextFor(
          EnvironmentKind.windowsNative,
        ).join(r'C:\Users\me', 'auth.json'),
        r'C:\Users\me\auth.json',
      );
    });

    test('WSL stays on the Windows context', () {
      // Its store is reached from the host through the `\\wsl.localhost\…` UNC
      // form, which is a Windows path however Linux-shaped the machine is —
      // so it must not switch to POSIX just because the guest is Linux.
      // `usesWindowsPaths(wsl)` is false — paths *inside* WSL are POSIX — but
      // the store home this joins onto is the UNC form, which is not.
      expect(usesWindowsPaths(EnvironmentKind.wsl), isFalse);
      expect(
        storePathContextFor(EnvironmentKind.wsl).separator,
        storePathContextFor(EnvironmentKind.windowsNative).separator,
      );
    });

    test('an SSH host builds POSIX paths', () {
      expect(storePathContextFor(EnvironmentKind.ssh).separator, '/');
    });

    test('an unknown environment keeps the old default', () {
      expect(storePathContextFor(null).separator, r'\');
    });
  });
}
