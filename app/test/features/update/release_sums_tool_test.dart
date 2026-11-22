import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/update/domain/install_kind.dart';

// The scripts CI runs on every release.
import '../../../../tool/package_manifests.dart' show readSums;
import '../../../../tool/release_sums.dart';

String _hex(int seed) => seed.toRadixString(16).padLeft(2, '0') * 32;

Map<String, Object?> _asset(String name, int seed, {bool digest = true}) => {
  'name': name,
  'size': 1000 + seed,
  'digest': digest ? 'sha256:${_hex(seed).toUpperCase()}' : null,
  'browser_download_url':
      'https://github.com/lohanidamodar/karmashala/releases/download/v1.35.0/$name',
};

void main() {
  test('every file with a digest is listed, lower-case and sorted; the old '
      'SHA256SUMS.txt and undigested files are not', () {
    final sums = ReleaseSums.fromGitHub({
      'tag_name': 'v1.35.0',
      'assets': [
        _asset('Karmashala-windows-portable.zip', 2),
        _asset('Karmashala-Setup-1.35.0.exe', 1),
        _asset('Karmashala-macOS-1.35.0.dmg', 3),
        _asset('Karmashala-1.35.0-x86_64.AppImage', 4),
        _asset('install.sh', 8, digest: false),
        _asset('SHA256SUMS.txt', 10),
      ],
    });
    expect(sums.version, '1.35.0');
    expect(
      sums.text,
      '${_hex(4)}  Karmashala-1.35.0-x86_64.AppImage\n'
      '${_hex(1)}  Karmashala-Setup-1.35.0.exe\n'
      '${_hex(3)}  Karmashala-macOS-1.35.0.dmg\n'
      '${_hex(2)}  Karmashala-windows-portable.zip\n',
    );
    expect(sums.warnings, [
      'install.sh has no SHA-256 digest on GitHub; left out.',
    ]);
    // package_manifests.dart reads exactly what this writes.
    expect(readSums(sums.text), {
      'Karmashala-1.35.0-x86_64.AppImage': _hex(4),
      'Karmashala-Setup-1.35.0.exe': _hex(1),
      'Karmashala-macOS-1.35.0.dmg': _hex(3),
      'Karmashala-windows-portable.zip': _hex(2),
    });
  });

  test('a missing desktop file is warned about, not fatal', () {
    final sums = ReleaseSums.fromGitHub({
      'tag_name': 'v1.35.0',
      'assets': [_asset('Karmashala-Setup-1.35.0.exe', 1)],
    });
    expect(sums.count, 1);
    expect(sums.warnings, hasLength(3));
    expect(sums.warnings.first, contains('Karmashala-windows-portable.zip'));
  });

  test("the files it checks for are the ones the app's updater asks for", () {
    final names = desktopAssetNames('1.35.0');
    for (final kind in [
      InstallKind.windowsInstaller,
      InstallKind.linuxAppImage,
      InstallKind.macos,
    ]) {
      expect(names, contains(assetNameFor(kind, '1.35.0')), reason: '$kind');
    }
  });
}
