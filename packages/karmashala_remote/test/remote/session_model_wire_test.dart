import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

void main() {
  test('a session snapshot carries the model it was launched on', () {
    const sent = RemoteSessionSnapshot(
      sessionId: 's1',
      title: 'Fix the tests',
      status: 'running',
      model: 'opus',
    );
    final read = RemoteSessionSnapshot.fromJson(sent.toJson());
    expect(read.model, 'opus');
    expect(read, sent);
  });

  test('no model is no key: an older phone reads the same bytes', () {
    const sent = RemoteSessionSnapshot(
      sessionId: 's1',
      title: 'Fix the tests',
      status: 'running',
    );
    expect(sent.toJson().containsKey('model'), isFalse);
    expect(RemoteSessionSnapshot.fromJson(sent.toJson()).model, isNull);
  });

  test('a session snapshot carries what its agent is doing', () {
    const sent = RemoteSessionSnapshot(
      sessionId: 's1',
      title: 'Fix the tests',
      status: 'running',
      activity: 'idle',
    );
    final read = RemoteSessionSnapshot.fromJson(sent.toJson());
    expect(read.activity, 'idle');
    expect(read, sent);
    expect(
      const RemoteSessionSnapshot(
        sessionId: 's1',
        title: 'Fix the tests',
        status: 'running',
      ).toJson().containsKey('activity'),
      isFalse,
      reason: 'nobody keeps a status: no key',
    );
  });
}
