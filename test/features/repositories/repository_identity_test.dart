import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/checkout.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/application/repository_identity_recorder.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

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

  group('recording it', () {
    late AppDatabase db;
    late RepositoryDao dao;

    setUp(() {
      db = AppDatabase.memory();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      dao = RepositoryDao(db);
    });
    tearDown(() => db.close());

    test('a fresh row starts with none, which is the honest answer', () {
      dao.insert(repository());
      expect(dao.getById('r1')!.canonicalId, isNull);
    });

    test('a reading of origin names every row standing in that directory', () {
      dao.insert(repository());
      // The same directory recorded a second time with the other separator and
      // the other case, which is how two spellings of one tree get in.
      dao.insert(
        repository(id: 'r2', name: 'app (again)', path: r'c:/src/demo/app/'),
      );
      dao.insert(repository(id: 'r3', name: 'other', path: r'C:\src\demo\lib'));

      recordRepositoryIdentity(
        dao,
        const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\app',
        ),
        const RepositoryOrigin(url: 'git@github.com:acme/app.git'),
      );

      expect(dao.getById('r1')!.canonicalId, 'github.com/acme/app');
      expect(dao.getById('r2')!.canonicalId, 'github.com/acme/app');
      // A different directory is a different question, and was not asked.
      expect(dao.getById('r3')!.canonicalId, isNull);
    });

    test('a remote that went away clears the key rather than keeping it', () {
      dao.insert(repository());
      final at = const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\app',
      );
      recordRepositoryIdentity(
        dao,
        at,
        const RepositoryOrigin(url: 'https://github.com/acme/app.git'),
      );
      expect(dao.getById('r1')!.canonicalId, 'github.com/acme/app');

      // Repointed at a local path: the old key is now wrong, not merely stale.
      recordRepositoryIdentity(
        dao,
        at,
        const RepositoryOrigin(url: r'C:\mirrors\app'),
      );
      expect(dao.getById('r1')!.canonicalId, isNull);
    });

    test('a rescan does not undo it', () {
      dao.insert(repository());
      recordRepositoryIdentity(
        dao,
        const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\app',
        ),
        const RepositoryOrigin(url: 'https://github.com/acme/app.git'),
      );
      // `update` is the rescan's write and knows only names and paths.
      dao.update(dao.getById('r1')!.copyWith(name: 'renamed'));
      expect(dao.getById('r1')!.canonicalId, 'github.com/acme/app');
    });
  });

  group('wired to the reading the app already takes', () {
    Future<String?> identityAfterReading(String? url) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());

      final container = ProviderContainer(
        overrides: fakeTerminalOverrides(
          database: db,
          gitFiles: _OneRemote(url),
        ),
      );
      addTearDown(container.dispose);

      await container.read(
        repositoryOriginProvider(Checkout(repository().path)).future,
      );
      return RepositoryDao(db).getById('r1')!.canonicalId;
    }

    test('reading a checkout is what records what it is', () async {
      expect(
        await identityAfterReading('git@github.com:acme/app.git'),
        'github.com/acme/app',
      );
    });

    test('a clone with no origin stays null, and nothing groups on it', () async {
      expect(await identityAfterReading(null), isNull);
    });
  });
}
