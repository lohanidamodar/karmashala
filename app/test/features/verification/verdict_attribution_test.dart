import 'package:karmashala_verification/verification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the same session on both sides is a self-graded verdict', () {
    expect(
      VerdictAttribution.of(producerSessionId: 's-1', subjectSessionId: 's-1'),
      VerdictAttribution.author,
    );
  });

  test('a different producer is an independent verdict', () {
    expect(
      VerdictAttribution.of(producerSessionId: 's-2', subjectSessionId: 's-1'),
      VerdictAttribution.independent,
    );
  });

  test('no producer is not recorded — never author, never independent', () {
    final attribution = VerdictAttribution.of(
      producerSessionId: null,
      subjectSessionId: 's-1',
    );
    expect(attribution, VerdictAttribution.notRecorded);
    expect(attribution, isNot(VerdictAttribution.author));
    expect(attribution, isNot(VerdictAttribution.independent));
    expect(attribution.isRecorded, isFalse);
  });

  test('a producer with nothing to compare against is also not recorded', () {
    // Knowing who graded but not whose work it was leaves the question open.
    // Calling that independent would be the same lie in the other direction.
    expect(
      VerdictAttribution.of(producerSessionId: 's-2', subjectSessionId: null),
      VerdictAttribution.notRecorded,
    );
  });

  test('each state reads differently to a human', () {
    final labels = {for (final a in VerdictAttribution.values) a.label};
    expect(labels, hasLength(VerdictAttribution.values.length));
    expect(VerdictAttribution.notRecorded.label, contains('not recorded'));
  });

  test('a verdict Karmashala read off an exit code is its own, and '
      'independent', () {
    final attribution = VerdictAttribution.of(
      producerSessionId: kAppVerifierId,
      subjectSessionId: 's-1',
    );
    expect(attribution, VerdictAttribution.app);
    expect(attribution.isIndependent, isTrue);
    expect(VerdictAttribution.author.isIndependent, isFalse);
    expect(VerdictAttribution.notRecorded.isIndependent, isFalse);
  });
}
