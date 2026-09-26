import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:karmashala_snippets/store.dart';
import 'package:karmashala_store/database.dart';

/// Command snippets and saved terminal presets at the server: applies the
/// rules in `karmashala_snippets`, stamps the times, writes, and says what
/// changed.
class SnippetsHandler {
  SnippetsHandler(AppDatabase db, this._now)
    : _snippets = CommandSnippetDao(db),
      _presets = TerminalPresetDao(db);

  final CommandSnippetDao _snippets;
  final TerminalPresetDao _presets;
  final DateTime Function() _now;

  SnippetsSnapshot list() =>
      SnippetsSnapshot(snippets: _snippets.list(), presets: _presets.getAll());

  CommandSnippet add(SnippetAdd request, List<DataChange> changes) {
    _check(request.label, request.command);
    if (request.id.trim().isEmpty) {
      throw const DataRefused.invalid('a snippet needs an id');
    }
    if (_snippets.getById(request.id) != null) {
      throw DataRefused.invalid('a snippet with id ${request.id} exists');
    }
    final now = _now();
    final snippet = CommandSnippet(
      id: request.id,
      label: request.label.trim(),
      command: singleLine(request.command),
      shellId: request.shellId,
      submit: request.submit,
      createdAt: now,
      updatedAt: now,
    );
    _snippets.insert(snippet);
    changes.add(SnippetChanged(snippet));
    return snippet;
  }

  CommandSnippet edit(SnippetEdit request, List<DataChange> changes) {
    _check(request.label, request.command);
    final existing =
        _snippets.getById(request.id) ??
        (throw DataRefused.notFound('no snippet with id ${request.id}'));
    final snippet = existing.copyWith(
      label: request.label.trim(),
      command: singleLine(request.command),
      shellId: request.shellId,
      clearShell: request.shellId == null,
      submit: request.submit,
      updatedAt: _now(),
    );
    _snippets.update(snippet);
    changes.add(SnippetChanged(snippet));
    return snippet;
  }

  DataAck delete(SnippetDelete request, List<DataChange> changes) {
    if (_snippets.getById(request.id) == null) return const DataAck();
    _snippets.delete(request.id);
    changes.add(SnippetRemoved(request.id));
    return const DataAck();
  }

  StoredPreset savePreset(PresetSave request, List<DataChange> changes) {
    final name = request.presetName.trim();
    if (name.isEmpty) throw const DataRefused.invalid('A preset needs a name.');
    if (request.shape.isEmpty) {
      throw const DataRefused.invalid('A preset needs a shape to open.');
    }
    final id = presetIdFor(name, request.id, _presets.getAll());
    _presets.save(
      StoredPreset(id: id, name: name, shape: request.shape, updatedAt: _now()),
    );
    final saved = _presets.byId(id)!;
    changes.add(PresetChanged(saved));
    return saved;
  }

  DataAck deletePreset(PresetDelete request, List<DataChange> changes) {
    if (_presets.byId(request.id) == null) return const DataAck();
    _presets.delete(request.id);
    changes.add(PresetRemoved(request.id));
    return const DataAck();
  }

  static void _check(String label, String command) {
    final problem = snippetProblem(label: label, command: command);
    if (problem != null) throw DataRefused.invalid(problem);
  }
}
