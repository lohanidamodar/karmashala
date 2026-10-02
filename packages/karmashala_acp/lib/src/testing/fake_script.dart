import 'package:meta/meta.dart';

import '../json.dart';
import '../types/content_block.dart';
import '../types/enums.dart';
import '../types/permission.dart';
import '../types/plan.dart';
import '../types/session_update.dart';
import '../types/tool_call.dart';

/// One `session/prompt` as the fake agent answers it: [steps] in order, then
/// [stopReason]. A `session/cancel` arriving mid-way ends it with `cancelled`.
@immutable
final class FakeTurn {
  const FakeTurn(this.steps, {this.stopReason = StopReason.endTurn});

  final List<FakeStep> steps;
  final StopReason stopReason;
}

/// Something the fake agent does during a turn.
@immutable
sealed class FakeStep {
  const FakeStep();

  const factory FakeStep.message(String text, {String? messageId}) =
      FakeMessageStep;

  const factory FakeStep.thought(String text, {String? messageId}) =
      FakeThoughtStep;

  const factory FakeStep.toolCall({
    required String toolCallId,
    required String title,
    ToolKind kind,
    Object? rawInput,
    List<ToolCallLocation> locations,
    List<PermissionOption>? permissionOptions,
    List<ToolCallContent> completedContent,
    Object? rawOutput,
  }) = FakeToolCallStep;

  const factory FakeStep.plan(List<PlanEntry> entries) = FakePlanStep;

  const factory FakeStep.mode(String modeId) = FakeModeStep;

  /// Any update, verbatim.
  const factory FakeStep.update(SessionUpdate update) = FakeUpdateStep;

  /// Raw `update` JSON, for shapes this package does not model.
  const factory FakeStep.rawUpdate(JsonMap update) = FakeRawUpdateStep;

  /// Blocks until the client sends `session/cancel`; the turn then ends
  /// `cancelled`.
  const factory FakeStep.waitForCancel() = FakeWaitForCancelStep;

  const factory FakeStep.readFile(String path, {int? line, int? limit}) =
      FakeReadFileStep;

  const factory FakeStep.writeFile(String path, String content) =
      FakeWriteFileStep;
}

final class FakeMessageStep extends FakeStep {
  const FakeMessageStep(this.text, {this.messageId});

  final String text;
  final String? messageId;
}

final class FakeThoughtStep extends FakeStep {
  const FakeThoughtStep(this.text, {this.messageId});

  final String text;
  final String? messageId;
}

/// Emits `tool_call` (pending); with [permissionOptions], asks the client
/// and then emits `tool_call_update` completed (allowed) or failed
/// (rejected). A `cancelled` outcome ends the turn `cancelled`.
final class FakeToolCallStep extends FakeStep {
  const FakeToolCallStep({
    required this.toolCallId,
    required this.title,
    this.kind = ToolKind.other,
    this.rawInput,
    this.locations = const [],
    this.permissionOptions,
    this.completedContent = const [],
    this.rawOutput,
  });

  final String toolCallId;
  final String title;
  final ToolKind kind;
  final Object? rawInput;
  final List<ToolCallLocation> locations;
  final List<PermissionOption>? permissionOptions;
  final List<ToolCallContent> completedContent;
  final Object? rawOutput;

  ToolCallUpdate get opening => ToolCallUpdate(
    toolCallId: toolCallId,
    isNew: true,
    title: title,
    kind: kind,
    status: ToolCallStatus.pending,
    rawInput: rawInput,
    locations: locations,
  );
}

final class FakePlanStep extends FakeStep {
  const FakePlanStep(this.entries);

  final List<PlanEntry> entries;
}

final class FakeModeStep extends FakeStep {
  const FakeModeStep(this.modeId);

  final String modeId;
}

final class FakeUpdateStep extends FakeStep {
  const FakeUpdateStep(this.update);

  final SessionUpdate update;
}

final class FakeRawUpdateStep extends FakeStep {
  const FakeRawUpdateStep(this.update);

  final JsonMap update;
}

final class FakeWaitForCancelStep extends FakeStep {
  const FakeWaitForCancelStep();
}

final class FakeReadFileStep extends FakeStep {
  const FakeReadFileStep(this.path, {this.line, this.limit});

  final String path;
  final int? line;
  final int? limit;
}

final class FakeWriteFileStep extends FakeStep {
  const FakeWriteFileStep(this.path, this.content);

  final String path;
  final String content;
}

/// Standard permission options: allow once/always, reject once.
const fakePermissionOptions = [
  PermissionOption(
    optionId: 'allow',
    name: 'Allow',
    kind: PermissionOptionKind.allowOnce,
  ),
  PermissionOption(
    optionId: 'allow-always',
    name: 'Always allow',
    kind: PermissionOptionKind.allowAlways,
  ),
  PermissionOption(
    optionId: 'reject',
    name: 'Reject',
    kind: PermissionOptionKind.rejectOnce,
  ),
];

/// Shorthand for a one-block text prompt.
List<ContentBlock> textPrompt(String text) => [ContentBlock.text(text)];
