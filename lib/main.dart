import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart';
import 'package:phone_state/phone_state.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Инициализируем фоновый сервис при старте приложения
  await initializeService();
  runApp(const MyApp());
}

Future<void> showFullScreenAlert() async {
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
    'dzvonyk_alarm_channel',
    'Дзвоник Тревога',
    channelDescription: 'Полноэкранные уведомления о вызове',
    importance: Importance.max,
    priority: Priority.high,
    fullScreenIntent: true,
    category: AndroidNotificationCategory.call,
  );

  const NotificationDetails platformChannelSpecifics =
      NotificationDetails(android: androidPlatformChannelSpecifics);

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin.show(
    id: 0,
    title: 'Внимание!',
    body: 'Сигнал от устройства Forest Stone!',
    notificationDetails: platformChannelSpecifics,
  );
}

Future<void> requestBatteryOptimization() async {
  var status = await Permission.ignoreBatteryOptimizations.status;
  if (!status.isGranted) {
    await Permission.ignoreBatteryOptimizations.request();
  }
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'dzvonyk_foreground',
    'Dzvonyk Background Service',
    description: "Підтримує зв'язок з пристроєм Дзвоник",
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'dzvonyk_foreground',
      initialNotificationTitle: 'Дзвоник працює у фоні',
      initialNotificationContent: 'Підключення до плати активне',
      foregroundServiceNotificationId: 888,
    ),

    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
  
  service.startService();
}

// Эта функция выполняется в отдельном фоновом потоке
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }

  // Фоновый пульс для удержания службы активной
  Timer.periodic(const Duration(seconds: 10), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: "Дзвоник активний",
          content: "Зв'язок з платою підтримується",
        );
      }
    }
  });
}

@pragma('vm:entry-point')
bool onIosBackground(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Дзвоник',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
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
  String _status = "Шукаємо Дзвоник в ефірі...";
  String _incomingNumber = "Номер відсутній";
  
  BluetoothDevice? _targetDevice;
  BluetoothCharacteristic? _targetCharacteristic;
  bool _isConnected = false;
  
  StreamSubscription<OnConnectionStateChangedEvent>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  StreamSubscription<List<int>>? _characteristicValueSubscription;

  String _lastAckStatus = ""; 
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _initConnectionStateListener();
    _initAdapterStateListener();
    _requestPermissionsAndStart();
  }

  @override
  void dispose() {
    _connectionStateSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _characteristicValueSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  void _initConnectionStateListener() {
    _connectionStateSubscription = FlutterBluePlus.events.onConnectionStateChanged.listen((event) {
      if (_targetDevice != null && event.device.remoteId == _targetDevice!.remoteId) {
        if (event.connectionState == BluetoothConnectionState.disconnected) {
          _characteristicValueSubscription?.cancel();
          setState(() {
            _isConnected = false;
            _targetCharacteristic = null;
            _status = "Зв'язок втрачено. Перепідключення...";
          });
          Timer(const Duration(seconds: 2), _startBleScanning);
        }
      }
    });
  }

  void _initAdapterStateListener() {
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        if (!_isConnected) {
          print("BLE: Bluetooth увімкнено, запускаємо пошук пристрою...");
          Timer(const Duration(seconds: 1), _startBleScanning);
        }
      } else if (state == BluetoothAdapterState.off) {
        _characteristicValueSubscription?.cancel();
        setState(() {
          _isConnected = false;
          _targetCharacteristic = null;
          _status = "Bluetooth вимкнено!";
        });
      }
    });
  }

  Future<void> _requestPermissionsAndStart() async {
    await [
      Permission.phone,
      Permission.contacts,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    // Запрос на игнорирование оптимизации батареи для стабильности фона
    await requestBatteryOptimization();

    setState(() {
      _status = "Шукаємо ESP32 в ефірі...";
    });

    _startBleScanning();
    _initPhoneStateListener();
  }

  void _startBleScanning() async {
    if (_isConnected) return;

    try {
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        setState(() { _status = "Увімкніть Bluetooth!"; });
        return;
      }

      await FlutterBluePlus.stopScan();
      _scanResultsSubscription?.cancel();

      setState(() {
        _status = "Шукаємо Дзвоник в ефірі...";
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

      bool deviceFound = false;

      _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult result in results) {
          bool hasOurService = result.advertisementData.serviceUuids
              .contains("4fafc201-1fb5-459e-8fcc-c5c9c331914b");

          String deviceName = result.device.platformName.isNotEmpty 
              ? result.device.platformName 
              : result.device.name;

          if (hasOurService || deviceName.startsWith("Dzvonyk")) {
            if (deviceFound) return;
            deviceFound = true;

            await FlutterBluePlus.stopScan();
            _scanResultsSubscription?.cancel();
            
            setState(() {
              _status = "Дзвоник знайдено! Підключення...";
            });

            _targetDevice = result.device;
            await _connectToDevice();
            break;
          }
        }
      });

      Future.delayed(const Duration(seconds: 15), () {
        if (!_isConnected && !deviceFound && mounted) {
          print("Час сканування вийшов, повторюємо пошук...");
          FlutterBluePlus.stopScan();
          _scanResultsSubscription?.cancel();
          _startBleScanning();
        }
      });

    } catch (e) {
      setState(() {
        _status = "Помилка сканування: $e";
      });
      Timer(const Duration(seconds: 3), _startBleScanning);
    }
  }

  Future<void> _connectToDevice() async {
    if (_targetDevice == null) return;

    try {
      setState(() {
        _status = "Підключення до ${_targetDevice!.platformName.isNotEmpty ? _targetDevice!.platformName : 'пристрою'}...";
      });

      try {
        await _targetDevice!.disconnect();
      } catch (_) {}
      
      await Future.delayed(const Duration(milliseconds: 500));

      print("BLE: Підключаємося до пристрою...");
      await _targetDevice!.connect(autoConnect: false, timeout: const Duration(seconds: 10));
      print("BLE: Успішно підключено! Шукаємо сервіси...");
      
      List<BluetoothService> services = await _targetDevice!.discoverServices();
      
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString().toLowerCase() == "BEB5483E-36E1-4688-B7F5-EA07361B26AA".toLowerCase()) {
            _targetCharacteristic = characteristic;

            await _targetCharacteristic!.setNotifyValue(true);
            _characteristicValueSubscription?.cancel();
            _characteristicValueSubscription = _targetCharacteristic!.lastValueStream.listen((value) {
              if (value.isNotEmpty) {
                String incomingString = utf8.decode(value);
                print("[BLE Вхідні дані] Отримано від плати: $incomingString");

                if (incomingString.startsWith("ack:")) {
                  String ackStatus = incomingString.substring(4);
                  _lastAckStatus = ackStatus; 
                } 
                else if (incomingString.startsWith("find:start")) {
                  print("🔔 [Пошук телефону] Натиснута кнопка на платі! Запускаємо пошук...");
                  _triggerPhoneAlarm();
                } 
                else if (incomingString.startsWith("find:stop")) {
                  print("🔕 [Пошук телефону] Зупинка пошуку з плати.");
                  _stopPhoneAlarm();
                }
              }
            });

            setState(() {
              _isConnected = true;
              _status = "Підключено до пристрою!";
            });
            print("BLE: Характеристику знайдено, Notify активовано!");
            return;
          }
        }
      }
      
      setState(() {
        _status = "Помилка: характеристику не знайдено";
      });
    } catch (e) {
      setState(() {
        _status = "Помилка підключення: $e";
        _isConnected = false;
      });
      Timer(const Duration(seconds: 3), _startBleScanning);
    }
  }

  void _triggerPhoneAlarm() async {
    if (!mounted) return;

    await FlutterVolumeController.setAndroidAudioStream(stream: AudioStream.alarm);
    await FlutterVolumeController.setVolume(0.2); // Увеличено до 1.0 для реальной тревоги

    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.play(AssetSource('media/alarm.mp3'));
    } catch (e) {
      print("Помилка відтворення звуку: $e");
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.red.shade900,
        title: const Text("🚨 Телефон шукають!", style: TextStyle(color: Colors.white)),
        content: const Text("Гучність викручено на максимум. Шукайте у пальто!", style: TextStyle(color: Colors.white70)),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.red),
            onPressed: () {
              _stopPhoneAlarm();
              _sendBleCommand("stop", "2");
              Navigator.of(context).pop();
            },
            child: const Text("Знайшли! Зупинити"),
          ),
        ],
      ),
    );
  }

  void _stopPhoneAlarm() {
    _audioPlayer.stop();

    if (Navigator.canPop(context)) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _sendBleCommand(String status, String number) async {
    if (!_isConnected || _targetCharacteristic == null) {
      print("BLE Помилка: немає активного підключення");
      return;
    }

    String trackNumber = "2"; 
    final String message = "$status:$trackNumber";
    const int maxAttempts = 3; 
    const Duration timeoutDuration = Duration(milliseconds: 1000); 

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        print("[BLE] Спроба $attempt: Відправка команди $message...");
        _lastAckStatus = "";

        await _targetCharacteristic!.write(message.codeUnits, withoutResponse: true);

        int msWait = 0;
        while (msWait < timeoutDuration.inMilliseconds) {
          if (_lastAckStatus == status) {
            print("🎉 [BLE] Успішно! Отримано підтвердження (ACK) для: $status");
            return;
          }
          await Future.delayed(const Duration(milliseconds: 50));
          msWait += 50;
        }

        print("⚠️ [BLE] Таймер вийшов. Плата не відповіла на спробу $attempt.");
      } catch (e) {
        print("❌ [BLE] Помилка відправки на спробі $attempt: $e");
      }
    }

    print("🚨 [BLE] Критична помилка: Не вдалося доставити команду $status після $maxAttempts спроб!");
  }

  void _initPhoneStateListener() {
    try {
      PhoneState.stream.listen((event) {
        setState(() {
          if (event.number != null && event.number!.isNotEmpty) {
            _incomingNumber = event.number!;
          }

          if (event.status == PhoneStateStatus.CALL_INCOMING) {
            _status = "УВАГА: Вхідний дзвінок!";
            _sendBleCommand("ring", _incomingNumber);
          } else if (event.status == PhoneStateStatus.CALL_STARTED ||
                     event.status == PhoneStateStatus.CALL_ENDED ||
                     event.status == PhoneStateStatus.NOTHING) { 
            _status = "Вже не дзвенить";
            _sendBleCommand("stop", _incomingNumber);
          }
        });
      });
    } catch (e) {
      print("Помилка ініціалізації прослуховування дзвінків: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Дзвоник')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              Icon(
                _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                size: 64,
                color: _isConnected ? Colors.green : Colors.orange,
              ),
              const SizedBox(height: 20),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              Text(
                "Номер: $_incomingNumber",
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, color: Colors.blueGrey),
              ),
              const SizedBox(height: 40),
              FilledButton.icon(
                onPressed: _isConnected ? () => _sendBleCommand("ring", "2") : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text("Тест Ring (2)"),
                style: FilledButton.styleFrom(backgroundColor: Colors.green),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isConnected ? () => _sendBleCommand("stop", "2") : null,
                icon: const Icon(Icons.stop),
                label: const Text("Тест Stop (2)"),
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
              ),
            ],
          ),
        ),
      ),
    );
  }
}