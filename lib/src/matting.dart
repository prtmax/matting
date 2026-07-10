import 'dart:io';
import 'dart:math' as math;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'matting_bean.dart';

/// Parameters for building model input tensor in a background isolate.
class _ModelInputParams {
  final int width;
  final int height;
  final Uint8List rgbData;

  const _ModelInputParams({
    required this.width,
    required this.height,
    required this.rgbData,
  });
}

/// Parameters for resizing logits to mask in a background isolate.
class _ResizeLogitsParams {
  final Float32List logits;
  final int sourceWidth;
  final int sourceHeight;
  final int targetWidth;
  final int targetHeight;

  const _ResizeLogitsParams({
    required this.logits,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.targetWidth,
    required this.targetHeight,
  });
}

/// Builds the ImageNet-normalized 512x512 RGB tensor in a background isolate.
Float32List _buildModelInputInIsolate(_ModelInputParams params) {
  const int modelInputSize = 512;
  const List<double> imageNetMean = <double>[0.485, 0.456, 0.406];
  const List<double> imageNetStd = <double>[0.229, 0.224, 0.225];

  final Float32List tensor = Float32List(3 * modelInputSize * modelInputSize);
  final double scaleX = params.width / modelInputSize;
  final double scaleY = params.height / modelInputSize;
  final int planeSize = modelInputSize * modelInputSize;
  final Uint8List rgbData = params.rgbData;

  double bilinear(
      double tl,
      double tr,
      double bl,
      double br,
      double wx,
      double wy,
      ) {
    final double top = (tl * (1.0 - wx)) + (tr * wx);
    final double bottom = (bl * (1.0 - wx)) + (br * wx);
    return (top * (1.0 - wy)) + (bottom * wy);
  }

  int rgbIdx(int px, int py) => (py * params.width + px) * 3;

  for (int y = 0; y < modelInputSize; y++) {
    final double sourceY = ((y + 0.5) * scaleY) - 0.5;
    final int y0 = sourceY.floor().clamp(0, params.height - 1);
    final int y1 = math.min(y0 + 1, params.height - 1);
    final double wy = sourceY - y0;

    for (int x = 0; x < modelInputSize; x++) {
      final double sourceX = ((x + 0.5) * scaleX) - 0.5;
      final int x0 = sourceX.floor().clamp(0, params.width - 1);
      final int x1 = math.min(x0 + 1, params.width - 1);
      final double wx = sourceX - x0;

      final double red = bilinear(
        rgbData[rgbIdx(x0, y0)].toDouble(),
        rgbData[rgbIdx(x1, y0)].toDouble(),
        rgbData[rgbIdx(x0, y1)].toDouble(),
        rgbData[rgbIdx(x1, y1)].toDouble(),
        wx,
        wy,
      );
      final double green = bilinear(
        rgbData[rgbIdx(x0, y0) + 1].toDouble(),
        rgbData[rgbIdx(x1, y0) + 1].toDouble(),
        rgbData[rgbIdx(x0, y1) + 1].toDouble(),
        rgbData[rgbIdx(x1, y1) + 1].toDouble(),
        wx,
        wy,
      );
      final double blue = bilinear(
        rgbData[rgbIdx(x0, y0) + 2].toDouble(),
        rgbData[rgbIdx(x1, y0) + 2].toDouble(),
        rgbData[rgbIdx(x0, y1) + 2].toDouble(),
        rgbData[rgbIdx(x1, y1) + 2].toDouble(),
        wx,
        wy,
      );

      final int index = y * modelInputSize + x;
      tensor[index] = ((red / 255.0) - imageNetMean[0]) / imageNetStd[0];
      tensor[planeSize + index] =
          ((green / 255.0) - imageNetMean[1]) / imageNetStd[1];
      tensor[(planeSize * 2) + index] =
          ((blue / 255.0) - imageNetMean[2]) / imageNetStd[2];
    }
  }

  return tensor;
}

/// Resizes the low-resolution logits back to the original image size in a
/// background isolate.
Uint8List? _resizeLogitsToMaskInIsolate(_ResizeLogitsParams params) {
  final int expectedPixelCount = params.sourceWidth * params.sourceHeight;
  if (params.logits.length < expectedPixelCount) {
    return null;
  }

  double bilinear(
      double tl,
      double tr,
      double bl,
      double br,
      double wx,
      double wy,
      ) {
    final double top = (tl * (1.0 - wx)) + (tr * wx);
    final double bottom = (bl * (1.0 - wx)) + (br * wx);
    return (top * (1.0 - wy)) + (bottom * wy);
  }

  double sigmoid(double value) {
    if (value >= 0) {
      final double z = math.exp(-value);
      return 1.0 / (1.0 + z);
    }
    final double z = math.exp(value);
    return z / (1.0 + z);
  }

  final int offset = params.logits.length - expectedPixelCount;
  final Uint8List output = Uint8List(params.targetWidth * params.targetHeight);
  final double scaleX = params.sourceWidth / params.targetWidth;
  final double scaleY = params.sourceHeight / params.targetHeight;

  for (int y = 0; y < params.targetHeight; y++) {
    final double sourceY = ((y + 0.5) * scaleY) - 0.5;
    final int y0 = sourceY.floor().clamp(0, params.sourceHeight - 1);
    final int y1 = math.min(y0 + 1, params.sourceHeight - 1);
    final double wy = sourceY - y0;

    for (int x = 0; x < params.targetWidth; x++) {
      final double sourceX = ((x + 0.5) * scaleX) - 0.5;
      final int x0 = sourceX.floor().clamp(0, params.sourceWidth - 1);
      final int x1 = math.min(x0 + 1, params.sourceWidth - 1);
      final double wx = sourceX - x0;

      final double logit = bilinear(
        params.logits[offset + (y0 * params.sourceWidth) + x0],
        params.logits[offset + (y0 * params.sourceWidth) + x1],
        params.logits[offset + (y1 * params.sourceWidth) + x0],
        params.logits[offset + (y1 * params.sourceWidth) + x1],
        wx,
        wy,
      );
      output[(y * params.targetWidth) + x] = (sigmoid(logit) * 255.0)
          .round()
          .clamp(0, 255);
    }
  }

  return output;
}

/// 图片识别
class Matting {
  static const int _modelInputSize = 512;
  static const List<double> _imageNetMean = <double>[0.485, 0.456, 0.406];
  static const List<double> _imageNetStd = <double>[0.229, 0.224, 0.225];

  late OrtSession session;

  /// 解析中
  bool _processing = false;

  Future<bool> _loadSession(File modelFile) async {
    final OrtSessionOptions options = OrtSessionOptions();
    options.setSessionGraphOptimizationLevel(
      GraphOptimizationLevel.ortEnableAll,
    );
    options.setIntraOpNumThreads(math.max(1, Platform.numberOfProcessors ~/ 2));
    options.appendCPUProvider(CPUFlags.useArena);

    try {
      session = OrtSession.fromFile(modelFile, options);
      return true;
    } catch (e) {
      print('创建 ONNX Session 失败：$e');
      return false;
    } finally {
      options.release();
    }
  }

  /// 抠图
  Future<MattingMask?> runSmartCut({
    required File modelFile,
    required Uint8List imageBytes,
  }) async {
    if (_processing) return null;

    OrtEnv.instance.init();

    final bool sessionLoaded = await _loadSession(modelFile);
    if (!sessionLoaded) {
      print('加载模型失败');
      return null;
    }

    final img.Image? decodedImage = img.decodeImage(imageBytes);
    if (decodedImage == null) {
      print('无法解码当前图片');
      return null;
    }

    print(
      '图片尺寸: ${decodedImage.width}x${decodedImage.height}, '
          '通道数: ${decodedImage.numChannels}, '
          '平台: ${Platform.operatingSystem}',
    );

    _processing = true;

    // Extract flat RGB data from the decoded image so it can be sent to an
    // isolate without the full image-package object graph.
    final Uint8List rgbData = Uint8List(
      decodedImage.width * decodedImage.height * 3,
    );
    for (int y = 0; y < decodedImage.height; y++) {
      for (int x = 0; x < decodedImage.width; x++) {
        final img.Pixel p = decodedImage.getPixel(x, y);
        final int idx = (y * decodedImage.width + x) * 3;
        rgbData[idx] = p.r.toInt();
        rgbData[idx + 1] = p.g.toInt();
        rgbData[idx + 2] = p.b.toInt();
      }
    }

    // Build the model-input tensor on a background isolate to keep the UI
    // responsive during the bilinear-resize pass.
    final Float32List inputTensor;
    try {
      inputTensor = await Isolate.run(() {
        return _buildModelInputInIsolate(
          _ModelInputParams(
            width: decodedImage.width,
            height: decodedImage.height,
            rgbData: rgbData,
          ),
        );
      });
    } catch (e) {
      print('构建模型输入失败：$e');
      _processing = false;
      dispose();
      return null;
    }

    final OrtValueTensor inputValue = OrtValueTensor.createTensorWithDataList(
      <Float32List>[inputTensor],
      <int>[1, 3, _modelInputSize, _modelInputSize],
    );
    final OrtRunOptions runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;

    final String inputName = _resolveInputName(session);
    final String outputName = _resolveOutputName(session);
    print(
      'ONNX 推理: input=$inputName (shape=[1,3,${_modelInputSize},${_modelInputSize}]), '
          'output=$outputName, '
          'inputs列表=${session.inputNames}, outputs列表=${session.outputNames}',
    );

    try {
      outputs = await session.runAsync(
        runOptions,
        <String, OrtValue>{inputName: inputValue},
        <String>[outputName],
      );

      if (outputs == null ||
          outputs.isEmpty ||
          outputs.first is! OrtValueTensor) {
        print('模型推理失败：未返回有效张量');
        return null;
      }

      final logits = _flattenTensor((outputs.first! as OrtValueTensor).value);
      if (logits == null) {
        print('张量扁平化失败：无法识别的数据结构');
        return null;
      }
      final int expectedCount = _modelInputSize * _modelInputSize;
      // 诊断：采样 logits 值，判断模型是否输出有效数据
      double logitMin = double.infinity, logitMax = double.negativeInfinity;
      double logitSum = 0;
      int nanCount = 0, infCount = 0, zeroCount = 0;
      for (int i = 0; i < logits.length; i++) {
        final double v = logits[i];
        if (v.isNaN) {
          nanCount++;
          continue;
        }
        if (v.isInfinite) {
          infCount++;
          continue;
        }
        if (v == 0.0) zeroCount++;
        if (v < logitMin) logitMin = v;
        if (v > logitMax) logitMax = v;
        logitSum += v;
      }
      final int validCount = logits.length - nanCount - infCount;
      print(
        '模型输出: logits 总数=${logits.length}, '
            '期望最少=${expectedCount}(512×512), '
            '差值=${logits.length - expectedCount}',
      );
      print(
        'logits 采样: min=$logitMin, max=$logitMax, '
            'avg=${validCount > 0 ? (logitSum / validCount).toStringAsFixed(4) : "N/A"}, '
            'NaN=$nanCount, Inf=$infCount, zero=$zeroCount',
      );

      // Resize logits back to the original image size on a background isolate.
      final Uint8List? bytes;
      try {
        bytes = await Isolate.run(() {
          return _resizeLogitsToMaskInIsolate(
            _ResizeLogitsParams(
              logits: logits,
              sourceWidth: _modelInputSize,
              sourceHeight: _modelInputSize,
              targetWidth: decodedImage.width,
              targetHeight: decodedImage.height,
            ),
          );
        });
      } catch (e) {
        print('mask 缩放失败（Isolate）：$e');
        return null;
      }
      if (bytes == null) {
        print('模型输出尺寸异常');
        return null;
      }

      return MattingMask(
        width: decodedImage.width,
        height: decodedImage.height,
        bytes: bytes,
      );
    } finally {
      _processing = false;

      inputValue.release();
      runOptions.release();
      outputs?.forEach((OrtValue? output) => output?.release());

      dispose();
    }
  }

  String _resolveInputName(OrtSession session) {
    if (session.inputNames.contains('input_image')) {
      return 'input_image';
    }
    return session.inputNames.first;
  }

  String _resolveOutputName(OrtSession session) {
    if (session.outputNames.contains('output_image')) {
      return 'output_image';
    }
    return session.outputNames.first;
  }

  Float32List? _flattenTensor(dynamic value) {
    final List<double> flattened = <double>[];
    bool hasError = false;

    void walk(dynamic node) {
      if (hasError) return;
      if (node is num) {
        flattened.add(node.toDouble());
        return;
      }
      if (node is List) {
        for (final dynamic child in node) {
          walk(child);
        }
        return;
      }
      print('模型返回了无法识别的张量结构：${node.runtimeType}');
      hasError = true;
    }

    walk(value);
    if (hasError) return null;
    return Float32List.fromList(flattened);
  }

  void dispose() {
    session.release();
    OrtEnv.instance.release();
  }

  /// 获取抠图结果：根据 mask 裁剪非透明区域，返回相对位置、大小及裁剪后的图片
  static Future<MattingResult?> mergeImageContour(
      Uint8List imageBytes,
      MattingMask mask,
      ) async {
    final img.Image? decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      print('无法解码原图');
      return null;
    }

    // 确保是 RGBA 格式
    img.Image rgbaImage = decoded;
    if (rgbaImage.numChannels != 4) {
      final img.Image converted = img.Image(
        width: decoded.width,
        height: decoded.height,
        numChannels: 4,
      );
      for (int y = 0; y < decoded.height; y++) {
        for (int x = 0; x < decoded.width; x++) {
          final img.Pixel p = decoded.getPixel(x, y);
          converted.setPixelRgba(
            x,
            y,
            p.r.toInt(),
            p.g.toInt(),
            p.b.toInt(),
            p.a.toInt(),
          );
        }
      }
      rgbaImage = converted;
    }

    // 将 mask 的 alpha 应用到原图上
    for (int y = 0; y < mask.height; y++) {
      for (int x = 0; x < mask.width; x++) {
        final int alpha = mask.bytes[mask.indexOf(x, y)];
        final img.Pixel pixel = rgbaImage.getPixel(x, y);
        rgbaImage.setPixelRgba(
          x,
          y,
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
          alpha,
        );
      }
    }

    // 查找非透明区域的包围盒
    int minX = mask.width;
    int minY = mask.height;
    int maxX = -1;
    int maxY = -1;

    for (int y = 0; y < mask.height; y++) {
      for (int x = 0; x < mask.width; x++) {
        if (mask.bytes[mask.indexOf(x, y)] > 0) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }

    // 没有找到任何非透明像素
    if (maxX < 0 || maxY < 0) {
      print('mask 中没有非透明区域');
      return null;
    }

    final int cropWidth = maxX - minX + 1;
    final int cropHeight = maxY - minY + 1;

    // 裁剪图片
    final img.Image cropped = img.copyCrop(
      rgbaImage,
      x: minX,
      y: minY,
      width: cropWidth,
      height: cropHeight,
    );

    return MattingResult(
      x: minX,
      y: minY,
      width: cropWidth,
      height: cropHeight,
      data: Uint8List.fromList(img.encodePng(cropped)),
    );
  }

  /// 获取抠图结果
  static Future<Uint8List?> mergeImageAndMask(
      Uint8List imageBytes,
      MattingMask mask,
      ) async {
    final img.Image? decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      print('无法解码原图');
      return null;
    }

    img.Image rgbaImage = decoded;
    if (rgbaImage.numChannels != 4) {
      final img.Image converted = img.Image(
        width: decoded.width,
        height: decoded.height,
        numChannels: 4,
      );
      for (int y = 0; y < decoded.height; y++) {
        for (int x = 0; x < decoded.width; x++) {
          final img.Pixel p = decoded.getPixel(x, y);
          converted.setPixelRgba(
            x,
            y,
            p.r.toInt(),
            p.g.toInt(),
            p.b.toInt(),
            p.a.toInt(),
          );
        }
      }
      rgbaImage = converted;
    }

    print(
      '原图尺寸: ${rgbaImage.width}x${rgbaImage.height}, mask尺寸: ${mask.width}x${mask.height}',
    );

    for (int y = 0; y < mask.height; y++) {
      for (int x = 0; x < mask.width; x++) {
        final int alpha = mask.bytes[mask.indexOf(x, y)];
        final img.Pixel pixel = rgbaImage.getPixel(x, y);
        rgbaImage.setPixelRgba(
          x,
          y,
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
          alpha,
        );
      }
    }

    return Uint8List.fromList(img.encodePng(rgbaImage));
  }
}
