import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Messages carried by the sound channel (see sound.dart for the modem).
///
/// Talk-back: the receiver, which can't show anything to the sender's
/// camera-less screen, chirps its progress so the sender can adapt its
/// speed and stop when the file is done.
///
/// Short messages: small texts sent by sound alone, split into chunks that
/// the sender loops until the listener has them all.
sealed class SoundMessage {
  static const _progress = 0x51, _done = 0x52, _text = 0x53;

  const SoundMessage();

  List<int> encode();

  /// Parses a frame payload; null if it isn't a LightBeam sound message.
  static SoundMessage? decode(List<int> b) {
    if (b.isEmpty) return null;
    final d = ByteData.sublistView(Uint8List.fromList(b));
    switch (b[0]) {
      case _progress when b.length == 7:
        return ProgressMessage(d.getUint32(1), b[5], b[6] & 1 != 0);
      case _done when b.length == 5:
        return DoneMessage(d.getUint32(1));
      case _text when b.length >= 5 && b[3] < b[4]:
        return TextChunk(d.getUint16(1), b[3], b[4], b.sublist(5));
    }
    return null;
  }
}

/// Receiver → sender: how far the transfer of [fileId] has got.
class ProgressMessage extends SoundMessage {
  final int fileId;
  final int percent; // 0..100
  final bool struggling; // stalled or seeing many damaged frames
  const ProgressMessage(this.fileId, this.percent, this.struggling);

  @override
  List<int> encode() => (ByteData(7)
        ..setUint8(0, SoundMessage._progress)
        ..setUint32(1, fileId)
        ..setUint8(5, percent.clamp(0, 100))
        ..setUint8(6, struggling ? 1 : 0))
      .buffer
      .asUint8List();
}

/// Receiver → sender: [fileId] arrived and passed its SHA-256 check.
class DoneMessage extends SoundMessage {
  final int fileId;
  const DoneMessage(this.fileId);

  @override
  List<int> encode() => (ByteData(5)
        ..setUint8(0, SoundMessage._done)
        ..setUint32(1, fileId))
      .buffer
      .asUint8List();
}

/// One piece of a short text message.
class TextChunk extends SoundMessage {
  static const maxData = 32;
  final int messageId;
  final int index;
  final int count;
  final List<int> data;
  const TextChunk(this.messageId, this.index, this.count, this.data);

  @override
  List<int> encode() => [
        SoundMessage._text,
        messageId >> 8,
        messageId & 0xFF,
        index,
        count,
        ...data,
      ];
}

/// Longest text that can be sent by sound (UTF-8 bytes). At 12.5 B/s this
/// is about half a minute per loop; anything bigger belongs on the screen.
const maxSoundText = 256;

List<TextChunk> chunkText(String text, {int? messageId}) {
  final bytes = utf8.encode(text);
  if (bytes.isEmpty || bytes.length > maxSoundText) {
    throw ArgumentError(
        'Sound messages must be 1 to $maxSoundText bytes (this is ${bytes.length})');
  }
  final id = messageId ?? math.Random.secure().nextInt(0x10000);
  final count = (bytes.length / TextChunk.maxData).ceil();
  return [
    for (var i = 0; i < count; i++)
      TextChunk(
          id,
          i,
          count,
          bytes.sublist(i * TextChunk.maxData,
              math.min(bytes.length, (i + 1) * TextChunk.maxData))),
  ];
}

/// Collects chunks (in any order, duplicates welcome) into the text.
class TextAssembler {
  int? messageId;
  List<List<int>?> _parts = const [];

  int get received => _parts.where((p) => p != null).length;
  int get total => _parts.length;

  /// Returns the full text once every chunk of a message has arrived.
  String? add(TextChunk c) {
    if (c.messageId != messageId || c.count != _parts.length) {
      // A new message (or the sender restarted): start over.
      messageId = c.messageId;
      _parts = List.filled(c.count, null);
    }
    _parts[c.index] ??= c.data;
    if (_parts.any((p) => p == null)) return null;
    try {
      return utf8.decode([for (final p in _parts) ...p!]);
    } on FormatException {
      _parts = List.filled(c.count, null);
      return null;
    }
  }
}
