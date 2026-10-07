// Renders an agent's question card in the chat into PNGs, so its layout can be
// looked at. Under tool/ so `flutter test` never picks it up; run it from app/:
//
//   flutter test tool/question_card_screenshot.dart
//
// Images land in build/question-card-shots/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/remote_approval_bindings.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../test/features/sessions/chat_cards_support.dart';
import '../test/support/fixtures.dart';

const _outDir = 'build/question-card-shots';

/// Every font the app bundles — without this flutter_test draws boxes.
Future<void> _loadBundledFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font
        in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

/// Four options with long descriptions, the shape of the owner's report.
AgentQuestionSet _fixture() => const AgentQuestionSet(
  toolUseId: 'toolu_1',
  questions: [
    AgentQuestion(
      header: 'Overview',
      question:
          'Which Overview should the next round build? Each concept was '
          'drawn at desktop and phone width, and they differ mostly in what '
          'the first screen answers.',
      options: [
        AgentQuestionOption(
          label: 'A · Strips',
          description:
              'One full-width strip per session, sorted by what needs you. '
              'Dense and scannable, but the fleet chart has to live in a '
              'separate tab and plans are one click further away.',
        ),
        AgentQuestionOption(
          label: 'B · Cards',
          description:
              'A grid of cards, each with its activity strip, plan and '
              'files. Rich at a glance on a desktop, but a phone shows two '
              'cards per screen and the queue of asks gets lost among them.',
        ),
        AgentQuestionOption(
          label: 'C · Hybrid (Recommended)',
          description:
              "Fleet heartbeat chart on top; a 'Waiting on you' queue on the "
              'left with full Allow/Deny, question options and a reply box; '
              'compact cards for everything else on the right, each with its '
              'own activity strip, plan, files and message box.',
        ),
        AgentQuestionOption(
          label: 'D · Keep today’s',
          description:
              'Leave the Overview as it is and spend the round on the '
              'Running tab instead. Nothing to migrate, but the complaints '
              'about finding what needs you stay open.',
        ),
      ],
    ),
  ],
);

void main() {
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    Size size = const Size(390, 844),
    bool phone = true,
    double textScale = 1,
    String? tap,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const kind = ChatCardSession.terminalCli;
    final h = await ChatCardHarness.open(
      kind,
      messages: [
        TranscriptMessage(
          role: 'user',
          text: 'Draw three Overview concepts and ask me which to build.',
          at: testTime,
        ),
        TranscriptMessage(
          role: 'tool',
          text: '',
          tool: const ToolActivity(name: 'AskUserQuestion', subject: 'Which'),
          pendingToolUseId: 'toolu_1',
          at: testTime,
        ),
      ],
      // The waiting clock reads the wall clock, so the wait starts from it.
      status: AgentStatusReport(
        agentId: ChatCardHarness.agentIdOf(kind),
        sessionId: 's1',
        status: AgentActivityStatus.awaitingApproval,
        observedAt: testTime,
        source: AgentStatusSource.hook,
        waiting: AgentWaitKind.question,
        evidence: const ['Which Overview should the next round build?'],
        waitingSince: DateTime.now().toUtc().subtract(
          const Duration(minutes: 1, seconds: 47),
        ),
      ),
      overrides: [
        sessionAnswerableProvider.overrideWithValue((_) => true),
        transcriptOpenQuestionProvider.overrideWithValue(
          (sessionId, agentId) async => _fixture(),
        ),
        chatQuestionAnswerProvider.overrideWithValue((_) async => 'Answered.'),
      ],
    );
    addTearDown(h.dispose);
    final key = GlobalKey();
    final theme = AppTheme.dark().copyWith(
      platform: phone ? TargetPlatform.android : TargetPlatform.windows,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: RepaintBoundary(
              key: key,
              child: UiDensity.wrap(context, child!),
            ),
          ),
          home: Scaffold(
            body: SessionTranscriptView(sessionId: 's1', holdForPrompt: phone),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (tap != null) {
      await tester.tap(find.text(tap).first);
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull);
  }

  final prefix = Platform.environment['SHOT_PREFIX'] ?? 'after';
  testWidgets('phone 390', (t) => shoot(t, '$prefix-phone-390'));
  testWidgets(
    'phone 390, one chosen',
    (t) => shoot(t, '$prefix-phone-390-chosen', tap: 'B · Cards'),
  );
  testWidgets(
    'phone 360',
    (t) => shoot(t, '$prefix-phone-360', size: const Size(360, 640)),
  );
  testWidgets(
    'phone 390, text 1.6',
    (t) => shoot(t, '$prefix-phone-390-text160', textScale: 1.6),
  );
  testWidgets(
    'desktop 1440',
    (t) => shoot(
      t,
      '$prefix-desktop-1440',
      size: const Size(1440, 900),
      phone: false,
    ),
  );
}
