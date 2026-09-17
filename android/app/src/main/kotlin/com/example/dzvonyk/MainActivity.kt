package com.example.dzvonyk

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    companion object {
        private const val TAG = "DzvonykMainActivity"
    }
    
    private val CHANNEL = "com.example.dzvonyk/service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.i(TAG, "🔧 [MAIN] Налаштування FlutterEngine та MethodChannel ('$CHANNEL')...")
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            Log.i(TAG, "📥 [CHANNEL] Отримано виклик з Dart: method='${call.method}'")
            
            when (call.method) {
                "startService" -> {
                    startDzvonykService()
                    result.success(true)
                    Log.i(TAG, "✅ [CHANNEL] Метод 'startService' успішно оброблено, повернуто результат true")
                }
                "saveMacAddress" -> {
                    val mac = call.argument<String>("mac")
                    if (!mac.isNullOrEmpty()) {
                        val prefs = getSharedPreferences("DzvonykPrefs", Context.MODE_PRIVATE)
                        val currentSet = prefs.getStringSet("target_macs", mutableSetOf()) ?: mutableSetOf()
                        val newSet = currentSet.toMutableSet()
                        newSet.add(mac)
                        prefs.edit().putStringSet("target_macs", newSet).apply()
                        
                        Log.i(TAG, "💾 [PREFS] Успішно збережено MAC-адресу плати: $mac")
                        result.success(true)
                    } else {
                        Log.w(TAG, "⚠️ [PREFS] Спроба зберегти порожню або невалідну MAC-адресу")
                        result.error("INVALID_MAC", "MAC-адреса не передана або порожня", null)
                    }
                }
                "getSavedMacs" -> {
                    val prefs = getSharedPreferences("DzvonykPrefs", Context.MODE_PRIVATE)
                    val currentSet = prefs.getStringSet("target_macs", mutableSetOf()) ?: mutableSetOf()
                    result.success(currentSet.toList())
                }
                "removeMacAddress" -> {
                    val mac = call.argument<String>("mac")
                    if (!mac.isNullOrEmpty()) {
                        val prefs = getSharedPreferences("DzvonykPrefs", Context.MODE_PRIVATE)
                        val currentSet = prefs.getStringSet("target_macs", mutableSetOf()) ?: mutableSetOf()
                        val newSet = currentSet.toMutableSet()
                        newSet.remove(mac)
                        prefs.edit().putStringSet("target_macs", newSet).apply()
                        
                        Log.i(TAG, "🗑️ [PREFS] Видалено MAC-адресу: $mac")
                        result.success(true)
                    } else {
                        result.error("INVALID_MAC", "MAC не передано", null)
                    }
                }
                else -> {
                    Log.w(TAG, "⚠️ [CHANNEL] Невідомий метод з Dart: '${call.method}'")
                    result.notImplemented()
                }
            }
        }
    }

    private fun startDzvonykService() {
        val intent = Intent(this, DzvonykService::class.java)
        Log.i(TAG, "⚙️ [SERVICE] Ініціалізація запуску DzvonykService з MainActivity (SDK: ${Build.VERSION.SDK_INT})...")
        
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
                Log.i(TAG, "🚀 [SERVICE] startForegroundService викликано успішно")
            } else {
                startService(intent)
                Log.i(TAG, "🚀 [SERVICE] startService викликано успішно")
            }
        } catch (e: Exception) {
            Log.e(TAG, "💥 [SERVICE] Помилка запуску сервісу з MainActivity: ${e.message}", e)
        }
    }
}