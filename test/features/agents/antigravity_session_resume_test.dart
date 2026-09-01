import 'dart:io';

import 'package:karmashala/src/features/agents/data/antigravity_session_resume.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// How a session gets attributed to an Antigravity conversation, and what it
/// does when it cannot be.
///
/// The owner's report was: started a session, sent a prompt, ended it, and
/// "cannot resume it, says no cli session id found". Every case below is one
/// of the situations that message used to cover indiscriminately.
void main() {
  const registry = AgentRegistry.builtIn;
  final descriptor = registry.byId(AgentIds.antigravity)!;
  const attributor = AntigravitySessionAttributor();

  const conversation = 'df3c0708-a27f-4799-b761-57a657a84274';
  const otherConversation = 'e921cb55-8234-4370-b3c6-6f8b3fea0596';
  const workdir = '/mnt/c/Users/dlohani/projects/popupbits';

  late Directory tmp;
  late String storeHome;
  final launchedAt = DateTime.utc(2026, 9, 1, 9, 45);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('chitra_agy_resume_');
    storeHome = p.join(tmp.path, '.gemini', 'antigravity-cli');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // The temp directory is the OS's problem, not this suite's.
    }
  });

  void writeLastConversations(Map<String, String> byDirectory) {
    final entries = byDirectory.entries
        .map((e) => '  "${e.key}": "${e.value}"')
        .join(',\n');
    File(p.join(storeHome, 'cache', 'last_conversations.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{\n$entries\n}\n');
  }

  void writeConversationFile(String id, DateTime modified) {
    File(p.join(storeHome, 'conversations', '$id.db'))
      ..createSync(recursive: true)
      ..writeAsStringSync('')
      ..setLastModifiedSync(modified);
  }

  group('what the CLI itself said', () {
    // The 2026-08-31 note recorded that `agy` announces its id nowhere, and
    // built resume on a flag nothing could supply. It prints its own resume
    // command on the way out.
    test('the printed resume hint names the conversation', () async {
      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
        paneOutput:
            'Session ended.\n'
            'Resume with -c (or command below):\n'
            'agy --conversation=$conversation\n',
      );

      expect(learned.conversationId, conversation);
      expect(learned.source, AntigravityIdSource.announcement);
    });

    test('it wins over the store, and needs no other evidence', () async {
      // Nothing else exists here: no store, no directory entry, no file.
      // The agent's own statement is not an inference that needs corroborating.
      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
        paneOutput: 'agy --conversation=$conversation',
      );

      expect(learned.conversationId, conversation);
    });

    test('the newest announcement in the pane is the one believed', () async {
      // A pane holds a whole session: a resume prints the id it was given, and
      // the CLI prints it again on exit. The conversation the pane is on *now*
      // is the last one named.
      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
        paneOutput:
            'agy --conversation=$otherConversation\n'
            '...much later...\n'
            'agy --conversation=$conversation\n',
      );

      expect(learned.conversationId, conversation);
    });

    test('our own resume command line is not mistaken for it', () async {
      // The app passes the flag and the id as two arguments, so the echoed
      // command line uses a space. Only the `=` form the CLI prints is matched.
      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
        paneOutput: r'$ agy --conversation ' + conversation,
      );

      expect(learned.isLearned, isFalse);
    });

    test('something that only looks like an id is not one', () async {
      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
        paneOutput: 'agy --conversation=not-a-uuid',
      );

      expect(learned.isLearned, isFalse);
    });
  });

  group('what the store recorded for the directory', () {
    test('an entry written after the launch is this session', () async {
      writeLastConversations({workdir: conversation});
      writeConversationFile(conversation, launchedAt.add(const Duration(minutes: 1)));

      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
      );

      expect(learned.conversationId, conversation);
      expect(learned.source, AntigravityIdSource.lastConversation);
    });

    test('an entry written before the launch is an earlier session', () async {
      // The whole defence: a directory the user has worked in before already
      // names a conversation, and attributing it here would resume that one.
      writeLastConversations({workdir: conversation});
      writeConversationFile(conversation, launchedAt.subtract(const Duration(hours: 3)));

      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
      );

      expect(learned.isLearned, isFalse);
      expect(learned.reason, contains('belongs to an earlier one'));
    });

    test('a snapshot taken at launch beats the file time', () async {
      // The sharpest guard: an entry that *changed* can only have been written
      // by the process we started, whatever the clocks say.
      writeLastConversations({workdir: conversation});
      writeConversationFile(conversation, launchedAt.subtract(const Duration(hours: 3)));

      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
        directoryHeldBefore: otherConversation,
      );

      expect(learned.conversationId, conversation);
    });

    test('an unchanged snapshot refuses even when the file looks '
        'fresh', () async {
      writeLastConversations({workdir: conversation});
      writeConversationFile(conversation, launchedAt.add(const Duration(minutes: 1)));

      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
        directoryHeldBefore: conversation,
      );

      expect(learned.isLearned, isFalse);
      expect(learned.reason, contains('already open beforehand'));
    });

    test('a conversation another session holds is never taken', () async {
      // `SessionAdoptionService`'s idempotence rule: the CLI's own id is the
      // key, and one conversation is one session row.
      writeLastConversations({workdir: conversation});
      writeConversationFile(conversation, launchedAt.add(const Duration(minutes: 1)));

      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
        conversationIdsHeldByOtherSessions: {conversation},
      );

      expect(learned.isLearned, isFalse);
      expect(learned.reason, contains('already belongs to another session'));
    });

    test('a different directory is never borrowed from', () async {
      writeLastConversations({'/somewhere/else': conversation});
      writeConversationFile(conversation, launchedAt.add(const Duration(minutes: 1)));

      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
      );

      expect(learned.isLearned, isFalse);
      expect(learned.reason, contains('no conversation for $workdir'));
    });

    test('a trailing separator is the same directory', () async {
      writeLastConversations({'$workdir/': conversation});
      writeConversationFile(conversation, launchedAt.add(const Duration(minutes: 1)));

      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
      );

      expect(learned.conversationId, conversation);
    });

    test('a directory differing only in case is a different directory', () {
      // No case folding: these paths are POSIX, and matching two real
      // directories to each other resumes a stranger's conversation.
      expect(
        conversationForDirectory({'/Work': conversation}, '/work'),
        isNull,
      );
    });

    test('an entry naming a file that is not there refuses', () async {
      writeLastConversations({workdir: conversation});

      final learned = await attributor.attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workdir,
        launchedAt: launchedAt,
      );

      expect(learned.isLearned, isFalse);
      expect(learned.reason, contains('could not be read'));
    });
  });

  group('planning the command line', () {
    test('a known id is named outright', () {
      final plan = planAntigravityResume(
        descriptor: descriptor,
        workingDirectory: workdir,
        conversationId: conversation,
      );

      expect(plan, isA<AntigravityResumeById>());
      expect(plan.arguments, ['--conversation', conversation]);
    });

    test('no id resumes the directory\'s conversation, and says '
        'which', () {
      // The honest fallback, and the reason it is not a recency picker: the
      // app reads which conversation `--continue` would reach and can name it.
      final plan = planAntigravityResume(
        descriptor: descriptor,
        workingDirectory: workdir,
        lastConversationForDirectory: conversation,
      );

      expect(plan, isA<AntigravityContinueLatest>());
      expect((plan as AntigravityContinueLatest).conversationId, conversation);
    });

    test('and names it rather than passing --continue', () {
      // `--continue`'s directory scope is read off the binary's symbols, not an
      // observed run. Naming the conversation reaches the same one with no
      // scope assumption — and if the assumption were wrong, this still opens
      // the conversation the app just said it would.
      final plan = planAntigravityResume(
        descriptor: descriptor,
        workingDirectory: workdir,
        lastConversationForDirectory: conversation,
      );

      expect(plan.arguments, ['--conversation', conversation]);
      expect(plan.arguments, isNot(contains('--continue')));
    });

    test('an id beats a continuable directory', () {
      final plan = planAntigravityResume(
        descriptor: descriptor,
        workingDirectory: workdir,
        conversationId: conversation,
        lastConversationForDirectory: otherConversation,
      );

      expect((plan as AntigravityResumeById).conversationId, conversation);
    });

    test('nothing to continue refuses, in words', () {
      final plan = planAntigravityResume(
        descriptor: descriptor,
        workingDirectory: workdir,
      );

      expect(plan.arguments, isEmpty);
      expect(
        (plan as AntigravityResumeRefused).reason,
        contains('no conversation for $workdir to continue'),
      );
    });

    test('it refuses rather than continuing into another session', () {
      // `--continue` would reopen a conversation the app already has a session
      // row for, and `agy` does not refuse a second opener — it warns and
      // carries on. So this is the app's refusal, not the CLI's.
      final plan = planAntigravityResume(
        descriptor: descriptor,
        workingDirectory: workdir,
        lastConversationForDirectory: conversation,
        conversationIdsHeldByOtherSessions: {conversation},
      );

      expect(
        (plan as AntigravityResumeRefused).reason,
        contains('another session here already holds'),
      );
    });

    test('an agent with no --continue refuses instead of inventing '
        'one', () {
      final claude = registry.byId(AgentIds.claudeCode)!;

      final plan = planAntigravityResume(
        descriptor: claude,
        workingDirectory: workdir,
        lastConversationForDirectory: conversation,
      );

      expect(
        (plan as AntigravityResumeRefused).reason,
        contains('cannot be told to continue without one'),
      );
    });
  });
}
