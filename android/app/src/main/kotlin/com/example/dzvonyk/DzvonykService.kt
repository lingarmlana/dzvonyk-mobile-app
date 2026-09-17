package com.example.dzvonyk

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.util.UUID

class DzvonykService : Service() {

    companion object {
        private const val TAG = "DzvonykNativeService"
        private const val CHANNEL_ID = "dzvonyk_foreground"
        private const val NOTIFICATION_ID = 888

        private val SERVICE_UUID = UUID.fromString("4fafc201-1fb5-459e-8fcc-c5c9c331914b")
        private val CHAR_UUID = UUID.fromString("BEB5483E-36E1-4688-B7F5-EA07361B26AA")
        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb") // Descriptor для нотифікацій
    }

    // Зберігаємо стан для кожного підключеного пристрою окремо за його MAC-адресою
    private class DeviceHolder(
        val mac: String,
        var bluetoothGatt: BluetoothGatt? = null,
        var targetCharacteristic: BluetoothGattCharacteristic? = null,
        var isConnected: Boolean = false,
        var isGattReady: Boolean = false,
        var descriptorWritten: Boolean = false
    )

    private val connectedDevices = mutableMapOf<String, DeviceHolder>()
    private val handler = Handler(Looper.getMainLooper())
    private val pendingCommandsQueue = mutableListOf<String>()

    private val callReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val status = intent.getStringExtra("status") ?: "stop"
            val number = intent.getStringExtra("number") ?: "2"
            Log.i(TAG, "📞 [CALL EVENT] Отримано дзвінок через Broadcast -> Status: '$status', Number: '$number'")
            sendBleCommandToAll(status, number)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "🚀 [SERVICE] DzvonykService успішно створено (onCreate)")
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification("Підключення до плат..."))

        // Реєстрація ресивера дзвінків
        val filter = IntentFilter("com.example.dzvonyk.ACTION_CALL_EVENT")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(callReceiver, filter, RECEIVER_NOT_EXPORTED)
            Log.i(TAG, "📡 [RECEIVER] Зареєстровано callReceiver (TIRAMISU+ / NOT_EXPORTED)")
        } else {
            registerReceiver(callReceiver, filter)
            Log.i(TAG, "📡 [RECEIVER] Зареєстровано callReceiver (стандартний)")
        }

        // Підключаємося до всіх збережених плат при старті сервісу
        connectAllSavedDevices()
    }

    private fun getSavedDeviceAddresses(): Set<String> {
        val prefs = getSharedPreferences("DzvonykPrefs", Context.MODE_PRIVATE)
        return prefs.getStringSet("target_macs", emptySet()) ?: emptySet()
    }

    private fun connectAllSavedDevices() {
        val macs = getSavedDeviceAddresses()
        if (macs.isEmpty()) {
            Log.w(TAG, "⚠️ [GATT] Немає збережених MAC-адрес плат у SharedPreferences!")
            updateNotification("Немає збережених плат")
            return
        }

        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bluetoothAdapter = bluetoothManager.adapter

        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "❌ [GATT] Bluetooth вимкнено!")
            updateNotification("Bluetooth вимкнено")
            return
        }

        for (mac in macs) {
            try {
                val device = bluetoothAdapter.getRemoteDevice(mac)
                val holder = DeviceHolder(mac = mac)
                connectedDevices[mac] = holder
                connectToDevice(holder, device)
            } catch (e: Exception) {
                Log.e(TAG, "❌ [GATT] Помилка ініціалізації для $mac: ${e.message}")
            }
        }
    }

    private fun connectToDevice(holder: DeviceHolder, device: BluetoothDevice) {
        Log.i(TAG, "🔗 [GATT] Підключаємося до плати ${holder.mac}...")

        holder.bluetoothGatt = device.connectGatt(this, false, object : BluetoothGattCallback() {

            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.e(TAG, "❌ [GATT] Помилка для ${holder.mac}, статус: $status. Закриваємо...")
                    closeGatt(holder)
                    scheduleReconnection(holder)
                    return
                }

                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    Log.i(TAG, "✅ [GATT] Підключено до ESP32 (${holder.mac})! Запит сервісів...")
                    holder.descriptorWritten = false
                    gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    Log.i(TAG, "❌ [GATT] З'єднання з ${holder.mac} втрачено. Перепідключення...")
                    closeGatt(holder)
                    scheduleReconnection(holder)
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    val service = gatt.getService(SERVICE_UUID)
                    if (service != null) {
                        holder.targetCharacteristic = service.getCharacteristic(CHAR_UUID)
                        val characteristic = holder.targetCharacteristic

                        if (characteristic != null && !holder.descriptorWritten) {
                            holder.descriptorWritten = true
                            Log.i(TAG, "⭐ [GATT] Характеристику знайдено для ${holder.mac}, налаштовуємо нотифікації...")

                            gatt.setCharacteristicNotification(characteristic, true)
                            val descriptor = characteristic.getDescriptor(CCCD_UUID)
                            if (descriptor != null) {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                    gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                                } else {
                                    @Suppress("DEPRECATION")
                                    descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                                    @Suppress("DEPRECATION")
                                    gatt.writeDescriptor(descriptor)
                                }
                            } else {
                                markGattReady(holder)
                            }
                        }
                    } else {
                        Log.e(TAG, "❌ [GATT] Цільовий сервіс не знайдено на ${holder.mac}")
                    }
                }
            }

            override fun onDescriptorWrite(gatt: BluetoothGatt?, descriptor: BluetoothGattDescriptor?, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    Log.i(TAG, "✅ [GATT] Дескриптор записано для ${holder.mac}!")
                    markGattReady(holder)
                } else {
                    Log.w(TAG, "⚠️ [GATT] Помилка запису дескриптора для ${holder.mac}, статус: $status")
                }
            }

            override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                val value = characteristic.value
                if (value != null && value.isNotEmpty()) {
                    val incomingString = String(value, Charsets.UTF_8)
                    Log.i(TAG, "📥 [BLE READ] Від ${holder.mac}: '$incomingString'")
                }
            }

            override fun onCharacteristicWrite(gatt: BluetoothGatt?, characteristic: BluetoothGattCharacteristic?, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    Log.i(TAG, "👍 [BLE WRITE] Плата ${holder.mac} підтвердила приймання")
                } else {
                    Log.w(TAG, "⚠️ [BLE WRITE] Помилка запису для ${holder.mac}, статус: $status")
                }
            }
        }, BluetoothDevice.TRANSPORT_LE)
    }

    private fun markGattReady(holder: DeviceHolder) {
        holder.isConnected = true
        handler.postDelayed({
            holder.isGattReady = true
            Log.i(TAG, "🎉 [GATT] Плата ${holder.mac} повністю готова до роботи!")
            updateNotificationActiveStatus()

            // Виконуємо відкладені команди, якщо вони були в черзі
            if (pendingCommandsQueue.isNotEmpty()) {
                val cmd = pendingCommandsQueue.removeAt(0)
                val parts = cmd.split(":")
                if (parts.size == 2) {
                    executeWriteToDevice(holder, parts[0], parts[1])
                }
            }
        }, 400)
    }

    private fun scheduleReconnection(holder: DeviceHolder) {
        updateNotificationActiveStatus()
        handler.postDelayed({
            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            val bluetoothAdapter = bluetoothManager.adapter
            try {
                val device = bluetoothAdapter?.getRemoteDevice(holder.mac)
                if (device != null) {
                    connectToDevice(holder, device)
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ [GATT] Помилка повторного підключення до ${holder.mac}: ${e.message}")
            }
        }, 5000) // Повторна спроба через 5 секунд
    }

    private fun closeGatt(holder: DeviceHolder) {
        holder.isConnected = false
        holder.isGattReady = false
        holder.targetCharacteristic = null
        try {
            holder.bluetoothGatt?.close()
        } catch (_: Exception) {}
        holder.bluetoothGatt = null
    }

    private fun sendBleCommandToAll(status: String, number: String) {
        val message = "$status:$number"
        var sentAny = false

        for ((_, holder) in connectedDevices) {
            if (holder.isGattReady && holder.targetCharacteristic != null && holder.bluetoothGatt != null) {
                executeWriteToDevice(holder, status, number)
                sentAny = true
            }
        }

        if (!sentAny) {
            Log.w(TAG, "⚠️ [BLE] Жодна плата зараз не готова. Зберігаємо команду в чергу: '$message'")
            pendingCommandsQueue.add(message)
        }
    }

    private fun executeWriteToDevice(holder: DeviceHolder, status: String, number: String) {
        val message = "$status:$number"
        val bytes = message.toByteArray(Charsets.UTF_8)
        val gatt = holder.bluetoothGatt
        val characteristic = holder.targetCharacteristic

        if (gatt == null || characteristic == null) return

        Log.i(TAG, "📤 [BLE SEND] Надсилаємо на ${holder.mac} пакет: '$message'")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    bytes,
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                )
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = bytes
                @Suppress("DEPRECATION")
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
        } catch (e: Exception) {
            Log.e(TAG, "💥 [BLE SEND] Помилка запису для ${holder.mac}: ${e.message}", e)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Dzvonyk Background Service",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun createNotification(content: String): Notification {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Дзвоник працює у фоні")
                .setContentText(content)
                .setSmallIcon(android.R.drawable.ic_menu_info_details)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("Дзвоник працює у фоні")
                .setContentText(content)
                .setSmallIcon(android.R.drawable.ic_menu_info_details)
                .build()
        }
    }

    private fun updateNotification(content: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, createNotification(content))
    }

    private fun updateNotificationActiveStatus() {
        val total = connectedDevices.size
        val readyCount = connectedDevices.values.count { it.isGattReady }
        updateNotification("Підключено плат: $readyCount / $total")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.w(TAG, "⚠️ [SERVICE] Зупинка сервісу DzvonykService")
        handler.removeCallbacksAndMessages(null)

        try {
            unregisterReceiver(callReceiver)
        } catch (_: Exception) {}

        for ((_, holder) in connectedDevices) {
            closeGatt(holder)
        }
        connectedDevices.clear()
    }
}