// Real H.264 into a real MP4, through the operating system's own encoder.
//
// ## This file can take the tester process down, and the crash is measured
//
// Under load — six gates at once — the case that renders an MP4 has killed
// `flutter_tester.exe` outright: no Dart exception, every later case in the
// file reported "did not complete". `device_mp4_recording_test.dart` and
// `recording_tools_test.dart` go through the same encoder and do the same
// thing. Alone, all three pass.
//
// **Measured 2026-09-09 from the Windows Application log, and it is not
// Media Foundation's own DLLs.** Sixteen crashes between 2026-09-08 17:14 and
// 2026-09-09 02:42, every one of them identical in the part that matters:
//
//   Faulting application: flutter_tester.exe
//   Faulting module:      flutter_tester.exe   <- not mfplat/mfreadwrite/mf
//   Fault offset:         0x000000000035aaf0   <- the same site every time
//   Exception code:       0xc0000005 (10x) / 0x80000001 (6x)
//
// One site in the engine binary, alternating between an access violation and
// a guard-page violation — which is what a stack that cannot grow looks like
// on Windows, and why it only shows up when the machine is short.
//
// The Windows Error Reporting record (event 1001) is what ties it to *this*
// code: it attached `%TEMP%\karmashala-mp4-probe-<pid>.mp4`, the file
// `probeVideoSupport` opens, so the process that died was inside the probe.
// Its loaded-module list also shows what the probe drags in, because
// `_Mp4Sink.open` asks for `MFT_ENABLE_HARDWARE_TRANSFORMS`: NVIDIA's
// `nvEncMFTH264x.dll` and Intel's whole media stack — `mfx_mft_h264ve_64.dll`,
// `libmfx64-gen.dll`, `igc64.dll`, `igd10iumd64.dll` and eight more UMD
// libraries — loaded into every test process that touches an MP4.
//
// **Nothing was changed in `media_foundation.dart` on this evidence.** The
// faulting module is the engine, not `mfplat`, `mfreadwrite` or `mf.dll`, and
// turning hardware transforms off would trade a real feature against a guess.
//
// ### Repeating the measurement
//
// 1. Make a second worktree and start a full `flutter test` in it, so the
//    machine is loaded by something other than the run being watched.
// 2. Run the three files together in this worktree, repeatedly:
//    `flutter test test/core/media/video_writer_test.dart
//     test/features/devices/device_mp4_recording_test.dart
//     test/features/mcp/recording_tools_test.dart`
// 3. Read the log, in PowerShell — the crash leaves nothing in the test
//    output but "did not complete":
//    `Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000}`
//    for the faulting module and exception code, and `Id=1001` for the
//    attached files and the loaded-module list.
//
// Attempted 2026-09-09 in eight runs at `--concurrency=4` and `8`, alongside a
// full suite in a second worktree and nineteen other `flutter_tester`
// processes live: green every time, no new event. So the sixteen above remain
// the whole of the evidence, and a fix needs a symbolised stack from the
// minidump WER keeps beside the report, not another guess.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/media/frame_sink.dart';
import 'package:karmashala/src/core/media/media_foundation.dart';

import 'mp4_reader.dart';

/// A 4x4 frame of one flat colour.
RgbaFrame _frame(int r, int g, int b, {int size = 64}) {
  final rgba = Uint8List(size * size * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
  return RgbaFrame(
    rgba: rgba,
    width: size,
    height: size,
    hold: const Duration(milliseconds: 83),
  );
}

void main() {
  group('video support', () {
    test('says which platform it is speaking for either way', () {
      final support = probeVideoSupport();
      expect(support.detail, isNotEmpty);
      if (!Platform.isWindows) {
        expect(support.available, isFalse);
        // §19: the reason names the platform, not a shrug.
        expect(support.detail.toLowerCase(), contains(Platform.operatingSystem));
      }
    });

    test('on Windows it names the encoder it found', () {
      final support = probeVideoSupport();
      expect(support.available, isTrue, reason: support.detail);
      expect(support.detail.toLowerCase(), contains('h.264'));
    }, skip: !Platform.isWindows);
  });

  group('Media Foundation encoder', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mf-encode'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writes an MP4 that starts with an ftyp box', () {
      final path = '${dir.path}${Platform.pathSeparator}out.mp4';
      final encoder = openMediaFoundationEncoder(
        path: path,
        width: 64,
        height: 64,
        frameRate: 12,
      );
      for (var i = 0; i < 12; i++) {
        encoder.add(_frame(i * 20, 255 - i * 20, 128));
      }
      final bytes = encoder.finish();
      expect(bytes, greaterThan(0));
      final head = File(path).readAsBytesSync().sublist(4, 8);
      expect(String.fromCharCodes(head), 'ftyp');
      expect(File(path).lengthSync(), bytes);
    }, skip: !Platform.isWindows);

    test('abort leaves no file behind', () {
      final path = '${dir.path}${Platform.pathSeparator}gone.mp4';
      final encoder = openMediaFoundationEncoder(
        path: path,
        width: 64,
        height: 64,
        frameRate: 12,
      );
      encoder.add(_frame(10, 20, 30));
      encoder.abort();
      expect(File(path).existsSync(), isFalse);
    }, skip: !Platform.isWindows);

    test('a remux of its own output is byte-identical in the payload', () {
      final source = '${dir.path}${Platform.pathSeparator}src.mp4';
      final encoder = openMediaFoundationEncoder(
        path: source,
        width: 64,
        height: 64,
        frameRate: 12,
      );
      for (var i = 0; i < 12; i++) {
        encoder.add(_frame(i * 20, 255 - i * 20, 128));
      }
      encoder.finish();

      final track = readMp4Track(File(source).readAsBytesSync());
      final copy = '${dir.path}${Platform.pathSeparator}copy.mp4';
      final remuxer = openMediaFoundationRemuxer(
        path: copy,
        width: 64,
        height: 64,
        frameRate: 12,
        sequenceHeader: track.sequenceHeader,
      );
      for (final frame in track.frames) {
        remuxer.add(frame);
      }
      expect(remuxer.finish(), greaterThan(0));

      final before = readMp4Track(File(source).readAsBytesSync());
      final after = readMp4Track(File(copy).readAsBytesSync());
      expect(after.frames.length, before.frames.length);
      for (var i = 0; i < after.frames.length; i++) {
        expect(after.frames[i].bytes, before.frames[i].bytes);
      }
    }, skip: !Platform.isWindows);
  });
}
