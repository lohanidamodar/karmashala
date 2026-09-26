import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// A `.git` that answers for one clone and nothing else.
class _OneRemote implements GitFiles {
  _OneRemote(this.url);

  /// Null spells a clone with no `origin` at all.
  final String? url;

  final List<String> reads = [];

  @override
  Future<String?> readString(String path) async {
    reads.add(path);
    if (!path.endsWith(r'\.git\config')) return null;
    if (url == null) return '[core]\n\tbare = false\n';
    return '[remote "origin"]\n\turl = $url\n';
  }

  @override
  Future<bool> exists(String path) async => throw UnimplementedError();

  @override
  Future<PathEntry> typeOf(String path) async => PathEntry.none;

  @override
  Future<void> createDirectory(String path) => throw UnimplementedError();

  @override
  Future<void> writeString(String path, String contents) =>
      throw UnimplementedError();
}

void main() {
  group('the identity a remote spells', () {
    // Every row is one repository written the different ways one machine ends
    // up holding it. The left column is what `.git/config` says; the right is
    // the key two of those checkouts have to agree on.
    const cases = <String, String?>{
      'git@github.com:PopupBits/Karmashala.git':
          'github.com/popupbits/karmashala',
      'https://github.com/popupbits/karmashala':
          'github.com/popupbits/karmashala',
      'https://dlohani:ghp_secret@github.com/PopupBits/karmashala.git/':
          'github.com/popupbits/karmashala',
      'ssh://git@github.com:2222/popupbits/karmashala.git':
          'github.com/popupbits/karmashala',
      // A nested group survives whole — it is part of the name, not the host.
      'git@gitlab.com:acme/platform/api.git': 'gitlab.com/acme/platform/api',
      // An explicit web port *is* the address and is kept.
      'https://git.example.com:8443/acme/app.git':
          'git.example.com:8443/acme/app',
      // And the four ways to have nothing to say.
      r'C:\src\demo\app': null,
      'file:///home/me/app': null,
      '/home/me/app': null,
      '': null,
    };

    for (final entry in cases.entries) {
      test('${entry.key.isEmpty ? '(empty)' : entry.key} → ${entry.value}', () {
        expect(canonicalRepositoryId(entry.key), entry.value);
      });
    }

    test('nothing read is not a repository with no remote', () {
      expect(canonicalRepositoryId(null), isNull);
    });
  });

  group('wired to the reading the app already takes', () {
    Future<String?> identityAfterReading(String? url) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final server = FakeDataServer()
        ..projectRows.insert(project())
        ..repositoryRows.insert(repository());
      server.environmentRows.upsert(windowsEnv());

      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db, gitFiles: _OneRemote(url)),
          await server.override(),
        ],
      );
      addTearDown(container.dispose);

      await container.read(
        repositoryOriginProvider(Checkout(repository().path)).future,
      );
      await pumpEventQueue();
      return server.repositoryRows.getById('r1')!.canonicalId;
    }

    test('reading a checkout is what records what it is', () async {
      expect(
        await identityAfterReading('git@github.com:acme/app.git'),
        'github.com/acme/app',
      );
    });

    test(
      'a clone with no origin stays null, and nothing groups on it',
      () async {
        expect(await identityAfterReading(null), isNull);
      },
    );
  });
}
