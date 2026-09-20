import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

void main() {
  late Directory beside;
  late Directory repository;

  setUp(() {
    beside = Directory.systemTemp.createTempSync('beside');
    repository = Directory.systemTemp.createTempSync('repo');
  });

  tearDown(() {
    for (final directory in [beside, repository]) {
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can still hold a handle; the temp directory is not the test.
      }
    }
  });

  File give(String path) {
    final file = File(path)..parent.createSync(recursive: true);
    return file..writeAsStringSync('not really a binary');
  }

  LocalHostExecutable executable() => LocalHostExecutable(
    executableDirectory: beside.path,
    repositoryRoot: repository.path,
  );

  test(
    'nothing installed is nothing found, and the search says where it looked',
    () {
      expect(executable().locate(), isNull);
      expect(executable().describeSearch(), contains('host/bin'));
    },
  );

  test('the bundle beside the app wins', () {
    final bundled = give(
      '${beside.path}/host/bin/${LocalHostExecutable.fileName}',
    );

    expect(executable().locate()?.path, bundled.path);
  });

  test('a flat install from before the store still serves panes', () {
    final flat = give('${beside.path}/${LocalHostExecutable.fileName}');

    expect(executable().locate()?.path, flat.path);
  });

  test(
    'the bundle is preferred over a flat one, which cannot find its sqlite',
    () {
      give('${beside.path}/${LocalHostExecutable.fileName}');
      final bundled = give(
        '${beside.path}/host/bin/${LocalHostExecutable.fileName}',
      );

      expect(executable().locate()?.path, bundled.path);
    },
  );

  test(
    'a debug build is found under whatever target directory it landed in',
    () {
      // The `<os>_<arch>` name is the building machine's, so it is listed rather
      // than spelled out.
      final built = give(
        '${repository.path}/packages/host/build/cli/some_target/bundle/bin/'
        '${LocalHostExecutable.fileName}',
      );

      // As URIs: the listed directory carries the platform separator, and which
      // file was found is the claim, not how the path was spelled.
      expect(executable().locate()?.absolute.uri, built.absolute.uri);
    },
  );

  test('an installed host beats a debug build', () {
    give(
      '${repository.path}/packages/host/build/cli/some_target/bundle/bin/'
      '${LocalHostExecutable.fileName}',
    );
    final bundled = give(
      '${beside.path}/host/bin/${LocalHostExecutable.fileName}',
    );

    expect(executable().locate()?.path, bundled.path);
  });
}
