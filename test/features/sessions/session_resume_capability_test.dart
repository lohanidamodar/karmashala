import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/sessions/domain/session_resume.dart';
import 'package:flutter_test/flutter_test.dart';

/// The decision matrix, as a table.
///
/// Written as data rather than as six `test(...)` blocks because the point of
/// `resumeActionFor` is that it is *total*: every combination has an answer, and
/// a reader should be able to check the whole thing at once. The rows are the
/// owner's requirement, verbatim — "attach to an active session if the agent
/// permits; Claude can have multiple terminals listening to the same session,
/// Codex cannot".
void main() {
  group('resumeActionFor', () {
    // (weHostItLive, allowsConcurrentResume, heldByAnotherProcess, canReattach)
    const cases = <(bool, bool, bool, bool, ResumeAction, String)>[
      // --- we own a live pane, and the caller can reopen it ------------------
      (true, true, false, true, ResumeAction.reattach, 'permissive agent'),
      (true, false, false, true, ResumeAction.reattach, 'restrictive agent'),
      (
        true,
        false,
        true,
        true,
        ResumeAction.reattach,
        'even with another holder',
      ),

      // --- we own a live pane, but reopening is not what was asked -----------
      // Handing the conversation to a terminal window we do not own. This is the
      // case the owner wants kept for Claude and refused for Codex.
      (
        true,
        true,
        false,
        false,
        ResumeAction.resume,
        'Claude, second terminal',
      ),
      (true, false, false, false, ResumeAction.blocked, 'Codex, second writer'),

      // --- nothing of ours is running it ------------------------------------
      (false, true, false, true, ResumeAction.resume, 'ordinary resume'),
      (false, false, false, true, ResumeAction.resume, 'ordinary resume'),
      (false, true, false, false, ResumeAction.resume, 'ordinary handoff'),
      (false, false, false, false, ResumeAction.resume, 'ordinary handoff'),

      // --- someone else is *known* to hold it -------------------------------
      // Certain knowledge only: an agent's own refusal, read off its screen.
      (false, false, true, true, ResumeAction.blocked, 'known holder'),
      (false, false, true, false, ResumeAction.blocked, 'known holder'),
      // A permissive agent does not care that someone else holds it — that is
      // exactly what "concurrent resume" means.
      (false, true, true, true, ResumeAction.resume, 'permissive, shared'),
      (false, true, true, false, ResumeAction.resume, 'permissive, shared'),
    ];

    for (final (hosted, permits, held, canReattach, expected, why) in cases) {
      test(
        'hosted=$hosted permits=$permits held=$held reattachable=$canReattach '
        '→ ${expected.name} ($why)',
        () {
          expect(
            resumeActionFor(
              weHostItLive: hosted,
              allowsConcurrentResume: permits,
              heldByAnotherProcess: held,
              canReattach: canReattach,
            ),
            expected,
          );
        },
      );
    }

    test('every combination has an answer', () {
      expect(cases, hasLength(2 * 2 * 2 * 2 - 3));
      // The three missing rows are (hosted, *, held=true, canReattach=true)
      // duplicates of rows already covered above; assert them explicitly rather
      // than leaving a hole in the table.
      expect(
        resumeActionFor(
          weHostItLive: true,
          allowsConcurrentResume: true,
          heldByAnotherProcess: true,
          canReattach: true,
        ),
        ResumeAction.reattach,
      );
      expect(
        resumeActionFor(
          weHostItLive: true,
          allowsConcurrentResume: true,
          heldByAnotherProcess: true,
          canReattach: false,
        ),
        ResumeAction.resume,
      );
      expect(
        resumeActionFor(
          weHostItLive: true,
          allowsConcurrentResume: false,
          heldByAnotherProcess: true,
          canReattach: false,
        ),
        ResumeAction.blocked,
      );
    });

    test('defaults to reattachable, which is what the in-app surfaces are', () {
      expect(
        resumeActionFor(
          weHostItLive: true,
          allowsConcurrentResume: false,
          heldByAnotherProcess: false,
        ),
        ResumeAction.reattach,
      );
    });
  });

  group('AgentLaunchSpec.allowsConcurrentResume', () {
    test('is false unless an agent has been verified to permit it', () {
      const spec = AgentLaunchSpec();
      expect(spec.allowsConcurrentResume, isFalse);
      // The asymmetry that sets the default: refusing a resume that would have
      // worked costs a click; allowing one the agent forbids can interleave two
      // writers into one transcript.
      expect(
        resumeActionFor(
          weHostItLive: false,
          allowsConcurrentResume: spec.allowsConcurrentResume,
          heldByAnotherProcess: true,
        ),
        ResumeAction.blocked,
      );
    });
  });

  group('SessionWhereabouts', () {
    test('weighs its three facts differently', () {
      // Certain: we own the process.
      const hosted = SessionWhereabouts(hostedLive: true);
      expect(hosted.note, 'running here');
      expect(hosted.knownHeldElsewhere, isFalse);

      // Certain: the agent itself told us.
      const refused = SessionWhereabouts(refusedResume: true);
      expect(refused.knownHeldElsewhere, isTrue);
      expect(refused.note, 'open in another process');

      // A record of where it was *started*, and nothing more. It must never
      // become "it is running now" — a confidently wrong badge on every closed
      // external terminal is worse than no badge at all.
      const external = SessionWhereabouts(external: true);
      expect(external.knownHeldElsewhere, isFalse);
      expect(external.note, 'opened in an external terminal');

      // Nothing known says nothing.
      expect(const SessionWhereabouts().note, isNull);
      expect(const SessionWhereabouts().explanation, isNull);
    });

    test('hostedLive outranks the weaker facts in the note', () {
      const both = SessionWhereabouts(
        hostedLive: true,
        external: true,
        refusedResume: true,
      );
      expect(both.note, 'running here');
      expect(both.explanation, contains('terminal pane in this window'));
    });

    test('a refusal outranks the record-only external note', () {
      const both = SessionWhereabouts(external: true, refusedResume: true);
      expect(both.note, 'open in another process');
      expect(both.explanation, contains('another process'));
    });

    test('a live session is never given an age', () {
      final now = DateTime.utc(2026, 8, 30, 12);
      final whereabouts = SessionWhereabouts(
        hostedLive: true,
        lastSeen: now.subtract(const Duration(hours: 3)),
      );
      // We can see the process. "running here" is stronger than any timestamp,
      // and showing both would invite the reader to distrust the stronger one.
      expect(whereabouts.lastSeenLabel(now), isNull);
    });

    test('an absent last-seen renders as nothing, never as zero', () {
      final now = DateTime.utc(2026, 8, 30, 12);
      expect(const SessionWhereabouts().lastSeenLabel(now), isNull);
      expect(
        const SessionWhereabouts(external: true).lastSeenLabel(now),
        isNull,
      );
    });

    test('ages the evidence, not the poll', () {
      final now = DateTime.utc(2026, 8, 30, 12);
      String? at(Duration ago) => SessionWhereabouts(
        external: true,
        lastSeen: now.subtract(ago),
      ).lastSeenLabel(now);

      expect(at(const Duration(seconds: 5)), 'last seen just now');
      expect(at(const Duration(minutes: 2)), 'last seen 2m ago');
      expect(at(const Duration(hours: 5)), 'last seen 5h ago');
      expect(at(const Duration(days: 3)), 'last seen 3d ago');
    });
  });

  group('describeAge', () {
    test('rounds down and never counts seconds', () {
      expect(describeAge(Duration.zero), 'just now');
      expect(describeAge(const Duration(seconds: 59)), 'just now');
      expect(describeAge(const Duration(seconds: 61)), '1m ago');
      expect(describeAge(const Duration(minutes: 59)), '59m ago');
      expect(describeAge(const Duration(minutes: 61)), '1h ago');
      expect(describeAge(const Duration(hours: 23)), '23h ago');
      expect(describeAge(const Duration(hours: 25)), '1d ago');
    });

    test('a clock that ran backwards reads as now, not as a negative age', () {
      expect(describeAge(const Duration(minutes: -5)), 'just now');
    });
  });

  group('the words the user sees', () {
    test('name the agent and offer a way out, with no JSON-RPC in sight', () {
      final message = resumeBlockedMessage('Codex');
      expect(message, startsWith('Codex'));
      expect(message, contains('start a new session'));
      expect(message, contains('Close it wherever it is open'));
      // The whole point: the CLI's own error never reaches the user.
      expect(message, isNot(contains('-32600')));
      expect(message.toLowerCase(), isNot(contains('json')));
      expect(message.toLowerCase(), isNot(contains('rpc')));
      expect(message.toLowerCase(), isNot(contains('flock')));
    });

    test('the pane banner says which agent, not which error code', () {
      final banner = resumeConflictPaneMessage('Codex');
      expect(banner, contains('Codex'));
      expect(banner, isNot(contains('-32600')));
    });
  });
}
