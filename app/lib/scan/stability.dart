import 'dart:math' as math;
import 'dart:ui';

import 'quad.dart';

/// Decides when the live outline has held still long enough to shoot.
///
/// Feed one detection per preview frame. [update] returns true once, when
/// the outline has stayed within [tolerance] (fraction of the frame
/// diagonal) for [frames] consecutive frames and covers at least
/// [minAreaRatio] of the frame. After that it disarms until the page
/// leaves the frame or moves by more than [rearmMove], so a batch scan
/// does not shoot the same page twice.
class StabilityTracker {
  StabilityTracker({
    this.frames = 6,
    this.tolerance = 0.015,
    this.minAreaRatio = 0.12,
    this.rearmMove = 0.08,
  });

  final int frames;
  final double tolerance;
  final double minAreaRatio;
  final double rearmMove;

  Quad? _last;
  Quad? _shotAt;
  int _still = 0;

  /// 0..1, how close the current outline is to triggering. For UI only.
  double get progress => _shotAt != null ? 0 : (_still / frames).clamp(0, 1);

  void reset() {
    _last = null;
    _shotAt = null;
    _still = 0;
  }

  bool update(Quad? q, Size frame) {
    final diag = math.sqrt(frame.width * frame.width + frame.height * frame.height);
    if (q == null || diag == 0) {
      _last = null;
      _shotAt = null; // page left the frame: ready for the next one
      _still = 0;
      return false;
    }
    if (_shotAt != null) {
      if (_maxMove(_shotAt!, q) / diag > rearmMove) _shotAt = null;
      _last = q;
      _still = 0;
      return false;
    }
    final prev = _last;
    _last = q;
    final bigEnough = q.area >= minAreaRatio * frame.width * frame.height;
    if (prev == null || !bigEnough || _maxMove(prev, q) / diag > tolerance) {
      _still = bigEnough ? 1 : 0;
      return false;
    }
    _still++;
    if (_still < frames) return false;
    _shotAt = q;
    _still = 0;
    return true;
  }

  static double _maxMove(Quad a, Quad b) {
    var m = 0.0;
    for (var i = 0; i < 4; i++) {
      m = math.max(m, (a.points[i] - b.points[i]).distance);
    }
    return m;
  }
}
