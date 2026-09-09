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
// ## The fix: the tester does not ask for the hardware encoder
//
// `appHardwareTransforms` is true in the app, where the hardware encoder is
// the point, and every open in these three files passes `false`. The attribute
// is then omitted rather than set to zero, so MF uses its own default and the
// vendor MFTs are never loaded — which `an encode here loads no vendor
// hardware encoder` below checks by asking `GetModuleHandleW` for them.
//
// **Measured 2026-09-09, five runs each way**, the three files together at
// `--concurrency=8` beside a full suite in a second worktree:
//
//   before   2 of 5 killed the tester, +2 event 1000 (0x80000001, the same
//            0x35aaf0), both WER records attaching a probe MP4; runs 5-39 s
//   after    5 of 5 green, no new event of either id; runs 2-9 s
//
// The speed is the same finding from the other side: loading NVIDIA's and
// Intel's stacks cost more than the encode did.
//
// It is a mitigation and not a diagnosis. The faulting module is still the
// engine rather than `mfplat`, so what the crash *is* would still need a
// symbolised stack from the minidump WER keeps beside the report; what is
// established is which attribute has to be set for it to happen at all.
//
// ### Repeating the measurement
//
// 1. Make a second worktree and start a full `flutter test` in it, so the
//    machine is loaded by something other than the run being watched.
// 2. Run the three files together in this worktree, repeatedly:
//    `flutter test test/core/media/video_writer_test.dart
//     test/features/devices/device_mp4_recording_test.dart
//     test/features/mcp/recording_tools_test.dart --concurrency=8`
// 3. Read the log, in PowerShell — the crash leaves nothing in the test
//    output but "did not complete":
//    `Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000}`
//    for the faulting module and exception code, and `Id=1001` for the
//    attached files and the loaded-module list.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:karmashala_media/media.dart';

import 'package:karmashala_media/testing.dart';
import '../support/temp_directory.dart';

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

/// Whether a DLL of that name is loaded into this process right now.
///
/// `GetModuleHandleW` rather than an enumeration: the question is about three
/// named libraries, and a handle either exists or it does not.
bool _isLoaded(String dll) {
  final name = calloc<Uint16>(dll.length + 1);
  try {
    for (var i = 0; i < dll.length; i++) {
      (name + i).value = dll.codeUnitAt(i);
    }
    return DynamicLibrary.open('kernel32.dll').lookupFunction<
          IntPtr Function(Pointer<Uint16>),
          int Function(Pointer<Uint16>)
        >('GetModuleHandleW')(name) !=
        0;
  } finally {
    calloc.free(name);
  }
}

/// The vendor encoder MFTs the WER report listed, and the ones this machine
/// has. A hardware open loads them; a software one must not.
const _vendorEncoderMfts = [
  'nvEncMFTH264x.dll',
  'mfx_mft_h264ve_64.dll',
  'libmfx64-gen.dll',
];

void main() {
  group('video support', () {
    test('says which platform it is speaking for either way', () {
      final support = probeVideoSupport(hardwareTransforms: false);
      expect(support.detail, isNotEmpty);
      if (!Platform.isWindows) {
        expect(support.available, isFalse);
        // §19: the reason names the platform, not a shrug.
        expect(support.detail.toLowerCase(), contains(Platform.operatingSystem));
      }
    });

    test('on Windows it names the encoder it found', () {
      final support = probeVideoSupport(hardwareTransforms: false);
      expect(support.available, isTrue, reason: support.detail);
      expect(support.detail.toLowerCase(), contains('h.264'));
    }, skip: !Platform.isWindows);
  });

  group('Media Foundation encoder', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mf-encode'));
    tearDown(() => removeTempDirectory(dir));

    test('writes an MP4 that starts with an ftyp box', () {
      final path = '${dir.path}${Platform.pathSeparator}out.mp4';
      final encoder = openMediaFoundationEncoder(
        path: path,
        width: 64,
        height: 64,
        frameRate: 12,
        hardwareTransforms: false,
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
        hardwareTransforms: false,
      );
      encoder.add(_frame(10, 20, 30));
      encoder.abort();
      expect(File(path).existsSync(), isFalse);
    }, skip: !Platform.isWindows);

    // The guard for the fix, and it reads the evidence rather than the flag:
    // every open in this file passes `hardwareTransforms: false`, and a module
    // stays loaded for the life of the process, so one vendor MFT anywhere in
    // the file fails this. It fails on the old code, where the attribute was
    // unconditional.
    test('an encode here loads no vendor hardware encoder', () {
      final path = '${dir.path}${Platform.pathSeparator}soft.mp4';
      final encoder = openMediaFoundationEncoder(
        path: path,
        width: 64,
        height: 64,
        frameRate: 12,
        hardwareTransforms: false,
      );
      for (var i = 0; i < 12; i++) {
        encoder.add(_frame(i * 20, 255 - i * 20, 128));
      }
      expect(encoder.finish(), greaterThan(0));

      for (final mft in _vendorEncoderMfts) {
        expect(
          _isLoaded(mft),
          isFalse,
          reason: '$mft is loaded here; see this file\'s doc comment',
        );
      }
    }, skip: !Platform.isWindows);

    test('a remux of its own output is byte-identical in the payload', () {
      final source = '${dir.path}${Platform.pathSeparator}src.mp4';
      final encoder = openMediaFoundationEncoder(
        path: source,
        width: 64,
        height: 64,
        frameRate: 12,
        hardwareTransforms: false,
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
        hardwareTransforms: false,
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
