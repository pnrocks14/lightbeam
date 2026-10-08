import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'base45.dart';
import 'fountain.dart';

/// Wire format of one QR frame (before Base45), protocol version 2:
///
///   0      magic 'L' (0x4C)
///   1      protocol version
///   2..5   fileId   (u32, random per transfer)
///   6..9   K        (u32, number of source blocks)
///   10..11 blockSize(u16)
///   12..15 seq      (u32, packet number)
///   16..17 degree   (u16, how many blocks are XOR-ed in)
///   18..21 CRC-32 of bytes 0..17 and the block data
///   22..   block data (blockSize bytes)
const packetMagic = 0x4C;
const protocolVersion = 2;
const headerSize = 22;

/// Upper bounds a receiver accepts. They stop a stray or hostile code from
/// making the receiver allocate gigabytes.
const maxBlockSize = 2900; // fits QR version 40-L in alphanumeric mode
const maxTransferBytes = 64 * 1024 * 1024;

/// Files up to this many blocks use dense packets and Gaussian decoding.
const denseLimit = FountainDecoder.gaussLimit;

enum AcceptResult {
  /// A packet that added information.
  newPacket,

  /// Already seen, or carried nothing new.
  duplicate,

  /// A valid packet from a different transfer.
  otherFile,

  /// Not a LightBeam code at all (any other QR code in view).
  invalid,

  /// A LightBeam code that failed its CRC or sanity checks.
  corrupt,

  /// A LightBeam code from an incompatible protocol version.
  incompatibleVersion,
}

class Packet {
  final int fileId;
  final int k;
  final int blockSize;
  final int seq;
  final int degree;
  final Uint8List data;

  Packet(this.fileId, this.k, this.blockSize, this.seq, this.degree, this.data);

  Uint8List toBytes() {
    final out = Uint8List(headerSize + data.length);
    final b = ByteData.sublistView(out);
    b.setUint8(0, packetMagic);
    b.setUint8(1, protocolVersion);
    b.setUint32(2, fileId);
    b.setUint32(6, k);
    b.setUint16(10, blockSize);
    b.setUint32(12, seq);
    b.setUint16(16, degree);
    out.setRange(headerSize, out.length, data);
    b.setUint32(18, _crc(out));
    return out;
  }

  static int _crc(Uint8List bytes) => getCrc32(
      Uint8List.sublistView(bytes, headerSize),
      getCrc32(Uint8List.sublistView(bytes, 0, 18)));

  String toQrText() => Base45.encode(toBytes());

  /// Parses and validates one scanned code.
  static (Packet?, AcceptResult) parse(String text) {
    final bytes = Base45.decode(text);
    if (bytes == null || bytes.length < 2 || bytes[0] != packetMagic) {
      return (null, AcceptResult.invalid);
    }
    if (bytes[1] != protocolVersion) {
      // Only call it a version clash when it looks like a LightBeam header.
      return (null,
          bytes.length >= 18 ? AcceptResult.incompatibleVersion : AcceptResult.invalid);
    }
    if (bytes.length < headerSize) return (null, AcceptResult.corrupt);
    final b = ByteData.sublistView(bytes);
    final k = b.getUint32(6);
    final blockSize = b.getUint16(10);
    final seq = b.getUint32(12);
    final degree = b.getUint16(16);
    final sane = blockSize > 0 &&
        blockSize <= maxBlockSize &&
        k > 0 &&
        k * blockSize <= maxTransferBytes + blockSize &&
        degree > 0 &&
        degree <= k &&
        (seq >= k || degree == 1) &&
        bytes.length == headerSize + blockSize &&
        b.getUint32(18) == _crc(bytes);
    if (!sane) return (null, AcceptResult.corrupt);
    return (
      Packet(b.getUint32(2), k, blockSize, seq, degree,
          Uint8List.sublistView(bytes, headerSize)),
      AcceptResult.newPacket
    );
  }

  static Packet? fromQrText(String text) => parse(text).$1;
}

/// A file as it travels: name + checksum + (maybe compressed) contents.
///
///   "LBF1" | flags u8 (bit0 = zlib) | nameLen u16 | name utf8
///   | sha256(original) 32 | originalSize u32 | payloadSize u32 | payload
class TransferFile {
  final String name;
  final Uint8List bytes;
  TransferFile(String name, this.bytes) : name = safeFileName(name);

  static const _magic = [0x4C, 0x42, 0x46, 0x31];

  /// Strips anything that could escape the save folder or upset a file
  /// system: path parts, control characters and reserved symbols.
  static String safeFileName(String raw) {
    var name = raw.split(RegExp(r'[/\\]')).last;
    name = name.replaceAll(RegExp(r'[\x00-\x1F\x7F<>:"|?*]'), '_').trim();
    while (name.startsWith('.')) {
      name = name.substring(1);
    }
    if (name.length > 120) {
      final dot = name.lastIndexOf('.');
      final ext = dot > 0 && name.length - dot <= 12 ? name.substring(dot) : '';
      name = name.substring(0, 120 - ext.length) + ext;
    }
    return name.isEmpty ? 'received.bin' : name;
  }

  Uint8List pack() {
    final compressed =
        Uint8List.fromList(const ZLibEncoder().encode(bytes, level: 9));
    final useZlib = compressed.length < bytes.length * 0.97;
    final payload = useZlib ? compressed : bytes;
    final nameBytes = utf8.encode(name);
    final b = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(useZlib ? 1 : 0)
      ..add(_u16(nameBytes.length))
      ..add(nameBytes)
      ..add(sha256.convert(bytes).bytes)
      ..add(_u32(bytes.length))
      ..add(_u32(payload.length))
      ..add(payload);
    return b.toBytes();
  }

  /// Throws [FormatException] when the data is corrupt or the checksum fails.
  static TransferFile unpack(Uint8List data) {
    try {
      return _unpack(data);
    } on FormatException {
      rethrow;
    } catch (e) {
      // Truncated fields, bad UTF-8, broken zlib stream...
      throw FormatException('Damaged file container ($e)');
    }
  }

  static TransferFile _unpack(Uint8List data) {
    if (data.length < 47) throw const FormatException('Too short');
    final b = ByteData.sublistView(data);
    for (var i = 0; i < 4; i++) {
      if (data[i] != _magic[i]) {
        throw const FormatException('Not a LightBeam file');
      }
    }
    final flags = data[4];
    final nameLen = b.getUint16(5);
    var o = 7;
    final name = utf8.decode(data.sublist(o, o + nameLen));
    o += nameLen;
    final hash = data.sublist(o, o + 32);
    o += 32;
    final originalSize = b.getUint32(o);
    final payloadSize = b.getUint32(o + 4);
    o += 8;
    if (o + payloadSize > data.length || originalSize > maxTransferBytes * 4) {
      throw const FormatException('Size fields out of range');
    }
    final payload = data.sublist(o, o + payloadSize);
    final bytes = flags & 1 == 1
        ? Uint8List.fromList(const ZLibDecoder().decodeBytes(payload))
        : payload;
    if (bytes.length != originalSize) {
      throw const FormatException('Size mismatch');
    }
    final actual = sha256.convert(bytes).bytes;
    for (var i = 0; i < 32; i++) {
      if (actual[i] != hash[i]) {
        throw const FormatException('Checksum mismatch');
      }
    }
    return TransferFile(name, bytes);
  }

  static List<int> _u16(int v) => [v >> 8 & 0xFF, v & 0xFF];
  static List<int> _u32(int v) =>
      [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
}

class FileTooLargeException implements Exception {
  final int size;
  FileTooLargeException(this.size);
  @override
  String toString() => 'File is too large to beam '
      '(${size ~/ (1024 * 1024)} MB after packing, limit '
      '${maxTransferBytes ~/ (1024 * 1024)} MB)';
}

/// Produces an endless stream of fountain-coded packets for one file.
class FountainEncoder {
  final int fileId;
  final int blockSize;
  final int k;
  final int packedSize;
  final List<Uint8List> _blocks;
  final RobustSoliton _soliton;
  int _seq = 0;

  FountainEncoder._(this.fileId, this.blockSize, this.k, this.packedSize,
      this._blocks, this._soliton);

  factory FountainEncoder(TransferFile file,
      {int blockSize = 700, int? fileId}) {
    if (blockSize <= 0 || blockSize > maxBlockSize) {
      throw ArgumentError.value(blockSize, 'blockSize');
    }
    final packed = file.pack();
    if (packed.length > maxTransferBytes) {
      throw FileTooLargeException(packed.length);
    }
    final k = math.max(1, (packed.length + blockSize - 1) ~/ blockSize);
    final blocks = List<Uint8List>.generate(k, (i) {
      final block = Uint8List(blockSize);
      final start = i * blockSize;
      block.setRange(
          0, math.min(blockSize, packed.length - start), packed, start);
      return block;
    });
    return FountainEncoder._(
      fileId ?? math.Random.secure().nextInt(0xFFFFFFFF),
      blockSize,
      k,
      packed.length,
      blocks,
      RobustSoliton(k),
    );
  }

  int get sequence => _seq;

  Packet next() {
    final seq = _seq;
    _seq = (_seq + 1) & 0xFFFFFFFF;
    final int degree;
    if (seq < k) {
      degree = 1; // systematic pass: the plain blocks
    } else if (k <= denseLimit) {
      // Dense mode: each packet mixes half the file. Almost every packet is
      // then useful whatever the receiver already holds, and the Gaussian
      // decoder needs only ~K + 1% packets even with 30% frame loss.
      degree = (k + 1) ~/ 2;
    } else {
      // Large files: sparse robust-soliton packets keep peeling cheap.
      degree = math.min(_soliton.sample(), 0xFFFF);
    }
    final data = Uint8List(blockSize);
    for (final i in blockIndices(fileId, k, seq, degree)) {
      xorInto(data, _blocks[i]);
    }
    return Packet(fileId, k, blockSize, seq, degree, data);
  }
}

/// Collects packets from the camera and rebuilds the file.
class Receiver {
  int? fileId;
  FountainDecoder? decoder;
  int totalScans = 0;
  int validScans = 0;
  int corruptScans = 0;
  int otherScans = 0;
  bool versionClash = false;
  DateTime? firstPacketAt;
  DateTime? lastNewPacketAt;
  int _otherStreak = 0;

  int get k => decoder?.k ?? 0;
  int get blockSize => decoder?.blockSize ?? 0;
  bool get isComplete => decoder?.isComplete ?? false;
  /// Share of the file's information received. Dense packets solve blocks
  /// only at the end, so independent pending equations count as progress.
  double get progress {
    final d = decoder;
    if (d == null) return 0;
    if (d.isComplete) return 1;
    return math.min(0.99, (d.solved + d.pendingEquations) / d.k);
  }

  AcceptResult accept(String text) {
    totalScans++;
    final (p, status) = Packet.parse(text);
    if (p == null) {
      if (status == AcceptResult.corrupt) corruptScans++;
      if (status == AcceptResult.incompatibleVersion) versionClash = true;
      return status;
    }
    validScans++;
    if (fileId != null && p.fileId != fileId) {
      // The sender restarted with new settings or a new file: follow it once
      // it is clearly the only thing on screen.
      otherScans++;
      if (isComplete || ++_otherStreak < 8) return AcceptResult.otherFile;
      fileId = null;
    }
    _otherStreak = 0;
    if (fileId == null) {
      fileId = p.fileId;
      decoder = FountainDecoder(p.k, p.blockSize);
      firstPacketAt = DateTime.now();
    } else if (p.k != decoder!.k || p.blockSize != decoder!.blockSize) {
      // Same id, different shape: cannot be ours.
      corruptScans++;
      return AcceptResult.corrupt;
    }
    final indices = blockIndices(p.fileId, p.k, p.seq, p.degree);
    final isNew = decoder!.add(p.seq, indices, p.data);
    if (isNew) lastNewPacketAt = DateTime.now();
    return isNew ? AcceptResult.newPacket : AcceptResult.duplicate;
  }

  TransferFile result() => TransferFile.unpack(decoder!.assemble());
}
