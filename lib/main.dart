import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pitch_detector.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const AfinadorApp());
}

const kBg = Color(0xFF0A0C0A);
const kGreen = Color(0xFFA6E22E);
const kRed = Color(0xFF9E2B20);
const kDim = Color(0xFF7C8A80);
const kAmber = Color(0xFFE0A52A);
const kOff = Color(0xFFE23B2E);
const kInTune = Color(0xFF63C23C);

const _names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

double _log2(double x) => math.log(x) / math.ln2;

Color centsColor(double cents) {
  final a = cents.abs();
  if (a <= 5) return kInTune;
  if (a <= 20) return kAmber;
  return kOff;
}

class AfinadorApp extends StatelessWidget {
  const AfinadorApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Afinador',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: kBg),
      home: const TunerPage(),
    );
  }
}

class TunerPage extends StatefulWidget {
  const TunerPage({super.key});
  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with SingleTickerProviderStateMixin {
  final _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  late PitchDetector _detector;

  static const int _sr = 44100;
  int _n = 8192;
  int _hop = 2048;
  Float64List _ring = Float64List(8192);
  int _filled = 0;
  int _sinceDetect = 0;
  static const List<int> _nOptions = [2048, 4096, 8192, 16384];

  double _a4 = 440;
  double _minClarity = 0.6; // claridad NSDF mínima
  double _minRms = 0.008; // volumen mínimo
  bool _permission = true;
  bool _showSettings = false;
  Color _accent = const Color(0xFF1FC3C3); // turquesa por defecto

  // estado de visualización
  bool _active = false;
  double _emaFreq = 0;
  double _freq = 0;
  double _cents = 0; // objetivo (cents detectados)
  double _dispCents = 0; // valor animado de la aguja
  int _lastGoodMs = 0; // última detección buena (para mantener la nota)
  static const int _holdMs = 700;
  double _target = 0;
  String _note = '–';
  int _octave = 0;
  final List<double> _history = [];
  Ticker? _ticker;

  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    _a4 = p.getDouble('a4') ?? _a4;
    _minClarity = p.getDouble('clarity') ?? _minClarity;
    _minRms = p.getDouble('rms') ?? _minRms;
    _n = p.getInt('n') ?? _n;
    _accent = Color(p.getInt('accent') ?? _accent.toARGB32());
    _hop = (_n ~/ 6).clamp(1024, _n);
    _ring = Float64List(_n);
    _detector = PitchDetector(sampleRate: _sr, windowSize: _n);
    _ticker = createTicker(_onTick)..start();
    if (mounted) setState(() {});
    await _start();
  }

  void _onTick(Duration _) {
    bool changed = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_active && now - _lastGoodMs > _holdMs) {
      _active = false;
      changed = true;
    }
    // Aguja con glide suave hacia el objetivo.
    final nd = _dispCents + (_cents - _dispCents) * 0.25;
    if ((nd - _dispCents).abs() > 0.02) {
      _dispCents = nd;
      changed = true;
    }
    if (changed) setState(() {});
  }

  void _save() {
    final p = _prefs;
    if (p == null) return;
    p.setDouble('a4', _a4);
    p.setDouble('clarity', _minClarity);
    p.setDouble('rms', _minRms);
    p.setInt('n', _n);
    p.setInt('accent', _accent.toARGB32());
  }

  @override
  void dispose() {
    _save();
    _ticker?.dispose();
    _sub?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final ok = await _rec.hasPermission();
    if (!ok) {
      setState(() => _permission = false);
      return;
    }
    setState(() => _permission = true);
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sr,
      numChannels: 1,
      autoGain: true, // sube señales flojas (YIN es invariante a amplitud)
      echoCancel: false,
      noiseSuppress: false,
    ));
    _sub = stream.listen(_onAudio);
  }

  void _onAudio(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final count = bytes.lengthInBytes >> 1;
    if (count <= 0) return;
    if (count >= _n) {
      final base = count - _n;
      for (int i = 0; i < _n; i++) {
        _ring[i] = bd.getInt16((base + i) * 2, Endian.little) / 32768.0;
      }
    } else {
      _ring.setRange(0, _n - count, _ring, count);
      for (int i = 0; i < count; i++) {
        _ring[_n - count + i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
    }
    _filled = math.min(_n, _filled + count);
    _sinceDetect += count;
    if (_filled >= _n && _sinceDetect >= _hop) {
      _sinceDetect = 0;
      _process();
    }
  }

  void _process() {
    final res = _detector.detect(_ring);
    final good = res.hasPitch &&
        res.clarity > _minClarity &&
        res.rms > _minRms &&
        res.frequency >= 27 &&
        res.frequency <= 4500;
    if (!good) return; // mantener la última nota (el ticker la apaga tras _holdMs)
    // Suavizado: salto rápido entre notas, estable dentro de la nota.
    if (_emaFreq == 0 || (res.frequency - _emaFreq).abs() / _emaFreq > 0.03) {
      _emaFreq = res.frequency;
    } else {
      _emaFreq = _emaFreq * 0.7 + res.frequency * 0.3;
    }
    final f = _emaFreq;
    final midi = 69 + 12 * _log2(f / _a4);
    final nearest = midi.round();
    final cents = (midi - nearest) * 100;
    // Solo actualiza campos; el ticker anima la aguja y repinta.
    _freq = f;
    _cents = cents;
    _note = _names[((nearest % 12) + 12) % 12];
    _octave = (nearest ~/ 12) - 1;
    _target = _a4 * math.pow(2, (nearest - 69) / 12).toDouble();
    if (!_active) {
      _active = true;
      _dispCents = cents; // arranca sin barrido desde 0
    }
    _lastGoodMs = DateTime.now().millisecondsSinceEpoch;
    _history.add(cents.clamp(-50.0, 50.0));
    if (_history.length > 22) _history.removeAt(0);
  }

  void _setN(int n) {
    setState(() {
      _n = n;
      _hop = (n ~/ 6).clamp(1024, n);
      _ring = Float64List(n);
      _filled = 0;
      _sinceDetect = 0;
      _detector = PitchDetector(sampleRate: _sr, windowSize: n);
      _active = false;
      _history.clear();
    });
  }

  Widget _settingsView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () {
                  _save();
                  setState(() => _showSettings = false);
                },
              ),
              const Text('Ajustes',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetRow('Tamaño FFT', 'N=$_n · FFT ${_n * 2}'),
                const Text('Mayor = más preciso y llega a graves más bajos, pero reacciona más lento',
                    style: TextStyle(color: kDim, fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final n in _nOptions)
                      GestureDetector(
                        onTap: () => _setN(n),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                          decoration: BoxDecoration(
                            color: _n == n ? _accent : const Color(0xFF1F2426),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Text('$n',
                              style: TextStyle(
                                  color: _n == n ? Colors.black : Colors.white,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    const Text('Color',
                        style: TextStyle(color: Colors.white, fontSize: 17)),
                    const Spacer(),
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Center(
                  child: HueRingPicker(
                    pickerColor: _accent,
                    onColorChanged: (c) => setState(() => _accent = c),
                    enableAlpha: false,
                    displayThumbColor: true,
                    portraitOnly: true,
                  ),
                ),
                const SizedBox(height: 22),
                _sheetRow('Referencia A4', '${_a4.round()} Hz'),
                Slider(
                  value: _a4,
                  min: 430,
                  max: 450,
                  divisions: 20,
                  activeColor: _accent,
                  label: '${_a4.round()}',
                  onChanged: (v) => setState(() => _a4 = v),
                ),
                const SizedBox(height: 8),
                _sheetRow('Claridad mínima', _minClarity.toStringAsFixed(2)),
                const Text('Más alto = ignora sonidos poco claros (más estable, menos sensible)',
                    style: TextStyle(color: kDim, fontSize: 12)),
                Slider(
                  value: _minClarity,
                  min: 0.3,
                  max: 0.95,
                  divisions: 65,
                  activeColor: _accent,
                  label: _minClarity.toStringAsFixed(2),
                  onChanged: (v) => setState(() => _minClarity = v),
                ),
                const SizedBox(height: 8),
                _sheetRow('Umbral de volumen', _minRms.toStringAsFixed(4)),
                const Text('Más alto = ignora sonidos flojos / ruido de fondo',
                    style: TextStyle(color: kDim, fontSize: 12)),
                Slider(
                  value: _minRms,
                  min: 0.0,
                  max: 0.03,
                  divisions: 60,
                  activeColor: _accent,
                  label: _minRms.toStringAsFixed(4),
                  onChanged: (v) => setState(() => _minRms = v),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sheetRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 17)),
          Text(value,
              style: TextStyle(color: _accent, fontSize: 20, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: !_permission
            ? _permissionView()
            : (_showSettings ? _settingsView() : _tuner()),
      ),
    );
  }

  Widget _permissionView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mic_off, color: kDim, size: 64),
          const SizedBox(height: 16),
          const Text('Necesito acceso al micrófono',
              style: TextStyle(color: Colors.white, fontSize: 18)),
          const SizedBox(height: 16),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.black),
            onPressed: _start,
            child: const Text('Permitir'),
          ),
        ],
      ),
    );
  }

  Widget _tuner() {
    return Column(
      children: [
        _header(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1B1F21),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFF2C3133)),
              ),
              child: const Text('Cromático',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
        Expanded(child: _gauge()),
        _readouts(),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            onPressed: () => setState(() => _showSettings = true),
          ),
          const Spacer(),
          RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              children: [
                TextSpan(text: 'afina', style: TextStyle(color: _accent)),
                const TextSpan(text: 'dor', style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
          const Spacer(),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _gauge() {
    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      final h = c.maxHeight;
      final cx = w / 2;
      final markerX = cx + (_dispCents.clamp(-50.0, 50.0) / 50.0) * (w * 0.42);
      final col = centsColor(_dispCents);
      return Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _GaugePainter(_history, _active)),
          ),
          // Nota grande + octava
          Center(
            child: Opacity(
              opacity: _active ? 1 : 0.25,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_note,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 110, fontWeight: FontWeight.w700, height: 1)),
                  if (_active)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Text('$_octave',
                          style: const TextStyle(color: Colors.white70, fontSize: 44, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 14,
            top: h * 0.42,
            child: const Text('♭', style: TextStyle(color: kDim, fontSize: 30)),
          ),
          Positioned(
            right: 14,
            top: h * 0.42,
            child: const Text('♯', style: TextStyle(color: kDim, fontSize: 30)),
          ),
          // Burbuja de cents
          if (_active)
            Positioned(
              left: markerX - 30,
              top: h * 0.08,
              child: _bubble(_dispCents, col),
            ),
        ],
      );
    });
  }

  Widget _bubble(double cents, Color col) {
    final v = cents.round();
    final txt = v == 0 ? '0' : (v > 0 ? '+$v' : '$v');
    return Column(
      children: [
        Container(
          width: 60,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: col,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(txt,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        ),
        Transform.translate(
          offset: const Offset(0, -4),
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Container(width: 14, height: 14, color: col),
          ),
        ),
      ],
    );
  }

  Widget _readouts() {
    return Column(
      children: [
        const Text('FRECUENCIA ACTUAL',
            style: TextStyle(color: kDim, fontSize: 15, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(_active ? '${_freq.toStringAsFixed(1)} Hz' : '– Hz',
            style: TextStyle(color: _accent, fontSize: 40, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        const Text('FRECUENCIA DESEADA',
            style: TextStyle(color: kDim, fontSize: 15, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(_active ? '${_target.toStringAsFixed(1)} Hz' : '– Hz',
            style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  final List<double> history;
  final bool active;
  _GaugePainter(this.history, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;

    final bgRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(8, 0, size.width - 16, size.height), const Radius.circular(8));
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xFF0C140E));
    canvas.save();
    canvas.clipRRect(bgRect);

    // rejilla
    final grid = Paint()
      ..color = const Color(0xFF18271B)
      ..strokeWidth = 1;
    for (double x = (cx % 36); x < size.width; x += 36) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y < size.height; y += 36) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // línea central roja
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height),
        Paint()
          ..color = kRed
          ..strokeWidth = 3);

    // estela de puntos del historial
    final l = history.length;
    if (active && l > 0) {
      final top = size.height * 0.16;
      final span = size.height * 0.5;
      for (int i = 0; i < l; i++) {
        final c = history[i];
        final age = (l - 1 - i); // 0 = más reciente
        final x = cx + (c / 50.0) * (size.width * 0.42);
        final y = top + age * (span / l);
        final alpha = (1.0 - age / l).clamp(0.18, 1.0);
        final r = age == 0 ? 0.0 : (age <= 2 ? 4.0 : 3.0);
        if (r > 0) {
          canvas.drawCircle(
              Offset(x, y), r, Paint()..color = centsColor(c).withValues(alpha: alpha));
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GaugePainter old) => true;
}
