package com.kingmc.mintmusic.mintmusic

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.ryanheise.audioservice.MintNotification

/**
 * 通知栏卡片「收藏 / 桌面歌词 / 关闭」按钮的广播接收器。
 *
 * `MintNotification` 在 audio_service 模块里，拿不到 app 模块的类，所以按钮只发一个
 * 带包名的广播（`com.mintmusic.notification.*`），由这里转给
 * [PlayerNotificationChannel]，再由它转给 Dart。
 *
 * 三个按钮都不打开界面：收藏改收藏状态、桌面歌词切浮窗、关闭是停止播放并收起通知。
 */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            MintNotification.ACTION_FAVORITE ->
                PlayerNotificationChannel.dispatch(PlayerNotificationChannel.ACTION_FAVORITE)

            MintNotification.ACTION_LYRIC ->
                PlayerNotificationChannel.dispatch(PlayerNotificationChannel.ACTION_LYRIC)

            MintNotification.ACTION_CLOSE ->
                PlayerNotificationChannel.dispatch(PlayerNotificationChannel.ACTION_CLOSE)
        }
    }
}
