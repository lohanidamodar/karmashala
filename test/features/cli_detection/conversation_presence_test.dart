import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// "Does this conversation exist" has three answers, and the third one is why
/// this file is long.
///
/// A resume is refused on [ConversationPresence.absent] alone, so every way of
/// failing to read a store has to come out as [ConversationPresence.unknown] —
/// otherwise a stopped WSL distribution would tell the user their work is gone.

const _claudeish = AgentDescriptor(
  id: 'claudeish',
  displayName: 'Claudeish',
  binaries: AgentBinaries(windows: ['claudeish'], posix: ['claudeish']),
  store: AgentStoreSpec(
    homeDirectoryName: '.claude',
    format: AgentStoreFormat.claudeJsonl,
  ),
);

const _storeless = AgentDescriptor(
  id: 'storeless',
  displayName: 'Storeless',
  binaries: AgentBinaries(windows: ['s'], posix: ['s']),
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_presence_'));
  tearDown(() => removeTempDirectory(tmp));

  String home(String name) => p.join(tmp.path, name);

  void writeConversation(String storeHome, String project, String id) {
    File(p.join(storeHome, 'projects', project, '$id.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"type":"user","cwd":"/x"}\n');
  }

  group('ConversationStoreIndex', () {
    test('a Claude conversation on disk is present, whichever project '
        'directory holds it', () async {
      writeConversation(home('.claude'), '-mnt-c-src-demo', 'abc');

      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: home('.claude'),
          format: AgentStoreFormat.claudeJsonl,
          conversationId: 'abc',
        ),
        ConversationPresence.present,
      );
    });

    test('a store that was read to the end without it is absent', () async {
      writeConversation(home('.claude'), '-mnt-c-src-demo', 'abc');

      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: home('.claude'),
          format: AgentStoreFormat.claudeJsonl,
          conversationId: 'never-written',
        ),
        ConversationPresence.absent,
      );
    });

    test('a store with no projects directory tells us nothing', () async {
      // The distinction the whole fix rests on: an empty answer from a store
      // that is not there is not the same as an empty answer from one that is.
      Directory(home('.claude')).createSync(recursive: true);

      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: home('.claude'),
          format: AgentStoreFormat.claudeJsonl,
          conversationId: 'abc',
        ),
        ConversationPresence.unknown,
      );
    });

    test('a store home that does not exist at all tells us nothing', () async {
      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: home('.nowhere'),
          format: AgentStoreFormat.claudeJsonl,
          conversationId: 'abc',
        ),
        ConversationPresence.unknown,
      );
    });

    test('a Codex rollout is found by the id in its file name', () async {
      File(
          p.join(
            home('.codex'),
            'sessions',
            '2026',
            '01',
            '02',
            'rollout-2026-01-02T03-04-05-thread-9.jsonl',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('{"type":"session_meta"}\n');

      final index = const ConversationStoreIndex();
      expect(
        await index.presenceOf(
          storeHome: home('.codex'),
          format: AgentStoreFormat.codexRollout,
          conversationId: 'thread-9',
        ),
        ConversationPresence.present,
      );
      expect(
        await index.presenceOf(
          storeHome: home('.codex'),
          format: AgentStoreFormat.codexRollout,
          conversationId: 'thread-8',
        ),
        ConversationPresence.absent,
      );
    });

    test('a store format nobody has read yet tells us nothing', () async {
      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: home('.gemini'),
          format: AgentStoreFormat.none,
          conversationId: 'abc',
        ),
        ConversationPresence.unknown,
      );
    });
  });

  group('conversationPresenceProvider', () {
    ProviderContainer containerOver(
      List<CliStore> stores, {
      List<ExecutionEnvironment> environments = const [],
    }) {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final dao = ExecutionEnvironmentDao(db);
      for (final env
          in environments.isEmpty ? [windowsEnv(), wslEnv()] : environments) {
        dao.upsert(env);
      }
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          cliStoreLocatorProvider.overrideWithValue(FixedLocator(stores)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('an agent with no readable store is never asked', () async {
      final container = containerOver(const []);

      expect(
        await container.read(conversationPresenceProvider)(
          descriptor: _storeless,
          environmentId: 'windows',
          conversationId: 'abc',
        ),
        ConversationPresence.unknown,
      );
    });

    test('an environment whose store could not be located tells us '
        'nothing', () async {
      // The WSL home is what `CliStoreLocator` drops when the distribution is
      // not running. The session runs there; nothing may be concluded.
      final container = containerOver([
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeish': home('.claude')},
        ),
      ]);
      writeConversation(home('.claude'), '-c-src-demo', 'other');

      expect(
        await container.read(conversationPresenceProvider)(
          descriptor: _claudeish,
          environmentId: 'wsl:Ubuntu',
          conversationId: 'abc',
        ),
        ConversationPresence.unknown,
      );
    });

    test("only the session's own environment may say absent", () async {
      final container = containerOver([
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeish': home('.claude')},
        ),
        CliStore(
          environmentId: 'wsl:Ubuntu',
          homesByAgentId: {'claudeish': home('.wsl-claude')},
        ),
      ]);
      writeConversation(home('.claude'), '-c-src-demo', 'kept');
      writeConversation(home('.wsl-claude'), '-mnt-c-src-demo', 'kept');

      expect(
        await container.read(conversationPresenceProvider)(
          descriptor: _claudeish,
          environmentId: 'windows',
          conversationId: 'gone',
        ),
        ConversationPresence.absent,
      );
    });

    test('a conversation found in another environment is present', () async {
      // A repository that moved between WSL and Windows keeps its history, and
      // finding the transcript anywhere at all is proof it exists.
      final container = containerOver([
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeish': home('.claude')},
        ),
        CliStore(
          environmentId: 'wsl:Ubuntu',
          homesByAgentId: {'claudeish': home('.wsl-claude')},
        ),
      ]);
      Directory(
        p.join(home('.claude'), 'projects'),
      ).createSync(recursive: true);
      writeConversation(home('.wsl-claude'), '-mnt-c-src-demo', 'moved');

      expect(
        await container.read(conversationPresenceProvider)(
          descriptor: _claudeish,
          environmentId: 'windows',
          conversationId: 'moved',
        ),
        ConversationPresence.present,
      );
    });
  });
}
