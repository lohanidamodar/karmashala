import 'package:googleapis/androidpublisher/v3.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_play/src/play_mapping.dart';
import 'package:test/test.dart';

void main() {
  group('releasesFromSummaries', () {
    ReleaseSummary summary(String state, List<int> codes, {String? name}) =>
        ReleaseSummary.fromJson({
          'releaseName': ?name,
          'releaseLifecycleState': 'RELEASE_LIFECYCLE_STATE_$state',
          'activeArtifacts': [
            for (final code in codes) {'versionCode': code},
          ],
        });

    test('published is live on production, newest build first', () {
      final releases = releasesFromSummaries('production', [
        summary('PUBLISHED', [190], name: '1.9.0'),
        summary('PUBLISHED', [200, 201], name: '2.0.0'),
      ]);
      expect([for (final r in releases) r.build], ['201', '190']);
      expect(releases.first.state, ReleaseState.live);
      expect(releases.first.version, '2.0.0');
      expect(releases.first.rolloutFraction, isNull);
    });

    test('published elsewhere is testing', () {
      expect(
        releasesFromSummaries('internal', [
          summary('PUBLISHED', [300]),
        ]).single.state,
        ReleaseState.testing,
      );
    });

    test('review states map, and the raw word is kept', () {
      final states = [
        for (final state in [
          'IN_REVIEW',
          'APPROVED_NOT_PUBLISHED',
          'NOT_APPROVED',
          'NOT_SENT_FOR_REVIEW',
          'DRAFT',
          'SOMETHING_NEW',
        ])
          releaseFromSummary('production', summary(state, const [])),
      ];
      expect(
        [for (final r in states) r.state],
        [
          ReleaseState.inReview,
          ReleaseState.pendingRelease,
          ReleaseState.rejected,
          ReleaseState.draft,
          ReleaseState.draft,
          ReleaseState.unknown,
        ],
      );
      expect(states.last.rawState, 'RELEASE_LIFECYCLE_STATE_SOMETHING_NEW');
      expect(states.last.build, isNull);
    });
  });

  group('reviewsFrom', () {
    final reviews = ReviewsListResponse.fromJson({
      'reviews': [
        {
          'reviewId': 'old',
          'authorName': 'Asha',
          'comments': [
            {
              'userComment': {
                'text': 'Great\tLove using this app!',
                'lastModified': {'seconds': '1758000000', 'nanos': 213000000},
                'starRating': 5,
                'reviewerLanguage': 'en_US',
                'appVersionName': '1.2.3',
              },
            },
            {
              'developerComment': {
                'text': 'Thank you!',
                'lastModified': {'seconds': '1758100000'},
              },
            },
          ],
        },
        {
          'reviewId': 'new',
          'authorName': ' ',
          'comments': [
            {
              'userComment': {
                'text': '\tCrashes on start',
                'lastModified': {'seconds': '1759000000'},
                'starRating': 1,
              },
            },
          ],
        },
        {'reviewId': 'empty', 'comments': <Object>[]},
      ],
    }).reviews!;

    final mapped = reviewsFrom(reviews);

    test('is newest first and drops a review with no user comment', () {
      expect([for (final review in mapped) review.id], ['new', 'old']);
    });

    test('splits the title from the body at the tab', () {
      expect(mapped[1].title, 'Great');
      expect(mapped[1].body, 'Love using this app!');
      expect(mapped[0].title, isNull);
      expect(mapped[0].body, 'Crashes on start');
    });

    test('carries the rating, author, locale, version and time', () {
      final review = mapped[1];
      expect(review.rating, 5);
      expect(review.author, 'Asha');
      expect(review.locale, 'en_US');
      expect(review.appVersion, '1.2.3');
      expect(
        review.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1758000000213, isUtc: true),
      );
      expect(mapped[0].author, isNull);
    });

    test('carries the reply and when it was made', () {
      expect(mapped[1].reply, 'Thank you!');
      expect(
        mapped[1].repliedAt,
        DateTime.fromMillisecondsSinceEpoch(1758100000000, isUtc: true),
      );
      expect(mapped[0].answered, isFalse);
      expect(mapped[0].repliedAt, isNull);
    });

    test('text with no tab is all body', () {
      final review = reviewFrom(
        Review(
          reviewId: 'r',
          comments: [Comment(userComment: UserComment(text: 'Fine'))],
        ),
      )!;
      expect(review.title, isNull);
      expect(review.body, 'Fine');
    });
  });
}
