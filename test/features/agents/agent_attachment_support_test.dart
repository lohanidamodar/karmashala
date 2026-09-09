/// Which agents can be handed a file, as declared data with its evidence.
///
/// The question is narrower than "does this CLI understand pictures", and the
/// narrowing is the whole point: Karmashala delivers a message to a running
/// session by typing it into that session's PTY, so a **launch flag** a CLI
/// has is not a door that is open once the session is up. Only a path written
/// into the prompt is.
///
/// Modelled on `agent_fork_support_test.dart`, which pins the same shape of
/// claim for the same reason — an assertion about somebody else's CLI is worth
/// only the evidence beside it.
library;

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/remote/data/companion_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';

AgentDescriptor _descriptor(String id) => AgentRegistry.builtIn.byId(id)!;

void main() {
  group('AgentAttachmentSupport as declared data', () {
    test('defaults to none, the way fork support defaults to unsupported', () {
      const descriptor = AgentDescriptor(
        id: 'x',
        displayName: 'X',
        binaries: AgentBinaries(windows: ['x'], posix: ['x']),
      );

      expect(descriptor.attachments.isSupported, isFalse);
      expect(descriptor.attachments.mediaTypes, isEmpty);
      expect(
        descriptor.attachments.evidence,
        isEmpty,
        reason: 'there is nothing to have verified about a no',
      );
    });

    test('a supported one must carry the evidence it was read off', () {
      const support = AgentAttachmentSupport.byPath(
        ['image/png'],
        evidence: 'read off a real transcript',
      );

      expect(support.isSupported, isTrue);
      expect(support.evidence, isNotEmpty);
      expect(support.refusal, isEmpty, reason: 'a yes needs no excuse');
    });
  });

  group('the three shipped agents', () {
    test('Claude Code takes a picture named in a prompt', () {
      final support = _descriptor(AgentIds.claudeCode).attachments;

      expect(support.isSupported, isTrue);
      expect(support.mediaTypes, contains('image/png'));
      expect(support.mediaTypes, contains('image/jpeg'));
      // Measured in this repo rather than read off `--help`: the media
      // feature's `read` origin exists because real transcripts here carry
      // Read calls naming image files.
      expect(support.evidence, contains('Read tool calls'));
    });

    test('Codex is refused, and the refusal names why', () {
      final support = _descriptor(AgentIds.codex).attachments;

      expect(
        support.isSupported,
        isFalse,
        reason: 'codex-cli 0.153.4 takes --image on the command line that '
            'starts a session, which a running one cannot be handed',
      );
      expect(support.refusal, contains('--image'));
    });

    test('Antigravity is refused as an unknown, not as a no we measured', () {
      final support = _descriptor(AgentIds.antigravity).attachments;

      expect(support.isSupported, isFalse);
      expect(
        support.refusal,
        contains('Nobody here has seen'),
        reason: 'its store is protobuf in an unpublished schema this app reads '
            'none of, so §19 forbids reporting the unknown as either answer',
      );
    });

    test('every declared type is one this desktop can name a file for', () {
      for (final id in AgentIds.builtIn) {
        for (final type in _descriptor(id).attachments.mediaTypes) {
          expect(
            kAttachmentExtensions,
            contains(type),
            reason: '$id declares $type, which the store cannot write an '
                'extension for — a path nobody can open',
          );
        }
      }
    });

    test('no agent is declared to read audio, and that is deliberate', () {
      // Speaking a prompt is already solved without a byte crossing the link:
      // the phone's own keyboard dictates into the composer and the words
      // travel as an ordinary `prompt.send`. And no CLI here is known to
      // *listen* to a file, so an audio attachment would land on a disk and
      // never be looked at. The mechanism is media types all the way down, so
      // the day one does, it is a line in `built_in_agents.dart` — not code.
      for (final id in AgentIds.builtIn) {
        expect(
          _descriptor(id).attachments.mediaTypes.where(
            (type) => type.startsWith('audio/'),
          ),
          isEmpty,
        );
      }
      expect(
        kAttachmentExtensions.keys.where((t) => t.startsWith('audio/')),
        isEmpty,
      );
    });
  });
}
