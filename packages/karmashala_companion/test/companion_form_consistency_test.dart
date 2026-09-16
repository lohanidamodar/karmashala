import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/pairing.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/src/presentation/pairing/add_machine_screen.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/primitives.dart';

import 'companion_test_support.dart';

class _SlowGateway extends FakeCompanionGateway {
  _SlowGateway({super.sessions, super.transcripts})
    : super(
        pairing: CompanionPairing(
          capabilities: CapabilitySet.all,
          hostName: 'Desktop',
        ),
        link: CompanionLinkState.connected,
      );

  Object? failure;
  final waiting = Completer<Never>();

  @override
  Future<RemoteWorkspaceProject> addProject({
    required String requestId,
    required String name,
    required String path,
  }) async {
    if (failure case final error?) throw error;
    return waiting.future;
  }

  @override
  Future<RemoteSessionStarted> resumeSession({
    required String requestId,
    required String sessionId,
  }) async {
    if (failure case final error?) throw error;
    return waiting.future;
  }

  @override
  Future<CompanionPairing> pairWithCode(String shortCode, {String? at}) =>
      waiting.future;

  @override
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    CompanionOutgoingAttachment? attachment,
    void Function(int sent, int total)? onProgress,
    String? requestId,
  }) => waiting.future;
}

/// Every companion form says a failure the same way, spins the same spinner
/// while it works, and draws the same field.
void main() {
  group('add project', () {
    Future<void> submit(WidgetTester tester, _SlowGateway gateway) async {
      await pumpPhone(tester, gateway: gateway, home: const AddProjectScreen());
      await tester.enterText(find.byType(TextField).at(0), 'Demo');
      await tester.enterText(find.byType(TextField).at(1), r'C:\work\demo');
      await tester.ensureVisible(find.byType(FilledButton));
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('says a refusal with the shared inline error', (tester) async {
      await submit(
        tester,
        _SlowGateway()..failure = const GatewayException('Refused.'),
      );
      expect(
        find.widgetWithText(CompanionInlineError, 'Refused.'),
        findsOneWidget,
      );
    });

    testWidgets('spins the house spinner while it works', (tester) async {
      await submit(tester, _SlowGateway());
      expect(find.byType(InlineSpinner), findsOneWidget);
    });

    testWidgets('draws outlined fields like every other form', (tester) async {
      await pumpPhone(
        tester,
        gateway: _SlowGateway(),
        home: const AddProjectScreen(),
      );
      for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
        expect(field.decoration?.border, isA<OutlineInputBorder>());
      }
    });
  });

  group('add machine', () {
    testWidgets('says a bad address with the shared inline error', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: _SlowGateway(),
        home: const AddMachineScreen(),
      );
      await tester.enterText(find.byType(TextField).at(0), 'not an address!');
      await tester.enterText(find.byType(TextField).at(1), 'K7QM3X2W');
      await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
      await tester.pump();

      expect(find.byType(CompanionInlineError), findsOneWidget);
      for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
        expect(field.decoration?.border, isA<OutlineInputBorder>());
      }
    });
  });

  testWidgets('the scan screen refuses a foreign code the same way', (
    tester,
  ) async {
    late ValueChanged<String> deliver;
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: ScanQrScreen(
        scannerBuilder: (context, onPayload) {
          deliver = onPayload;
          return const Placeholder();
        },
      ),
    );
    deliver('https://example.com/some-other-qr');
    await tester.pump();

    expect(find.byType(CompanionInlineError), findsOneWidget);
  });

  testWidgets('the code screen spins the house spinner while pairing', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: _SlowGateway(),
      home: const ShortCodeScreen(),
    );
    await tester.enterText(find.byType(TextField), 'not-a-code');
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();

    expect(find.byType(InlineSpinner), findsOneWidget);
  });

  group('the session view', () {
    _SlowGateway idle() => _SlowGateway(
      sessions: [summary('s1', status: CompanionSessionStatus.idle)],
      transcripts: {
        's1': const [CompanionChatMessage(role: 'agent', text: 'hi')],
      },
    );

    testWidgets('says a failed resume with the shared inline error', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: idle()..failure = const GatewayException('Cannot resume.'),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.tap(find.text('Resume session'));
      await tester.pump();
      await tester.pump();

      expect(
        find.widgetWithText(CompanionInlineError, 'Cannot resume.'),
        findsOneWidget,
      );
    });

    testWidgets('spins the house spinner while resuming and sending', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: idle(),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.tap(find.text('Resume session'));
      await tester.pump();
      expect(find.byType(InlineSpinner), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(find.byType(InlineSpinner), findsNWidgets(2));
    });
  });
}
