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

  test('anything else is not one', () {
    expect(taskNotificationLine('please fix the login'), isNull);
    expect(
      taskNotificationLine('see ${_envelope('a1', summary: 'x')}'),
      isNull,
      reason: 'somebody wrote around it',
    );
  });
}
