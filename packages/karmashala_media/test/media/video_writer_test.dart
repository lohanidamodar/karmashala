// Real H.264 into a real MP4, through the operating system's own encoder.
//
// Every open here passes `hardwareTransforms: false`: asking for the vendor
// MFTs has killed `flutter_tester.exe` outright under load, with nothing in the
// test output but "did not complete". `an encode here loads no vendor hardware
// encoder` below is the guard, and docs/SETTLED.md has the measurement and how
// to repeat it.

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

/// The vendor encoder MFTs a hardware open loads, and a software one must not.
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

    // A module stays loaded for the life of the process, so one vendor MFT
    // opened anywhere in this file fails here.
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
