import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

/// Walks a process's virtual address space and totals the committed regions by
/// type, so native growth can be attributed to something.
///
/// The Dart heap is visible through the VM service; everything else in the
/// process is not. This asks Windows directly: how much is committed private
/// (a heap or a `VirtualAlloc`), how much is a mapped file, how much is a
/// loaded image — and which individual allocations are the largest.
///
///   `dart run tool/regions.dart <pid> [out.csv]`
const int memCommit = 0x1000;
const int memPrivate = 0x20000;
const int memMapped = 0x40000;
const int memImage = 0x1000000;

typedef _OpenC = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenD = int Function(int, int, int);
typedef _QueryC =
    IntPtr Function(IntPtr, Pointer<Void>, Pointer<Uint8>, IntPtr);
typedef _QueryD = int Function(int, Pointer<Void>, Pointer<Uint8>, int);

void main(List<String> args) {
  final pid = int.parse(args[0]);
  final k32 = DynamicLibrary.open('kernel32.dll');
  final openProcess = k32.lookupFunction<_OpenC, _OpenD>('OpenProcess');
  final virtualQuery = k32.lookupFunction<_QueryC, _QueryD>('VirtualQueryEx');
  final closeHandle = k32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

  // PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
  final handle = openProcess(0x0400 | 0x0010, 0, pid);
  if (handle == 0) {
    stderr.writeln('could not open process $pid');
    exit(2);
  }

  final buffer = calloc<Uint8>(48);
  var address = 0;
  var private = 0, mapped = 0, image = 0, reserved = 0;
  final byBase = <int, int>{};
  final protOf = <int, int>{};
  var regions = 0;

  while (address < 0x7FFFFFFF0000) {
    final written = virtualQuery(
      handle,
      Pointer<Void>.fromAddress(address),
      buffer,
      48,
    );
    if (written == 0) break;
    final data = buffer.asTypedList(48).buffer.asByteData();
    final allocationBase = data.getUint64(8, Endian.little);
    final regionSize = data.getUint64(24, Endian.little);
    final state = data.getUint32(32, Endian.little);
    final protect = data.getUint32(36, Endian.little);
    final type = data.getUint32(40, Endian.little);
    if (regionSize == 0) break;
    if (state == memCommit) {
      regions++;
      if (type == memPrivate) {
        private += regionSize;
        byBase[allocationBase] = (byBase[allocationBase] ?? 0) + regionSize;
        protOf[allocationBase] = protect;
      } else if (type == memMapped) {
        mapped += regionSize;
      } else if (type == memImage) {
        image += regionSize;
      }
    } else if (state == 0x2000) {
      reserved += regionSize;
    }
    address += regionSize;
  }
  calloc.free(buffer);
  closeHandle(handle);

  String mb(int b) => (b / 1048576).toStringAsFixed(1);
  stdout.writeln(
    'pid $pid  committed: private ${mb(private)} MiB · '
    'mapped ${mb(mapped)} MiB · image ${mb(image)} MiB · '
    'reserved ${mb(reserved)} MiB · $regions regions',
  );

  final top = byBase.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('  largest private allocations:');
  for (final e in top.take(12)) {
    stdout.writeln(
      '    0x${e.key.toRadixString(16).padLeft(12, '0')}  '
      '${mb(e.value).padLeft(8)} MiB  prot=0x${protOf[e.key]!.toRadixString(16)}',
    );
  }
  if (args.length > 1) {
    final sink = StringBuffer();
    for (final e in top) {
      sink.writeln('${e.key},${e.value}');
    }
    File(args[1]).writeAsStringSync(sink.toString());
  }
}
