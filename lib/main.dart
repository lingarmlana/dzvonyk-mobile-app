import 'dart:async';
import 'package:flutter/material.dart';
import 'package:phone_state/phone_state.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dzvonyk BLE',
      theme: ThemeData(primarySwatch: Colors.blue),
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
  String _status = "Ініціалізація BLE...";
  String _incomingNumber = "Номер відсутній";
  
  BluetoothDevice? _targetDevice;
  BluetoothCharacteristic? _targetCharacteristic;
  bool _isConnected = false;
  
  // UUID з нашої прошивки ESP32
  final String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String characteristicUuid = "beb5483e-36e1-4688-b7f5-ea07361b26aade";

  @override
  void initState() {
    super.initState();
    _initPermissionsAndBle();
  }

  Future<void> _initPermissionsAndBle() async {
    // Запитуємо дозволи на телефоні та Bluetooth
    var statusPhone = await Permission.phone.request();
    var statusContact = await Permission.contacts.request();
    var statusBleScan = await Permission.bluetoothScan.request();
    var statusBleConnect = await Permission.bluetoothConnect.request();
    var statusLocation = await Permission.location.request(); // Потрібно для BLE на Android/iOS

    if (statusPhone.isGranted && statusBleConnect.isGranted) {
      setState(() {
        _status = "Шукаємо ESP32 в ефірі...";
      });

      // Запускаємо пошук та підключення до плати
      _startBleScanning();
      
      // Запускаємо прослуховування дзвінків
      _initPhoneStateListener();
    } else {
      setState(() {
        _status = "Необхідні дозволи не надано!";
      });
    }
  }

  // Сканування та підключення до ESP32 по UUID
  void _startBleScanning() async {
    // Перевіряємо чи увімкнений Bluetooth
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      setState(() { _status = "Увімкніть Bluetooth!"; });
      return;
    }

    // Слухаємо стан підключення
    FlutterBluePlus.events.onConnectionStateChanged.listen((event) {
      if (event.connectionState == BluetoothConnectionState.disconnected) {
        setState(() {
          _isConnected = false;
          _status = "Зв'язок втрачено. Перепідключення...";
        });
        _startBleScanning(); // Пробуємо знайти знову, якщо роз'єдналося
      }
    });

    // Шукаємо пристрої, фільтруя за нашим сервісом
    FlutterBluePlus.startScan(
      withServices: [Guid(serviceUuid)],
      timeout: const Duration(seconds: 15),
    );

    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult result in results) {
        if (result.advertisementData.serviceUuids.contains(Guid(serviceUuid))) {
          await FlutterBluePlus.stopScan();
          
          setState(() {
            _status = "Знайдено плату! Підключення...";
          });

          _targetDevice = result.device;
          await _connectToDevice();
          break;
        }
      }
    });
  }

  Future<void> _connectToDevice() async {
    if (_targetDevice == null) return;

    try {
      await _targetDevice!.connect(timeout: const Duration(seconds: 5));
      
      // Шукаємо сервіси та характеристики
      List<BluetoothService> services = await _targetDevice!.discoverServices();
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUuid.toLowerCase()) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toLowerCase() == characteristicUuid.toLowerCase()) {
              _targetCharacteristic = characteristic;
              setState(() {
                _isConnected = true;
                _status = "Підключено до Dzvonyk_ESP32!";
              });
              return;
            }
          }
        }
      }
    } catch (e) {
      setState(() {
        _status = "Помилка підключення: $e";
        _isConnected = false;
      });
      // Повторюємо спробу через 3 секунди
      Timer(const Duration(seconds: 3), _startBleScanning);
    }
  }

  // Відправка команди на ESP32 через BLE
  Future<void> _sendBleCommand(String status, String number) async {
    if (!_isConnected || _targetCharacteristic == null) {
      print("BLE Помилка: немає активного підключення для відправки команди");
      return;
    }

    try {
      String message = "$status:$number";
      await _targetCharacteristic!.write(message.codeUnits, withoutResponse: true);
      print("BLE Команда успішно відправлена: $message");
    } catch (e) {
      print("BLE Помилка запису: $e");
    }
  }

  // Прослуховування дзвінків
  void _initPhoneStateListener() {
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
          _status = "Вже не звенить";
          _sendBleCommand("stop", _incomingNumber);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dzvonyk BLE Control')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
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
            ],
          ),
        ),
      ),
    );
  }
}