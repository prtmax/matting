
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

// ──── 轮廓过滤（优化版）────

/// 带缓存的轮廓元信息，避免重复 getBounds / computeMetrics
class _MattingContourInfo {
  final Path path;
  final Rect bounds;
  final double area;
  final double length;

  _MattingContourInfo(this.path)
      : bounds = path.getBounds(),
        area = (path.getBounds().size.width) * (path.getBounds().size.height),
        length = _calcLength(path);

  static double _calcLength(Path p) {
    double total = 0;
    for (final PathMetric m in p.computeMetrics()) {
      total += m.length;
    }
    return total;
  }
}

class MattingContour{
  // ──── 距离轮廓提取 ────

  /// 从图像字节中提取距离非透明区域 [distance] 像素的轮廓路径。
  /// 掩码预扩 padding 防止贴边膨胀不完整，Chaikin 平滑去锯齿。
  /// 参考 extractFilteredContours 做去重、包含树构建与嵌套过滤。
  /// [distanceRatio] 比例 0--1
  static List<Path> extractDistanceContours(Uint8List imageBytes, {double distanceRatio = 0.02}) {
    final img.Image? image = img.decodeImage(imageBytes);
    if (image == null) return <Path>[];

    final int distance = (max(image.width, image.height)*distanceRatio).toInt();

    final int w = image.width, h = image.height, pad = distance;
    final int pw = w + 2 * pad, ph = h + 2 * pad;

    final Uint8List mask = Uint8List(pw * ph);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        mask[(y + pad) * pw + (x + pad)] = image.getPixel(x, y).a > 128 ? 1 : 0;
      }
    }

    final Uint8List dilated = _dilateMask(mask, pw, ph, distance);
    final Matrix4 shift = Matrix4.translationValues(
        -pad.toDouble(), -pad.toDouble(), 0.0);
    final List<Path> paths = _extractContoursFromMask(dilated, pw, ph)
        .map((p) => _smoothContour(p.transform(shift.storage)))
        .toList();

    if (paths.isEmpty) return paths;

    // 裁剪 dilated mask 到原始图像坐标空间，供 _isHole 使用
    final Uint8List dilatedCrop = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        dilatedCrop[y * w + x] = dilated[(y + pad) * pw + (x + pad)];
      }
    }

    // 预计算所有轮廓元信息
    final List<_MattingContourInfo> infos = paths.map((p) => _MattingContourInfo(p)).toList();

    // Step 1: 去重
    final Set<int> dedupSet = _deduplicateInfos(infos);
    if (dedupSet.length <= 1) {
      return <Path>[for (final int i in dedupSet) infos[i].path];
    }

    // 重新编号
    final List<int> remap = dedupSet.toList();
    final int n = remap.length;
    final List<_MattingContourInfo> ki = remap.map((i) => infos[i]).toList();

    // Step 2: 按面积降序，O(n²) 构建包含树
    final List<int> order = List<int>.generate(n, (i) => i);
    order.sort((a, b) => ki[b].area.compareTo(ki[a].area));

    final List<List<int>> children = List.generate(n, (_) => <int>[]);

    for (int si = 1; si < n; si++) {
      final int idx = order[si];
      int best = -1;
      double bestArea = double.infinity;
      for (int sj = 0; sj < si; sj++) {
        final int cand = order[sj];
        if (!_bboxContains(ki[cand].bounds, ki[idx].bounds)) continue;
        final double a = ki[cand].area;
        if (a < bestArea && ki[cand].path.contains(ki[idx].bounds.center)) {
          best = cand;
          bestArea = a;
        }
      }
      if (best >= 0) children[best].add(idx);
    }

    // Step 3: 按规则过滤（使用 dilated 裁剪掩码做孔洞检测）
    final List<bool> keep = List<bool>.filled(n, true);
    for (int i = 0; i < n; i++) {
      if (!keep[i] || children[i].isEmpty) continue;

      final List<int> holes = <int>[], nonHoles = <int>[];
      for (final int c in children[i]) {
        (_isHole(ki[c], dilatedCrop, w, h) ? holes : nonHoles).add(c);
      }

      // 非孔洞 → 全部丢弃
      for (final int c in nonHoles) {
        keep[c] = false;
        _markDescendants(children, keep, c);
      }

      // 孔洞 → 去重
      if (holes.length > 1) {
        final List<_MattingContourInfo> hInfos = holes.map((c) => ki[c]).toList();
        final Set<int> hKeep = _deduplicateInfos(hInfos);
        for (int hi = 0; hi < holes.length; hi++) {
          if (!hKeep.contains(hi)) {
            keep[holes[hi]] = false;
            _markDescendants(children, keep, holes[hi]);
          }
        }
      }
    }

    return <Path>[
      for (int i = 0; i < n; i++)
        if (keep[i]) ki[i].path,
    ];
  }

  /// 从图像字节中提取并过滤轮廓（解码 → 掩码 → 轮廓提取 → 去重 → 嵌套过滤，一步完成）
  /// - 预缓存 bounds/周长/面积，避免重复计算
  /// - 按面积降序排序 → O(n²) 构建包含树
  /// - 非孔洞子轮廓 → 只保留最外层；孔洞子轮廓 → 去重
  static List<Path> extractFilteredContours(Uint8List imageBytes) {
    final img.Image? image = img.decodeImage(imageBytes);
    if (image == null) return <Path>[];

    final int w = image.width;
    final int h = image.height;

    // 二值掩码
    final Uint8List mask = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        mask[y * w + x] = image.getPixel(x, y).a > 128 ? 1 : 0;
      }
    }

    final List<Path> paths = _extractContoursFromMask(mask, w, h);
    if (paths.isEmpty) return paths;

    // 一次性预计算所有轮廓元信息
    final List<_MattingContourInfo> infos = paths.map((p) => _MattingContourInfo(p)).toList();

    // Step 1: 去重
    final Set<int> dedupSet = _deduplicateInfos(infos);
    if (dedupSet.length <= 1) {
      return <Path>[for (final int i in dedupSet) infos[i].path];
    }

    // 重新编号
    final List<int> remap = dedupSet.toList();
    final int n = remap.length;
    final List<_MattingContourInfo> ki = remap.map((i) => infos[i]).toList();

    // Step 2: 按面积降序，O(n²) 构建包含树
    final List<int> order = List<int>.generate(n, (i) => i);
    order.sort((a, b) => ki[b].area.compareTo(ki[a].area));

    final List<List<int>> children = List.generate(n, (_) => <int>[]);

    for (int si = 1; si < n; si++) {
      final int idx = order[si];
      int best = -1;
      double bestArea = double.infinity;
      for (int sj = 0; sj < si; sj++) {
        final int cand = order[sj];
        if (!_bboxContains(ki[cand].bounds, ki[idx].bounds)) continue;
        final double a = ki[cand].area;
        if (a < bestArea && ki[cand].path.contains(ki[idx].bounds.center)) {
          best = cand;
          bestArea = a;
        }
      }
      if (best >= 0) children[best].add(idx);
    }

    // Step 3: 按规则过滤
    final List<bool> keep = List<bool>.filled(n, true);
    for (int i = 0; i < n; i++) {
      if (!keep[i] || children[i].isEmpty) continue;

      final List<int> holes = <int>[], nonHoles = <int>[];
      for (final int c in children[i]) {
        (_isHole(ki[c], mask, w, h) ? holes : nonHoles).add(c);
      }

      // 非孔洞 → 全部丢弃
      for (final int c in nonHoles) {
        keep[c] = false;
        _markDescendants(children, keep, c);
      }

      // 孔洞 → 去重
      if (holes.length > 1) {
        final List<_MattingContourInfo> hInfos = holes.map((c) => ki[c]).toList();
        final Set<int> hKeep = _deduplicateInfos(hInfos);
        for (int hi = 0; hi < holes.length; hi++) {
          if (!hKeep.contains(hi)) {
            keep[holes[hi]] = false;
            _markDescendants(children, keep, holes[hi]);
          }
        }
      }
    }

    return <Path>[
      for (int i = 0; i < n; i++)
        if (keep[i]) ki[i].path,
    ];
  }

  /// 从二值掩码中提取轮廓路径
  static List<Path> _extractContoursFromMask(Uint8List mask, int w, int h) {
    final Uint8List visited = Uint8List(w * h);
    final List<Path> paths = <Path>[];

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int i = y * w + x;
        if (mask[i] == 0 || visited[i] != 0) continue;
        if (!_isEdge(mask, w, h, x, y)) {
          visited[i] = 2;
          continue;
        }

        final Path? p = _trace(mask, visited, w, h, x, y);
        if (p != null) paths.add(p);
      }
    }
    return paths;
  }

  static bool _isEdge(Uint8List m, int w, int h, int x, int y) {
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final int nx = x + dx, ny = y + dy;
        if (nx < 0 || nx >= w || ny < 0 || ny >= h) return true;
        if (m[ny * w + nx] == 0) return true;
      }
    }
    return false;
  }

  static Path? _trace(Uint8List m, Uint8List v, int w, int h, int sx, int sy) {
    // 8 邻域，顺时针从右开始
    const List<List<int>> d = <List<int>>[
      [1, 0],
      [1, 1],
      [0, 1],
      [-1, 1],
      [-1, 0],
      [-1, -1],
      [0, -1],
      [1, -1],
    ];

    final Path p = Path();
    int cx = sx, cy = sy, dir = 0, n = 0;
    p.moveTo(cx.toDouble(), cy.toDouble());
    v[cy * w + cx] = 1;
    n++;

    for (int iter = 0; iter < w * h; iter++) {
      bool found = false;
      for (int k = 0; k < 8; k++) {
        final int nd = (dir + k) % 8;
        final int nx = cx + d[nd][0], ny = cy + d[nd][1];
        if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
        if (m[ny * w + nx] == 0) continue;

        cx = nx;
        cy = ny;
        if (cx == sx && cy == sy) {
          found = true;
          break;
        }

        p.lineTo(cx.toDouble(), cy.toDouble());
        v[cy * w + cx] = 1;
        n++;
        dir = (nd + 5) % 8; // 回溯方向
        found = true;
        break;
      }
      if (cx == sx && cy == sy) {
        p.close();
        break;
      }
      if (!found) break;
    }
    return n >= 3 ? p : null;
  }


  /// 基于预计算信息去重，返回保留的索引集合
  static Set<int> _deduplicateInfos(List<_MattingContourInfo> infos) {
    final int n = infos.length;
    if (n == 0) return <int>{};
    if (n == 1) return {0};
    final List<bool> keep = List<bool>.filled(n, true);
    for (int i = 0; i < n; i++) {
      if (!keep[i]) continue;
      for (int j = i + 1; j < n; j++) {
        if (!keep[j]) continue;
        final Rect inter = infos[i].bounds.intersect(infos[j].bounds);
        final double interArea = inter.width * inter.height;
        if (interArea <= 0) continue;
        final double union = infos[i].area + infos[j].area - interArea;
        final double lenA = infos[i].length, lenB = infos[j].length;
        if (interArea / union > 0.9 &&
            (lenA < lenB ? lenA / lenB : lenB / lenA) > 0.8) {
          keep[j] = false;
        }
      }
    }
    return {
      for (int i = 0; i < n; i++)
        if (keep[i]) i,
    };
  }

  /// 纯矩形包含检测（快速预过滤）
  static bool _bboxContains(Rect outer, Rect inner) {
    return inner.left >= outer.left &&
        inner.top >= outer.top &&
        inner.right <= outer.right &&
        inner.bottom <= outer.bottom;
  }


  /// 判断轮廓是否为孔洞（内部是透明区域）
  /// 在轮廓路径内部多点采样，多数像素为背景时判定为孔洞
  static bool _isHole(_MattingContourInfo info, Uint8List mask, int w, int h) {
    final Rect b = info.bounds;
    if (b.isEmpty) return false;

    // 采样步长：至少 3×3 个采样点，但不超过实际像素范围
    final int stepX = (b.width / 4).ceil().clamp(1, b.width.ceil());
    final int stepY = (b.height / 4).ceil().clamp(1, b.height.ceil());

    int bgCount = 0, totalCount = 0;
    for (double y = b.top + 1; y < b.bottom; y += stepY) {
      for (double x = b.left + 1; x < b.right; x += stepX) {
        final int px = x.round(), py = y.round();
        if (px < 0 || px >= w || py < 0 || py >= h) continue;
        // 仅采样位于轮廓路径内部的点
        if (!info.path.contains(Offset(x, y))) continue;
        totalCount++;
        if (mask[py * w + px] == 0) bgCount++;
      }
    }

    // 至少采样到 3 个点才做判断，多数背景 → 孔洞
    if (totalCount < 3) return false;
    return bgCount / totalCount > 0.5;
  }

  /// 递归标记后代
  static void _markDescendants(List<List<int>> children, List<bool> keep, int node) {
    for (final int child in children[node]) {
      keep[child] = false;
      _markDescendants(children, keep, child);
    }
  }

  static Uint8List _dilateMask(Uint8List mask, int w, int h, int dist) {
    final Uint8List result = Uint8List(w * h);
    final List<int> edge = <int>[];
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (mask[y * w + x] == 0) continue;
        bool isEdge = false;
        for (int dy = -1; dy <= 1 && !isEdge; dy++) {
          for (int dx = -1; dx <= 1 && !isEdge; dx++) {
            if (dx == 0 && dy == 0) continue;
            final int nx = x + dx, ny = y + dy;
            if (nx < 0 || nx >= w || ny < 0 || ny >= h ||
                mask[ny * w + nx] == 0) isEdge = true;
          }
        }
        if (isEdge) edge.add(y * w + x);
      }
    }
    for (int i = 0; i < mask.length; i++) {
      if (mask[i] > 0) result[i] = 1;
    }
    final int d2 = dist * dist;
    for (final int idx in edge) {
      final int ex = idx % w, ey = idx ~/ w;
      for (int dy = -dist; dy <= dist; dy++) {
        final int ny = ey + dy;
        if (ny < 0 || ny >= h) continue;
        for (int dx = -dist; dx <= dist; dx++) {
          if (dx * dx + dy * dy > d2) continue;
          final int nx = ex + dx;
          if (nx < 0 || nx >= w) continue;
          result[ny * w + nx] = 1;
        }
      }
    }
    return result;
  }

  static Path _smoothContour(Path path, {int iterations = 3}) {
    final List<Offset> pts = <Offset>[];
    for (final PathMetric m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 1.0) {
        final Tangent? t = m.getTangentForOffset(d);
        if (t != null) pts.add(t.position);
      }
    }
    if (pts.length < 3) return path;
    if ((pts.first - pts.last).distance < 0.5) pts.removeLast();
    List<Offset> s = pts;
    for (int i = 0; i < iterations; i++) s = _chaikinSmooth(s);
    final Path r = Path()..moveTo(s.first.dx, s.first.dy);
    for (int i = 1; i < s.length; i++) r.lineTo(s[i].dx, s[i].dy);
    return r..close();
  }

  static List<Offset> _chaikinSmooth(List<Offset> pts) {
    if (pts.length < 3) return pts;
    final int n = pts.length;
    final List<Offset> r = <Offset>[];
    for (int i = 0; i < n; i++) {
      final Offset a = pts[i], b = pts[(i + 1) % n];
      r.add(Offset(a.dx * .75 + b.dx * .25, a.dy * .75 + b.dy * .25));
      r.add(Offset(a.dx * .25 + b.dx * .75, a.dy * .25 + b.dy * .75));
    }
    return r;
  }

}