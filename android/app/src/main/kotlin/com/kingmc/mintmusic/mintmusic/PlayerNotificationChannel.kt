package com.kingmc.mintmusic.mintmusic

import android.util.Log
import com.ryanheise.audioservice.MintNotification
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 通知栏播放卡片上「收藏 / 歌词」按钮与 Dart 之间的桥。
 *
 * 通知卡片由 audio_service 的 `MintNotification` 生成，按钮点击落地方式有两种：
 *  - 收藏：发广播 → [NotificationActionReceiver] → 这里 → Dart（不打开界面）；
 *  - 歌词：直接启动 MainActivity（intent action 为 [MintNotification.ACTION_LYRIC]）
 *    → 这里 → Dart 跳歌词页。
 *
 * 反方向（Dart → 原生）只有一个：`setFavorite`，把「当前歌曲是否已收藏」同步过来，
 * 通知里的红心据此显示实心 / 空心。
 */
object PlayerNotificationChannel {
    private const val TAG = "MintNotification"
    private const val CHANNEL = "mintmusic/notification"

    const val ACTION_FAVORITE = "favorite"
    const val ACTION_LYRIC = "lyric"

    private var channel: MethodChannel? = null

    /** Dart 还没准备好时（冷启动）先把动作存起来，等它启动后主动来取。 */
    private var pendingAction: String? = null

    /** 引擎重建时挂上通道（MainActivity.configureFlutterEngine）。 */
    fun attach(engine: FlutterEngine) {
        val methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeLaunchAction" -> {
                    val action = pendingAction
                    pendingAction = null
                    result.success(action)
                }
                "setFavorite" -> {
                    // 状态没变时 MintNotification 内部会直接返回，不会重绘通知。
                    MintNotification.setFavorite(call.arguments == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = methodChannel
    }

    /** 通知栏按钮点击 → 转给 Dart。Dart 还没准备好时先存着，等它启动后来取。 */
    fun dispatch(action: String) {
        val methodChannel = channel
        if (methodChannel == null) {
            pendingAction = action
            return
        }
        methodChannel.invokeMethod("action", action, object : MethodChannel.Result {
            override fun success(result: Any?) = Unit

            override fun error(code: String, message: String?, details: Any?) {
                Log.w(TAG, "通知栏动作处理失败($action): $message")
            }

            override fun notImplemented() {
                // Dart 侧还没注册处理器（理论上不会发生，兜底存起来）。
                pendingAction = action
            }
        })
    }
}
