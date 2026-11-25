package org.mewx.wenku8_flutter

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Flutter plugin exposing [OnlineSessionStore] over `org.mewx.wenku8/online_session`.
 *
 * All KeyStore/AES-GCM crypto and SharedPreferences disk I/O run serially on a
 * dedicated background thread, and error responses never include session secrets.
 */
class OnlineSessionPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var store: OnlineSessionStore? = null
    private var io: ExecutorService? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        store = OnlineSessionStore(binding.applicationContext)
        io = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "online-session-store").apply { isDaemon = true }
        }
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        store = null
        io?.shutdown()
        io = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val method = call.method
        if (method != METHOD_READ && method != METHOD_WRITE && method != METHOD_CLEAR) {
            result.notImplemented()
            return
        }

        val writePayload: String? = if (method == METHOD_WRITE) {
            extractPayload(call.arguments) ?: run {
                result.error(ERROR_INVALID_ARGUMENT, MESSAGE_INVALID_ARGUMENT, null)
                return
            }
        } else {
            null
        }

        val executor = io
        val sessionStore = store
        if (executor == null || sessionStore == null || executor.isShutdown) {
            result.error(ERROR_STORAGE, MESSAGE_STORAGE_UNAVAILABLE, null)
            return
        }

        try {
            executor.execute {
                try {
                    when (method) {
                        METHOD_READ -> {
                            val value = sessionStore.read()
                            main.post { result.success(value) }
                        }
                        METHOD_WRITE -> {
                            sessionStore.write(requireNotNull(writePayload))
                            main.post { result.success(null) }
                        }
                        METHOD_CLEAR -> {
                            sessionStore.clear()
                            main.post { result.success(null) }
                        }
                    }
                } catch (_: IllegalArgumentException) {
                    main.post {
                        result.error(ERROR_INVALID_ARGUMENT, MESSAGE_INVALID_ARGUMENT, null)
                    }
                } catch (_: Exception) {
                    main.post {
                        result.error(ERROR_STORAGE, MESSAGE_STORAGE_FAILED, null)
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error(ERROR_STORAGE, MESSAGE_STORAGE_UNAVAILABLE, null)
        }
    }

    private fun extractPayload(arguments: Any?): String? = when (arguments) {
        is Map<*, *> -> arguments[ARG_PAYLOAD] as? String
        is String -> arguments
        else -> null
    }

    companion object {
        const val CHANNEL_NAME = "org.mewx.wenku8/online_session"

        private const val METHOD_READ = "read"
        private const val METHOD_WRITE = "write"
        private const val METHOD_CLEAR = "clear"
        private const val ARG_PAYLOAD = "payload"

        private const val ERROR_INVALID_ARGUMENT = "invalid_argument"
        private const val ERROR_STORAGE = "secure_storage"

        private const val MESSAGE_INVALID_ARGUMENT = "会话数据无效或超出大小限制"
        private const val MESSAGE_STORAGE_UNAVAILABLE = "本机安全会话存储暂不可用"
        private const val MESSAGE_STORAGE_FAILED = "无法读取或保存本机登录会话，请重试"
    }
}
