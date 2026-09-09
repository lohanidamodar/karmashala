import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/adb_file_parsing.dart';
import 'package:karmashala_devices/src/domain/device_files.dart';

/// Every fixture here is output this build has actually seen, or a documented
/// format from a device generation this app still supports. `ls -l` is not one
/// format — toybox, the old toolbox and busybox each print a different one —
/// and the whole value of these cases is that they are not invented.
void main() {
  group('shellQuote', () {
    test('wraps a path so the device shell does not split it', () {
      // `adb shell` joins its arguments and hands the string to sh on the
      // device, which splits it again. Unquoted, this is two arguments.
      expect(shellQuote('/sdcard/my file.txt'), "'/sdcard/my file.txt'");
    });

    test('survives an apostrophe, which is the only hard character', () {
      // Verified against a real emulator: `touch` with this exact quoting made
      // a file called `it's here.txt`.
      expect(shellQuote("/sdcard/it's here.txt"), r"'/sdcard/it'\''s here.txt'");
    });

    test('leaves shell metacharacters inert rather than escaping them', () {
      // Inside single quotes the device's shell expands nothing, so `$HOME`
      // arrives as four characters and a glob matches only itself.
      expect(shellQuote(r'/sdcard/$HOME *.txt'), r"'/sdcard/$HOME *.txt'");
    });

    test('passes non-ASCII through untouched', () {
      expect(shellQuote('/sdcard/नेपाली.txt'), "'/sdcard/नेपाली.txt'");
    });
  });

  group('parseLsLong on toybox — Android 6 and up', () {
    // Captured verbatim from the owner's handset (CPH1989, Android 11).
    const listing = '''
total 1392
-rw-rw---- 1 root everybody     16 2026-09-01 18:49 .dev
drwxrwx--- 2 root everybody   4096 2024-12-11 18:44 Alarms
drwxrwx--- 4 root everybody   4096 2025-07-20 14:29 DCIM
''';

    test('reads the columns a modern device prints', () {
      final result = parseLsLong(listing, directory: '/sdcard');

      expect(result.skipped, isEmpty);
      expect(result.entries.map((e) => e.name), ['Alarms', 'DCIM', '.dev']);
      final dev = result.entries.last;
      expect(dev.kind, DeviceEntryKind.file);
      expect(dev.sizeBytes, 16);
      expect(dev.owner, 'root');
      expect(dev.group, 'everybody');
      expect(dev.mode, '-rw-rw----');
      expect(dev.modifiedLabel, '2026-09-01 18:49');
      expect(dev.path, '/sdcard/.dev');
    });

    test('puts directories first, then names, case-insensitively', () {
      // The order a file browser is expected to be in, decided in the parser
      // so the pane and the MCP tool cannot disagree about it.
      final result = parseLsLong(listing, directory: '/sdcard');
      expect(result.entries.take(2).every((e) => e.isDirectory), isTrue);
    });

    test('keeps a name with spaces and non-ASCII whole', () {
      // Pushed to a real emulator and listed back, exactly this line.
      final result = parseLsLong(
        '-rw-rw---- 1 u0_a182 media_rw 17 2026-09-03 18:52 '
        'my file नेपाली.txt\n',
        directory: '/sdcard/karmashala test dir',
      );

      expect(result.entries.single.name, 'my file नेपाली.txt');
      expect(
        result.entries.single.path,
        '/sdcard/karmashala test dir/my file नेपाली.txt',
      );
    });

    test('reports a symlink as a symlink, with where it points', () {
      final result = parseLsLong(
        'lrw-r--r--   1 root   root         11 2026-01-07 18:40 '
        'bin -> /system/bin\n',
        directory: '/',
      );

      final link = result.entries.single;
      expect(link.kind, DeviceEntryKind.symlink);
      expect(link.name, 'bin');
      expect(link.linkTarget, '/system/bin');
      // The size column of a symlink is the length of its target, not a file
      // size, but it is what the device said and this does not second-guess it.
      expect(link.path, '/bin');
    });

    test('drops . and .. rather than offering them as folders', () {
      final result = parseLsLong(
        'drwxr-xr-x  31 root root 4096 2026-01-07 18:40 .\n'
        'drwxr-xr-x  31 root root 4096 2026-01-07 18:40 ..\n'
        'drwxr-xr-x   2 root root 4096 2009-01-01 05:45 debug_ramdisk\n',
        directory: '/',
      );

      expect(result.entries.map((e) => e.name), ['debug_ramdisk']);
    });
  });

  group('rows a device could not stat', () {
    // Also real, from `/` on the owner's handset. Half a dozen rows look like
    // this, and hiding them would be wrong twice over: they exist, and *why*
    // they cannot be read is the interesting part.
    const unstattable =
        'd?????????   ? ?      ?             ?                ? data_mirror\n'
        'l?????????   ? ?      ?             ?                ? init -> ?\n';

    test('keeps the entry, marked unreadable, rather than dropping it', () {
      final result = parseLsLong(unstattable, directory: '/');

      expect(result.skipped, isEmpty);
      expect(result.entries.map((e) => e.name), ['data_mirror', 'init']);
      final mirror = result.entries.first;
      expect(mirror.kind, DeviceEntryKind.directory);
      expect(mirror.readable, isFalse);
      expect(mirror.sizeBytes, isNull);
      expect(mirror.modifiedLabel, isNull);
    });

    test('a link whose target is unknown says null, not "?"', () {
      final result = parseLsLong(unstattable, directory: '/');
      final init = result.entries.last;
      expect(init.kind, DeviceEntryKind.symlink);
      expect(init.linkTarget, isNull);
    });
  });

  group('older and stranger formats', () {
    test('busybox month-name dates still find where the name begins', () {
      final result = parseLsLong(
        '-rw-r--r--    1 root     root            17 Sep  3 18:52 notes.txt\n'
        'drwxr-xr-x    2 root     root          4096 Jan 14  2024 old\n',
        directory: '/data/local/tmp',
      );

      expect(result.skipped, isEmpty);
      expect(result.entries.map((e) => e.name), ['old', 'notes.txt']);
      expect(result.entries.last.sizeBytes, 17);
      // Kept as the device's own words. `Jan 14  2024` has a year and
      // `Sep  3 18:52` does not, so turning either into a DateTime would mean
      // inventing a year, a timezone, or both.
      expect(result.entries.first.modifiedLabel, 'Jan 14  2024');
    });

    test('a toolbox directory with no size column is not given one', () {
      // Android 5 and earlier print no size for a directory and no link count
      // at all, so counting columns from the left reads the group as the size.
      final result = parseLsLong(
        'drwxrwx--- root     everybody          2024-12-11 18:44 Alarms\n',
        directory: '/sdcard',
      );

      final entry = result.entries.single;
      expect(entry.name, 'Alarms');
      expect(entry.sizeBytes, isNull);
      expect(entry.owner, 'root');
      expect(entry.group, 'everybody');
    });

    test('a device node reports no size rather than its minor number', () {
      // `1, 3` sits where the size goes. Reporting /dev/null as 3 bytes is
      // exactly the confidently-wrong row this parser must never emit.
      final result = parseLsLong(
        'crw-rw-rw- 1 root root 1, 3 2026-08-21 17:42 null\n',
        directory: '/dev',
      );

      final entry = result.entries.single;
      expect(entry.name, 'null');
      expect(entry.kind, DeviceEntryKind.other);
      expect(entry.sizeBytes, isNull);
      expect(entry.owner, 'root');
      expect(entry.group, 'root');
    });
  });

  group('a line it cannot read', () {
    test('becomes a skipped entry with a reason, never a crash', () {
      final result = parseLsLong(
        'drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 Alarms\n'
        'this is not an ls row at all\n',
        directory: '/sdcard',
      );

      expect(result.entries.map((e) => e.name), ['Alarms']);
      expect(result.skipped.single.line, 'this is not an ls row at all');
      expect(result.skipped.single.reason, isNotEmpty);
    });

    test('and never a row with invented values', () {
      // A permissions word but no date: where the name begins is genuinely
      // unknowable, so nothing is guessed.
      final result = parseLsLong(
        '-rw-rw---- 1 root everybody 16 whenever .dev\n',
        directory: '/sdcard',
      );

      expect(result.entries, isEmpty);
      expect(result.skipped, hasLength(1));
      expect(result.skipped.single.reason, contains('date'));
    });

    test('a per-entry refusal from ls is kept as a skipped row', () {
      final result = parseLsLong(
        'ls: /sdcard/secret: Permission denied\n'
        'drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 Alarms\n',
        directory: '/sdcard',
      );

      expect(result.entries.map((e) => e.name), ['Alarms']);
      expect(result.skipped.single.reason, contains('refused'));
    });
  });

  group('classifyLsFailure', () {
    test('names a refusal, which must never look like an empty folder', () {
      // Real: `ls -la /data` on the owner's handset, exit 1, on stderr.
      expect(
        classifyLsFailure('ls: /data: Permission denied', ok: false),
        LsFailure.permissionDenied,
      );
    });

    test('tells absent apart from unreadable', () {
      expect(
        classifyLsFailure('ls: /sdcard/nope: No such file or directory',
            ok: false),
        LsFailure.missing,
      );
      expect(
        classifyLsFailure('ls: /sdcard/a.txt/: Not a directory', ok: false),
        LsFailure.notADirectory,
      );
    });

    test('reads the output, not only the exit status', () {
      // adb shell did not forward the remote exit code before Android 7, so a
      // refusal arrives with exit 0 on those devices.
      expect(
        classifyLsFailure('ls: /data: Permission denied', ok: true),
        LsFailure.permissionDenied,
      );
    });

    test('a good listing is not a failure', () {
      expect(
        classifyLsFailure(
          'drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 Alarms',
          ok: true,
        ),
        isNull,
      );
    });

    test('a non-zero exit with words it does not know is still a failure', () {
      expect(classifyLsFailure('something went wrong', ok: false),
          LsFailure.unknown);
    });
  });

  group('transfer output', () {
    // Measured: this arrives on **stderr** with exit code 0.
    const pulled =
        '/sdcard/.dev: 1 file pulled, 0 skipped. 0.0 MB/s (16 bytes in 0.006s)';

    test('reads the byte count out of adb\'s summary line', () {
      expect(parseTransferredBytes(pulled), 16);
      expect(transferSucceeded(pulled), isTrue);
    });

    test('a push says pushed, and that counts too', () {
      expect(
        transferSucceeded(
          r'C:\tmp\a.txt: 1 file pushed, 0 skipped. 0.0 MB/s '
          '(17 bytes in 0.002s)',
        ),
        isTrue,
      );
    });

    test('an adb error is not a success however it is spelled', () {
      const failed =
          "adb: error: remote object '/data/x' does not exist";
      expect(transferSucceeded(failed), isFalse);
      expect(parseTransferredBytes(failed), isNull);
      expect(cleanAdbError(failed), "remote object '/data/x' does not exist");
    });

    test('an error with no adb prefix is still reported verbatim', () {
      expect(cleanAdbError('rm: /system/build.prop: Read-only file system'),
          'rm: /system/build.prop: Read-only file system');
    });
  });

  group('device paths are always forward slashes', () {
    test('joining never uses the host separator', () {
      // package:path would build `\sdcard\DCIM` on Windows, where this app
      // mostly runs — a perfectly good Windows path and not a path on a phone.
      expect(devicePathJoin('/sdcard', 'DCIM'), '/sdcard/DCIM');
      expect(devicePathJoin('/sdcard/', 'DCIM'), '/sdcard/DCIM');
      expect(devicePathJoin('/', 'system'), '/system');
    });

    test('the parent of a root is nothing, which is how "up" stops', () {
      expect(devicePathParent('/sdcard/DCIM/Camera'), '/sdcard/DCIM');
      expect(devicePathParent('/sdcard'), '/');
      expect(devicePathParent('/'), isNull);
    });

    test('a basename ignores a trailing slash', () {
      expect(devicePathBasename('/sdcard/DCIM/'), 'DCIM');
      expect(devicePathBasename('/sdcard/a b.txt'), 'a b.txt');
    });
  });
}
