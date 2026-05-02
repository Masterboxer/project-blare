import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:battery_plus/battery_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: AlarmPage());
  }
}

class AlarmPage extends StatefulWidget {
  const AlarmPage({super.key});

  @override
  State<AlarmPage> createState() => _AlarmPageState();
}

class _AlarmPageState extends State<AlarmPage> {
  final AudioPlayer _player = AudioPlayer();
  final Battery _battery = Battery();

  StreamSubscription<BatteryState>? _batterySub;
  bool isAlarmRunning = false;

  Future<void> startAlarm() async {
    setState(() => isAlarmRunning = true);

    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(AssetSource('alarm.mp3'));

    _batterySub = _battery.onBatteryStateChanged.listen((state) {
      if (state == BatteryState.charging || state == BatteryState.full) {
        stopAlarm();
      }
    });
  }

  Future<void> stopAlarm() async {
    await _player.stop();
    await _batterySub?.cancel();

    setState(() => isAlarmRunning = false);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Charger connected. Alarm stopped.")),
    );
  }

  @override
  void dispose() {
    _player.dispose();
    _batterySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Charger Alarm POC")),
      body: Center(
        child: ElevatedButton(
          onPressed: isAlarmRunning ? null : startAlarm,
          child: Text(isAlarmRunning ? "Alarm Running..." : "Start Alarm"),
        ),
      ),
    );
  }
}
