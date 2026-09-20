/// Small dependency-free helpers shared across the app: a clock seam, id
/// generation, byte-bounded text, a debounced directory watcher, JSON object
/// splicing, link detection and a deterministic ZIP writer.
library;

export 'src/util/bounded_text.dart';
export 'src/util/clock.dart';
export 'src/util/directory_change_watcher.dart';
export 'src/util/id_generator.dart';
export 'src/util/json_object_splice.dart';
export 'src/util/text_links.dart';
export 'src/util/zip_archive.dart';
