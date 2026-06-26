import 'dart:typed_data';


class MattingMask {
  const MattingMask({
    required this.width,
    required this.height,
    required this.bytes,
  });

  final int width;
  final int height;
  final Uint8List bytes;

  int get length => bytes.length;

  MattingMask copyWithBytes(Uint8List nextBytes) {
    return MattingMask(width: width, height: height, bytes: nextBytes);
  }

  Float32List toFloat32() {
    final Float32List buffer = Float32List(bytes.length);
    for (int index = 0; index < bytes.length; index++) {
      buffer[index] = bytes[index] / 255.0;
    }
    return buffer;
  }

  int indexOf(int x, int y) => y * width + x;
}


class MattingResult {
  int x;
  int y;
  int width;
  int height;

  Uint8List data;

  MattingResult({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.data,
  });
}
