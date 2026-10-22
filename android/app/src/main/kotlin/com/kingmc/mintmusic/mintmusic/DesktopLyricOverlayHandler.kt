package com.kingmc.mintmusic.mintmusic

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextUtils
import android.text.style.RelativeSizeSpan
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
 * - `WindowManager.addView` + `TYPE_APPLICATION_OVERLAY`,歌词可显示在其它应用之上;
 * - 拖动结束时把像素坐标换算成**屏幕百分比**回传 Dart 保存;
 * - **窗口高度是显式计算的固定值**,换句时绝不触发 `updateViewLayout`;
 * - **固定两个槽位**:当前行按行号奇偶落在对应槽位,另一个槽位预载下一行,
 *   换句时两个槽位的位置都不动,进度直接出现在另一个槽位。
 */
class DesktopLyricOverlayHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    private data class LyricLineData(
        val time: Long,
        val text: String,
        val translation: String?,
        val roman: String?,
    )

    /** 一个固定槽位的内容：主歌词 + 可选的翻译 / 罗马音。 */
    private data class SlotContent(
        val text: String,
        val translation: String?,
        val roman: String?,
        val active: Boolean,
    )

    private val appContext = context.applicationContext
    private val windowManager: WindowManager =
        appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private var rootView: LinearLayout? = null
    private var slotRows: List<TextView> = emptyList()
    private var layoutParams: WindowManager.LayoutParams? = null
    private var backgroundDrawable: GradientDrawable? = null

    // ---- 配置 ----
    private var fontSizeSp = 18f
    private var playedColor = Color.parseColor("#07C556")
    private var unplayColor = Color.WHITE
    private var shadowColor = Color.argb(153, 0, 0, 0)
    private var positionXPercent = 3.0
    private var positionYPercent = 8.0

    // 歌词设置里的字体 / 字重（原生悬浮窗需要自己加载字体文件）。
    private var fontFamily = ""
    private var fontPath = ""
    private var fontWeight = 500
    private var lyricTypeface: Typeface = Typeface.DEFAULT


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
            applyContent()
            return true
        }
        // 清理上一次运行(例如热重启)遗留的窗口,避免歌词窗重复叠加。
        releaseOrphanWindow()
        if (!hasOverlayPermission()) return false

        val root = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
        }
        // 固定两个槽位的歌词容器：每行平分剩余高度，换句时不重新布局。
        val lyricContainer = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
        }
        val rows = ArrayList<TextView>(FIXED_LINE_COUNT)
        for (i in 0 until FIXED_LINE_COUNT) {
            val tv = newRowTextView()
            rows.add(tv)
            lyricContainer.addView(
                tv,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    0,
                    1f,
                ),
            )
        }
        root.addView(
            lyricContainer,
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
            alpha = WINDOW_OPACITY
        }

        root.setOnTouchListener(createTouchListener(root))

        return try {
            windowManager.addView(root, lp)
            activeRoot = root
            activeWindowManager = windowManager
            rootView = root
            slotRows = rows
            layoutParams = lp
            applyBackground()
            rebuildHandle()
            applyContent()
            // 首帧之后才能拿到真实高度,再按百分比精确定位一次。
            root.post { applyPositionPercent() }
            true
        } catch (error: Throwable) {
            Log.w(TAG, "addView failed", error)
            rootView = null
            slotRows = emptyList()
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
        slotRows = emptyList()
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
        return WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
    }

    /**
     * 窗口高度：**显式计算的固定值**，不用 WRAP_CONTENT。
     *
     * 固定两个槽位；开启翻译 / 罗马音时每个槽位额外预留对应行数。高度恒定
     * 意味着换句时窗口不需要重新测量、也不需要 `updateViewLayout`。
     */
    private fun contentHeight(): Int {
        val metrics = appContext.resources.displayMetrics
        val lineHeight = (fontSizeSp * metrics.scaledDensity * 1.35f).roundToInt()
        val slotHeight = lineHeight * (1 + subLineCount())
        var height = slotHeight * FIXED_LINE_COUNT + handleHeightPx()
        val limit = screenHeight() - 100
        if (height > limit) height = limit
        return height.coerceAtLeast(1)
    }

    private fun subLineCount(): Int =
        (if (showTranslation) 1 else 0) + (if (showRoman) 1 else 0)

    private fun handleHeightPx(): Int =
        (HANDLE_HEIGHT_DP * appContext.resources.displayMetrics.density).roundToInt()

    private fun rebuildHandle() {
        val root = rootView ?: return
        // 移除已有的把手（保持在最前面）
        if (root.childCount > 1) {
            root.removeViewAt(0)
        }

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
        drawable.setColor(Color.argb(41, 0, 0, 0))
        drawable.setStroke(1, Color.argb(56, 255, 255, 255))
        root.background = drawable
    }

    // ------------------------------------------------------------------ 配置

    private fun applyConfig(args: Map<*, *>?) {
        if (args == null) return
        fontSizeSp = (args["fontSize"] as? Number)?.toFloat()?.coerceIn(10f, 120f) ?: fontSizeSp
        playedColor = (args["playedColor"] as? Number)?.toInt() ?: playedColor
        unplayColor = (args["unplayColor"] as? Number)?.toInt() ?: unplayColor
        shadowColor = (args["shadowColor"] as? Number)?.toInt() ?: shadowColor
        positionXPercent = (args["positionX"] as? Number)?.toDouble() ?: positionXPercent
        positionYPercent = (args["positionY"] as? Number)?.toDouble() ?: positionYPercent
        fontFamily = args["fontFamily"] as? String ?: ""
        fontPath = args["fontPath"] as? String ?: ""
        fontWeight = (args["fontWeight"] as? Number)?.toInt()?.coerceIn(1, 1000) ?: fontWeight
        rebuildTypeface()

        val root = rootView ?: return
        val lp = layoutParams ?: return
        lp.flags = buildFlags()
        lp.alpha = WINDOW_OPACITY
        // 悬浮窗宽度固定为屏幕宽度（100%）。
        lp.width = screenWidth().coerceAtLeast(120)
        lp.height = contentHeight()
        applyBackground()
        rebuildHandle()
        root.setOnTouchListener(createTouchListener(root))
        // 样式/尺寸变更直接刷新内容，不做翻页动画。
        applyContent()
        root.post { applyPositionPercent() }
        safeUpdateLayout()
    }

    /** 按歌词设置加载字体文件 / 字体族，并应用字重。 */
    private fun rebuildTypeface() {
        var base: Typeface? = null
        if (fontPath.isNotBlank()) {
            base = try {
                if (fontPath.startsWith("/")) {
                    Typeface.createFromFile(fontPath)
                } else {
                    val asset = if (fontPath.startsWith("flutter_assets/")) {
                        fontPath
                    } else {
                        "flutter_assets/$fontPath"
                    }
                    Typeface.createFromAsset(appContext.assets, asset)
                }
            } catch (error: Throwable) {
                Log.w(TAG, "加载歌词字体失败: $fontPath", error)
                null
            }
        }
        if (base == null && fontFamily.isNotBlank() && fontFamily != "system") {
            base = try {
                Typeface.create(fontFamily, Typeface.NORMAL)
            } catch (_: Throwable) {
                null
            }
        }
        val family = base ?: Typeface.DEFAULT
        lyricTypeface = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                Typeface.create(family, fontWeight, false)
            } else {
                Typeface.create(
                    family,
                    if (fontWeight >= 600) Typeface.BOLD else Typeface.NORMAL,
                )
            }
        } catch (_: Throwable) {
            family
        }
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
        val previousSubLineCount = subLineCount()
        showTranslation = args["showTranslation"] != false
        showRoman = args["showRoman"] != false
        // 换歌：直接刷新内容。
        setActiveIndex((args["activeIndex"] as? Number)?.toInt() ?: 0, force = true)
        // 新歌词的时间轴变了，重新调度下一次换句
        refresh()
        // 翻译 / 罗马音开关变化会改变每个槽位预留的行数，此时才需要调整窗口高度。
        if (previousSubLineCount != subLineCount()) {
            val lp = layoutParams
            if (rootView != null && lp != null) {
                lp.height = contentHeight()
                safeUpdateLayout()
                rootView?.post { applyPositionPercent() }
            }
        }
    }

    /// 更新当前行。行号没变时直接返回，避免每个定时 tick 都重写 TextView。
    private fun setActiveIndex(index: Int, force: Boolean = false) {
        if (!force && index == activeIndex) return
        activeIndex = index
        applyContent()
    }

    /**
     * 固定两个槽位：当前播放行在 `activeIndex % 2` 对应的槽位，另一个槽位
     * 预载下一行。唱到下一行时进度直接出现在另一个槽位，两个槽位的位置不变。
     */
    private fun buildSlots(): List<SlotContent> {
        val slots = MutableList(FIXED_LINE_COUNT) {
            SlotContent("", null, null, false)
        }
        if (lines.isEmpty()) return slots
        val hasActive = activeIndex in lines.indices
        val index = activeIndex.coerceIn(0, lines.lastIndex)
        val activeSlot = if (hasActive) index % FIXED_LINE_COUNT else 0
        for (slot in slots.indices) {
            val offset = (slot - activeSlot + FIXED_LINE_COUNT) % FIXED_LINE_COUNT
            val lineIndex = index + offset
            if (lineIndex >= lines.size) continue
            val line = lines[lineIndex]
            slots[slot] = SlotContent(
                text = line.text,
                translation = line.translation?.takeIf {
                    showTranslation && it.isNotBlank()
                },
                roman = line.roman?.takeIf { showRoman && it.isNotBlank() },
                active = hasActive && lineIndex == activeIndex,
            )
        }
        return slots
    }

    /**
     * 写入歌词内容。
     *
     * 只更新两个固定槽位的 TextView 文本，不调用 `updateViewLayout`：换句时
     * 窗口尺寸与槽位位置都保持不变。
     */
    private fun applyContent() {
        val rows = slotRows
        if (rows.isEmpty()) return
        val slots = buildSlots()
        for (i in rows.indices) {
            val tv = rows[i]
            val slot = slots.getOrNull(i) ?: SlotContent("", null, null, false)
            tv.typeface = lyricTypeface
            tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
            tv.setTextColor(if (slot.active) playedColor else unplayColor)
            tv.gravity = Gravity.CENTER_HORIZONTAL or Gravity.CENTER_VERTICAL
            tv.setShadowLayer(4f, 1f, 1f, shadowColor)

            val hasSub = !slot.translation.isNullOrBlank() || !slot.roman.isNullOrBlank()
            if (slot.text.isBlank() && !hasSub) {
                tv.text = ""
                tv.visibility = View.INVISIBLE
                continue
            }
            tv.visibility = View.VISIBLE

            val builder = SpannableStringBuilder(slot.text)
            fun appendSub(text: String) {
                if (text.isBlank()) return
                val start = builder.length
                builder.append('\n').append(text)
                builder.setSpan(
                    RelativeSizeSpan(SUB_TEXT_SCALE),
                    start,
                    builder.length,
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
            }
            slot.translation?.let { appendSub(it) }
            slot.roman?.let { appendSub(it) }
            tv.text = builder

            if (hasSub) {
                tv.setSingleLine(false)
                tv.maxLines = 1 + subLineCount()
                tv.ellipsize = TextUtils.TruncateAt.END
                tv.marqueeRepeatLimit = 0
                tv.isSelected = false
            } else {
                // 单行且超长时使用系统跑马灯横向滚动。
                tv.setSingleLine(true)
                tv.ellipsize = TextUtils.TruncateAt.MARQUEE
                tv.marqueeRepeatLimit = -1
                tv.isSelected = true
            }
        }
    }

    private fun newRowTextView(): TextView = TextView(appContext).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
        includeFontPadding = false
        setLineSpacing(0f, 1.15f)
        gravity = Gravity.CENTER
        setTextColor(unplayColor)
        typeface = lyricTypeface
        visibility = View.INVISIBLE
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
        /// 桌面歌词固定显示两个槽位。
        private const val FIXED_LINE_COUNT = 2
        /// 不透明度固定 80%。
        private const val WINDOW_OPACITY = 0.8f
        /// 翻译 / 罗马音相对主歌词的字号比例。
        private const val SUB_TEXT_SCALE = 0.62f
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
