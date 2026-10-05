import 'package:agent_cli/read.dart';
import 'package:test/test.dart';

String _envelope(String id, {String? summary}) =>
    '<task-notification>\n<task-id>$id</task-id>\n'
    '<status>completed</status>\n'
    '${summary == null ? '' : '<summary>$summary</summary>\n'}'
    '<result>done</result>\n</task-notification>';

/// The one line a background run's completion notice says, for the chat.
void main() {
  test('a notice is its summary', () {
    expect(
      taskNotificationLine(
        _envelope('a1', summary: 'Agent "Sleep 90 then report" finished'),
      ),
      'Agent "Sleep 90 then report" finished',
    );
  });

  test('two notices in one row are a line each', () {
    expect(
      taskNotificationLine(
        '${_envelope('a1', summary: 'First finished')}\r\n'
        '${_envelope('a2', summary: 'Second failed')}\r\n',
      ),
      'First finished\nSecond failed',
    );
  });

  test('a notice with no summary claims no outcome', () {
    expect(taskNotificationLine(_envelope('a1')), kTaskNotificationFallback);
  });

  test('an interim notice reported progress, whatever its summary says', () {
    const note =
        '<note>This agent stopped with background work of its own still '
        'running. It may resume on its own when that work completes or '
        'reports, and the same task-id notifies again if it does; the result '
        'below may be interim.</note>\n';
    String interim(String? summary) => _envelope(
      'a1',
      summary: summary,
    ).replaceFirst('<result>', '$note<result>');

    expect(
      taskNotificationLine(interim('Agent "Sleep 60 then report" finished')),
      'Agent "Sleep 60 then report" reported progress',
    );
    expect(taskNotificationLine(interim(null)), kTaskNotificationProgress);
    expect(
      taskNotificationLine(interim('Something odd')),
      kTaskNotificationProgress,
    );
  });

  test('anything else is not one', () {
    expect(taskNotificationLine('please fix the login'), isNull);
    expect(
      taskNotificationLine('see ${_envelope('a1', summary: 'x')}'),
      isNull,
      reason: 'somebody wrote around it',
    );
  });
}
