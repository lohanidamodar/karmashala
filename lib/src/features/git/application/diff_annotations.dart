import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/diff_line.dart';

class DiffAnnotation {
  const DiffAnnotation({
    required this.repositoryId,
    required this.path,
    required this.diffIndex,
    required this.line,
    required this.comment,
  });

  final String repositoryId;
  final String path;
  final int diffIndex;
  final DiffLine line;
  final String comment;
}

class DiffAnnotationsController extends Notifier<List<DiffAnnotation>> {
  @override
  List<DiffAnnotation> build() => const [];

  void put(DiffAnnotation annotation) {
    state = [
      for (final current in state)
        if (!(current.repositoryId == annotation.repositoryId &&
            current.path == annotation.path &&
            current.diffIndex == annotation.diffIndex))
          current,
      annotation,
    ];
  }

  void remove(String repositoryId, String path, int diffIndex) {
    state = [
      for (final current in state)
        if (!(current.repositoryId == repositoryId &&
            current.path == path &&
            current.diffIndex == diffIndex))
          current,
    ];
  }

  void clearRepository(String repositoryId) {
    state = state.where((item) => item.repositoryId != repositoryId).toList();
  }
}

final diffAnnotationsProvider =
    NotifierProvider<DiffAnnotationsController, List<DiffAnnotation>>(
      DiffAnnotationsController.new,
    );

String buildDiffFeedbackPrompt(List<DiffAnnotation> annotations) {
  final buffer = StringBuffer(
    'Please address these review comments. Keep each requested change scoped '
    'to the referenced file and verify the result:\n',
  );
  for (final annotation in annotations) {
    buffer
      ..write(
        '\n- `${annotation.path}` (diff line ${annotation.diffIndex + 1})',
      )
      ..write('\n  Code: `${annotation.line.text.replaceAll('`', r'\`')}`')
      ..write('\n  Review: ${annotation.comment.trim()}\n');
  }
  return buffer.toString().trimRight();
}
