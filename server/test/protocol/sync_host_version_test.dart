import 'package:test/test.dart';

import '../../../tool/sync_host_version.dart';

/// Every build writes the app's release into `kHostVersion`, so a version bump
/// that touches only `app/pubspec.yaml` still ships a host that says it.
void main() {
  const source = "/// Doc.\nconst String kHostVersion = '1.31.1';\n";

  test('reads the release, without the build number', () {
    expect(releaseOf('name: x\nversion: 1.32.0+61\n'), '1.32.0');
    expect(releaseOf('version:   2.0.0\r\n'), '2.0.0');
  });

  test('a pubspec without a version is refused', () {
    expect(() => releaseOf('name: x\n'), throwsFormatException);
  });

  test('rewrites a stale kHostVersion and keeps the rest', () {
    expect(
      withHostVersion(source, '1.32.0'),
      "/// Doc.\nconst String kHostVersion = '1.32.0';\n",
    );
  });

  test('leaves a current kHostVersion as it is', () {
    expect(withHostVersion(source, '1.31.1'), source);
  });

  test('a source without kHostVersion is refused', () {
    expect(
      () => withHostVersion('const x = 1;', '1.32.0'),
      throwsFormatException,
    );
  });
}
