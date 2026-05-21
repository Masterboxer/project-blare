import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:volume_controller/volume_controller.dart';

const String kPortName = 'blare_port';

String? globalAlarmPath;

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  final AudioPlayer _player = AudioPlayer();
  final Battery _battery = Battery();

  StreamSubscription<BatteryState>? _batterySub;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    dev.log('Foreground service started', name: 'BLARE');

    final path = await copyAlarmToFile();

    await _player.setFilePath(path);

    await _player.setLoopMode(LoopMode.one);

    await _player.setVolume(1.0);

    await _player.play();

    dev.log('Alarm audio started from foreground service', name: 'BLARE');

    _batterySub = _battery.onBatteryStateChanged.listen((state) async {
      if (state == BatteryState.charging || state == BatteryState.full) {
        await _player.stop();
        await FlutterForegroundTask.stopService();
      }
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _batterySub?.cancel();
    await _player.stop();
    await _player.dispose();

    dev.log('Foreground service destroyed', name: 'BLARE');
  }
}

Future<String> copyAlarmToFile() async {
  final dir = await getApplicationDocumentsDirectory();

  final file = File('${dir.path}/alarm.mp3');

  if (await file.exists()) {
    return file.path;
  }

  final data = await rootBundle.load('assets/alarm.mp3');

  final bytes = data.buffer.asUint8List();

  await file.writeAsBytes(bytes);

  return file.path;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterForegroundTask.requestNotificationPermission();

  globalAlarmPath = await copyAlarmToFile();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'blare_alarm',
      channelName: 'Blare Alarm',
      channelDescription: 'Keeps alarm alive in background',
      onlyAlertOnce: true,
      playSound: false,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
    ),
  );

  runApp(const BlareApp());
}

class BlareApp extends StatelessWidget {
  const BlareApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Blare',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0E0A00),
      ),
      home: const AlarmPage(),
    );
  }
}

class AlarmPage extends StatefulWidget {
  const AlarmPage({super.key});
  @override
  State<AlarmPage> createState() => _AlarmPageState();
}

class _AlarmPageState extends State<AlarmPage> with TickerProviderStateMixin {
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySub;

  bool _isRunning = false;
  double _volume = 0.8;
  int _batteryLevel = 0;
  BatteryState _batteryState = BatteryState.unknown;

  late AnimationController _ringController;
  late AnimationController _glowController;
  late Animation<double> _glowAnim;

  static const _orange = Color(0xFFFF6B00);
  static const _orangeDim = Color(0xFFFF6B0033);
  static const _bg = Color(0xFF0E0A00);
  static const _surface = Color(0xFF1C1200);
  static const _surfaceBright = Color(0xFF2A1C00);

  @override
  void initState() {
    super.initState();

    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _glowAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _loadBattery();
    Timer.periodic(const Duration(seconds: 20), (_) => _loadBattery());

    VolumeController.instance.showSystemUI = false;
    VolumeController.instance.addListener((vol) {
      if (mounted) setState(() => _volume = vol);
    }, fetchInitialVolume: true);
  }

  Future<void> _loadBattery() async {
    final level = await _battery.batteryLevel;
    final state = await _battery.batteryState;
    if (mounted) {
      setState(() {
        _batteryLevel = level;
        _batteryState = state;
      });
    }
  }

  Future<void> _start() async {
    setState(() => _isRunning = true);
    _ringController.repeat();
    _glowController.repeat(reverse: true);
    HapticFeedback.heavyImpact();

    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: '🔔 Blare is armed',
      notificationText: 'Plug in charger to silence the alarm.',
      callback: startCallback,
    );

    _batterySub = _battery.onBatteryStateChanged.listen((state) {
      if (mounted) setState(() => _batteryState = state);
      if (state == BatteryState.charging || state == BatteryState.full) {
        _stopAlarm(auto: true);
      }
    });
  }

  Future<void> _stopAlarm({bool auto = false}) async {
    if (!_isRunning) return;
    setState(() => _isRunning = false);
    _ringController.stop();
    _ringController.reset();
    _glowController.stop();
    _glowController.reset();
    HapticFeedback.mediumImpact();

    await _batterySub?.cancel();
    _batterySub = null;
    await FlutterForegroundTask.stopService();

    _showSnack(
      auto ? 'Charger detected — alarm silenced.' : 'Alarm stopped.',
      isAuto: auto,
    );
  }

  void _onVolumeChange(double v) {
    setState(() => _volume = v);
    VolumeController.instance.setVolume(v);
  }

  void _showSnack(String msg, {required bool isAuto}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: _surfaceBright,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: _orange.withOpacity(0.3)),
        ),
        content: Row(
          children: [
            Icon(
              isAuto ? Icons.bolt_rounded : Icons.alarm_off_rounded,
              color: _orange,
              size: 18,
            ),
            const SizedBox(width: 10),
            Text(
              msg,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    _batterySub?.cancel();
    _ringController.dispose();
    _glowController.dispose();
    VolumeController.instance.removeListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCharging =
        _batteryState == BatteryState.charging ||
        _batteryState == BatteryState.full;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _orange,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.alarm_rounded,
                      color: Colors.black,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'BLARE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const Spacer(),
                  _BatteryChip(level: _batteryLevel, state: _batteryState),
                ],
              ),
            ),

            const SizedBox(height: 12),

            Expanded(
              child: Center(
                child: GestureDetector(
                  onTap: _isRunning ? () => _stopAlarm() : _start,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (_isRunning) ...[
                        AnimatedBuilder(
                          animation: _glowAnim,
                          builder: (_, __) => Container(
                            width: 280,
                            height: 280,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: _orange.withOpacity(
                                    0.15 * _glowAnim.value,
                                  ),
                                  blurRadius: 60,
                                  spreadRadius: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                        RotationTransition(
                          turns: _ringController,
                          child: CustomPaint(
                            size: const Size(240, 240),
                            painter: _DashedRingPainter(color: _orange),
                          ),
                        ),
                      ],
                      Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _isRunning
                                ? _orange.withOpacity(0.6)
                                : Colors.white.withOpacity(0.06),
                            width: 1.5,
                          ),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: _glowAnim,
                        builder: (_, child) => Container(
                          width: 180,
                          height: 180,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isRunning ? _orange : _surface,
                            boxShadow: _isRunning
                                ? [
                                    BoxShadow(
                                      color: _orange.withOpacity(
                                        0.5 * _glowAnim.value,
                                      ),
                                      blurRadius: 40,
                                      spreadRadius: 4,
                                    ),
                                  ]
                                : [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.4),
                                      blurRadius: 24,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                          ),
                          child: child,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _isRunning
                                  ? Icons.stop_rounded
                                  : Icons.alarm_rounded,
                              size: 48,
                              color: _isRunning
                                  ? Colors.black
                                  : Colors.white.withOpacity(0.85),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _isRunning ? 'STOP' : 'ARM',
                              style: TextStyle(
                                color: _isRunning
                                    ? Colors.black
                                    : Colors.white.withOpacity(0.85),
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 4,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _isRunning
                      ? 'WAITING FOR CHARGER...'
                      : isCharging
                      ? 'CHARGER CONNECTED'
                      : 'CONNECT CHARGER TO TRIGGER',
                  key: ValueKey(_isRunning),
                  style: TextStyle(
                    color: _isRunning
                        ? _orange.withOpacity(0.8)
                        : isCharging
                        ? Colors.greenAccent.withOpacity(0.7)
                        : Colors.white24,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),

            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(
                        _volume == 0
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        color: _orange.withOpacity(0.8),
                        size: 18,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            activeTrackColor: _orange,
                            inactiveTrackColor: Colors.white10,
                            thumbColor: Colors.white,
                            overlayColor: _orangeDim,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                          ),
                          child: Slider(
                            value: _volume,
                            min: 0,
                            max: 1,
                            onChanged: _onVolumeChange,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 34,
                        child: Text(
                          '${(_volume * 100).round()}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _Stat(
                        label: 'BATTERY',
                        value: '$_batteryLevel%',
                        accent: _batteryLevel < 20
                            ? Colors.redAccent
                            : Colors.white70,
                      ),
                      _divider(),
                      _Stat(
                        label: 'POWER',
                        value: isCharging ? 'IN' : 'OUT',
                        accent: isCharging
                            ? Colors.greenAccent
                            : Colors.white38,
                      ),
                      _divider(),
                      _Stat(
                        label: 'ALARM',
                        value: _isRunning ? 'LIVE' : 'OFF',
                        accent: _isRunning ? _orange : Colors.white38,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(
    width: 1,
    height: 28,
    color: Colors.white.withOpacity(0.07),
    margin: const EdgeInsets.symmetric(horizontal: 4),
  );
}

class _DashedRingPainter extends CustomPainter {
  final Color color;
  const _DashedRingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(0.5)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final center = Offset(size.width / 2, size.height / 2);
    const dashCount = 24;
    const dashAngle = 0.18;
    const gap = (3.14159 * 2 / dashCount) - dashAngle;
    double angle = 0;
    for (int i = 0; i < dashCount; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: size.width / 2),
        angle,
        dashAngle,
        false,
        paint,
      );
      angle += dashAngle + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
}

class _BatteryChip extends StatelessWidget {
  final int level;
  final BatteryState state;
  const _BatteryChip({required this.level, required this.state});

  @override
  Widget build(BuildContext context) {
    final charging =
        state == BatteryState.charging || state == BatteryState.full;
    final col = level < 20
        ? Colors.redAccent
        : charging
        ? Colors.greenAccent
        : Colors.white38;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: col.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: col.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            charging ? Icons.bolt_rounded : Icons.battery_std_rounded,
            color: col,
            size: 13,
          ),
          const SizedBox(width: 4),
          Text(
            '$level%',
            style: TextStyle(
              color: col,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value;
  final Color accent;
  const _Stat({required this.label, required this.value, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: accent,
              fontSize: 15,
              fontWeight: FontWeight.w900,
              fontFamily: 'monospace',
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white24,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }
}
