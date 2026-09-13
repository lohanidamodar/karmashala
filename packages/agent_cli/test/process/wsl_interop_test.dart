import 'package:agent_cli/src/process/wsl_interop.dart';
import 'package:test/test.dart';

/// Whether a distribution can start Windows programs at all.
///
/// This vanished three times on the owner's machine on 2026-09-03 and took
/// every MCP server, every `cmd.exe` and every Windows build tool inside WSL
/// with it. The parser's job is to tell "gone" from "we could not look", which
/// are the two answers a health panel must never confuse.
void main() {
  group('the command', () {
    test('runs in plain sh and asks about both handler names', () {
      final request = wslInteropRequest();
      expect(request.executable, 'sh');
      expect(request.arguments.first, '-c');
      final script = request.arguments[1];
      // Older WSL registers `WSLInterop`; newer builds register
      // `WSLInterop-late`. Knowing only one would report a healthy machine as
      // broken.
      expect(script, contains('WSLInterop'));
      expect(script, contains('WSLInterop-late'));
      expect(script, contains('/proc/sys/fs/binfmt_misc'));
    });
  });

  group('parsing', () {
    test('an enabled handler means Windows programs run', () {
      expect(
        parseWslInterop(
          '${kInteropMarker}WSLInterop=enabled\n${kInteropMarker}checked=1\n',
        ),
        WslInteropState.registered,
      );
    });

    test('the late handler counts too', () {
      expect(
        parseWslInterop(
          '${kInteropMarker}WSLInterop-late=enabled\n'
          '${kInteropMarker}checked=1\n',
        ),
        WslInteropState.registered,
      );
    });

    test('a registered but switched-off handler is a failure', () {
      expect(
        parseWslInterop(
          '${kInteropMarker}WSLInterop=disabled\n${kInteropMarker}checked=1\n',
        ),
        WslInteropState.disabled,
      );
    });

    test('either handler being enabled is enough', () {
      expect(
        parseWslInterop(
          '${kInteropMarker}WSLInterop=disabled\n'
          '${kInteropMarker}WSLInterop-late=enabled\n'
          '${kInteropMarker}checked=1\n',
        ),
        WslInteropState.registered,
      );
    });

    test('no handler at all is the failure that happened', () {
      expect(
        parseWslInterop('${kInteropMarker}checked=1\n'),
        WslInteropState.missing,
      );
    });

    test('output with no completion marker is unknown, never missing', () {
      // The distribution did not answer, or `sh` died halfway. Reporting
      // "missing" here would blame WSL for our own blind spot.
      expect(parseWslInterop(''), WslInteropState.unknown);
      expect(parseWslInterop('sh: not found\n'), WslInteropState.unknown);
    });

    test('a shell that printed a banner is still read correctly', () {
      expect(
        parseWslInterop(
          'Welcome to Arch Linux!\n'
          'You have mail.\n'
          '${kInteropMarker}WSLInterop=enabled\n'
          '${kInteropMarker}checked=1\n',
        ),
        WslInteropState.registered,
      );
    });

    test('UTF-16 noise from wsl.exe is stripped', () {
      final noisy =
          '﻿${kInteropMarker}WSLInterop=enabled\n'
          '${kInteropMarker}checked=1\n';
      expect(parseWslInterop(noisy), WslInteropState.registered);
    });
  });

  group('the repair line', () {
    // Offered to copy, so it must be usable verbatim.
    test('registers MZ against /init for this boot', () {
      expect(kWslInteropRepairCommand, contains(':WSLInterop:M::MZ::/init:PF'));
      expect(
        kWslInteropRepairCommand,
        contains('/proc/sys/fs/binfmt_misc/register'),
      );
      expect(kWslInteropRepairCommand, startsWith('sudo '));
    });

    test('and writes the file that makes the repair survive a shutdown', () {
      // Without this the handler goes again on the next boot:
      // systemd-binfmt.service, where WSL's own re-registration lives, is
      // skipped whenever every binfmt.d directory is empty.
      expect(
        kWslInteropRepairCommand,
        contains('/etc/binfmt.d/WSLInterop.conf'),
      );
    });

    test('drops a stale registration first, so a disabled one is repaired', () {
      // The same order WSL's own drop-in uses. Registering over a name that
      // already exists fails, which is exactly the "switched off" case.
      final unregister = kWslInteropRepairCommand.indexOf('echo -1 >');
      final register = kWslInteropRepairCommand.indexOf('binfmt_misc/register');
      expect(unregister, greaterThan(-1));
      expect(unregister, lessThan(register));
    });
  });
}
