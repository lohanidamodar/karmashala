import 'dart:async';
import 'dart:io';

/// Ends a process and every process it started.
abstract interface class ProcessTreeKiller {
  Future<void> killTree(int pid);
}

/// `taskkill /T /F` on Windows; elsewhere every descendant found by `ps`, then
/// the root, terminated and then killed.
class SystemProcessTreeKiller implements ProcessTreeKiller {
  const SystemProcessTreeKiller();

  @override
  Future<void> killTree(int pid) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
      return;
    }
    final tree = [...await _descendantsOf(pid), pid];
    for (final one in tree) {
      Process.killPid(one, ProcessSignal.sigterm);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    for (final one in tree) {
      Process.killPid(one, ProcessSignal.sigkill);
    }
  }

  /// Leaves first, so a parent never restarts a child it just lost.
  static Future<List<int>> _descendantsOf(int root) async {
    final ProcessResult listed;
    try {
      listed = await Process.run('ps', ['-A', '-o', 'pid=', '-o', 'ppid=']);
    } on ProcessException {
      return const [];
    }
    if (listed.exitCode != 0) return const [];
    final children = <int, List<int>>{};
    for (final line in '${listed.stdout}'.split('\n')) {
      final words = line.trim().split(RegExp(r'\s+'));
      if (words.length != 2) continue;
      final child = int.tryParse(words[0]);
      final parent = int.tryParse(words[1]);
      if (child == null || parent == null) continue;
      (children[parent] ??= []).add(child);
    }
    return descendantsLeavesFirst(root, children);
  }
}

/// Every descendant of [root] in [children] (parent to its children), each
/// after all of its own descendants.
List<int> descendantsLeavesFirst(int root, Map<int, List<int>> children) {
  final order = <int>[];
  final seen = <int>{root};
  void visit(int pid) {
    for (final child in children[pid] ?? const <int>[]) {
      if (!seen.add(child)) continue;
      visit(child);
      order.add(child);
    }
  }

  visit(root);
  return order;
}
