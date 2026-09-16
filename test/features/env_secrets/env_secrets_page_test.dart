import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/features/env_secrets/presentation/settings_item_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/env_secrets/application/env_secrets_controller.dart';
import 'package:karmashala/src/features/env_secrets/domain/env_variable.dart';
import 'package:karmashala/src/features/env_secrets/presentation/env_secrets_page.dart';
import 'package:karmashala_ui/dialogs.dart';

class _Seeded extends EnvSecretsController {
  @override
  EnvVaultData build() => EnvVaultData(
    variables: [
      EnvVariable(
        id: 'v1',
        name: 'GITHUB_TOKEN',
        value: 'secret',
        secret: true,
        updatedAt: DateTime.utc(2026, 9, 16),
      ),
    ],
  );
}

void main() {
  testWidgets('removing a variable is confirmed with a destructive button', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [envSecretsControllerProvider.overrideWith(_Seeded.new)],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: EnvSecretsPage())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The same card the snippets and automations pages draw.
    expect(find.byType(SettingsItemCard), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove GITHUB_TOKEN?'), findsOneWidget);
    expect(find.widgetWithText(DestructiveButton, 'Remove'), findsOneWidget);
  });
}
