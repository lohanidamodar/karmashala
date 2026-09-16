import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:karmashala_devices/src/application/device_file_staging.dart';
import 'package:karmashala_devices/src/domain/android_device.dart';
import 'package:karmashala_devices/src/domain/device_file_clipboard.dart';
import 'package:karmashala_devices/src/domain/device_files.dart';
import 'package:karmashala_devices/src/domain/device_target.dart';

DeviceFileEntry _file(String path) => DeviceFileEntry(
  path: path,
  name: path.split('/').last,
  kind: DeviceEntryKind.file,
);

DeviceFileEntry _dir(String path) => DeviceFileEntry(
  path: path,
  name: path.split('/').last,
  kind: DeviceEntryKind.directory,
);

DeviceTarget _target(String serial) => AndroidTarget(
  AndroidDevice(
    serial: serial,
    environmentId: 'windows',
    state: DeviceConnectionState.device,
  ),
);

void main() {
  group('the device file clipboard', () {
    test('a paste into the same folder is refused by name', () {
      final clip = DeviceFileClipboard(
        serial: 'emulator-5554',
        entries: [_file('/sdcard/DCIM/a.jpg')],
        mode: DeviceFileClipboardMode.copy,
      );
      expect(
        clip.refusalFor(
          intoSerial: 'emulator-5554',
          directory: '/sdcard/DCIM',
        ),
        contains('already in /sdcard/DCIM'),
      );
    });

    test('a paste into another folder on the same device is allowed', () {
      final clip = DeviceFileClipboard(
        serial: 'emulator-5554',
        entries: [_file('/sdcard/DCIM/a.jpg')],
        mode: DeviceFileClipboardMode.copy,
      );
      expect(
        clip.refusalFor(
          intoSerial: 'emulator-5554',
          directory: '/sdcard/Download',
        ),
        isNull,
      );
    });

    test('a paste onto a different device says what to do instead', () {
      // Two devices can be attached and /sdcard/DCIM/a.jpg exists on both;
      // running the copy would have written to whichever one adb reached.
      final clip = DeviceFileClipboard(
        serial: 'emulator-5554',
        entries: [_file('/sdcard/DCIM/a.jpg')],
        mode: DeviceFileClipboardMode.copy,
      );
      final refusal = clip.refusalFor(
        intoSerial: 'F6IZLV6LMFT4U4ZT',
        directory: '/sdcard/Download',
      );
      expect(refusal, contains('emulator-5554'));
      expect(refusal, contains('F6IZLV6LMFT4U4ZT'));
      expect(refusal, contains('pull followed by a push'));
    });

    test('a directory pasted into itself is refused, not started', () {
      final clip = DeviceFileClipboard(
        serial: 'emulator-5554',
        entries: [_dir('/sdcard/pics')],
        mode: DeviceFileClipboardMode.copy,
      );
      expect(
        clip.refusalFor(
          intoSerial: 'emulator-5554',
          directory: '/sdcard/pics/inner',
        ),
        contains('does not terminate'),
      );
    });

    test('a file whose name merely shares a prefix is not "inside" it', () {
      // `/sdcard/picsandmore` starts with `/sdcard/pics` as a string. Only a
      // separator makes it a subtree.
      final clip = DeviceFileClipboard(
        serial: 'emulator-5554',
        entries: [_dir('/sdcard/pics')],
        mode: DeviceFileClipboardMode.copy,
      );
      expect(
        clip.refusalFor(
          intoSerial: 'emulator-5554',
          directory: '/sdcard/picsandmore',
        ),
        isNull,
      );
    });

    test('an empty clipboard is refused rather than pasted as nothing', () {
      const clip = DeviceFileClipboard(
        serial: 'emulator-5554',
        entries: [],
        mode: DeviceFileClipboardMode.copy,
      );
      expect(
        clip.refusalFor(intoSerial: 'emulator-5554', directory: '/sdcard'),
        contains('nothing on the clipboard'),
      );
    });

    test('a cut is consumed by its paste and a copy is not', () {
      // A cut pasted twice would move paths that no longer exist and report a
      // device fault for the app's own bookkeeping.
      final cut = DeviceFileClipboard(
        serial: 'e',
        entries: [_file('/sdcard/a')],
        mode: DeviceFileClipboardMode.cut,
      );
      expect(cut.afterPaste(), isNull);
      final copy = DeviceFileClipboard(
        serial: 'e',
        entries: [_file('/sdcard/a')],
        mode: DeviceFileClipboardMode.copy,
      );
      expect(copy.afterPaste(), same(copy));
    });

    test('the summary names one item and counts several', () {
      expect(
        DeviceFileClipboard(
          serial: 'e',
          entries: [_file('/sdcard/a.jpg')],
          mode: DeviceFileClipboardMode.cut,
        ).summary,
        'Cut a.jpg',
      );
      expect(
        DeviceFileClipboard(
          serial: 'e',
          entries: [_file('/sdcard/a'), _file('/sdcard/b')],
          mode: DeviceFileClipboardMode.copy,
        ).summary,
        'Copy 2 items',
      );
    });
  });

  group('the host staging path', () {
    // The staging code joins with this host's separator, so the temp root has to
    // be one this host could hand it. The colon rule is still checked here: the
    // id is flattened on every platform, not only where a colon would hurt.
    final temp = Platform.isWindows
        ? r'C:\Users\x\AppData\Local\Temp'
        : '/Users/x/Library/Caches/TemporaryItems';
    final sep = p.separator;

    test('a cabled serial is used as it stands', () {
      expect(
        deviceStagingDirectory(
          target: _target('F6IZLV6LMFT4U4ZT'),
          temporaryDirectory: temp,
        ),
        '$temp${sep}karmashala-device-files${sep}F6IZLV6LMFT4U4ZT',
      );
    });

    test('a HOST:PORT id never puts a colon in a Windows path', () {
      // A colon here does not fail — it opens an alternate data stream, so the
      // pull writes where nothing reads back and every step reports success.
      final path = deviceStagedFilePath(
        target: _target('192.168.1.24:37129'),
        temporaryDirectory: temp,
        name: 'a.jpg',
      );
      expect(path, endsWith('192.168.1.24-37129${sep}a.jpg'));
      // Nothing below the temp root carries a colon; a drive letter's is legal.
      expect(path.substring(temp.length), isNot(contains(':')));
    });

    test('an mDNS id is flattened too, dots and all kept', () {
      final path = deviceStagingDirectory(
        target: _target('adb-2B071FDH300JJ9-zcg43M._adb-tls-connect._tcp'),
        temporaryDirectory: temp,
      );
      expect(
        path,
        endsWith('${sep}adb-2B071FDH300JJ9-zcg43M._adb-tls-connect._tcp'),
      );
      expect(path.substring(temp.length), isNot(contains(':')));
    });

    test('two devices get two directories, so names cannot collide', () {
      expect(
        deviceStagedFilePath(
          target: _target('emulator-5554'),
          temporaryDirectory: temp,
          name: 'screen.png',
        ),
        isNot(
          deviceStagedFilePath(
            target: _target('emulator-5556'),
            temporaryDirectory: temp,
            name: 'screen.png',
          ),
        ),
      );
    });

    test('the device-side name is used verbatim', () {
      // It came from the device's own listing; rewriting it would hand the user
      // a file whose name is not the one they copied.
      expect(
        deviceStagedFilePath(
          target: _target('emulator-5554'),
          temporaryDirectory: temp,
          name: 'नेपाली.txt',
        ),
        endsWith('$sepनेपाली.txt'),
      );
    });
  });
}
