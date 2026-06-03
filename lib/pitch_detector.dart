import 'dart:math' as math;
import 'dart:typed_data';
import 'package:fftea/fftea.dart';

class PitchResult {
  final double frequency; // Hz (0 si no hay tono)
  final double clarity; // 0..1 (1 - aperiodicidad YIN)
  final double rms;
  const PitchResult(this.frequency, this.clarity, this.rms);
  bool get hasPitch => frequency > 0;
}

/// Detector de tono YIN (de Cheveigné & Kawahara, 2002), el estándar de los
/// afinadores tipo GuitarTuna. Pasos:
///   1. Función de diferencia d(tau) = Σ (x[j]-x[j+tau])²
///   2. CMNDF: d'(tau) = d(tau)·tau / Σ d(1..tau)   (normaliza, evita octavas)
///   3. Umbral absoluto + búsqueda del primer mínimo
///   4. Interpolación parabólica -> periodo sub-muestra (precisión sub-cent)
/// La diferencia se obtiene de la autocorrelación calculada con FFT
/// (Wiener–Khinchin) => O(N·logN), rápido incluso con N grande.
class PitchDetector {
  final int sampleRate;
  final int windowSize; // N
  final int fftSize; // potencia de 2 >= 2N
  final double threshold; // umbral YIN (0.10–0.15)
  final FFT _fft;
  final Float64x2List _cx;
  final Float64List _prefix; // sumas acumuladas de cuadrados
  final Float64List _buf; // d(tau) / d'(tau)
  final Float64List _work; // señal sin DC

  PitchDetector({
    required this.sampleRate,
    this.windowSize = 8192,
    this.threshold = 0.12,
  })  : fftSize = _nextPow2(2 * windowSize),
        _fft = FFT(_nextPow2(2 * windowSize)),
        _cx = Float64x2List(_nextPow2(2 * windowSize)),
        _prefix = Float64List(windowSize + 1),
        _buf = Float64List(windowSize),
        _work = Float64List(windowSize);

  static int _nextPow2(int v) {
    var p = 1;
    while (p < v) {
      p <<= 1;
    }
    return p;
  }

  PitchResult detect(Float64List x) {
    final n = windowSize;
    final maxTau = n >> 1;

    // Quitar DC/offset: mejora la detección de señales débiles.
    double mean = 0;
    for (int i = 0; i < n; i++) {
      mean += x[i];
    }
    mean /= n;
    final w = _work;
    double energy = 0;
    for (int i = 0; i < n; i++) {
      final v = x[i] - mean;
      w[i] = v;
      energy += v * v;
    }
    if (energy <= 0) return const PitchResult(0, 0, 0);
    final rms = math.sqrt(energy / n);

    // Autocorrelación lineal vía FFT (zero-padding a fftSize).
    for (int i = 0; i < fftSize; i++) {
      _cx[i] = i < n ? Float64x2(w[i], 0) : Float64x2(0, 0);
    }
    _fft.inPlaceFft(_cx);
    for (int i = 0; i < fftSize; i++) {
      final c = _cx[i];
      _cx[i] = Float64x2(c.x * c.x + c.y * c.y, 0);
    }
    _fft.inPlaceInverseFft(_cx);
    final r0 = _cx[0].x;
    if (r0 <= 0) return PitchResult(0, 0, rms);
    final scale = energy / r0; // r'(tau) = _cx[tau].x * scale

    _prefix[0] = 0;
    for (int i = 0; i < n; i++) {
      _prefix[i + 1] = _prefix[i] + w[i] * w[i];
    }
    final pN = _prefix[n];

    // Función de diferencia d(tau).
    final d = _buf;
    for (int tau = 1; tau < maxTau; tau++) {
      final rTau = _cx[tau].x * scale;
      var val = _prefix[n - tau] + (pN - _prefix[tau]) - 2 * rTau;
      if (val < 0) val = 0;
      d[tau] = val;
    }

    // CMNDF.
    d[0] = 1.0;
    double running = 0;
    for (int tau = 1; tau < maxTau; tau++) {
      running += d[tau];
      d[tau] = running > 0 ? d[tau] * tau / running : 1.0;
    }

    // Umbral absoluto: primer tau bajo el umbral, descendiendo al mínimo local.
    int tau = -1;
    for (int t = 2; t < maxTau - 1; t++) {
      if (d[t] < threshold) {
        while (t + 1 < maxTau && d[t + 1] < d[t]) {
          t++;
        }
        tau = t;
        break;
      }
    }
    if (tau == -1) {
      // Sin candidato bajo umbral: usar el mínimo global.
      double minV = double.infinity;
      int minT = -1;
      for (int t = 2; t < maxTau; t++) {
        if (d[t] < minV) {
          minV = d[t];
          minT = t;
        }
      }
      if (minT == -1) return PitchResult(0, 0, rms);
      tau = minT;
    }

    final betterTau = _parabolic(d, tau, maxTau);
    if (betterTau <= 0) return PitchResult(0, 0, rms);
    final clarity = (1.0 - d[tau]).clamp(0.0, 1.0);
    return PitchResult(sampleRate / betterTau, clarity, rms);
  }

  double _parabolic(Float64List a, int tau, int maxTau) {
    final x0 = tau < 1 ? tau : tau - 1;
    final x2 = tau + 1 < maxTau ? tau + 1 : tau;
    if (x0 == tau) return (a[tau] <= a[x2]) ? tau.toDouble() : x2.toDouble();
    if (x2 == tau) return (a[tau] <= a[x0]) ? tau.toDouble() : x0.toDouble();
    final s0 = a[x0], s1 = a[tau], s2 = a[x2];
    final denom = s0 - 2 * s1 + s2;
    if (denom == 0) return tau.toDouble();
    return tau + 0.5 * (s0 - s2) / denom;
  }
}
