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
  void addImageMattingResult(MattingResult result, double boardScale){
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
    // 只取未撤销的活跃历史记录（_history 保留所有项，currentIndex 标记有效范围）
    final List<PaintContent> history = getHistory.sublist(0, currentIndex);
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

  /// 构建画笔图层的遮罩数据，按 history 时序逐操作处理
  Future<Uint8List> _buildMask(List<PaintContent> history, int w, int h) async {
    final Uint8List mask = Uint8List(w * h);

    final Size boardSize =
        drawConfig.value.size ?? Size(w.toDouble(), h.toDouble());
    final double scaleX = w / boardSize.width;
    final double scaleY = h / boardSize.height;

    // 按历史顺序逐个处理，确保后操作覆盖前操作
    for (final PaintContent content in history) {
      if (content is SimpleLine) {
        // 检测是否为孔洞路径（BlendMode.clear），
        // 孔洞在空白画布上绘制时 clear 模式不会产生可见像素，
        // 需要用实色 paint 检测覆盖区域，再清除 mask
        final bool isClear = content.paint.blendMode == BlendMode.clear;

        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final Canvas canvas = Canvas(recorder);
        canvas.scale(scaleX, scaleY);

        if (isClear) {
          // 用实色 paint 绘制路径以检测覆盖的像素
          final Paint detectPaint = Paint()
            ..color = Colors.black
            ..style = content.paint.style
            ..strokeCap = content.paint.strokeCap
            ..strokeJoin = content.paint.strokeJoin
            ..strokeWidth = content.paint.strokeWidth;
          canvas.drawPath(content.path.path, detectPaint);
        } else {
          content.draw(canvas, boardSize, true);
        }

        final ui.Picture picture = recorder.endRecording();
        final ui.Image image = await picture.toImage(w, h);
        final ByteData? bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );

        if (bytes != null) {
          for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
              final int offset = (y * w + x) * 4;
              if (bytes.getUint8(offset + 3) > 0) {
                // 孔洞路径：清除 mask；普通路径：设为前景
                mask[y * w + x] = isClear ? 0 : 255;
              }
            }
          }
        }
      } else if (content is Eraser) {
        // Eraser → 设为背景（清除）
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final Canvas canvas = Canvas(recorder);
        canvas.scale(scaleX, scaleY);

        final Paint eraserDetectPaint = Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = content.paint.strokeWidth;

        canvas.drawPath(content.drawPath.path, eraserDetectPaint);

        final ui.Picture picture = recorder.endRecording();
        final ui.Image image = await picture.toImage(w, h);
        final ByteData? bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );

        if (bytes != null) {
          for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
              final int offset = (y * w + x) * 4;
              if (bytes.getUint8(offset + 3) > 0) {
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
    // 只取未撤销的活跃历史记录（_history 保留所有项，currentIndex 标记有效范围）
    final List<PaintContent> history = getHistory.sublist(0, currentIndex);
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
