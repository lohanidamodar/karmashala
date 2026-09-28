import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala/src/features/github/presentation/github_section.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

/// GitHub, as a section of the Repository pane: what it can show, and a
/// sentence for what it cannot.
void main() {
  const gitHub = (kind: GitHubReachKind.gitHub, host: 'github.com');

  Future<void> pump(
    WidgetTester tester, {
    GitHubReach reach = gitHub,
    GitTroubleReport? trouble,
    FutureOr<GitHubRepo?> Function()? repo,
    FutureOr<List<PullRequest>> Function()? prs,
    FutureOr<List<Issue>> Function()? issues,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedCheckoutGitTroubleProvider.overrideWith((ref) => trouble),
          githubReachProvider.overrideWith((ref) => reach),
          githubRepositoryProvider.overrideWith(
            (ref) async => (repo ?? () => null)(),
          ),
          githubPullRequestsProvider.overrideWith(
            (ref) async => (prs ?? () => const <PullRequest>[])(),
          ),
          githubIssuesProvider.overrideWith(
            (ref) async => (issues ?? () => const <Issue>[])(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: GitHubSection())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows pull requests and issues', (tester) async {
    await pump(
      tester,
      prs: () => const [
        PullRequest(
          number: 7,
          title: 'Add feature',
          state: 'OPEN',
          author: 'me',
        ),
      ],
      issues: () => const [Issue(number: 3, title: 'Fix bug', state: 'OPEN')],
    );

    expect(find.text('#7 Add feature'), findsOneWidget);
    expect(find.text('#3 Fix bug'), findsOneWidget);
    // Section headers are the house eyebrow — `labelSmall`, uppercase.
    expect(find.text('GITHUB'), findsOneWidget);
    expect(find.text('PULL REQUESTS'), findsOneWidget);
    expect(find.text('ISSUES'), findsOneWidget);
    expect(find.byTooltip('Refresh from GitHub'), findsOneWidget);
  });

  testWidgets('an empty part is a line in the list, not a pane placeholder', (
    tester,
  ) async {
    await pump(tester);

    expect(find.byType(PanePlaceholder), findsNothing);
    expect(find.text('No open issues.'), findsOneWidget);
    final header = tester.getRect(find.text('ISSUES'));
    final line = tester.getRect(find.text('No open issues.'));
    expect(line.top - header.bottom, lessThan(Insets.xl));
  });

  testWidgets('waiting on gh is the house spinner', (tester) async {
    final never = Completer<List<PullRequest>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedCheckoutGitTroubleProvider.overrideWith((ref) => null),
          githubReachProvider.overrideWith((ref) => gitHub),
          githubRepositoryProvider.overrideWith((ref) async => null),
          githubPullRequestsProvider.overrideWith((ref) => never.future),
          githubIssuesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: Scaffold(body: GitHubSection())),
      ),
    );
    await tester.pump();
    expect(find.byType(InlineSpinner), findsOneWidget);
  });

  testWidgets('one part failing leaves the others, and says why in gh\'s '
      'words', (tester) async {
    await pump(
      tester,
      prs: () => const [
        PullRequest(number: 7, title: 'Add feature', state: 'OPEN'),
      ],
      issues: () => throw GitHubException(
        'gh issue list failed: the repository has disabled issues',
      ),
    );

    expect(find.text('#7 Add feature'), findsOneWidget);
    expect(
      find.text('gh issue list failed: the repository has disabled issues'),
      findsOneWidget,
    );
    expect(find.textContaining('GitHubException'), findsNothing);
  });

  testWidgets('gh missing or signed out is said once, not three times', (
    tester,
  ) async {
    const signedOut =
        'gh is not signed in on WSL · archlinux. Run gh auth login.';
    await pump(
      tester,
      repo: () => throw GitHubException(signedOut),
      prs: () => throw GitHubException(signedOut),
      issues: () => throw GitHubException(signedOut),
    );

    expect(find.text(signedOut), findsOneWidget);
    expect(find.text('PULL REQUESTS'), findsNothing);
  });

  testWidgets('no remote says so, and asks nothing', (tester) async {
    await pump(tester, reach: (kind: GitHubReachKind.noRemote, host: null));

    expect(find.textContaining('No remote'), findsOneWidget);
    expect(find.text('PULL REQUESTS'), findsNothing);
    expect(find.byTooltip('Refresh from GitHub'), findsNothing);
  });

  testWidgets('a remote on another forge names it', (tester) async {
    await pump(
      tester,
      reach: (kind: GitHubReachKind.otherHost, host: 'gitlab.com'),
    );

    expect(find.textContaining('gitlab.com'), findsOneWidget);
    expect(find.text('PULL REQUESTS'), findsNothing);
  });

  testWidgets('nothing at all when git has trouble — the Git section says '
      'it', (tester) async {
    await pump(
      tester,
      trouble: const GitTroubleReport(GitTrouble.notARepository),
    );

    expect(find.text('GITHUB'), findsNothing);
  });
}
