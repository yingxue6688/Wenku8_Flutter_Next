import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

class ReaderPaperMesh {
  const ReaderPaperMesh({
    required this.positions,
    required this.uv,
    required this.normals,
    required this.indices,
    required this.outline,
  });

  final Float32List positions;
  final Float32List uv;
  final Float32List normals;
  final Uint16List indices;
  final Path outline;
}

class ReaderPaperGeometry {
  ReaderPaperGeometry({
    required this.size,
    required this.gap,
    required this.progress,
    required this.touchY,
  }) : lift = math.sin(progress.clamp(0.0, 1.0) * math.pi) {
    final w = size.width;
    final h = size.height;
    final t = progress.clamp(0.0, 1.0);
    final angle = t * math.pi;
    final cosA = math.cos(angle);
    final xEdge = w * cosA;
    final arch = math.sin(angle) * math.min(w * 0.08, 24.0);
    final skew = (touchY - 0.5) * arch * 0.35;

    final frontRect = Rect.fromLTRB(
      math.min(0.0, xEdge),
      0,
      math.max(0.0, xEdge),
      h,
    );
    final sheetPath = Path()..addRect(frontRect);
    sheet = sheetPath;

    final mesh = _buildQuadMesh(
      x0: 0,
      y0: 0,
      x1: xEdge,
      y1: -skew,
      x2: xEdge,
      y2: h + skew,
      x3: 0,
      y3: h,
      width: w,
      height: h,
      normal: cosA,
      outline: sheetPath,
    );
    front = mesh;
    frontInk = mesh;
    back = mesh;
    backInk = mesh;
  }

  final Size size;
  final double gap;
  final double progress;
  final double touchY;
  final double lift;
  late final Path sheet;
  late final ReaderPaperMesh front;
  late final ReaderPaperMesh back;
  late final ReaderPaperMesh frontInk;
  late final ReaderPaperMesh backInk;

  static ReaderPaperMesh _buildQuadMesh({
    required double x0,
    required double y0,
    required double x1,
    required double y1,
    required double x2,
    required double y2,
    required double x3,
    required double y3,
    required double width,
    required double height,
    required double normal,
    required Path outline,
  }) {
    final positions = Float32List.fromList([x0, y0, x1, y1, x2, y2, x3, y3]);
    final uv = Float32List.fromList([0, 0, width, 0, width, height, 0, height]);
    final normals = Float32List.fromList([1.0, normal, normal, 1.0]);
    final indices = Uint16List.fromList([0, 1, 2, 0, 2, 3]);
    return ReaderPaperMesh(
      positions: positions,
      uv: uv,
      normals: normals,
      indices: indices,
      outline: outline,
    );
  }
}
