import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    await _requestPermissions();
    await _loadSavedMacs();
    _startAndroidService(); // Автозапуск фонового сервісу
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  // 1. Запит дозволів
  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
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

    // Підписуємося на результати сканування
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _scanResults = results;
      });
    });

    try {
      // Запускаємо сканування на 5 секунд
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
      await _loadSavedMacs(); // Оновлюємо список на екрані
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
                        final deviceMac = r.device.remoteId.str; // MAC-адреса

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