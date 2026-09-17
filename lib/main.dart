import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

// Глобальний ключ для виклику попапа з будь-якого місця
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Дзвоник',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const CallListenerPage(),
    );
  }
}

class CallListenerPage extends StatefulWidget {
  const CallListenerPage({super.key});

  @override
  State<CallListenerPage> createState() => _CallListenerPageState();
}

class _CallListenerPageState extends State<CallListenerPage> {
  static const platform = MethodChannel('com.example.dzvonyk/service');

  // Збережені MAC-адреси
  List<String> _savedMacs = [];
  
  // Список знайдених пристроїв при скануванні
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // Змінні для керування сигналізацією та аудіо
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isAlarmActive = false;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    await _requestPermissions();
    await _loadSavedMacs();
    _startAndroidService(); // Автозапуск фонового сервісу
    
    // Слухач команд від нативного фонового сервісу (коли плата надсилає find:start / find:stop)
    platform.setMethodCallHandler((call) async {
      switch (call.method) {
        case "triggerAlarmUI":
          print("🚨 Отримано команду на запуск тривоги з нативного сервісу!");
          triggerPhoneAlarm();
          break;
        case "stopAlarmUI":
          print("🔕 Отримано команду на зупинку тривоги з нативного сервісу!");
          stopPhoneAlarm();
          break;
        default:
          print("⚠️ Невідомий метод від сервісу: ${call.method}");
      }
    });
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    _audioPlayer.dispose();
    super.dispose();
  }

  // 1. Запит дозволів
  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.ignoreBatteryOptimizations,
    ].request();

    if (statuses[Permission.location]?.isGranted ?? false) {
      print("✅ Дозволи на геопозицію/BLE отримано");
    } else {
      print("⚠️ Увага: Дозволи обмежені, Bluetooth може не працювати.");
    }
  }

  // 2. Завантаження збережених MAC-адрес з Android SharedPreferences через MethodChannel
  Future<void> _loadSavedMacs() async {
    try {
      final List<dynamic>? macs = await platform.invokeMethod('getSavedMacs');
      setState(() {
        _savedMacs = macs?.map((e) => e.toString()).toList() ?? [];
      });
    } on PlatformException catch (e) {
      print("⚠️ Не вдалося завантажити збережені MAC: ${e.message}");
    }
  }

  // 3. Запуск сканування BLE
  Future<void> _startScanning() async {
    setState(() {
      _scanResults.clear();
      _isScanning = true;
    });

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _scanResults = results;
      });
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    } catch (e) {
      print("❌ Помилка сканування: $e");
    } finally {
      setState(() {
        _isScanning = false;
      });
    }
  }

  // 4. Збереження MAC-адреси
  Future<void> _saveMac(String mac) async {
    try {
      await platform.invokeMethod('saveMacAddress', {'mac': mac});
      await _loadSavedMacs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ Збережено плату: $mac')),
        );
      }
    } on PlatformException catch (e) {
      print("❌ Помилка збереження: ${e.message}");
    }
  }

  // 5. Видалення MAC-адреси
  Future<void> _removeMac(String mac) async {
    try {
      await platform.invokeMethod('removeMacAddress', {'mac': mac});
      await _loadSavedMacs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('🗑️ Видалено: $mac')),
        );
      }
    } on PlatformException catch (e) {
      print("❌ Помилка видалення: ${e.message}");
    }
  }

  // Запуск нативного фонового сервісу
  Future<void> _startAndroidService() async {
    try {
      await platform.invokeMethod('startService');
      print("🚀 Команда на запуск нативного сервісу відправлена");
    } on PlatformException catch (e) {
      print("⚠️ Помилка запуску сервісу: ${e.message}");
    }
  }

  // ==========================================
  // ЛОГІКА ТРИВОГИ ТА ПОПАПА
  // ==========================================

  void triggerPhoneAlarm() async {
    if (_isAlarmActive) return;
    _isAlarmActive = true;

    try {
      await FlutterVolumeController.setAndroidAudioStream(stream: AudioStream.alarm);
      await FlutterVolumeController.setVolume(0.1);
    } catch (e) {
      print("⚠️ Помилка налаштування гучності: $e");
    }

    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.play(AssetSource('media/alarm.mp3'));
    } catch (e) {
      print("❌ Помилка відтворення звуку: $e");
    }

    if (!mounted) return;
    showDialog(
      context: navigatorKey.currentContext ?? context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          backgroundColor: Colors.red.shade900,
          title: const Text(
            "🚨 ТЕЛЕФОН ШУКАЮТЬ!", 
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)
          ),
          content: const Text(
            "Натиснута кнопка на платі «Дзвоник»!\nГучність викручено на максимум.", 
            style: TextStyle(color: Colors.white70, fontSize: 16)
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white, 
                  foregroundColor: Colors.red.shade900,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  stopPhoneAlarm();
                },
                child: const Text("Знайшли! Зупинити", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void stopPhoneAlarm() {
    _audioPlayer.stop();
    _isAlarmActive = false;
    
    if (navigatorKey.currentState?.canPop() ?? false) {
      navigatorKey.currentState?.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Дзвоник — Налаштування BLE')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Статус сервісу
            const Row(
              children: [
                Icon(Icons.shield_rounded, color: Colors.greenAccent),
                SizedBox(width: 10),
                Text("Фоновий захист активний", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(height: 30),

            // Розділ: Збережені пристрої
            const Text("Збережені плати:", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _savedMacs.isEmpty
                ? const Text("Немає збережених плат. Знайдіть і виберіть пристрій нижче.", style: TextStyle(color: Colors.grey))
                : SizedBox(
                    height: 120,
                    child: ListView.builder(
                      itemCount: _savedMacs.length,
                      itemBuilder: (context, index) {
                        final mac = _savedMacs[index];
                        return Card(
                          color: Colors.grey[850],
                          child: ListTile(
                            leading: const Icon(Icons.bluetooth_connected, color: Colors.blueAccent),
                            title: Text(mac, style: const TextStyle(fontWeight: FontWeight.bold)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.redAccent),
                              onPressed: () => _removeMac(mac),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

            const SizedBox(height: 20),
            
            // Кнопка пошуку
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Сканування ефіру:", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ElevatedButton.icon(
                  onPressed: _isScanning ? null : _startScanning,
                  icon: _isScanning 
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: Text(_isScanning ? "Сканування..." : "Шукати плати"),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Список знайдених пристроїв
            Expanded(
              child: _scanResults.isEmpty
                  ? Center(
                      child: Text(
                        _isScanning ? "Шукаємо пристрої навколо..." : "Натисніть «Шукати плати», щоб знайти ESP32",
                        style: const TextStyle(color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _scanResults.length,
                      itemBuilder: (context, index) {
                        final r = _scanResults[index];
                        final deviceName = r.device.platformName.isNotEmpty ? r.device.platformName : "Невідомий пристрій";
                        final deviceMac = r.device.remoteId.str;

                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.bluetooth, color: Colors.green),
                            title: Text(deviceName),
                            subtitle: Text("MAC: $deviceMac\nСигнал: ${r.rssi} dBm"),
                            isThreeLine: true,
                            trailing: ElevatedButton(
                              onPressed: () => _saveMac(deviceMac),
                              child: const Text("Зберегти"),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}