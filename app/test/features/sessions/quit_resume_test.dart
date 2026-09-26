import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/quit_resume.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:riverpod/riverpod.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Quitting used to take every hosted agent with it in silence. What this pins
/// is the whole of the replacement: which sessions the question is about, what
/// a "yes" actually records, and — the part that matters most — that every one
/// it will not bring back says why.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  var now = testTime;

  /// Sessions this fake claims to be hosting, by id.
  final live = <String>{};

  /// Sessions this fake reports as mid-turn.
  final working = <String>{};

  ProviderContainer build() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(MovableClock(now)),
      sessionIsHostedLiveProvider.overrideWithValue(live.contains),
      sessionStatusLookupProvider.overrideWithValue(
        (id) => AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: id,
          status: working.contains(id)
              ? AgentActivityStatus.working
              : AgentActivityStatus.idle,
          observedAt: now,
          source: AgentStatusSource.hook,
        ),
      ),
    ],
  );

  void seed(String id, String title, {SessionStatus? status}) =>
      SessionDao(db).insert(
        session(
          id: id,
          title: title,
          status: status ?? SessionStatus.running,
        ).copyWith(externalSessionId: 'conv-$id'),
      );

  setUp(() {
    now = testTime;
    live.clear();
    working.clear();
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    container = build();
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  QuitResumeService service() => container.read(quitResumeServiceProvider);

  group('what a quit would interrupt', () {
    test('is only what this app is actually hosting', () {
      seed('s1', 'Hosted');
      seed('s2', 'A row that claims to be live');
      live.add('s1');

      expect(service().interrupted().map((s) => s.id), ['s1']);
    });

    test('says which ones are mid-turn, and puts those first', () {
      seed('s1', 'Idle one');
      seed('s2', 'Busy one');
      live.addAll(['s1', 's2']);
      working.add('s2');

      final interrupted = service().interrupted();
      expect(interrupted.first.id, 's2');
      expect(interrupted.first.working, isTrue);
      expect(interrupted.first.line, contains('mid-turn'));
      expect(interrupted.last.working, isFalse);
      expect(interrupted.last.line, isNot(contains('mid-turn')));
    });

    test('names the agent, so the list is about something', () {
      seed('s1', 'Port the importer');
      live.add('s1');
      expect(
        service().interrupted().single.line,
        'Port the importer — Claude Code',
      );
    });
  });

  group('recording the intent', () {
    test('writes the ids and when, and reads them back on launch', () {
      seed('s1', 'One');
      seed('s2', 'Two');
      expect(service().remember(['s1', 's2']), isTrue);

      final plan = service().planForLaunch();
      expect(plan.resume, ['s1', 's2']);
      expect(plan.skipped, isEmpty);
    });

    test('is consumed by reading it, so it cannot fire twice', () {
      seed('s1', 'One');
      service().remember(['s1']);
      expect(service().planForLaunch().resume, ['s1']);
      // A second launch must not reopen a session the user closed in between.
      expect(service().planForLaunch().isEmpty, isTrue);
    });

    test('remembering nothing writes nothing, and succeeds', () {
      expect(service().remember(const []), isTrue);
      expect(service().planForLaunch().isEmpty, isTrue);
    });

    test('forgetting clears last time\'s answer', () {
      seed('s1', 'One');
      service().remember(['s1']);
      service().forget();
      expect(service().planForLaunch().isEmpty, isTrue);
    });

    test('an unreadable record is dropped rather than guessed at', () {
      db.writeMetadata(kQuitResumeKey, 'not json at all');
      expect(service().planForLaunch().isEmpty, isTrue);
      // And it does not stay to be misread on the next launch too.
      expect(db.readMetadata(kQuitResumeKey), '');
    });
  });

  group('what is reopened is guarded, not unconditional', () {
    test('a session that is gone says so rather than disappearing', () {
      seed('s1', 'Still here');
      service().remember(['s1', 'deleted']);

      final plan = service().planForLaunch();
      expect(plan.resume, ['s1']);
      expect(plan.skipped.single.sessionId, 'deleted');
      expect(
        plan.skipped.single.reason,
        contains('no longer in the workspace'),
      );
    });

    test('an archived one is left archived', () {
      seed('s1', 'Archived');
      SessionDao(db).markArchived('s1', testTime);
      service().remember(['s1']);

      expect(
        service().planForLaunch().skipped.single.reason,
        contains('archived'),
      );
    });

    test('one already open is not opened a second time', () {
      seed('s1', 'Already open');
      service().remember(['s1']);
      live.add('s1');

      expect(
        service().planForLaunch().skipped.single.reason,
        contains('already open'),
      );
    });

    test('one with no conversation recorded cannot be resumed', () {
      SessionDao(db).insert(session(id: 's1', title: 'Never named one'));
      service().remember(['s1']);

      expect(
        service().planForLaunch().skipped.single.reason,
        contains('no conversation'),
      );
    });

    test('a stale intent is refused, with the reason, not acted on', () {
      seed('s1', 'From last week');
      service().remember(['s1']);
      now = testTime.add(kQuitResumeFreshness + const Duration(hours: 1));
      container.dispose();
      container = build();

      final plan = service().planForLaunch();
      expect(plan.resume, isEmpty);
      expect(plan.skipped.single.reason, contains('too long ago'));
    });

    test('an intent recorded moments ago is still acted on', () {
      seed('s1', 'From a minute ago');
      service().remember(['s1']);
      now = testTime.add(const Duration(minutes: 1));
      container.dispose();
      container = build();

      expect(service().planForLaunch().resume, ['s1']);
    });

    test('a record with no timestamp is refused rather than trusted', () {
      seed('s1', 'Undated');
      db.writeMetadata(
        kQuitResumeKey,
        jsonEncode({
          'sessions': ['s1'],
        }),
      );
      expect(
        service().planForLaunch().skipped.single.reason,
        contains('unreadable time'),
      );
    });
  });
}
