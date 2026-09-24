import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/settings/presentation/permissions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

void main() {
  testWidgets('says these are defaults, not overrides', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_StaticSettings.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PermissionModesSection()),
          ),
        ),
      ),
    );

    // The natural reading of a settings screen is that it governs everything,
    // which is exactly the misunderstanding this page has to head off: a
    // session that picked a mode keeps it when these move.
    expect(
      find.textContaining('a mode picked on a session keeps it').first,
      findsOneWidget,
    );
  });

  testWidgets('each row names its rung beside the CLI own word', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_StaticSettings.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PermissionModesSection()),
          ),
        ),
      ),
    );

    // The first card is Claude Code's, and its first dropdown is what a new
    // session starts under.
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    // This page is where somebody configures an agent, so the CLI's own word
    // is the half that must never leave — the borrowed name is only ever in
    // front of it, and only where the CLI does not already say it.
    expect(find.text('Build · Accept edits'), findsWidgets);
    expect(find.text('Build · Automatic'), findsWidgets);
    expect(find.text('Plan mode'), findsWidgets);
    expect(find.text('Bypass (full autonomy)'), findsWidgets);
  });
}
