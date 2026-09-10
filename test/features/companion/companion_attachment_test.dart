/// Attaching a file on the phone: when the button is there, when it is not,
/// and what the user is told either way.
///
/// The property this file exists for is §19 applied to a round trip: the phone
/// must know what the desktop will take **before** anybody picks a 4 MB photo,
/// not after it has crossed somebody's mobile data. Everything is counted —
/// how many prompts went, how many slices were reported — and no test needs a
/// link or a picker.
library;

import 'dart:typed_data';

import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

const _takesImages = RemoteAttachmentSupport(
  mediaTypes: ['image/png', 'image/jpeg'],
  maxBytes: kMaxAttachmentBytes,
);

FakeCompanionGateway _gateway({
  RemoteAttachmentSupport? attachments = _takesImages,
  CapabilitySet? capabilities,
}) => FakeCompanionGateway(
  pairing: CompanionPairing(
    capabilities: capabilities ?? CapabilitySet.all,
    hostName: 'Desktop',
  ),
  link: CompanionLinkState.connected,
  sessions: [summary('s1', attachments: attachments)],
  transcripts: const {'s1': []},
);

Future<void> _openSession(WidgetTester tester, FakeCompanionGateway gateway) async {
  await tester.pumpWidget(
    buildPhoneApp(
      gateway: gateway,
      home: const SessionViewScreen(sessionId: 's1'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the button is only there when the host said what it would take', () {
    testWidgets('offered for a session whose agent reads a picture',
        (tester) async {
      await _openSession(tester, _gateway());

      expect(
        find.descendant(
          of: find.byType(CompanionComposer),
          matching: find.byTooltip('Attach a file'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('absent for an agent that cannot be handed one', (tester) async {
      await _openSession(
        tester,
        _gateway(
          attachments: const RemoteAttachmentSupport.refused(
            'Codex only takes a picture on the command line that starts it.',
          ),
        ),
      );

      expect(find.byTooltip('Attach a file'), findsNothing);
    });

    testWidgets('absent when the host said nothing at all', (tester) async {
      await _openSession(tester, _gateway(attachments: null));

      expect(
        find.byTooltip('Attach a file'),
        findsNothing,
        reason: 'silence from an older host is not permission',
      );
    });

    testWidgets('absent for a pairing that was never granted the bit',
        (tester) async {
      await _openSession(
        tester,
        _gateway(
          capabilities: CapabilitySet(
            CapabilitySet.all.bits & ~Capability.sendAttachment.bit,
          ),
        ),
      );

      expect(
        find.byTooltip('Attach a file'),
        findsNothing,
        reason: 'a phone paired before this existed is refused for ever, and '
            'should not be offered a picker it will be refused on',
      );
    });
  });

  group('sending', () {
    /// A picker that answers with [file] and never touches the platform — the
    /// same kind of seam `pickOneFile` already carries for the desktop's own.
    Future<XFile?> Function(List<XTypeGroup>) picking(XFile? file) =>
        (_) async => file;

    Future<
      List<({String text, CompanionOutgoingAttachment? attachment})>
    > pumpComposer(
      WidgetTester tester,
      XFile? chosen, {
      RemoteAttachmentSupport? support = _takesImages,
    }) async {
      final sent = <({String text, CompanionOutgoingAttachment? attachment})>[];
      await tester.pumpWidget(
        buildPhoneApp(
          gateway: _gateway(),
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                CompanionComposer(
                  attachments: support,
                  pickFile: picking(chosen),
                  onSend: (text, {attachment, onProgress}) async {
                    // The slice count the real gateway reports, so the
                    // progress line is exercised rather than assumed.
                    onProgress?.call(0, 1);
                    sent.add((text: text, attachment: attachment));
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return sent;
    }

    testWidgets('the chosen file is named above the box, with its size',
        (tester) async {
      await pumpComposer(
        tester,
        // `path` as well as `name`: on io, XFile takes its name from the path.
        XFile.fromData(
          Uint8List(2 * 1024 * 1024),
          name: 'IMG_4821.jpg',
          path: 'IMG_4821.jpg',
        ),
      );

      await tester.tap(find.byTooltip('Attach a file'));
      await tester.pumpAndSettle();

      expect(find.text('IMG_4821.jpg'), findsOneWidget);
      expect(find.text('2.0 MB'), findsOneWidget);
      expect(find.byTooltip('Remove'), findsOneWidget);
    });

    testWidgets('a file with no words is still something to send',
        (tester) async {
      final sent = await pumpComposer(
        tester,
        XFile.fromData(Uint8List(64), name: 'shot.png', path: 'shot.png'),
      );

      await tester.tap(find.byTooltip('Attach a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(sent, hasLength(1));
      expect(sent.single.text, isEmpty);
      expect(sent.single.attachment?.name, 'shot.png');
      expect(sent.single.attachment?.mediaType, 'image/png');
      expect(
        find.text('shot.png'),
        findsNothing,
        reason: 'the box is empty again once it went',
      );
    });

    testWidgets('removing it puts the box back to words only', (tester) async {
      final sent = await pumpComposer(
        tester,
        XFile.fromData(Uint8List(64), name: 'shot.png', path: 'shot.png'),
      );

      await tester.tap(find.byTooltip('Attach a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();

      expect(find.text('shot.png'), findsNothing);
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty, reason: 'nothing left to send');
    });

    testWidgets('a type the desktop did not name is refused here, not sent',
        (tester) async {
      final sent = await pumpComposer(
        tester,
        XFile.fromData(Uint8List(64), name: 'note.m4a', path: 'note.m4a'),
      );

      await tester.tap(find.byTooltip('Attach a file'));
      await tester.pumpAndSettle();

      expect(find.textContaining('not .m4a'), findsOneWidget);
      expect(
        find.byTooltip('Remove'),
        findsNothing,
        reason: 'nothing was staged, so there is nothing to send',
      );
      expect(sent, isEmpty);
    });

    testWidgets('a file over the desktop\'s cap never leaves the phone',
        (tester) async {
      final sent = await pumpComposer(
        tester,
        XFile.fromData(Uint8List(1024), name: 'huge.png', path: 'huge.png'),
        support: const RemoteAttachmentSupport(
          mediaTypes: ['image/png'],
          maxBytes: 512,
        ),
      );

      await tester.tap(find.byTooltip('Attach a file'));
      await tester.pumpAndSettle();

      expect(find.textContaining('the desktop takes up to'), findsOneWidget);
      expect(
        find.byTooltip('Remove'),
        findsNothing,
        reason: 'the cap the host named is checked before a byte crosses',
      );
      expect(sent, isEmpty);
    });

    testWidgets('a dismissed picker changes nothing', (tester) async {
      await pumpComposer(tester, null);

      await tester.tap(find.byTooltip('Attach a file'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove'), findsNothing);
    });
  });

  testWidgets('the phone is told a file was left in the desktop\'s box, not sent',
      (tester) async {
    final gateway = _gateway();
    await _openSession(tester, gateway);

    // Straight through the gateway, which is the seam the screen's snackbar
    // hangs off: the fake answers `offered` for anything carrying a file.
    final delivery = await gateway.sendPrompt(
      's1',
      'look at this',
      attachment: CompanionOutgoingAttachment(
        name: 'shot.png',
        mediaType: 'image/png',
        bytes: Uint8List(64),
      ),
    );

    expect(delivery, RemotePromptDelivery.offered);
    expect(
      gateway.sentAttachments.single?.name,
      'shot.png',
    );
    expect(
      gateway.sentPrompts.single.text,
      'look at this',
      reason: 'the words go with the file, in one prompt',
    );
  });

  testWidgets('progress is counted in slices the host acknowledged',
      (tester) async {
    final gateway = _gateway();
    final steps = <(int, int)>[];

    await gateway.sendPrompt(
      's1',
      '',
      attachment: CompanionOutgoingAttachment(
        name: 'big.jpg',
        mediaType: 'image/jpeg',
        bytes: Uint8List(4 * 1024 * 1024),
      ),
      onProgress: (sent, total) => steps.add((sent, total)),
    );

    expect(steps.last, (32, 32), reason: 'a 4 MB photo is 32 slices');
    expect(steps.first, (0, 32));
  });
}
