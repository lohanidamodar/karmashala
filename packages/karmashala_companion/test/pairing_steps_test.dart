import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/pairing.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

/// Where each step of a pairing attempt stands, and how a grant is worded.
void main() {
  List<PairingStepState> row({
    required CompanionPairingStage current,
    CompanionPairingStage failurePoint = CompanionPairingStage.codeAccepted,
  }) => [
    for (final step in const [
      CompanionPairingStage.codeAccepted,
      CompanionPairingStage.searching,
      CompanionPairingStage.proving,
      CompanionPairingStage.paired,
    ])
      pairingStepStateOf(
        step: step,
        current: current,
        failurePoint: failurePoint,
      ),
  ];

  test('steps before the current one are done, later ones pending', () {
    expect(row(current: CompanionPairingStage.searching), [
      PairingStepState.done,
      PairingStepState.active,
      PairingStepState.pending,
      PairingStepState.pending,
    ]);
  });

  test('paired marks every step done, itself included', () {
    expect(
      row(current: CompanionPairingStage.paired),
      everyElement(PairingStepState.done),
    );
  });

  test('a failure wears the warning where the attempt died', () {
    expect(
      row(
        current: CompanionPairingStage.failed,
        failurePoint: CompanionPairingStage.proving,
      ),
      [
        PairingStepState.done,
        PairingStepState.done,
        PairingStepState.failed,
        PairingStepState.pending,
      ],
    );
  });

  test('grants are worded as the wire names them, spaced', () {
    expect(
      companionGrantsSentence(
        CapabilitySet.of([Capability.sendPrompt, Capability.approve]),
      ),
      'send prompt, approve',
    );
  });
}
