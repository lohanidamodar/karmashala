/// Input that acts on an agent is numbered, and one arriving after a later one
/// is refused with the number expected — never typed out of order.
library;

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import './fake_bindings.dart';

typedef Frame = ({FrameType type, String? id, Map<String, Object?> payload});

void main() {
  late FakeRemoteBindings fake;
  late HostSessionApi api;
  late List<Frame> sent;
  var seq = 0;

  setUp(() {
    fake = FakeRemoteBindings()..addSession('s1');
    sent = [];
    seq = 0;
    api = HostSessionApi(
      device: fakeDevice(),
      bindings: fake.bindings,
      send: (type, {id, payload = const {}}) async {
        sent.add((type: type, id: id, payload: payload));
        return true;
      },
    );
  });

  Future<void> prompt(String text, {int? inputSeq}) => api.handleEnvelope(
    Envelope.of(
      FrameType.promptSend,
      seq: seq++,
      id: 'q$seq',
      payload: {'sessionId': 's1', 'text': text, 'inputSeq': ?inputSeq},
    ),
  );

  test('in order, every input is typed', () async {
    await prompt('one', inputSeq: 0);
    await prompt('two', inputSeq: 1);
    expect(fake.prompts.map((p) => p.text), ['one', 'two']);
  });

  test('an input older than one already typed is refused with the next '
      'expected', () async {
    await prompt('two', inputSeq: 1);
    await prompt('one', inputSeq: 0);

    expect(fake.prompts.map((p) => p.text), ['two']);
    expect(sent.last.type, FrameType.error);
    expect(sent.last.payload['code'], ErrorCode.outOfOrder.wire);
    expect(sent.last.payload['expected'], 2);
  });

  test('a repeat is refused rather than typed twice', () async {
    await prompt('one', inputSeq: 0);
    await prompt('one', inputSeq: 0);
    expect(fake.prompts, hasLength(1));
    expect(sent.last.payload['code'], ErrorCode.outOfOrder.wire);
  });

  test('a gap is a lost frame, not a duplicate, and is let through', () async {
    await prompt('one', inputSeq: 0);
    await prompt('three', inputSeq: 2);
    expect(fake.prompts.map((p) => p.text), ['one', 'three']);
  });

  test('a phone that numbers nothing is typed for as before', () async {
    await prompt('one');
    await prompt('two');
    expect(fake.prompts, hasLength(2));
  });

  test('only frames that act on an agent are numbered', () {
    expect(
      FrameType.values.where((t) => t.isInput),
      unorderedEquals([
        FrameType.promptSend,
        FrameType.approvalAnswer,
        FrameType.questionAnswer,
        FrameType.menuAnswer,
      ]),
    );
  });
}
