import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';

const String kAlarmTimeKey = 'scheduled_alarm_time';
const String kAlarmPathKey = 'alarm_file_path';

Future<String> copyAlarmToFile() async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/alarm.mp3');
  if (!await file.exists()) {
    final data = await rootBundle.load('assets/alarm.mp3');
    await file.writeAsBytes(data.buffer.asUint8List());
    dev.log('alarm.mp3 written to ${file.path}', name: 'BLARE');
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(kAlarmPathKey, file.path);
  return file.path;
}

Future<String?> getAlarmFilePath() async {
  final prefs = await SharedPreferences.getInstance();
  final path = prefs.getString(kAlarmPathKey);
  if (path == null) return null;
  final exists = await File(path).exists();
  return exists ? path : null;
}

Future<void> saveAlarm(DateTime dt) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(kAlarmTimeKey, dt.toIso8601String());
}

Future<DateTime?> loadAlarm() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(kAlarmTimeKey);
  if (raw == null) return null;
  return DateTime.tryParse(raw);
}

Future<void> clearAlarm() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(kAlarmTimeKey);
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  AudioPlayer? _player;
  bool _stopping = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    dev.log('Service onStart', name: 'BLARE');
    _stopping = false;

    final path = await getAlarmFilePath();
    if (path == null) {
      dev.log('No alarm file path found — aborting', name: 'BLARE');
      return;
    }

    try {
      _player = AudioPlayer();
      await _player!.setFilePath(path);
      await _player!.setLoopMode(LoopMode.one);
      await _player!.setVolume(1.0);
      await _player!.play();
      dev.log('Audio playing: $path', name: 'BLARE');
    } catch (e) {
      dev.log('Audio error: $e', name: 'BLARE');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _checkCharger();
  }

  Future<void> _checkCharger() async {
    if (_stopping) return;
    try {
      await Battery().batteryLevel;
      final state = await Battery().batteryState;
      dev.log('Charger poll: $state', name: 'BLARE');
      if (state == BatteryState.charging || state == BatteryState.full) {
        await _doStop();
      }
    } catch (e) {
      dev.log('Charger poll error: $e', name: 'BLARE');
    }
  }

  Future<void> _doStop() async {
    if (_stopping) return;
    _stopping = true;
    dev.log('_doStop called', name: 'BLARE');
    try {
      await _player?.stop();
      await _player?.dispose();
      _player = null;
      await clearAlarm();
    } catch (e) {
      dev.log('_doStop error: $e', name: 'BLARE');
    }
    Future.delayed(Duration.zero, () async {
      await FlutterForegroundTask.stopService();
    });
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    dev.log('Service onDestroy', name: 'BLARE');
    try {
      await _player?.stop();
      await _player?.dispose();
      _player = null;
    } catch (_) {}
  }

  @override
  Future<void> onReceiveData(Object data) async {
    dev.log('Service received: $data', name: 'BLARE');
    if (data == 'STOP_ALARM') {
      await _doStop();
    }
  }
}

@pragma('vm:entry-point')
Future<void> alarmCallback() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  dev.log('alarmCallback fired', name: 'BLARE');

  final path = await getAlarmFilePath();
  if (path == null) {
    dev.log('alarmCallback: alarm file missing, aborting', name: 'BLARE');
    return;
  }

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
      eventAction: ForegroundTaskEventAction.repeat(1000),
      autoRunOnBoot: false,
    ),
  );

  await FlutterForegroundTask.startService(
    serviceId: 1001,
    notificationTitle: 'Project Blare Alarm Ringing',
    notificationText:
        'Plug in your charger and open the app to silence this alarm',
    callback: startCallback,
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterForegroundTask.requestNotificationPermission();
  await copyAlarmToFile();

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
      eventAction: ForegroundTaskEventAction.repeat(1000),
      autoRunOnBoot: false,
    ),
  );

  await AndroidAlarmManager.initialize();
  FlutterForegroundTask.initCommunicationPort();
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
  Timer? _watchdog;

  DateTime? _scheduledAlarm;
  bool _alarmTriggered = false;
  double _volume = 0.8;
  int _batteryLevel = 0;
  BatteryState _batteryState = BatteryState.unknown;

  late AnimationController _ringController;
  late AnimationController _glowController;

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

    _restoreAlarm();
    _loadBattery();

    // Stops alarm immediately when charger is plugged while app is open
    _batterySub = _battery.onBatteryStateChanged.listen((state) async {
      if (!mounted) return;
      setState(() => _batteryState = state);
      if ((state == BatteryState.charging || state == BatteryState.full) &&
          _alarmTriggered) {
        await _stopAlarmAuto();
      }
    });

    // Syncs UI if service stopped in background (charger plugged while locked)
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) => _sync());

    VolumeController.instance.showSystemUI = false;
    VolumeController.instance.addListener((vol) {
      if (mounted) setState(() => _volume = vol);
    }, fetchInitialVolume: true);
  }

  @override
  void dispose() {
    _batterySub?.cancel();
    _watchdog?.cancel();
    _ringController.dispose();
    _glowController.dispose();
    VolumeController.instance.removeListener();
    super.dispose();
  }

  Future<void> _sync() async {
    if (!mounted) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;

    if (_alarmTriggered && !running) {
      setState(() {
        _alarmTriggered = false;
        _scheduledAlarm = null;
      });
      _ringController.stop();
      _ringController.reset();
      _glowController.stop();
      _glowController.reset();
      _showSnack('Charger connected — alarm silenced.', isAuto: true);
    } else if (_alarmTriggered && running) {
      final state = await _battery.batteryState;
      if (!mounted) return;
      if (state == BatteryState.charging || state == BatteryState.full) {
        await _stopAlarmAuto();
      }
    } else if (!_alarmTriggered && running) {
      setState(() => _alarmTriggered = true);
      _ringController.repeat();
      _glowController.repeat(reverse: true);
    }
  }

  Future<void> _stopAlarmAuto() async {
    if (!_alarmTriggered) return;
    setState(() {
      _alarmTriggered = false;
      _scheduledAlarm = null;
    });
    _ringController.stop();
    _ringController.reset();
    _glowController.stop();
    _glowController.reset();
    await clearAlarm();
    FlutterForegroundTask.sendDataToTask('STOP_ALARM');
    await Future.delayed(const Duration(milliseconds: 400));
    await FlutterForegroundTask.stopService();
    _showSnack('Charger connected — alarm silenced.', isAuto: true);
  }

  Future<void> _stopAlarm() async {
    if (!_alarmTriggered) return;
    setState(() {
      _alarmTriggered = false;
      _scheduledAlarm = null;
    });
    _ringController.stop();
    _ringController.reset();
    _glowController.stop();
    _glowController.reset();
    HapticFeedback.mediumImpact();
    await clearAlarm();
    FlutterForegroundTask.sendDataToTask('STOP_ALARM');
    await Future.delayed(const Duration(milliseconds: 400));
    await FlutterForegroundTask.stopService();
    _showSnack('Alarm stopped.', isAuto: false);
  }

  Future<void> _restoreAlarm() async {
    final saved = await loadAlarm();
    if (!mounted) return;
    if (saved != null && saved.isAfter(DateTime.now())) {
      setState(() => _scheduledAlarm = saved);
    } else if (saved != null) {
      await clearAlarm();
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;
    if (running) {
      setState(() => _alarmTriggered = true);
      _ringController.repeat();
      _glowController.repeat(reverse: true);
    }
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

  Future<void> _scheduleAlarm() async {
    final now = DateTime.now();

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: DateTime(now.year + 5),
      builder: (_, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _orange,
            surface: _surface,
          ),
        ),
        child: child!,
      ),
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (_, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _orange,
            surface: _surface,
          ),
        ),
        child: child!,
      ),
    );
    if (pickedTime == null || !mounted) return;

    final alarmTime = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    if (alarmTime.isBefore(DateTime.now())) {
      _showSnack('Selected time is in the past.', isAuto: false);
      return;
    }

    setState(() => _scheduledAlarm = alarmTime);
    await saveAlarm(alarmTime);

    // Request both permissions needed for reliable background wakeup
    await Permission.scheduleExactAlarm.request();
    await Permission.ignoreBatteryOptimizations.request(); // ← ADD THIS

    await AndroidAlarmManager.oneShotAt(
      alarmTime,
      2001,
      alarmCallback,
      exact: true,
      wakeup: true,
      allowWhileIdle: true,
    );
    _showSnack('Alarm set for ${pickedTime.format(context)}', isAuto: false);
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
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_scheduledAlarm != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: _surface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: _orange.withOpacity(0.25)),
                        ),
                        child: Column(
                          children: [
                            Text(
                              TimeOfDay.fromDateTime(
                                _scheduledAlarm!,
                              ).format(context),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 54,
                                fontWeight: FontWeight.w900,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${_scheduledAlarm!.day}/${_scheduledAlarm!.month}/${_scheduledAlarm!.year}',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 14,
                                letterSpacing: 2,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: 20),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: _orange.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(100),
                              ),
                              child: Text(
                                _alarmTriggered ? 'RINGING' : 'SCHEDULED',
                                style: const TextStyle(
                                  color: _orange,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 2,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                    ],

                    SizedBox(
                      width: double.infinity,
                      height: 58,
                      child: ElevatedButton.icon(
                        onPressed: _scheduleAlarm,
                        icon: const Icon(Icons.add_alarm_rounded),
                        label: const Text('Schedule Alarm'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _orange,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          textStyle: const TextStyle(
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ),

                    if (_alarmTriggered) ...[
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        height: 58,
                        child: OutlinedButton.icon(
                          onPressed: _stopAlarm,
                          icon: const Icon(Icons.stop_rounded),
                          label: const Text('Stop Alarm'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _orange,
                            side: BorderSide(color: _orange.withOpacity(0.4)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _alarmTriggered
                      ? 'WAITING FOR CHARGER...'
                      : isCharging
                      ? 'CHARGER CONNECTED'
                      : 'CONNECT CHARGER TO TRIGGER',
                  key: ValueKey(_alarmTriggered),
                  style: TextStyle(
                    color: _alarmTriggered
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
                        value: _alarmTriggered ? 'LIVE' : 'OFF',
                        accent: _alarmTriggered ? _orange : Colors.white38,
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
  final String label;
  final String value;
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
