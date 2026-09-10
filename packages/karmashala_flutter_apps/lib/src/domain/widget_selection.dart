/// Where a widget was written, as the framework reports it. `creationLocation`
/// exists only under `--track-widget-creation`, so a missing location is a fact
/// about the build and never a failed pick.
class WidgetSourceLocation {
  const WidgetSourceLocation({
    required this.fileUri,
    required this.line,
    required this.column,
    this.name,
  });

  /// A `file://` URI as the framework writes it, not a host path.
  final String fileUri;

  /// 1-based, both of them.
  final int line;
  final int column;

  /// The constructor at that location, when the framework named it.
  final String? name;

  /// The form an editor and an agent both accept: `path:line:column`.
  String get asEditorTarget {
    final path = fileUri.startsWith('file://')
        ? Uri.tryParse(fileUri)?.toFilePath() ?? fileUri
        : fileUri;
    return '$path:$line:$column';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'fileUri': fileUri,
    'line': line,
    'column': column,
    if (name != null) 'name': name,
    'editorTarget': asEditorTarget,
  };

  /// Reads a `navigate` event's `extensionData`. It carries the location and
  /// nothing else, so a pick is this event *plus* one read of the selection.
  static WidgetSourceLocation? fromNavigateEvent(Map<Object?, Object?> data) {
    final file = data['fileUri'];
    final line = data['line'];
    final column = data['column'];
    if (file is! String || file.isEmpty) return null;
    if (line is! num || column is! num) return null;
    return WidgetSourceLocation(
      fileUri: file,
      line: line.toInt(),
      column: column.toInt(),
    );
  }
}

/// The widget the user picked, as `getSelectedSummaryWidget` describes it.
class WidgetSelection {
  const WidgetSelection({
    required this.description,
    this.widgetRuntimeType,
    this.valueId,
    this.location,
    this.createdByLocalProject = false,
    this.stateful = false,
  });

  /// The inspector's own label — `Text`, `Padding`, `MyHomePage`.
  final String description;

  final String? widgetRuntimeType;

  /// The inspector's handle, valid only while its object group is alive.
  final String? valueId;

  final WidgetSourceLocation? location;

  /// Whether it was written in the project rather than the framework: normally
  /// true, and worth showing when it is not.
  final bool createdByLocalProject;

  final bool stateful;

  Map<String, Object?> toJson() => <String, Object?>{
    'widget': description,
    if (widgetRuntimeType != null && widgetRuntimeType != description)
      'runtimeType': widgetRuntimeType,
    'createdByLocalProject': createdByLocalProject,
    'stateful': stateful,
    if (valueId != null) 'inspectorRef': valueId,
    if (location != null) 'location': location!.toJson(),
  };

  /// The sentence an agent should read.
  String toPromptText() {
    final where = location == null
        ? 'This build carries no widget locations, so there is no file to name.'
        : 'Written at ${location!.asEditorTarget}.';
    final origin = createdByLocalProject
        ? ''
        : ' It comes from the framework or a package rather than this project.';
    return 'Widget: $description${stateful ? ' (stateful)' : ''}. $where$origin';
  }

  /// Reads one `getSelectedSummaryWidget` reply, or null — which means select
  /// mode is on with nothing selected, a valid answer rather than a malformed one.
  static WidgetSelection? fromInspectorNode(Object? node) {
    if (node is! Map) return null;
    final description = node['description'];
    if (description is! String || description.isEmpty) return null;
    final creation = node['creationLocation'];
    WidgetSourceLocation? location;
    if (creation is Map) {
      final file = creation['file'];
      final line = creation['line'];
      final column = creation['column'];
      if (file is String && line is num && column is num) {
        location = WidgetSourceLocation(
          fileUri: file,
          line: line.toInt(),
          column: column.toInt(),
          name: creation['name'] as String?,
        );
      }
    }
    return WidgetSelection(
      description: description,
      widgetRuntimeType: node['widgetRuntimeType'] as String?,
      valueId: node['valueId'] as String?,
      location: location,
      createdByLocalProject: node['createdByLocalProject'] == true,
      stateful: node['stateful'] == true,
    );
  }
}
