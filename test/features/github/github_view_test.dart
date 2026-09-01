import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala/src/features/github/domain/issue.dart';
import 'package:karmashala/src/features/github/domain/pull_request.dart';
import 'package:karmashala/src/features/github/presentation/github_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    expect(find.text('Pull requests'), findsOneWidget);
    expect(find.text('Issues'), findsOneWidget);
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

    expect(find.textContaining('gh not authenticated'), findsOneWidget);
  });
}
