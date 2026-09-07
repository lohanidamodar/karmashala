import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The companion app as tests host it: the app theme, the touch density the
/// companion root installs, and [gateway] behind the provider — the way every
/// companion screen actually runs.
Widget buildPhoneApp({
  required CompanionGateway gateway,
  required Widget home,
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) => ProviderScope(
  overrides: [companionGatewayProvider.overrideWithValue(gateway)],
  // The Material ancestor the shell's Scaffold provides in the real app.
  child: MaterialApp(
    theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
    // Exactly what CompanionApp does: measure the width, install the density.
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: UiDensity.wrap(context, child!),
    ),
    home: Material(child: home),
  ),
);

/// The phone size named in CLAUDE.md §11 — the compact width class.
const Size kPhoneSize = Size(390, 844);

/// A tablet in portrait, comfortably past the 600px compact breakpoint: the
/// width class where the companion must stop stretching its lists.
const Size kTabletSize = Size(834, 1112);

/// Pumps [home] at [size] — [kPhoneSize] unless a test says otherwise. The
/// extra pump lets the gateway's seeded streams deliver their first value.
Future<void> pumpPhone(
  WidgetTester tester, {
  required CompanionGateway gateway,
  required Widget home,
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  Size size = kPhoneSize,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    buildPhoneApp(
      gateway: gateway,
      home: home,
      brightness: brightness,
      textScale: textScale,
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// [pumpPhone] at [kTabletSize] — the expanded-width case every adaptive
/// companion screen owes CLAUDE.md §6.
Future<void> pumpTablet(
  WidgetTester tester, {
  required CompanionGateway gateway,
  required Widget home,
  double textScale = 1.0,
}) => pumpPhone(
  tester,
  gateway: gateway,
  home: home,
  textScale: textScale,
  size: kTabletSize,
);

/// A session summary with test-friendly defaults.
CompanionSessionSummary summary(
  String id, {
  String? title,
  String project = 'popupbits',
  String? projectId,
  String? projectPath,
  String agentLabel = 'Claude Code  ·  running',
  CompanionSessionStatus status = CompanionSessionStatus.working,
  String? branch,
  String? subPath,
  bool worktree = false,
  String? whereabouts,
  CompanionAttention? attention,
  DateTime? lastActivityAt,
  bool archived = false,
  bool folderMissing = false,
  bool imported = false,
}) => CompanionSessionSummary(
  id: id,
  title: title ?? 'Session $id',
  agentLabel: agentLabel,
  projectName: project,
  projectId: projectId,
  projectPath: projectPath,
  status: status,
  branch: branch,
  subPath: subPath,
  worktree: worktree,
  whereabouts: whereabouts,
  attention: attention,
  lastActivityAt: lastActivityAt,
  archived: archived,
  folderMissing: folderMissing,
  imported: imported,
);
