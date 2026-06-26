import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_drawing_board/flutter_drawing_board.dart';
import 'package:flutter_drawing_board/paint_contents.dart';
import 'package:flutter_drawing_board/path_steps.dart';
import 'package:image/image.dart' as img;
import 'matting_bean.dart';
import 'matting_contour.dart';

extension MattingDraw on DrawingController {

  /// 将图片转为画笔，添加
  void addImageOcrResult(MattingResult result, double boardScale){
    // 提取 editImage 中有色区域的轮廓路径（与 refreshContourData 一致）
    final List<Path> paths = MattingContour.extractFilteredContours(result.data);
    if(paths.isEmpty) return;
    List<PaintContent> contents = [];
    // 按面积降序排列，大轮廓在前（外层），小轮廓在后（可能是孔洞）
    final List<(Path, Rect)> pathInfos =
    paths.map((p) => (p, p.getBounds())).toList()
      ..sort((a, b) {
        final double areaA = a.$2.width * a.$2.height;
        final double areaB = b.$2.width * b.$2.height;
        return areaB.compareTo(areaA);
      });

    for (final (Path path, Rect bounds) in pathInfos) {
      // 坐标变换：editImage 坐标 → 原图坐标 → 画板坐标
      // Matrix = Scale(boardScale) × Translate(x, y)
      // 对点 (cx, cy): boardScale * (cx + x, cy + y)
      final Matrix4 matrix = Matrix4.identity()
        ..scale(boardScale)
        ..translate(
          result.x.toDouble(),
          result.y.toDouble(),
        );
      final Path transformedPath = path.transform(matrix.storage);

      // 判断是否为孔洞：中心点被任一更大轮廓的路径包含
      final bool isHole = pathInfos.any((other) {
        final Rect ob = other.$2;
        final bool obContainsBounds =
            bounds.left >= ob.left &&
                bounds.top >= ob.top &&
                bounds.right <= ob.right &&
                bounds.bottom <= ob.bottom;
        return ob.width * ob.height > bounds.width * bounds.height &&
            obContainsBounds &&
            other.$1.contains(bounds.center);
      });

      final Paint paint = isHole
          ? (Paint()
        ..blendMode = BlendMode.clear)
          : (Paint()
        ..color = Colors.red.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill);


      contents.add(
        SimpleLine.data(
          paint: paint,
          arrowDraw: false,
          arrowSize: Size.zero,
          path: DrawPath(path: transformedPath),
        ),
      );
    }
    addContents(contents);
  }



  /// 获取画笔图层区域对应的原图像素数据，并去除四周透明区域后，返回相对位置和大小，去除四周后的图片
  Future<MattingResult?> getPaintAreaImageContour(Uint8List image) async {
    final history = getHistory;
    if (history.isEmpty) return null;

    // 解码原图
    final img.Image? originalImage = img.decodeImage(image);
    if (originalImage == null) return null;

    final int w = originalImage.width;
    final int h = originalImage.height;

    // 第一步：构建遮罩（0 = 透明/背景，255 = 不透明/前景）
    final Uint8List mask = await _buildMask(history, w, h);
    if (mask.isEmpty) return null;

    // 第二步：查找非透明区域的包围盒
    int minX = w, minY = h, maxX = 0, maxY = 0;
    bool hasForeground = false;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (mask[y * w + x] > 0) {
          hasForeground = true;
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }

    if (!hasForeground) return null;

    final int cropW = maxX - minX + 1;
    final int cropH = maxY - minY + 1;

    // 第三步：裁剪并生成结果图像
    final img.Image croppedImage = img.Image(
      width: cropW,
      height: cropH,
      numChannels: 4,
    );

    for (int y = 0; y < cropH; y++) {
      for (int x = 0; x < cropW; x++) {
        final int srcX = minX + x;
        final int srcY = minY + y;
        final img.Pixel pixel = originalImage.getPixel(srcX, srcY);
        final int maskAlpha = mask[srcY * w + srcX];
        croppedImage.setPixelRgba(
          x,
          y,
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
          maskAlpha,
        );
      }
    }

    return MattingResult(
      x: minX,
      y: minY,
      width: cropW,
      height: cropH,
      data: Uint8List.fromList(img.encodePng(croppedImage)),
    );
  }

  /// 构建画笔图层的遮罩数据
  Future<Uint8List> _buildMask(List<PaintContent> history, int w, int h) async {
    final Uint8List mask = Uint8List(w * h);

    final Size boardSize =
        drawConfig.value.size ?? Size(w.toDouble(), h.toDouble());
    final double scaleX = w / boardSize.width;
    final double scaleY = h / boardSize.height;

    // 渲染 SimpleLine 笔触为前景
    final ui.PictureRecorder lineRecorder = ui.PictureRecorder();
    final Canvas lineCanvas = Canvas(lineRecorder);
    lineCanvas.scale(scaleX, scaleY);

    for (final PaintContent content in history) {
      if (content is SimpleLine) {
        content.draw(lineCanvas, boardSize, true);
      }
    }

    final ui.Picture linePicture = lineRecorder.endRecording();
    final ui.Image lineImage = await linePicture.toImage(w, h);
    final ByteData? lineBytes = await lineImage.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );

    if (lineBytes != null) {
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final int offset = (y * w + x) * 4;
          final int alpha = lineBytes.getUint8(offset + 3);
          if (alpha > 0) {
            mask[y * w + x] = 255;
          }
        }
      }
    }

    // 渲染 Eraser 笔触为背景（清除）
    for (final PaintContent content in history) {
      if (content is Eraser) {
        final ui.PictureRecorder eraserRecorder = ui.PictureRecorder();
        final Canvas eraserCanvas = Canvas(eraserRecorder);
        eraserCanvas.scale(scaleX, scaleY);

        final Paint eraserDetectPaint = Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = content.paint.strokeWidth;

        eraserCanvas.drawPath(content.drawPath.path, eraserDetectPaint);

        final ui.Picture eraserPicture = eraserRecorder.endRecording();
        final ui.Image eraserImage = await eraserPicture.toImage(w, h);
        final ByteData? eraserBytes = await eraserImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );

        if (eraserBytes != null) {
          for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
              final int offset = (y * w + x) * 4;
              final int alpha = eraserBytes.getUint8(offset + 3);
              if (alpha > 0) {
                mask[y * w + x] = 0;
              }
            }
          }
        }
      }
    }

    return mask;
  }

  /// 获取画笔图层区域对应的原图像素数据
  Future<Uint8List?> getPaintAreaImage(Uint8List image) async {
    final history = getHistory;
    if (history.isEmpty) return null;

    final img.Image? originalImage = img.decodeImage(image);
    if (originalImage == null) return null;

    final int w = originalImage.width;
    final int h = originalImage.height;

    final Uint8List mask = await _buildMask(history, w, h);

    final img.Image outputImage = img.Image(
      width: w,
      height: h,
      numChannels: 4,
    );

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final img.Pixel pixel = originalImage.getPixel(x, y);
        final int maskAlpha = mask[y * w + x];
        outputImage.setPixelRgba(
          x,
          y,
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
          maskAlpha,
        );
      }
    }

    return Uint8List.fromList(img.encodePng(outputImage));
  }
}
