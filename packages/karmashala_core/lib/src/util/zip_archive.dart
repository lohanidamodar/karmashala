/// Writing a ZIP, in the one shape this app needs: a handful of text files,
/// built in memory, byte-for-byte the same every time it is asked.
///
/// No package: `dart:io` already ships the deflate this needs, and an archive
/// somebody may attach to a bug report is not a place to inherit a dependency's
/// idea of what a timestamp should be. Every entry is stamped with the same
/// zeroed DOS date, so two exports of the same session are the same file and a
/// diff between them is a diff of the session, not of the clock.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One file inside an archive.
class ZipEntry {
  ZipEntry(this.name, this.bytes);

  /// UTF-8 text at [name], the common case here.
  ZipEntry.text(String name, String text) : this(name, utf8.encode(text));

  /// The path inside the archive, `/`-separated. Never absolute, and never
  /// `..`: an entry that escapes its own archive is what makes a zip a weapon.
  final String name;
  final List<int> bytes;
}

/// Builds a ZIP holding [entries], in the order given.
///
/// Deflated where that is smaller and stored where it is not — a tiny file
/// deflates to more bytes than it started with, and the reader does not care.
Uint8List buildZipArchive(List<ZipEntry> entries) {
  final out = BytesBuilder(copy: false);
  final directory = BytesBuilder(copy: false);
  var count = 0;

  for (final entry in entries) {
    final name = _safeName(entry.name);
    if (name.isEmpty) continue;
    final nameBytes = utf8.encode(name);
    final raw = entry.bytes;
    final crc = zipCrc32(raw);
    final deflated = raw.isEmpty
        ? const <int>[]
        : ZLibEncoder(raw: true, level: 6).convert(raw);
    // Storing beats deflating whenever deflate did not actually help.
    final compress = deflated.isNotEmpty && deflated.length < raw.length;
    final payload = compress ? deflated : raw;
    final method = compress ? 8 : 0;
    final offset = out.length;

    out.add(
      _localHeader(
        nameBytes: nameBytes,
        method: method,
        crc: crc,
        compressed: payload.length,
        uncompressed: raw.length,
      ),
    );
    out.add(payload);

    directory.add(
      _centralHeader(
        nameBytes: nameBytes,
        method: method,
        crc: crc,
        compressed: payload.length,
        uncompressed: raw.length,
        offset: offset,
      ),
    );
    count++;
  }

  final directoryOffset = out.length;
  final directoryBytes = directory.takeBytes();
  out.add(directoryBytes);
  out.add(
    _endOfDirectory(
      count: count,
      size: directoryBytes.length,
      offset: directoryOffset,
    ),
  );
  return out.takeBytes();
}

/// Writes [entries] to [path], creating the parent directory if it is missing.
Future<File> writeZipArchive(String path, List<ZipEntry> entries) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  return file.writeAsBytes(buildZipArchive(entries), flush: true);
}

/// The archive path [name] is allowed to be: `/`-separated, never rooted, and
/// with every `..` segment dropped rather than resolved.
String _safeName(String name) {
  final parts = name
      .replaceAll(r'\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '.' && part != '..');
  return parts.join('/');
}

/// CRC-32 (IEEE 802.3), the one a ZIP reader checks each entry against.
int zipCrc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var value = i;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
    }
    table[i] = value;
  }
  return table;
}();

/// Bit 11 of the general-purpose flags: the name is UTF-8. Without it a
/// reader falls back to its own code page and a non-ASCII title comes out
/// mangled on somebody else's machine.
const int _utf8NameFlag = 0x0800;

/// The version that understands deflate — 2.0, as ZIP spells it.
const int _version = 20;

Uint8List _localHeader({
  required List<int> nameBytes,
  required int method,
  required int crc,
  required int compressed,
  required int uncompressed,
}) {
  final header = BytesBuilder(copy: false)
    ..add(_u32(0x04034b50))
    ..add(_u16(_version))
    ..add(_u16(_utf8NameFlag))
    ..add(_u16(method))
    ..add(_u16(0)) // modification time — zeroed, so exports are reproducible
    ..add(_u16(0)) // modification date, likewise
    ..add(_u32(crc))
    ..add(_u32(compressed))
    ..add(_u32(uncompressed))
    ..add(_u16(nameBytes.length))
    ..add(_u16(0))
    ..add(nameBytes);
  return header.takeBytes();
}

Uint8List _centralHeader({
  required List<int> nameBytes,
  required int method,
  required int crc,
  required int compressed,
  required int uncompressed,
  required int offset,
}) {
  final header = BytesBuilder(copy: false)
    ..add(_u32(0x02014b50))
    ..add(_u16(_version)) // version made by
    ..add(_u16(_version)) // version needed
    ..add(_u16(_utf8NameFlag))
    ..add(_u16(method))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(crc))
    ..add(_u32(compressed))
    ..add(_u32(uncompressed))
    ..add(_u16(nameBytes.length))
    ..add(_u16(0)) // extra
    ..add(_u16(0)) // comment
    ..add(_u16(0)) // disk number
    ..add(_u16(0)) // internal attributes
    ..add(_u32(0)) // external attributes
    ..add(_u32(offset))
    ..add(nameBytes);
  return header.takeBytes();
}

Uint8List _endOfDirectory({
  required int count,
  required int size,
  required int offset,
}) {
  final end = BytesBuilder(copy: false)
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(count))
    ..add(_u16(count))
    ..add(_u32(size))
    ..add(_u32(offset))
    ..add(_u16(0));
  return end.takeBytes();
}

Uint8List _u16(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);
