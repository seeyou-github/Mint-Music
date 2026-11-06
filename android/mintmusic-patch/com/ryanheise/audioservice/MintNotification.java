package com.ryanheise.audioservice;

import android.app.Notification;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Rect;
import android.graphics.RectF;
import android.os.Build;
import android.support.v4.media.MediaDescriptionCompat;
import android.support.v4.media.session.PlaybackStateCompat;
import android.view.View;
import android.widget.RemoteViews;

import androidx.core.app.NotificationCompat;

/**
 * MintMusic：自定义通知栏播放卡片（仅 Android）。
 *
 * <p>audio_service 默认用 {@code NotificationCompat.MediaStyle} 生成通知：封面以大图放在
 * 右侧、按钮只有「上一首 / 播放暂停 / 下一首」，样式无法改成设计稿那种「封面在左、
 * 歌名 + 五个按钮在右」的卡片。这里改成自绘 RemoteViews 布局
 * （{@code res/layout/mintmusic_notification_player.xml}），由
 * {@link AudioService#buildNotification()} 优先调用；任何一步失败（资源缺失、
 * 布局异常）都返回 {@code null}，调用方退回原来的 MediaStyle 通知，绝不会因为
 * 通知样式导致播放异常。
 *
 * <p>本文件位于 `android/mintmusic-patch/`，构建时被复制进 audio_service 的源码目录
 * （见 `android/build.gradle.kts`），因此包名必须是 {@code com.ryanheise.audioservice}
 * —— 只有同包才能拿到 {@code AudioService} 包内可见的
 * {@code buildMediaButtonPendingIntent()}。
 *
 * <p>布局里的资源全部用 {@code getIdentifier} 按名字取：本模块没有 app 的 R 类。
 * release 开了 shrinkResources，字符串引用的资源靠 `res/raw/keep.xml` 保住。
 */
public final class MintNotification {

    /** 收藏按钮的广播（由 app 模块的 NotificationActionReceiver 接住再转给 Dart）。 */
    public static final String ACTION_FAVORITE = "com.mintmusic.notification.FAVORITE";

    /** 歌词按钮：直接启动 MainActivity 并带上这个 action。 */
    public static final String ACTION_LYRIC = "com.mintmusic.notification.LYRIC";

    private static final int REQUEST_FAVORITE = 0x4D4D31;
    private static final int REQUEST_LYRIC = 0x4D4D32;

    /** 当前歌曲是否已收藏（由 Dart 侧通过 MethodChannel 同步过来）。 */
    private static boolean favorite = false;

    /** 封面圆角后的缓存：同一次通知重建里封面位图是同一个对象，不必重复裁剪。 */
    private static Bitmap cachedSource;
    private static Bitmap cachedRounded;

    private MintNotification() {}

    /** Dart 侧收藏状态变化时调用；状态真的变了才重绘通知。 */
    public static void setFavorite(boolean value) {
        if (favorite == value) return;
        favorite = value;
        // 与 AudioService 同包，可直接调用补丁里新增的刷新入口。
        AudioService.refreshNotification();
    }

    /**
     * 生成自定义通知；返回 {@code null} 表示「这次不用自定义样式」，调用方退回默认通知。
     */
    public static Notification build(
            AudioService service,
            NotificationCompat.Builder builder,
            MediaDescriptionCompat description,
            Bitmap art,
            boolean playing,
            boolean ongoing,
            PendingIntent contentIntent,
            PendingIntent stopIntent) {
        if (description == null || description.getTitle() == null) return null;
        try {
            final Context context = service;
            final int layoutId = res(context, "layout", "mintmusic_notification_player");
            final int coverId = res(context, "id", "mm_notif_cover");
            final int titleId = res(context, "id", "mm_notif_title");
            final int closeId = res(context, "id", "mm_notif_close");
            final int favoriteId = res(context, "id", "mm_notif_favorite");
            final int prevId = res(context, "id", "mm_notif_prev");
            final int playId = res(context, "id", "mm_notif_play");
            final int nextId = res(context, "id", "mm_notif_next");
            final int lyricId = res(context, "id", "mm_notif_lyric");
            if (layoutId == 0 || coverId == 0 || titleId == 0 || playId == 0) return null;

            final RemoteViews views = new RemoteViews(context.getPackageName(), layoutId);

            // 歌名：单行，超长由布局里的 ellipsize="end" 截断。
            views.setTextViewText(titleId, description.getTitle());

            // 封面：先按正方形居中裁剪，再把左侧两个角切圆（右侧贴着卡片内部，保持直角）。
            final Bitmap cover = roundCover(context, art);
            if (cover != null) {
                views.setImageViewBitmap(coverId, cover);
            }

            // 播放 / 暂停图标跟着状态走。
            views.setImageViewResource(
                    playId,
                    playing
                            ? res(context, "drawable", "mm_ic_notif_pause")
                            : res(context, "drawable", "mm_ic_notif_play"));
            // 收藏状态：实心红心 / 空心。
            final int heartId = res(
                    context, "drawable", favorite ? "mm_ic_notif_heart_on" : "mm_ic_notif_heart_off");
            if (heartId != 0) views.setImageViewResource(favoriteId, heartId);

            // 上一首 / 播放暂停 / 下一首：走系统媒体键，和耳机线控、通知栏旧按钮同一条链路。
            views.setOnClickPendingIntent(
                    prevId, service.buildMediaButtonPendingIntent(PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS));
            views.setOnClickPendingIntent(
                    playId, service.buildMediaButtonPendingIntent(PlaybackStateCompat.ACTION_PLAY_PAUSE));
            views.setOnClickPendingIntent(
                    nextId, service.buildMediaButtonPendingIntent(PlaybackStateCompat.ACTION_SKIP_TO_NEXT));

            // 收藏：广播给 app 自己，不打开界面。
            final Intent favoriteIntent = new Intent(ACTION_FAVORITE);
            favoriteIntent.setPackage(context.getPackageName());
            views.setOnClickPendingIntent(
                    favoriteId, PendingIntent.getBroadcast(context, REQUEST_FAVORITE, favoriteIntent, piFlags()));

            // 歌词：启动应用并停在歌词页。
            final Intent lyricIntent = context.getPackageManager()
                    .getLaunchIntentForPackage(context.getPackageName());
            if (lyricIntent != null) {
                lyricIntent.setAction(ACTION_LYRIC);
                lyricIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                views.setOnClickPendingIntent(
                        lyricId, PendingIntent.getActivity(context, REQUEST_LYRIC, lyricIntent, piFlags()));
            }

            // 右上角关闭：与原 MediaStyle 的取消按钮一样 = 停止播放并移除通知。
            if (stopIntent != null) {
                views.setOnClickPendingIntent(closeId, stopIntent);
            } else {
                views.setViewVisibility(closeId, View.GONE);
            }

            // 点卡片本体打开应用（与系统媒体通知一致）。
            if (contentIntent != null) builder.setContentIntent(contentIntent);
            builder.setCustomContentView(views);
            builder.setCustomBigContentView(views);
            builder.setOngoing(ongoing);
            return builder.build();
        } catch (Throwable error) {
            android.util.Log.w("MintNotification", "自定义通知构建失败，退回默认样式", error);
            return null;
        }
    }

    /** 通知卡片的封面尺寸（与布局里的 108dp 对应）。 */
    private static Bitmap roundCover(Context context, Bitmap art) {
        if (art == null || art.isRecycled()) return null;
        final float density = context.getResources().getDisplayMetrics().density;
        int size = Math.round(density * 108f);
        if (size <= 0) return null;
        // 通知走 Binder 传输，位图太大有 1MB 事务上限的风险，这里封顶 288px
        // （108dp 的缩略图在 xxhdpi 上也就 324px，缩到 288 肉眼看不出来）。
        if (size > 288) size = 288;
        final float radius = Math.min(density * 14f, size / 2f);
        if (art == cachedSource && cachedRounded != null && cachedRounded.getWidth() == size) {
            return cachedRounded;
        }
        try {
            final int width = art.getWidth();
            final int height = art.getHeight();
            final int side = Math.min(width, height);
            final Bitmap output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
            final Canvas canvas = new Canvas(output);
            final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
            final Path path = new Path();
            // 只切左侧两个角：封面贴在卡片左边缘，右侧要直接接上卡片底色。
            path.addRoundRect(
                    new RectF(0f, 0f, size, size),
                    new float[] {radius, radius, 0f, 0f, 0f, 0f, radius, radius},
                    Path.Direction.CW);
            canvas.save();
            canvas.clipPath(path);
            canvas.drawBitmap(
                    art,
                    new Rect((width - side) / 2, (height - side) / 2,
                            (width + side) / 2, (height + side) / 2),
                    new Rect(0, 0, size, size),
                    paint);
            canvas.restore();
            cachedSource = art;
            cachedRounded = output;
            return output;
        } catch (Throwable error) {
            android.util.Log.w("MintNotification", "封面裁剪失败", error);
            return null;
        }
    }

    private static int res(Context context, String type, String name) {
        return context.getResources().getIdentifier(name, type, context.getPackageName());
    }

    private static int piFlags() {
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;
        return flags;
    }
}
