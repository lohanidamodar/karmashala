import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala/src/features/github/presentation/github_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows pull requests and issues', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          githubPullRequestsProvider.overrideWith(
            (ref) async => const [
              PullRequest(
                number: 7,
                title: 'Add feature',
                state: 'OPEN',
                author: 'me',
              ),
            ],
          ),
          githubIssuesProvider.overrideWith(
            (ref) async => const [
              Issue(number: 3, title: 'Fix bug', state: 'OPEN'),
            ],
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: GitHubView())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('#7 Add feature'), findsOneWidget);
    expect(find.text('#3 Fix bug'), findsOneWidget);
    // Section headers are the house eyebrow — `labelSmall`, uppercase — like
    // the quick-open palette's, rather than a second title under the pane's.
    expect(find.text('PULL REQUESTS'), findsOneWidget);
    expect(find.text('ISSUES'), findsOneWidget);
  });

  testWidgets(
    'an empty section is a line in the list, not a pane placeholder',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            githubRepositoryProvider.overrideWith((ref) async => null),
            githubPullRequestsProvider.overrideWith((ref) async => const []),
            githubIssuesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: Scaffold(body: GitHubView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PanePlaceholder), findsNothing);
      expect(find.text('No open issues.'), findsOneWidget);
      // Close under its section header rather than centred in 24px of padding.
      final header = tester.getRect(find.text('ISSUES'));
      final line = tester.getRect(find.text('No open issues.'));
      expect(line.top - header.bottom, lessThan(Insets.xl));
    },
  );

  testWidgets('waiting on gh is the house spinner', (tester) async {
    final never = Completer<List<PullRequest>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          githubRepositoryProvider.overrideWith((ref) async => null),
          githubPullRequestsProvider.overrideWith((ref) => never.future),
          githubIssuesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: Scaffold(body: GitHubView())),
      ),
    );
    await tester.pump();
    expect(find.byType(InlineSpinner), findsOneWidget);
  });

  testWidgets('surfaces a gh error', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          githubPullRequestsProvider.overrideWith(
            (ref) async => throw Exception('gh not authenticated'),
          ),
          githubIssuesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: Scaffold(body: GitHubView())),
      ),
    );
    await tester.pumpAndSettle();
    // Riverpod retries a failed provider over ~38 s, and the section draws the
    // spinner until the attempts are spent. Spelled out, because
    // `pumpAndSettle` used to spend that time by accident: against a spinner
    // that asked for every vsync it never ran out of frames to pump.
    await tester.pump(const Duration(minutes: 2));
    await tester.pumpAndSettle();

    expect(find.textContaining('gh not authenticated'), findsOneWidget);
  });
}
