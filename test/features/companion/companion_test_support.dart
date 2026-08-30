import 'package:chitragupta/src/app/theme/app_theme.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The companion app as tests host it: the app theme and [gateway] behind the
/// provider — the way every companion screen actually runs.
Widget buildPhoneApp({
  required CompanionGateway gateway,
  required Widget home,
}) => ProviderScope(
  overrides: [companionGatewayProvider.overrideWithValue(gateway)],
  // The Material ancestor the shell's Scaffold provides in the real app.
  child: MaterialApp(
    theme: AppTheme.light(),
    home: Material(child: home),
  ),
);

/// Pumps [home] at the phone size named in CLAUDE.md §11 (390×844). The extra
/// pump lets the gateway's seeded streams deliver their first value.
Future<void> pumpPhone(
  WidgetTester tester, {
  required CompanionGateway gateway,
  required Widget home,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(buildPhoneApp(gateway: gateway, home: home));
  await tester.pump();
  await tester.pump();
}

/// A session summary with test-friendly defaults.
CompanionSessionSummary summary(
  String id, {
  String? title,
  String project = 'popupbits',
  String agentLabel = 'Claude Code  ·  running',
  CompanionSessionStatus status = CompanionSessionStatus.working,
  String? branch,
  String? whereabouts,
  CompanionAttention? attention,
  DateTime? lastActivityAt,
}) => CompanionSessionSummary(
  id: id,
  title: title ?? 'Session $id',
  agentLabel: agentLabel,
  projectName: project,
  status: status,
  branch: branch,
  whereabouts: whereabouts,
  attention: attention,
  lastActivityAt: lastActivityAt,
);
