import 'package:googleapis/androidpublisher/v3.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_play/src/play_mapping.dart';
import 'package:test/test.dart';

void main() {
  group('releasesFromTracks', () {
    final tracks = TracksListResponse.fromJson({
      'tracks': [
        {
          'track': 'internal',
          'releases': [
            {
              'name': '2.1.0',
              'status': 'completed',
              'versionCodes': ['210', '211'],
            },
          ],
        },
        {
          'track': 'qa-team',
          'releases': [
            {'status': 'draft'},
          ],
        },
        {
          'track': 'production',
          'releases': [
            {
              'name': '2.0.0',
              'status': 'inProgress',
              'userFraction': 0.2,
              'versionCodes': ['200'],
            },
            {
              'name': '1.9.0',
              'status': 'completed',
              'versionCodes': ['190'],
            },
          ],
        },
        {
          'track': 'beta',
          'releases': [
            {
              'name': '2.0.1',
              'status': 'halted',
              'userFraction': 0.5,
              'versionCodes': ['201'],
            },
          ],
        },
        {
          'track': 'alpha',
          'releases': [
            {'name': 'x', 'status': 'somethingNew'},
          ],
        },
      ],
    }).tracks!;

    final releases = releasesFromTracks(tracks);

    test('orders production, open, closed, internal, custom', () {
      expect(
        [for (final release in releases) release.track],
        ['production', 'production', 'beta', 'alpha', 'internal', 'qa-team'],
      );
    });

    test('a staged rollout carries its fraction', () {
      expect(releases[0].state, ReleaseState.rollingOut);
      expect(releases[0].rolloutFraction, 0.2);
      expect(releases[0].rawState, 'inProgress');
      expect(releases[0].version, '2.0.0');
      expect(releases[0].build, '200');
    });

    test('completed is live on production and testing elsewhere', () {
      expect(releases[1].state, ReleaseState.live);
      expect(releases[1].rolloutFraction, isNull);
      expect(releases[4].state, ReleaseState.testing);
    });

    test('the build is the highest version code', () {
      expect(releases[4].build, '211');
    });

    test('halted, draft and unknown keep their own word', () {
      expect(releases[2].state, ReleaseState.halted);
      expect(releases[2].rolloutFraction, isNull);
      expect(releases[3].state, ReleaseState.unknown);
      expect(releases[3].rawState, 'somethingNew');
      expect(releases[5].state, ReleaseState.draft);
      expect(releases[5].version, '');
      expect(releases[5].build, isNull);
    });

    test('a track with no releases adds nothing', () {
      expect(releasesFromTracks([Track(track: 'production')]), isEmpty);
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
