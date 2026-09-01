import 'package:karmashala/src/features/agents/data/resume_conflict_source.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captured from codex-cli 0.151.0 on 2026-08-30, by holding thread
/// `01a051ab-…` open in one process and resuming it in a second (which exited
/// 1). Verbatim, because the point of the matcher is that it survives this
/// sentence being wrapped, and a paraphrase would not be the same sentence.
const _refusal =
    'Error: Failed to resume session from /home/dlohani/.codex/sessions/2026/'
    '08/30/rollout-2026-08-30T13-41-56-01a051ab-eaeb-7a73-b8a4-a27d81e47984'
    '.jsonl: thread/resume failed during TUI bootstrap: thread/resume failed: '
    'thread 01a051ab-eaeb-7a73-b8a4-a27d81e47984 already has an active writer '
    '(code -32600)';

/// The refusal as a 40-column pane renders it — the wrap falls **inside**
/// "active", which is the case a per-line substring match cannot see.
List<String> _wrapped(String text, int columns) {
  final lines = <String>[];
  for (var i = 0; i < text.length; i += columns) {
    lines.add(text.substring(i, (i + columns).clamp(0, text.length)));
  }
  return lines;
}

const _codex = AgentDescriptor(
  id: AgentIds.codex,
  displayName: 'Codex',
  binaries: AgentBinaries(windows: ['codex'], posix: ['codex']),
  launch: AgentLaunchSpec(
    resumeConflict: AgentResumeConflictRules(
      markers: [GridMatcher('already has an active writer')],
    ),
  ),
);

/// An agent whose refusal nobody has ever seen.
const _unknownAgent = AgentDescriptor(
  id: 'mystery',
  displayName: 'Mystery',
  binaries: AgentBinaries(windows: ['mystery'], posix: ['mystery']),
);

void main() {
  group('showsResumeConflict', () {
    test('matches the refusal on a wide pane', () {
      expect(showsResumeConflict(_codex, [_refusal]), isTrue);
    });

    test('matches it at every pane width, including mid-word wraps', () {
      // The reason the matcher strips whitespace rather than scanning lines: a
      // detector that is right at the width the author happened to test and
      // wrong at the width the user happens to have is the worst failure shape
      // available.
      for (var columns = 8; columns <= 200; columns++) {
        expect(
          showsResumeConflict(_codex, _wrapped(_refusal, columns)),
          isTrue,
          reason: 'refusal not seen at $columns columns',
        );
      }
    });

    test('the wrap really does fall inside a word at some widths', () {
      // Guards the test above from becoming vacuous if the sample text changes:
      // at least one width must split the marker itself.
      final marker = 'already has an active writer';
      final splits = [
        for (var columns = 8; columns <= 200; columns++)
          if (_wrapped(_refusal, columns).every((l) => !l.contains(marker)))
            columns,
      ];
      expect(splits, isNotEmpty);
    });

    test('is case- and spacing-insensitive', () {
      expect(
        showsResumeConflict(_codex, [
          'THREAD X   ALREADY\tHAS\n AN  ACTIVE   WRITER',
        ]),
        isTrue,
      );
    });

    test('says nothing about an agent whose refusal we have never seen', () {
      // An undeclared marker means "we cannot explain this", never a guess — the
      // difference between an honest unknown and a confidently wrong badge.
      expect(showsResumeConflict(_unknownAgent, [_refusal]), isFalse);
      expect(showsResumeConflict(null, [_refusal]), isFalse);
    });

    test('an empty screen is not a refusal', () {
      expect(showsResumeConflict(_codex, const []), isFalse);
      expect(showsResumeConflict(_codex, const ['', '   ']), isFalse);
    });

    test('ordinary output is not mistaken for a refusal', () {
      expect(
        showsResumeConflict(_codex, const [
          '> resume the writer benchmark',
          'Reading src/writer.rs …',
          'The active writer count is 3.',
        ]),
        isFalse,
      );
    });
  });

  group('the shipped descriptors', () {
    test('Claude Code permits a second process; Codex does not', () {
      final registry = AgentRegistry.builtIn;
      expect(
        registry.byId(AgentIds.claudeCode)!.launch.allowsConcurrentResume,
        isTrue,
        reason: 'verified against Claude Code 2.1.251',
      );
      expect(
        registry.byId(AgentIds.codex)!.launch.allowsConcurrentResume,
        isFalse,
        reason: 'Codex 0.151 enforces one writer per thread with an flock',
      );
    });

    test('Codex declares how it refuses, so the pane can be explained', () {
      final codex = AgentRegistry.builtIn.byId(AgentIds.codex)!;
      expect(codex.launch.resumeConflict.isEmpty, isFalse);
      expect(showsResumeConflict(codex, _wrapped(_refusal, 37)), isTrue);
    });

    test('an agent that permits it needs no refusal markers', () {
      final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
      expect(claude.launch.resumeConflict.isEmpty, isTrue);
      expect(showsResumeConflict(claude, [_refusal]), isFalse);
    });
  });
}
