import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';

import '../../pipelines/application/pipelines_controller.dart'
    show pipelineDraftOf;

/// The Workflows page's three sections: automations (and, under them, the
/// sessions waiting to be resumed), pipelines, and every run of both.
enum WorkflowsSection {
  automations('Automations'),
  pipelines('Pipelines'),
  runs('Runs');

  const WorkflowsSection(this.label);

  final String label;
}

/// Which section the Workflows page shows; kept outside it so a link can open
/// the page on the one it means.
class WorkflowsSectionNotifier extends Notifier<WorkflowsSection> {
  @override
  WorkflowsSection build() => WorkflowsSection.automations;

  void show(WorkflowsSection section) => state = section;
}

final workflowsSectionProvider =
    NotifierProvider<WorkflowsSectionNotifier, WorkflowsSection>(
      WorkflowsSectionNotifier.new,
    );

/// What kind of thing a run in Runs is a run of.
enum WorkflowRunKind {
  automation('Automation'),
  pipeline('Pipeline');

  const WorkflowRunKind(this.label);

  final String label;
}

/// One run in Runs, by kind and id.
@immutable
class WorkflowRunRef {
  const WorkflowRunRef(this.kind, this.id);

  final WorkflowRunKind kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is WorkflowRunRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => '${kind.name}:$id';
}

/// The run Runs shows the detail of: beside the list on a wide page, over it
/// on a narrow one. Null shows none.
class SelectedWorkflowRunNotifier extends Notifier<WorkflowRunRef?> {
  @override
  WorkflowRunRef? build() => null;

  void select(WorkflowRunRef? run) => state = run;
}

final selectedWorkflowRunProvider =
    NotifierProvider<SelectedWorkflowRunNotifier, WorkflowRunRef?>(
      SelectedWorkflowRunNotifier.new,
    );

/// A pipeline open in the page's editor. [generation] tells two openings of
/// the same pipeline apart, so the editor starts fresh each time.
@immutable
class PipelineEditing {
  const PipelineEditing(this.draft, this.generation);

  final PipelineDefinition draft;
  final int generation;
}

/// The pipeline the Pipelines section edits, in the page rather than a
/// dialog: a pane beside the grid on a wide page, the whole page on a narrow
/// one. Null edits none.
class PipelineEditingNotifier extends Notifier<PipelineEditing?> {
  var _generation = 0;

  @override
  PipelineEditing? build() => null;

  /// Edits [pipeline] — a copy of it when it is built in — or, with none, a
  /// new one from the first template.
  void open([PipelineDefinition? pipeline]) =>
      state = PipelineEditing(pipelineDraftOf(pipeline), ++_generation);

  /// Edits a copy of [pipeline] under its own name.
  void duplicate(PipelineDefinition pipeline) => state = PipelineEditing(
    pipeline.copyWith(id: '', name: '${pipeline.name} (copy)', builtIn: false),
    ++_generation,
  );

  void close() => state = null;
}

final pipelineEditingProvider =
    NotifierProvider<PipelineEditingNotifier, PipelineEditing?>(
      PipelineEditingNotifier.new,
    );

/// A request, from an inbox item or a notification, to open pipeline run
/// [runId] in Workflows → Runs. [serial] tells two for the same run apart.
@immutable
class WorkflowsOpenRequest {
  const WorkflowsOpenRequest(this.runId, this.serial);

  final String runId;
  final int serial;
}

class WorkflowsOpenRequests extends Notifier<WorkflowsOpenRequest?> {
  var _serial = 0;

  @override
  WorkflowsOpenRequest? build() => null;

  void openPipelineRun(String runId) =>
      state = WorkflowsOpenRequest(runId, ++_serial);
}

final workflowsOpenRequestProvider =
    NotifierProvider<WorkflowsOpenRequests, WorkflowsOpenRequest?>(
      WorkflowsOpenRequests.new,
    );
