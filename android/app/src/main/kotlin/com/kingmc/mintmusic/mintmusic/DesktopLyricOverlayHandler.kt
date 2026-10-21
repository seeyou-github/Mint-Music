package com.kingmc.mintmusic.mintmusic

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * 桌面歌词的系统级悬浮窗(Android)。
 *
 * 实现参考 lx-music-mobile 的 `LyricView.java` / `LyricSwitchView.java`:
 * - `WindowManager.addView` + `TYPE_APPLICATION_OVERLAY`,歌词可显示在其它应用之上;
 * - 锁定时追加 `FLAG_NOT_TOUCHABLE`,触摸事件完全穿透;
 * - 拖动结束时把像素坐标换算成**屏幕百分比**回传 Dart 保存;
 * - **窗口高度是显式计算的固定值**,换句时绝不触发 `updateViewLayout`;
 * - **歌词切换动画交给 `LyricSwitchView`(ViewSwitcher)双页交叉淡入淡出**。
 *
 * 后两点是不闪动的关键,详见 [LyricSwitchView] 的注释。
 */
class DesktopLyricOverlayHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    private data class LyricLineData(
        val time: Long,
        val text: String,
        val translation: String?,
        val roman: String?,
    )

    /** 一行待渲染的歌词:`isSub` 表示它是当前行的翻译/罗马音。 */
    private data class LyricRow(
        val text: String,
        val active: Boolean,
        val isSub: Boolean,
    )

    private val appContext = context.applicationContext
    private val windowManager: WindowManager =
        appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private var rootView: LinearLayout? = null
    private var lyricSwitcher: LyricSwitchView? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var backgroundDrawable: GradientDrawable? = null

    // ---- 配置 ----
    private var isLock = false
    private var maxLineNum = 1
    private var fontSizeSp = 18f
    private var opacity = 1f
    private var playedColor = Color.parseColor("#07C556")
    private var unplayColor = Color.WHITE
    private var shadowColor = Color.argb(153, 0, 0, 0)
    private var positionXPercent = 3.0
    private var positionYPercent = 8.0


    // ---- 歌词数据 ----
    private var lines: List<LyricLineData> = emptyList()
    private var activeIndex = -1
    private var showTranslation = true
    private var showRoman = true

    // ---- 拖动状态 ----
    private var lastTouchRawX = 0f
    private var lastTouchRawY = 0f
    private var dragging = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermission" -> result.success(hasOverlayPermission())
            "openPermissionSettings" -> result.success(openPermissionSettings())
            "show" -> result.success(show())
            "hide" -> {
                hide()
                result.success(true)
            }
            "isShowing" -> result.success(rootView != null)
            "updateConfig" -> {
                applyConfig(call.arguments as? Map<*, *>)
                result.success(true)
            }
            "updateLyric" -> {
                updateLyric(call.arguments as? Map<*, *>)
                result.success(true)
            }
            "setPlayState" -> {
                val args = call.arguments as? Map<*, *>
                val positionMs = (args?.get("positionMs") as? Number)?.toLong() ?: 0L
                applyPlayState(positionMs, args?.get("isPlaying") == true)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ 权限

    private fun hasOverlayPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(appContext)
        } else {
            true
        }
    }

    private fun openPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${appContext.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
            true
        } catch (_: Throwable) {
            false
        }
    }

    // ------------------------------------------------------------- 窗口生命周期

    private fun show(): Boolean {
        if (rootView != null) {
            applyContent(animate = false)
            return true
        }
        // 清理上一次运行(例如热重启)遗留的窗口,避免歌词窗重复叠加。
        releaseOrphanWindow()
        if (!hasOverlayPermission()) return false

        val root = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
        }
        val switcher = LyricSwitchView(appContext)
        root.addView(
            switcher,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ),
        )

        val lp = WindowManager.LayoutParams().apply {
            width = screenWidth().coerceAtLeast(120)
            height = contentHeight()
            type = overlayWindowType()
            format = PixelFormat.TRANSLUCENT
            gravity = Gravity.TOP or Gravity.START
            flags = buildFlags()
            alpha = windowAlpha()
        }

        root.setOnTouchListener(createTouchListener(root))

        return try {
            windowManager.addView(root, lp)
            activeRoot = root
            activeWindowManager = windowManager
            rootView = root
            lyricSwitcher = switcher
            layoutParams = lp
            applyBackground()
            rebuildHandle()
            // 歌词切换动画固定开启。
            switcher.setAnimated(true, slideDistancePx())
            applyContent(animate = false)
            // 首帧之后才能拿到真实高度,再按百分比精确定位一次。
            root.post { applyPositionPercent() }
            true
        } catch (error: Throwable) {
            Log.w(TAG, "addView failed", error)
            rootView = null
            lyricSwitcher = null
            layoutParams = null
            false
        }
    }

    private fun hide() {
        val root = rootView ?: return
        stopTicker()
        // 复位行号，下次 show 时才会重新写入内容（否则会被"行号未变"判断跳过）
        activeIndex = -1
        try {
            windowManager.removeView(root)
        } catch (_: Throwable) {
            // 窗口可能已经被系统回收。
        }
        if (activeRoot === root) {
            activeRoot = null
            activeWindowManager = null
        }
        rootView = null
        lyricSwitcher = null
        layoutParams = null
    }

    @Suppress("DEPRECATION")
    private fun overlayWindowType(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        }
    }

    private fun buildFlags(): Int {
        var flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        // 锁定 = 整个窗口不可触摸,事件穿透到下层应用。
        if (isLock) flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        return flags
    }

    // Android 12+ 系统对悬浮窗有最大不透明度限制,锁定态需要主动降到 0.8
    // 才能真正实现点击穿透(与 lx-music 的处理一致)。
    private fun windowAlpha(): Float {
        return if (isLock && Build.VERSION.SDK_INT > Build.VERSION_CODES.R) {
            opacity.coerceAtMost(0.8f)
        } else {
            opacity
        }
    }

    /**
     * 窗口高度：**显式计算的固定值**，不用 WRAP_CONTENT。
     *
     * lx-music 的 `setLayoutParamsHeight()` 也是这么做的
     * (`fontMetricsInt * maxLineNum`)。高度恒定意味着换句时窗口不需要重新测量、
     * 也不需要 `updateViewLayout` —— 这是不闪动的前提之一。
     */
    private fun contentHeight(): Int {
        val metrics = appContext.resources.displayMetrics
        val lineHeight = (fontSizeSp * metrics.scaledDensity * 1.35f).roundToInt()
        val visible = maxLineNum
        var height = lineHeight * visible + (if (isLock) 0 else handleHeightPx())
        val limit = screenHeight() - 100
        if (height > limit) height = limit
        return height.coerceAtLeast(1)
    }

    private fun handleHeightPx(): Int =
        (HANDLE_HEIGHT_DP * appContext.resources.displayMetrics.density).roundToInt()

    private fun slideDistancePx(): Float =
        fontSizeSp * appContext.resources.displayMetrics.scaledDensity

    private fun rebuildHandle() {
        val root = rootView ?: return
        // 移除已有的把手（保持在最前面）
        if (root.childCount > 1) {
            root.removeViewAt(0)
        }
        if (isLock) return

        val handle = TextView(appContext).apply {
            text = "桌面歌词"
            textSize = 10f
            setTextColor(Color.argb(140, 255, 255, 255))
            gravity = Gravity.CENTER_VERTICAL or Gravity.START
            setPadding(
                (8 * appContext.resources.displayMetrics.density).roundToInt(),
                0,
                0,
                0,
            )
            val h = handleHeightPx()
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                h,
            )
        }
        root.addView(handle, 0)
    }

    private fun applyBackground() {
        val root = rootView ?: return
        val drawable = backgroundDrawable ?: GradientDrawable().also { backgroundDrawable = it }
        drawable.cornerRadius = 10f * appContext.resources.displayMetrics.density
        if (isLock) {
            drawable.setColor(Color.TRANSPARENT)
            drawable.setStroke(0, Color.TRANSPARENT)
        } else {
            drawable.setColor(Color.argb(41, 0, 0, 0))
            drawable.setStroke(1, Color.argb(56, 255, 255, 255))
        }
        root.background = drawable
    }

    // ------------------------------------------------------------------ 配置

    private fun applyConfig(args: Map<*, *>?) {
        if (args == null) return
        isLock = args["isLock"] == true
        maxLineNum = (args["maxLineNum"] as? Number)?.toInt()?.coerceIn(1, 8) ?: maxLineNum
        fontSizeSp = (args["fontSize"] as? Number)?.toFloat()?.coerceIn(12f, 80f) ?: fontSizeSp
        opacity = ((args["opacityPercent"] as? Number)?.toFloat() ?: 85f) / 100f
        playedColor = (args["playedColor"] as? Number)?.toInt() ?: playedColor
        unplayColor = (args["unplayColor"] as? Number)?.toInt() ?: unplayColor
        shadowColor = (args["shadowColor"] as? Number)?.toInt() ?: shadowColor
        positionXPercent = (args["positionX"] as? Number)?.toDouble() ?: positionXPercent
        positionYPercent = (args["positionY"] as? Number)?.toDouble() ?: positionYPercent

        val root = rootView ?: return
        val lp = layoutParams ?: return
        lp.flags = buildFlags()
        lp.alpha = windowAlpha()
        // 悬浮窗宽度固定为屏幕宽度（100%）。
        lp.width = screenWidth().coerceAtLeast(120)
        lp.height = contentHeight()
        applyBackground()
        rebuildHandle()
        root.setOnTouchListener(createTouchListener(root))
        // 歌词切换动画固定开启。
        lyricSwitcher?.setAnimated(true, slideDistancePx())
        // 样式/尺寸变更不播放切换动画，直接改当前页
        applyContent(animate = false)
        root.post { applyPositionPercent() }
        safeUpdateLayout()
    }

    // ------------------------------------------------------------------ 歌词

    private fun updateLyric(args: Map<*, *>?) {
        val raw = args?.get("lines") as? List<*> ?: return
        lines = raw.mapNotNull { item ->
            val map = item as? Map<*, *> ?: return@mapNotNull null
            LyricLineData(
                time = (map["time"] as? Number)?.toLong() ?: 0L,
                text = map["text"] as? String ?: "",
                translation = map["translation"] as? String,
                roman = map["roman"] as? String,
            )
        }.sortedBy { it.time }
        showTranslation = args["showTranslation"] != false
        showRoman = args["showRoman"] != false
        // 换歌：直接刷新内容，不播放切换动画
        setActiveIndex((args["activeIndex"] as? Number)?.toInt() ?: 0, force = true)
        // 新歌词的时间轴变了，重新调度下一次换句
        refresh()
    }

    /// 更新当前行。**行号没变时直接返回**，不做任何重绘 —— 否则定时器每 250ms
    /// 都会打断正在播放的切换动画（表现为闪烁、淡入淡出时有时无）。
    private fun setActiveIndex(index: Int, force: Boolean = false) {
        if (!force && index == activeIndex) return
        val changed = index != activeIndex
        activeIndex = index
        applyContent(animate = changed && !force && lines.isNotEmpty())
    }

    /** 与 Dart 侧 `DesktopLyricPanel._buildRows` 保持一致的取行规则。 */
    private fun buildRows(): List<LyricRow> {
        if (lines.isEmpty()) return emptyList()
        val index = activeIndex.coerceIn(0, lines.size - 1)
        val rows = mutableListOf<LyricRow>()
        val max = maxLineNum

        for (i in index until lines.size) {
            if (rows.size >= max) break
            val line = lines[i]
            if (line.text.isNotBlank()) {
                rows.add(LyricRow(line.text, active = i == index, isSub = false))
            }
            if (i != index) continue
            if (showTranslation && !line.translation.isNullOrBlank() && rows.size < max) {
                rows.add(LyricRow(line.translation!!, active = true, isSub = true))
            }
            if (showRoman && !line.roman.isNullOrBlank() && rows.size < max) {
                rows.add(LyricRow(line.roman!!, active = true, isSub = true))
            }
        }
        return rows
    }

    /**
     * 写入歌词内容。
     *
     * **只操作 View，绝不调用 `windowManager.updateViewLayout`** —— 与 lx-music
     * 的 `setLyric()` 一致（它只做 `textView.setText()`)。窗口重排只在配置变更
     * 或旋转时发生，换句时窗口尺寸恒定，因此不会有额外的重绘帧。
     */
    private fun applyContent(animate: Boolean) {
        val switcher = lyricSwitcher ?: return
        val target = maxLineNum
        switcher.ensureRowCount(target) { newRowTextView() }
        switcher.setPageGravity(Gravity.CENTER_HORIZONTAL or Gravity.CENTER_VERTICAL)
        val rows = buildRows()
        switcher.showPage(animate) { page -> fillPage(page, rows) }
    }

    private fun newRowTextView(): TextView = TextView(appContext).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
        includeFontPadding = false
        setLineSpacing(0f, 1.25f)
        visibility = View.GONE
    }

    private fun fillPage(page: LyricSwitchView.Page, rows: List<LyricRow>) {
        for (i in page.rows.indices) {
            val tv = page.rows[i]
            if (i >= rows.size) {
                tv.visibility = View.GONE
                continue
            }
            val row = rows[i]
            tv.visibility = View.VISIBLE
            tv.text = row.text
            tv.setTextColor(if (row.active) playedColor else unplayColor)
            tv.setTextSize(
                TypedValue.COMPLEX_UNIT_SP,
                if (row.isSub) fontSizeSp * 0.62f else fontSizeSp,
            )
            tv.gravity = Gravity.CENTER_HORIZONTAL
            tv.setShadowLayer(4f, 1f, 1f, shadowColor)
            tv.setSingleLine()
            if (!row.isSub) {
                // 单行且超长时使用系统跑马灯横向滚动
                tv.ellipsize = TextUtils.TruncateAt.MARQUEE
                tv.marqueeRepeatLimit = -1
                tv.isSelected = true
            } else {
                tv.ellipsize = TextUtils.TruncateAt.END
                tv.marqueeRepeatLimit = 0
                tv.isSelected = false
            }
        }
    }

    // ------------------------------------------------------------------ 拖动

    @SuppressLint("ClickableViewAccessibility")
    private fun createTouchListener(root: View): View.OnTouchListener {
        return View.OnTouchListener { _, event ->
            val lp = layoutParams ?: return@OnTouchListener false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    lastTouchRawX = event.rawX
                    lastTouchRawY = event.rawY
                    dragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - lastTouchRawX
                    val dy = event.rawY - lastTouchRawY
                    lastTouchRawX = event.rawX
                    lastTouchRawY = event.rawY
                    lp.x = (lp.x + dx).roundToInt().coerceIn(0, maxOffsetX(root))
                    lp.y = (lp.y + dy).roundToInt().coerceIn(0, maxOffsetY(root))
                    dragging = true
                    safeUpdateLayout()
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) notifyPositionChanged(root)
                    dragging = false
                    true
                }
                else -> false
            }
        }
    }

    /** 拖动结束:像素坐标 -> 百分比,回传给 Dart 持久化。 */
    private fun notifyPositionChanged(root: View) {
        val lp = layoutParams ?: return
        val maxX = maxOffsetX(root)
        val maxY = maxOffsetY(root)
        val xPercent = if (maxX <= 0) 0.0 else (lp.x.toDouble() / maxX * 100.0)
        val yPercent = if (maxY <= 0) 0.0 else (lp.y.toDouble() / maxY * 100.0)
        positionXPercent = xPercent
        positionYPercent = yPercent
        channel?.invokeMethod(
            "onPositionChanged",
            mapOf("x" to xPercent, "y" to yPercent),
        )
    }

    private fun applyPositionPercent() {
        val root = rootView ?: return
        val lp = layoutParams ?: return
        lp.x = (maxOffsetX(root) * positionXPercent / 100.0).roundToInt()
            .coerceIn(0, maxOffsetX(root))
        // 顶部位置时避开状态栏（默认就在状态栏下方）。
        val topInset = if (positionYPercent <= 0.01) statusBarHeightPx() else 0
        lp.y = (topInset + (maxOffsetY(root) * positionYPercent / 100.0).roundToInt())
            .coerceIn(0, (screenHeight() - root.height).coerceAtLeast(0))
        safeUpdateLayout()
    }

    /// 状态栏高度（px）；取不到时返回 0。
    private fun statusBarHeightPx(): Int {
        return try {
            val id = appContext.resources.getIdentifier(
                "status_bar_height", "dimen", "android"
            )
            if (id > 0) {
                appContext.resources.getDimensionPixelSize(id)
            } else {
                0
            }
        } catch (_: Throwable) {
            0
        }
    }

    private fun maxOffsetX(root: View): Int {
        val vw = if (root.width > 0) root.width else lpWidth()
        return (screenWidth() - vw).coerceAtLeast(0)
    }

    private fun maxOffsetY(root: View): Int {
        val vh = if (root.height > 0) root.height else contentHeight()
        return (screenHeight() - vh).coerceAtLeast(0)
    }

    // 悬浮窗宽度固定为屏幕宽度（100%）。
    private fun lpWidth(): Int = screenWidth().coerceAtLeast(120)

    private fun safeUpdateLayout() {
        val root = rootView ?: return
        val lp = layoutParams ?: return
        try {
            windowManager.updateViewLayout(root, lp)
        } catch (_: Throwable) {
            // 窗口可能已被移除。
        }
    }

    private fun screenWidth(): Int = appContext.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = appContext.resources.displayMetrics.heightPixels

    // --------------------------------------------------- 歌词时钟(原生侧推进)
    //
    // 应用退到后台后 Dart 侧的进度回调不可靠(可能被节流/暂停),所以这里与
    // lx-music 的 `LyricPlayer.refresh()` 完全一致:Dart 只下发一次「进度锚点」,
    // 之后由原生侧用单调时钟自行推进,并且**按「到下一行的精确剩余时间」调度
    // 下一次刷新**,而不是固定周期轮询。
    //
    // 固定周期轮询(之前的 250ms)会让换句最多慢 250ms,叠加 Dart 侧的通道延迟
    // 就是用户感知的"慢半拍"。
    private val mainHandler = Handler(Looper.getMainLooper())
    private var playing = false
    private var anchorMediaMs = 0L
    private var anchorElapsedMs = 0L
    private var lastKnownMediaMs = 0L
    private var scheduled = false

    private val tickRunnable = Runnable {
        scheduled = false
        refresh()
    }

    /** 设置进度锚点;Dart 会定期重新下发以校准漂移。 */
    private fun applyPlayState(positionMs: Long, isPlaying: Boolean) {
        val wasPlaying = playing
        val estimate = if (wasPlaying) currentMediaTimeMs() else positionMs
        val delta = positionMs - estimate

        // 死区:通道延迟/抖动造成的微小偏差不重设时钟,否则会反复把时钟往回
        // 拽,跨过行边界时表现为"往回跳一下"的闪动 + 慢半拍。
        // 超过死区(暂停、起播、跳转、卡顿恢复)才重新锚定。
        if (!isPlaying ||
            !wasPlaying ||
            delta > ANCHOR_DEAD_BAND_MS ||
            delta < -ANCHOR_DEAD_BAND_MS
        ) {
            anchorMediaMs = positionMs
            anchorElapsedMs = SystemClock.elapsedRealtime()
        }
        lastKnownMediaMs = positionMs
        playing = isPlaying

        refresh()
        if (!isPlaying) setActiveIndex(indexForTime(lastKnownMediaMs))
    }

    /**
     * 重新计算当前行并调度下一次刷新(对齐 lx-music 的 `LyricPlayer.refresh`)。
     */
    private fun refresh() {
        scheduled = false
        if (rootView == null || !playing || lines.isEmpty()) return

        val now = currentMediaTimeMs()
        val index = indexForTime(now)

        // 回退保护:小幅回退(来自锚点修正的抖动)直接忽略,继续等下一行。
        // 只有明显跳转(> REWIND_GUARD_MS,例如用户拖动进度)才真的回退,
        // 否则歌词会出现"往回跳一下"的闪动。
        if (activeIndex >= 0 && index < activeIndex &&
            lines[activeIndex].time - now < REWIND_GUARD_MS
        ) {
            val next = activeIndex + 1
            if (next < lines.size) schedule(lines[next].time - now)
            return
        }

        val drift = now - lines[index].time
        // 时钟还没走到这一行(卡顿/跳转导致超前):等剩余时间再算一次。
        if (drift < 0 && index > 0) {
            schedule(-drift)
            return
        }

        setActiveIndex(index)

        // 已是最后一行,不需要再调度。
        if (index + 1 >= lines.size) return
        schedule(lines[index + 1].time - now)
    }

    private fun schedule(delayMs: Long) {
        cancelScheduled()
        scheduled = true
        mainHandler.postDelayed(tickRunnable, delayMs.coerceIn(0L, MAX_DELAY_MS))
    }

    private fun cancelScheduled() {
        if (scheduled) {
            mainHandler.removeCallbacks(tickRunnable)
            scheduled = false
        }
    }

    private fun currentMediaTimeMs(): Long {
        if (!playing) return lastKnownMediaMs
        return anchorMediaMs + (SystemClock.elapsedRealtime() - anchorElapsedMs)
    }

    /** 与 Dart 侧 `lastIndexWhere(startTimeMs <= t)` 相同。 */
    private fun indexForTime(timeMs: Long): Int {
        if (lines.isEmpty()) return 0
        var index = 0
        // 不提前 break:万一上游给的行未按时间排序也能得到正确结果。
        for (i in lines.indices) {
            if (lines[i].time <= timeMs) index = i
        }
        return index
    }

    private fun stopTicker() {
        playing = false
        cancelScheduled()
    }

    /** 由 MainActivity 注入,用于把拖动后的位置回传给 Dart。 */
    private var channel: MethodChannel? = null

    fun attachChannel(methodChannel: MethodChannel) {
        channel = methodChannel
    }

    companion object {
        private const val TAG = "MintDesktopLyric"
        private const val HANDLE_HEIGHT_DP = 22f
        /// 重新锚定的死区:偏差小于它时认为是通道延迟/抖动,不重设时钟。
        /// 取值要大于通道往返延迟(几十毫秒),又要远小于一句歌词的时长。
        private const val ANCHOR_DEAD_BAND_MS = 120L
        /// 回退保护阈值:小于它认为是抖动而非真实跳转,不回退行号。
        private const val REWIND_GUARD_MS = 1000L
        /// 单次调度的最长等待,避免异常数据导致长时间不刷新。
        private const val MAX_DELAY_MS = 60_000L

        /** 当前挂在 WindowManager 上的窗口,用于跨引擎实例清理残留。 */
        private var activeRoot: View? = null
        private var activeWindowManager: WindowManager? = null

        private fun releaseOrphanWindow() {
            val root = activeRoot ?: return
            try {
                activeWindowManager?.removeView(root)
            } catch (_: Throwable) {
                // 窗口可能已经被系统回收。
            }
            activeRoot = null
            activeWindowManager = null
        }
    }
}
