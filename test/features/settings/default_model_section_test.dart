import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/agents/presentation/model_picker.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/default_model_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings → Agents → DEFAULT MODEL, over a real [SettingsController] and a
/// real database: the question is what the *preference* ends up as, and a
/// frozen fake settings object cannot answer that.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: DefaultModelSection()),
          ),
        ),
      ),
    );
    return container;
  }

  /// The card for Claude Code, whose picker is the one these tests drive.
  Finder claudePicker() => find.byType(ModelPicker).first;

  testWidgets('every agent starts on "let the agent choose"', (tester) async {
    final container = await pump(tester);

    // The shipped setting, and it is a setting rather than an absence of one:
    // no `--model` is passed and the CLI starts on whatever it is configured
    // to use.
    expect(find.text('Let the agent choose'), findsWidgets);
    expect(
      container
          .read(settingsControllerProvider)
          .defaultModelFor(AgentIds.claudeCode),
      isNull,
    );
  });

  testWidgets('picking a model records it, and it can be handed back', (
    tester,
  ) async {
    final container = await pump(tester);

    await tester.tap(claudePicker());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opus').last);
    await tester.pumpAndSettle();

    expect(
      container
          .read(settingsControllerProvider)
          .defaultModelFor(AgentIds.claudeCode),
      'opus',
    );
    expect(find.text('Opus'), findsOneWidget);

    await tester.tap(claudePicker());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Let the agent choose').last);
    await tester.pumpAndSettle();

    // Removed rather than written down as a null — see `Settings.defaultModels`.
    expect(
      container.read(settingsControllerProvider).defaultModels,
      isNot(contains(AgentIds.claudeCode)),
    );
  });

  testWidgets('says these are defaults, not overrides', (tester) async {
    await pump(tester);

    // The natural reading of a settings screen is that it governs everything,
    // which is exactly the misunderstanding this card has to head off: a
    // session that picked a model keeps it when this moves.
    expect(
      find.textContaining('have not chosen one of their own').first,
      findsOneWidget,
    );
    expect(
      find.textContaining('even after this changes').first,
      findsOneWidget,
    );
  });
}
