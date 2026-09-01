import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/settings/presentation/agents_pages.dart';
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
            body: SingleChildScrollView(child: PermissionsPage()),
          ),
        ),
      ),
    );

    // The natural reading of a settings screen is that it governs everything,
    // which is exactly the misunderstanding this page has to head off: a
    // session that picked a mode keeps it when these move.
    expect(
      find.textContaining('have not chosen a mode of their own').first,
      findsOneWidget,
    );
    expect(find.textContaining('even after this changes').first, findsOneWidget);
  });
}
