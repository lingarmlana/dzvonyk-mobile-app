package com.example.dzvonyk

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.telephony.TelephonyManager
import android.util.Log

class CallReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "DzvonykCallReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        Log.i(TAG, "📥 [CallReceiver] Отримано системний інтент з action: '$action'")

        if (action == Intent.ACTION_BOOT_COMPLETED) {
            Log.i(TAG, "🔄 [BOOT] Телефон перезавантажено. Запускаємо фоновий сервіс...")
            val serviceIntent = Intent(context, DzvonykService::class.java)
            startServiceSafely(context, serviceIntent)
            return
        }

        if (action == "android.intent.action.PHONE_STATE") {
            val stateStr = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
            val incomingNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER) ?: "2"

            Log.i(TAG, "📞 [PHONE_STATE] Стан дзвінка: '$stateStr' | Номер: '$incomingNumber'")

            val status = when (stateStr) {
                TelephonyManager.EXTRA_STATE_RINGING -> "ring"
                TelephonyManager.EXTRA_STATE_IDLE -> "stop"
                else -> {
                    Log.w(TAG, "⚠️ [PHONE_STATE] Невідомий або проміжний стан дзвінка: '$stateStr'")
                    null
                }
            }

            if (status != null) {
                Log.i(TAG, "🎯 [PHONE_STATE] Статус успішно переведено в команду: '$status'. Запускаємо сервіс...")
                val serviceIntent = Intent(context, DzvonykService::class.java)
                startServiceSafely(context, serviceIntent)

                val eventIntent = Intent("com.example.dzvonyk.ACTION_CALL_EVENT").apply {
                    putExtra("status", status)
                    putExtra("number", incomingNumber)
                    setPackage(context.packageName)
                }
                context.sendBroadcast(eventIntent)
                Log.i(TAG, "📤 [BROADCAST] Відправлено внутрішній бродкаст ACTION_CALL_EVENT з параметрами status=$status, number=$incomingNumber")
            }
        }
    }

    private fun startServiceSafely(context: Context, intent: Intent) {
        try {
            Log.i(TAG, "⚙️ [Service] Спроба безпечного запуску фонового сервісу (SDK: ${Build.VERSION.SDK_INT})...")
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
                Log.i(TAG, "✅ [Service] startForegroundService викликано успішно")
            } else {
                context.startService(intent)
                Log.i(TAG, "✅ [Service] startService викликано успішно")
            }
        } catch (e: Exception) {
            Log.e(TAG, "💥 [Service] Помилка запуску сервісу: ${e.message}", e)
        }
    }
}