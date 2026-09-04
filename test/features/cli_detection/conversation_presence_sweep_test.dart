import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/cli_detection/application/conversation_presence_sweep.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_store_index.dart';
import 'package:karmashala/src/features/cli_detection/domain/conversation_presence.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fixtures.dart';

/// **One reading of every store, and it must agree with the single-row probe.**
///
/// `conversationPresenceProvider` decides whether to *refuse a resume*. This
/// sweep decides what to *offer for deletion*. They are asked about the same
/// rows for opposite reasons, so a disagreement is not a cosmetic bug: a sweep
/// that called something absent which the resume path would have found would be
/// putting a live conversation on a delete list.
///
/// The other half of the file is the honesty rule the sweep inherits: `null`
/// from [ConversationStoreIndex.idsIn] means *nothing was read*, and an empty
/// set means *this store holds nothing*. Collapsing the two would condemn every
/// row on a machine whose WSL distribution is stopped.

const _claudeish = AgentDescriptor(
  id: 'claudeish',
  displayName: 'Claudeish',
  binaries: AgentBinaries(windows: ['claudeish'], posix: ['claudeish']),
  store: AgentStoreSpec(
    homeDirectoryName: '.claude',
    format: AgentStoreFormat.claudeJsonl,
  ),
);

const _codexish = AgentDescriptor(
  id: 'codexish',
  displayName: 'Codexish',
  binaries: AgentBinaries(windows: ['codexish'], posix: ['codexish']),
  store: AgentStoreSpec(
    homeDirectoryName: '.codex',
    format: AgentStoreFormat.codexRollout,
  ),
);

const _storeless = AgentDescriptor(
  id: 'storeless',
  displayName: 'Storeless',
  binaries: AgentBinaries(windows: ['s'], posix: ['s']),
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_sweep_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String home(String name) => p.join(tmp.path, name);

  void writeClaude(String storeHome, String project, String id) {
    File(p.join(storeHome, 'projects', project, '$id.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"type":"user","cwd":"/x"}\n');
  }

  void writeCodex(String storeHome, String id) {
    File(
        p.join(
          storeHome,
          'sessions',
          '2026',
          '01',
          '02',
          'rollout-2026-01-02T03-04-05-$id.jsonl',
        ),
      )
      ..createSync(recursive: true)
      ..writeAsStringSync('{"type":"session_meta"}\n');
  }

  ProviderContainer containerOver(
    List<CliStore> stores, {
    List<AgentDescriptor> agents = const [_claudeish],
  }) {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final dao = ExecutionEnvironmentDao(db);
    dao.upsert(windowsEnv());
    dao.upsert(wslEnv());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cliStoreLocatorProvider.overrideWithValue(FixedLocator(stores)),
        agentRegistryProvider.overrideWithValue(AgentRegistry(agents)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('idsIn', () {
    test('lists every Claude conversation across every project bucket', () async {
      writeClaude(home('.claude'), '-c-src-demo', 'one');
      writeClaude(home('.claude'), '-mnt-c-src-other', 'two');

      expect(
        await const ConversationStoreIndex().idsIn(
          storeHome: home('.claude'),
          format: AgentStoreFormat.claudeJsonl,
        ),
        {'one', 'two'},
      );
    });

    test('a Codex id survives the dashes in its own timestamp', () async {
      // `rollout-<timestamp>-<id>.jsonl`, and the timestamp is full of dashes —
      // so splitting on the first one would return a date.
      writeCodex(home('.codex'), '0199c2f5-1111-2222-3333-444455556666');

      expect(
        await const ConversationStoreIndex().idsIn(
          storeHome: home('.codex'),
          format: AgentStoreFormat.codexRollout,
        ),
        {'0199c2f5-1111-2222-3333-444455556666'},
      );
    });

    test('a store that is not there answers null, never an empty set', () async {
      // The distinction the delete decision rests on.
      expect(
        await const ConversationStoreIndex().idsIn(
          storeHome: home('.nowhere'),
          format: AgentStoreFormat.claudeJsonl,
        ),
        isNull,
      );
    });

    test('a store that is there and empty answers an empty set', () async {
      Directory(p.join(home('.claude'), 'projects')).createSync(
        recursive: true,
      );

      expect(
        await const ConversationStoreIndex().idsIn(
          storeHome: home('.claude'),
          format: AgentStoreFormat.claudeJsonl,
        ),
        isEmpty,
      );
    });

    test('a format nobody has read answers null', () async {
      expect(
        await const ConversationStoreIndex().idsIn(
          storeHome: home('.gemini'),
          format: AgentStoreFormat.none,
        ),
        isNull,
      );
    });
  });

  group('the sweep', () {
    test('a conversation on disk is present', () async {
      final container = containerOver([
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeish': home('.claude')},
        ),
      ]);
      writeClaude(home('.claude'), '-c-src-demo', 'kept');

      final sweep = await container.read(conversationPresenceSweepProvider)();
      expect(
        sweep.presenceOf(
          agentId: 'claudeish',
          environmentId: 'windows',
          conversationId: 'kept',
        ),
        ConversationPresence.present,
      );
    });

    test("only the session's own environment may say absent", () async {
      final container = containerOver([
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeish': home('.claude')},
        ),
      ]);
      writeClaude(home('.claude'), '-c-src-demo', 'kept');

      final sweep = await container.read(conversationPresenceSweepProvider)();
      expect(
        sweep.presenceOf(
          agentId: 'claudeish',
          environmentId: 'windows',
          conversationId: 'gone',
        ),
        ConversationPresence.absent,
      );
      // Nothing was read for the distribution, so nothing may be said about a
      // session that runs there.
      expect(
        sweep.presenceOf(
          agentId: 'claudeish',
          environmentId: 'wsl:Ubuntu',
          conversationId: 'gone',
        ),
        ConversationPresence.unknown,
      );
    });

    test('a conversation found in another environment is present', () async {
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
      writeClaude(home('.claude'), '-c-src-demo', 'other');
      writeClaude(home('.wsl-claude'), '-mnt-c-src-demo', 'moved');

      final sweep = await container.read(conversationPresenceSweepProvider)();
      expect(
        sweep.presenceOf(
          agentId: 'claudeish',
          // Asked about the Windows store, found in the WSL one.
          environmentId: 'windows',
          conversationId: 'moved',
        ),
        ConversationPresence.present,
      );
    });

    test('a located store that cannot be read condemns nobody', () async {
      // The WSL share is up but the store directory is gone. `idsIn` answers
      // null, so the environment's key exists with no set behind it — and every
      // row in it is `unknown`, not `absent`.
      final container = containerOver([
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeish': home('.missing')},
        ),
      ]);

      final sweep = await container.read(conversationPresenceSweepProvider)();
      expect(sweep.storesRead, 0);
      expect(sweep.storesUnreadable, 1);
      expect(
        sweep.presenceOf(
          agentId: 'claudeish',
          environmentId: 'windows',
          conversationId: 'anything',
        ),
        ConversationPresence.unknown,
      );
    });

    test('an agent with no store format is never judged', () async {
      final container = containerOver(
        [
          CliStore(
            environmentId: 'windows',
            homesByAgentId: {'storeless': home('.claude')},
          ),
        ],
        agents: const [_storeless],
      );
      writeClaude(home('.claude'), '-c-src-demo', 'kept');

      final sweep = await container.read(conversationPresenceSweepProvider)();
      expect(
        sweep.presenceOf(
          agentId: 'storeless',
          environmentId: 'windows',
          conversationId: 'anything',
        ),
        ConversationPresence.unknown,
      );
    });

    test('one agent\'s conversation is not another agent\'s', () async {
      final container = containerOver(
        [
          CliStore(
            environmentId: 'windows',
            homesByAgentId: {
              'claudeish': home('.claude'),
              'codexish': home('.codex'),
            },
          ),
        ],
        agents: const [_claudeish, _codexish],
      );
      writeClaude(home('.claude'), '-c-src-demo', 'shared-id');
      writeCodex(home('.codex'), 'aaaaaaaa-1111-2222-3333-444455556666');

      final sweep = await container.read(conversationPresenceSweepProvider)();
      expect(
        sweep.presenceOf(
          agentId: 'codexish',
          environmentId: 'windows',
          conversationId: 'shared-id',
        ),
        ConversationPresence.absent,
      );
      expect(
        sweep.presenceOf(
          agentId: 'claudeish',
          environmentId: 'windows',
          conversationId: 'shared-id',
        ),
        ConversationPresence.present,
      );
    });

    test('an empty conversation id is never answered', () async {
      final container = containerOver([
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeish': home('.claude')},
        ),
      ]);
      writeClaude(home('.claude'), '-c-src-demo', 'kept');

      final sweep = await container.read(conversationPresenceSweepProvider)();
      expect(
        sweep.presenceOf(
          agentId: 'claudeish',
          environmentId: 'windows',
          conversationId: '',
        ),
        ConversationPresence.unknown,
      );
    });
  });

  group('the sweep and the resume probe cannot disagree', () {
    /// Both are asked the same question over the same store fixtures. The
    /// resume path refuses on `absent`; the sweep offers deletion on `absent`.
    /// If these ever diverge, one of the two features is wrong about a real
    /// conversation.
    test('over present, absent, unreadable and unlocated stores', () async {
      final stores = [
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeish': home('.claude')},
        ),
        CliStore(
          environmentId: 'wsl:Ubuntu',
          homesByAgentId: {'claudeish': home('.missing')},
        ),
      ];
      writeClaude(home('.claude'), '-c-src-demo', 'kept');

      final container = containerOver(stores);
      final sweep = await container.read(conversationPresenceSweepProvider)();
      final probe = container.read(conversationPresenceProvider);

      for (final (environmentId, conversationId) in const [
        ('windows', 'kept'),
        ('windows', 'gone'),
        ('wsl:Ubuntu', 'kept'),
        ('wsl:Ubuntu', 'gone'),
        // An environment neither store covers.
        ('ssh:box', 'gone'),
      ]) {
        expect(
          sweep.presenceOf(
            agentId: 'claudeish',
            environmentId: environmentId,
            conversationId: conversationId,
          ),
          await probe(
            descriptor: _claudeish,
            environmentId: environmentId,
            conversationId: conversationId,
          ),
          reason: 'disagreed about $conversationId in $environmentId',
        );
      }
    });
  });
}
