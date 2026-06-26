
import 'package:flutter/material.dart';
import 'dart:ui';

/// 棋格盘
class MattingCheckerboard extends CustomPainter {
  final double squareSize; // 每个方格的尺寸
  final Color color1; // 颜色1
  final Color color2; // 颜色2

  MattingCheckerboard({
    this.squareSize = 8.0,
    this.color1 = const Color(0xFFCCCCCC),
    this.color2 = const Color(0xFFFFFFFF),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint1 = Paint()..color = color1;
    final paint2 = Paint()..color = color2;

    for (double y = 0; y < size.height; y += squareSize) {
      for (double x = 0; x < size.width; x += squareSize) {
        final isEven = ((x ~/ squareSize) + (y ~/ squareSize)) % 2 == 0;
        canvas.drawRect(
          Rect.fromLTWH(x, y, squareSize, squareSize),
          isEven ? paint1 : paint2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 描边绘制器 —— 将图像像素坐标的路径缩放到 widget 尺寸后绘制轮廓线。
/// 支持实线、虚线两种线型。
class MattingStroke extends CustomPainter {
  MattingStroke({
    required this.paths,
    required this.imageWidth,
    required this.imageHeight,
    this.color = Colors.blue,
    this.lineWidth = 8.0,
    this.dash = false,
    this.dashGap = 20.0,
    this.dashWidth = 15.0,
    this.displayPadding = 0.0,
    this.fill = false,
  });

  /// 轮廓路径列表
  final List<Path> paths;

  /// 原始图像宽度（像素）
  final int imageWidth;

  /// 原始图像高度（像素）
  final int imageHeight;

  /// 线条颜色
  final Color color;

  /// 线条宽度
  final double lineWidth;

  /// true 为虚线，false 为实线
  final bool dash;

  /// 虚线间距（仅在 [dash] 为 true 时生效）
  final double dashGap;

  /// 虚线每段的宽度（仅在 [dash] 为 true 时生效）
  final double dashWidth;


  /// 显示坐标下的外扩边距：widget 比图像区域多出的单侧 padding，
  /// 用于轮廓坐标超出图像范围时防止裁剪。
  final double displayPadding;

  /// 实心
  final bool fill;

  @override
  void paint(Canvas canvas, Size size) {
    if (paths.isEmpty || imageWidth == 0 || imageHeight == 0) return;

    final double sx = (size.width - 2 * displayPadding) / imageWidth;
    final double sy = (size.height - 2 * displayPadding) / imageHeight;
    final double scale = (sx < sy ? sx : sy);

    final double ox = displayPadding +
        (size.width - 2 * displayPadding - imageWidth * scale) / 2;
    final double oy = displayPadding +
        (size.height - 2 * displayPadding - imageHeight * scale) / 2;

    canvas.save();
    canvas.translate(ox, oy);
    canvas.scale(scale);

    if(fill){
      // 合并所有轮廓路径，使用 evenOdd 填充规则自动镂空内部透明区域
      final Path combined = Path()..fillType = PathFillType.evenOdd;
      for (final Path path in paths) {
        combined.addPath(path, Offset.zero);
      }

      final Path shifted = combined.shift(Offset(-lineWidth, 0));

      final Paint fillPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      canvas.drawPath(shifted, fillPaint);
    } else {

      for (final Path path in paths) {
        final Path drawPath = _resolveDrawPath(path, scale);
        canvas.drawPath(drawPath, _createStrokePaint(lineWidth / scale));
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MattingStroke old) =>
      old.paths != paths ||
          old.imageWidth != imageWidth ||
          old.imageHeight != imageHeight ||
          old.lineWidth != lineWidth ||
          old.color != color ||
          old.dash != dash ||
          old.dashGap != dashGap ||
          old.dashWidth != dashWidth ||
          old.displayPadding != displayPadding ||
          old.fill != fill;

  /// 创建描边画笔
  Paint _createStrokePaint(double strokeWidth) {
    return Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
  }

  /// 根据线型返回实际绘制的路径：实线返回原路径，虚线返回转换后的路径
  Path _resolveDrawPath(Path originalPath, double scale) {
    Path p = originalPath;
    if (dash) {
      p = _convertToDashPath(p, scale);
    }
    return p;
  }

  /// 将普通路径转换为虚线路径
  Path _convertToDashPath(Path originalPath, double scale) {
    final double gap = dashGap / scale;
    final double segWidth = dashWidth / scale;

    final Path dest = Path();
    for (final PathMetric metric in originalPath.computeMetrics()) {
      double distance = 0.0;
      bool draw = true;

      while (distance < metric.length) {
        double length = draw ? segWidth : gap;
        if (distance + length > metric.length) {
          length = metric.length - distance;
        }

        if (draw) {
          dest.addPath(
            metric.extractPath(distance, distance + length),
            Offset.zero,
          );
        }

        distance += length;
        draw = !draw;
      }
    }

    return dest;
  }
}






