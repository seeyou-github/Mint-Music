package com.kingmc.mintmusic.mintmusic

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.TextUtils
import android.text.style.CharacterStyle
import android.text.style.RelativeSizeSpan
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
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

    private data class WordTiming(
        val text: String,
        val startMs: Long,
        val endMs: Long,
    )

    private data class LyricLineData(
        val time: Long,
        val endTime: Long,
        val text: String,
        val translation: String?,
        val roman: String?,
        val words: List<WordTiming>,
    )

    /** 一个固定槽位的内容：主歌词 + 可选的翻译 / 罗马音。 */
    private data class SlotContent(
        val line: LyricLineData?,
        val text: String,
        val translation: String?,
        val roman: String?,
        val active: Boolean,
    )

    /**
     * 一个固定槽位的两层文字：描边层在下、填充层在上。
     *
     * 分开两层是为了不干扰填充层的进度着色：填充层要把「已唱」部分按像素裁剪
     * 重画成另一种颜色（会临时改写 TextPaint 的颜色），若在同一个 TextView 里
     * 先画描边就会被染成歌词色。
     */
    private data class SlotRow(
        val frame: FrameLayout,
        val stroke: StrokeTextView,
        val fill: ProgressFillTextView,
    )

    private val appContext = context.applicationContext
    private val windowManager: WindowManager =
        appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private var rootView: LinearLayout? = null
    private var slotRows: List<SlotRow> = emptyList()
    private var layoutParams: WindowManager.LayoutParams? = null

    /// 应用是否在前台。前台时只把窗口设为 INVISIBLE（不 removeView），
    /// 原生侧的歌词数据与时钟都保留，回到后台可以立刻显示。
    private var appForeground = true

    // ---- 当前行的进度着色状态 ----
    private var activeFillView: ProgressFillTextView? = null
    private var activeLine: LyricLineData? = null
    /** 上一次画出的已唱比例，用来跳过没有变化的 tick。 */
    private var lastFraction = -1f

    // ---- 配置 ----
    // 初始值与 Flutter 侧 DesktopLyricSettings.defaults 保持一致：收到第一帧
    // 设置前也能保持同样的字号 / 描边，不会先闪一下 18sp + 无描边。
    private var fontSizeSp = 26f
    private var playedColor = Color.parseColor("#07C556")
    private var unplayColor = Color.WHITE
    private var shadowColor = Color.argb(153, 0, 0, 0)
    // 文字描边：透明色表示关闭；宽度存「占字号的比例」，绘制时再换算成 px。
    private var strokeColor = 0xD21F1929.toInt()
    private var strokeWidthRatio = 0.06f
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
            "setForeground" -> {
                val args = call.arguments as? Map<*, *>
                setForeground(args?.get("foreground") != false)
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
            applyWindowVisibility()
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
        val rows = ArrayList<SlotRow>(FIXED_LINE_COUNT)
        for (i in 0 until FIXED_LINE_COUNT) {
            val stroke = newStrokeTextView()
            val fill = newFillTextView()
            // 两层用完全相同的布局参数叠在一起；先添加的描边层先绘制，
            // 填充层盖住字形内部，只露出外侧那一半描边。
            val frame = FrameLayout(appContext).apply {
                addView(
                    stroke,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        Gravity.CENTER,
                    ),
                )
                addView(
                    fill,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        Gravity.CENTER,
                    ),
                )
            }
            rows.add(SlotRow(frame, stroke, fill))
            lyricContainer.addView(
                frame,
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
            // 背景完全透明：根 View 不设 background / 描边，窗口 alpha 也是 1.0。
            rebuildHandle()
            applyContent()
            applyWindowVisibility()
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
        stopTicker() // 内部同时停掉行时钟与进度着色轮询
        cancelLongPress()
        // 复位行号，下次 show 时才会重新写入内容（否则会被"行号未变"判断跳过）
        activeIndex = -1
        clearHighlightState()
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

    /**
     * 应用前后台切换：只改 View 的可见性，不 removeView。
     *
     * 原生侧的歌词数据与单调时钟都保留着，回到后台可以立刻显示，不需要
     * Dart 在后台再走一轮（后台时 Flutter 的异步通道可能被节流）。
     */
    private fun setForeground(foreground: Boolean) {
        appForeground = foreground
        applyWindowVisibility()
        if (foreground) {
            stopProgressTicker()
        } else if (playing && rootView != null) {
            applyProgressHighlight(force = true)
            scheduleProgress()
        }
    }

    private fun applyWindowVisibility() {
        val root = rootView ?: return
        val lp = layoutParams ?: return
        // 进入应用时隐藏桌面歌词，最小化 / 后台时才显示。
        val target = if (appForeground) View.INVISIBLE else View.VISIBLE
        if (root.visibility != target) root.visibility = target
        val flags = buildFlags()
        if (lp.flags != flags) {
            lp.flags = flags
            safeUpdateLayout()
        }
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
        // 前台时窗口只是 INVISIBLE、仍挂在 WindowManager 上（要保留歌词数据和
        // 时钟），必须一并关掉触摸，否则这块透明窗口会吃掉应用顶部的点击。
        if (appForeground) {
            flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        }
        return flags
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

        // 顶部这条只作为拖动 / 长按的操作带，不再显示「桌面歌词」文字。
        val handle = TextView(appContext).apply {
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

    // ------------------------------------------------------------------ 配置
    // 悬浮窗背景保持完全透明：不设 background、不画描边，窗口 alpha 也是 1.0。
    // 文字在任意壁纸上都能看清靠的是每行 TextView 的 setShadowLayer。

    private fun applyConfig(args: Map<*, *>?) {
        if (args == null) return
        fontSizeSp = (args["fontSize"] as? Number)?.toFloat()?.coerceIn(10f, 120f) ?: fontSizeSp
        playedColor = (args["playedColor"] as? Number)?.toInt() ?: playedColor
        unplayColor = (args["unplayColor"] as? Number)?.toInt() ?: unplayColor
        shadowColor = (args["shadowColor"] as? Number)?.toInt() ?: shadowColor
        strokeColor = (args["strokeColor"] as? Number)?.toInt() ?: strokeColor
        strokeWidthRatio = (args["strokeWidth"] as? Number)?.toFloat()
            ?.coerceIn(0f, 0.2f) ?: strokeWidthRatio
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
        rebuildHandle()
        root.setOnTouchListener(createTouchListener(root))
        // 样式/尺寸变更直接刷新内容，不做翻页动画。
        applyContent()
        applyWindowVisibility()
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
            // Dart 侧会下发「行结束时间」和逐字时间轴（普通 LRC 只有行级时间），
            // 当前行的进度着色要用它们算「已经唱到哪个字」。
            val wordsRaw = map["words"] as? List<*>
            val words = wordsRaw.orEmpty().mapNotNull { w ->
                val wm = w as? Map<*, *> ?: return@mapNotNull null
                WordTiming(
                    text = wm["t"] as? String ?: "",
                    startMs = (wm["s"] as? Number)?.toLong() ?: 0L,
                    endMs = (wm["e"] as? Number)?.toLong() ?: 0L,
                )
            }
            LyricLineData(
                time = (map["time"] as? Number)?.toLong() ?: 0L,
                endTime = (map["endTime"] as? Number)?.toLong() ?: 0L,
                text = map["text"] as? String ?: "",
                translation = map["translation"] as? String,
                roman = map["roman"] as? String,
                words = words,
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
            SlotContent(null, "", null, null, false)
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
                line = line,
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
        clearHighlightState()
        val slots = buildSlots()
        for (i in rows.indices) {
            val row = rows[i]
            val stroke = row.stroke
            val tv = row.fill
            val slot = slots.getOrNull(i) ?: SlotContent(null, "", null, null, false)

            // 两层的字体 / 字号 / 对齐必须完全一致，否则描边会和文字错位。
            for (target in listOf(stroke, tv)) {
                target.typeface = lyricTypeface
                target.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
                target.gravity = Gravity.CENTER_HORIZONTAL or Gravity.CENTER_VERTICAL
            }
            // 描边层只画轮廓，不带阴影；填充层维持原有的阴影与逐字着色。
            stroke.setTextColor(strokeColor)
            stroke.strokeColor = strokeColor
            stroke.strokeWidthPx = currentStrokeWidthPx()
            stroke.setShadowLayer(0f, 0f, 0f, 0)
            // 基色一律是「未播放」；当前行已唱过的部分由填充层按已唱宽度
            // 裁剪重画成 playedColor，不再整行刷成已播放色。
            tv.setTextColor(unplayColor)
            tv.setShadowLayer(SHADOW_RADIUS, SHADOW_DX, SHADOW_DY, shadowColor)
            tv.playedColor = playedColor

            val hasSub = !slot.translation.isNullOrBlank() || !slot.roman.isNullOrBlank()
            if (slot.text.isBlank() && !hasSub) {
                stroke.text = ""
                tv.text = ""
                row.frame.visibility = View.INVISIBLE
                continue
            }
            row.frame.visibility = View.VISIBLE

            // 填充层含绘制阶段的颜色 span，不能与描边层共用文本。
            stroke.setText(buildSlotText(slot), TextView.BufferType.SPANNABLE)
            tv.setLyricText(buildSlotText(slot), slot.text.length)

            if (slot.active) {
                activeFillView = tv
                activeLine = slot.line
                applyProgressHighlight(force = true)
            }

            for (target in listOf(stroke, tv)) {
                if (hasSub) {
                    target.setSingleLine(false)
                    target.maxLines = 1 + subLineCount()
                    target.ellipsize = TextUtils.TruncateAt.END
                    target.marqueeRepeatLimit = 0
                    target.isSelected = false
                } else {
                    // 单行且超长时使用系统跑马灯横向滚动；两层连续启动，
                    // 滚动相位保持一致，描边不会和文字错开。
                    target.setSingleLine(true)
                    target.ellipsize = TextUtils.TruncateAt.MARQUEE
                    target.marqueeRepeatLimit = -1
                    target.isSelected = true
                }
            }
        }
    }

    /** 主歌词 + 翻译 / 罗马音（只带字号 span，不带任何颜色 span）。 */
    private fun buildSlotText(slot: SlotContent): SpannableStringBuilder {
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
        return builder
    }

    /** 描边线宽（px）。STROKE 以字形轮廓为中心，内侧一半会被填充层盖住，故乘 2。 */
    private fun currentStrokeWidthPx(): Float {
        val fontPx = fontSizeSp * appContext.resources.displayMetrics.scaledDensity
        return fontPx * strokeWidthRatio * 2f
    }

    private fun newStrokeTextView(): StrokeTextView =
        StrokeTextView(appContext).apply { applyCommonRowStyle(this) }

    private fun newFillTextView(): ProgressFillTextView =
        ProgressFillTextView(appContext).apply { applyCommonRowStyle(this) }

    private fun applyCommonRowStyle(tv: TextView) {
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
        tv.includeFontPadding = false
        tv.setLineSpacing(0f, 1.15f)
        tv.gravity = Gravity.CENTER
        tv.setTextColor(unplayColor)
        tv.typeface = lyricTypeface
        // 显隐由外层 FrameLayout 控制，两层自身始终可见。
        tv.visibility = View.VISIBLE
    }

    // ------------------------------------------------------------ 播放进度着色

    private fun clearHighlightState() {
        activeFillView?.clearProgress()
        activeFillView = null
        activeLine = null
        lastFraction = -1f
    }

    /**
     * 把当前行的播放进度交给填充层，由它按「已唱宽度」做像素级裁剪。
     *
     * 比例没变（小于千分之一）时直接跳过，避免每个 tick 都 invalidate。
     */
    private fun applyProgressHighlight(force: Boolean = false) {
        val view = activeFillView ?: return
        val line = activeLine ?: return
        val fraction = playedFraction(line, currentMediaTimeMs(), view.paint)
        if (!force && abs(fraction - lastFraction) < 0.0015f) return
        lastFraction = fraction
        view.setProgress(fraction)
    }

    /**
     * 当前行已唱比例（0~1）。
     *
     * 逐字歌词按「每个字的起止时间 + 实测字宽」累计已唱宽度，再除以整行宽度；
     * 这和 Windows 桌面歌词、播放详情页的逐字高亮是同一套算法。普通 LRC 没有
     * 逐字时间轴，退回整行时间线性插值。
     *
     * 注意：分母必须是**整行**宽度。边量边累加、又在当前字处 break 的话，
     * 分母只含已唱到当前字的宽度，比率会恒接近 1，表现为一句刚开始就填满。
     */
    private fun playedFraction(line: LyricLineData, nowMs: Long, paint: Paint): Float {
        val words = line.words
        if (words.size > 1 && words.any { it.endMs > it.startMs }) {
            val widths = FloatArray(words.size)
            var total = 0f
            for (i in words.indices) {
                widths[i] = paint.measureText(words[i].text).coerceAtLeast(1f)
                total += widths[i]
            }
            if (total > 0f) {
                var sung = 0f
                for (i in words.indices) {
                    val word = words[i]
                    val start = word.startMs
                    val end = if (word.endMs > start) word.endMs else start + 1
                    if (nowMs <= start) break // 这个字还没唱到，后面的都没唱
                    if (nowMs >= end) {
                        sung += widths[i] // 整个字唱完
                        continue
                    }
                    // 唱到这个字中间：按时间在字宽里线性推进，后面的都没唱。
                    sung += widths[i] * (nowMs - start).toFloat() / (end - start)
                    break
                }
                return (sung / total).coerceIn(0f, 1f)
            }
        }
        val start = line.time
        val end = if (line.endTime > start) line.endTime else start + DEFAULT_LINE_MS
        return ((nowMs - start).toFloat() / (end - start)).coerceIn(0f, 1f)
    }

    /** 进度着色的轮询：只在播放中、窗口可见（应用在后台）时运行。 */
    private var progressScheduled = false
    private val progressRunnable = Runnable {
        progressScheduled = false
        applyProgressHighlight()
        if (playing && rootView != null && !appForeground) scheduleProgress()
    }

    private fun scheduleProgress() {
        if (progressScheduled) return
        progressScheduled = true
        mainHandler.postDelayed(progressRunnable, PROGRESS_TICK_MS)
    }

    private fun stopProgressTicker() {
        if (progressScheduled) {
            mainHandler.removeCallbacks(progressRunnable)
            progressScheduled = false
        }
    }

    // ------------------------------------------------------------------ 拖动

    private val touchSlopPx =
        ViewConfiguration.get(appContext).scaledTouchSlop.toFloat()
    private val longPressMs = ViewConfiguration.getLongPressTimeout().toLong()
    private var downRawX = 0f
    private var downRawY = 0f
    private var longPressTriggered = false
    private var movedBeyondSlop = false

    /** 长按桌面歌词控件：关闭悬浮窗并通知 Dart 把开关置为关闭。 */
    private val longPressRunnable = Runnable {
        if (longPressTriggered || movedBeyondSlop || rootView == null) return@Runnable
        longPressTriggered = true
        hide()
        try {
            channel?.invokeMethod("onLongPressClose", null)
        } catch (_: Throwable) {
            // Dart 侧可能已经销毁。
        }
    }

    private fun cancelLongPress() {
        mainHandler.removeCallbacks(longPressRunnable)
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun createTouchListener(root: View): View.OnTouchListener {
        return View.OnTouchListener { _, event ->
            val lp = layoutParams ?: return@OnTouchListener false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    lastTouchRawX = event.rawX
                    lastTouchRawY = event.rawY
                    downRawX = event.rawX
                    downRawY = event.rawY
                    dragging = false
                    longPressTriggered = false
                    movedBeyondSlop = false
                    cancelLongPress()
                    mainHandler.postDelayed(longPressRunnable, longPressMs)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - lastTouchRawX
                    val dy = event.rawY - lastTouchRawY
                    lastTouchRawX = event.rawX
                    lastTouchRawY = event.rawY
                    // 手指移动超过阈值就当作拖动，取消长按，避免挪动窗口时误关闭。
                    if (abs(event.rawX - downRawX) + abs(event.rawY - downRawY) >
                        touchSlopPx
                    ) {
                        movedBeyondSlop = true
                        cancelLongPress()
                    }
                    lp.x = (lp.x + dx).roundToInt().coerceIn(0, maxOffsetX(root))
                    lp.y = (lp.y + dy).roundToInt().coerceIn(0, maxOffsetY(root))
                    dragging = true
                    safeUpdateLayout()
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    cancelLongPress()
                    if (dragging && !longPressTriggered) notifyPositionChanged(root)
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
        // 进度着色只在「正在播放 + 窗口可见（应用在后台）」时轮询；
        // 前台时窗口是 INVISIBLE，没必要耗电刷新。
        if (isPlaying && rootView != null && !appForeground) {
            applyProgressHighlight(force = true)
            scheduleProgress()
        } else {
            stopProgressTicker()
        }
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
        stopProgressTicker()
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
        /// 窗口整体不透明；「背景完全透明」靠根 View 不设 background 实现。
        private const val WINDOW_OPACITY = 1.0f
        /// 当前行进度着色的刷新间隔（只在播放 + 窗口可见时运行）。
        ///
        /// 已唱宽度是按像素裁剪的，刷新间隔直接决定填充的顺滑度：原来的 100ms
        /// （10fps）下一个字只摊到一两帧，看起来仍是整字跳；这里按 30fps 刷新，
        /// 填充前沿每帧只走几个像素，肉眼看是连续的，同时只有 60fps 一半的重绘
        /// 开销。只在播放 + 应用在后台时运行，绘制范围也只限两行文字。
        private const val PROGRESS_TICK_MS = 33L
        /// 歌词阴影（与填充层 onDraw 里临时去掉阴影后恢复时用的参数保持一致）。
        private const val SHADOW_RADIUS = 4f
        private const val SHADOW_DX = 1f
        private const val SHADOW_DY = 1f
        /// 普通 LRC 缺行结束时间时，按一行 4 秒估算进度。
        private const val DEFAULT_LINE_MS = 4000L
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

/**
 * 填充层 TextView：进度按「像素裁剪」绘制，而不是按整字换色。
 *
 * 改动前当前行用 ForegroundColorSpan 一段一段改颜色，进度只能整字跳，看起来
 * 就是「一个字一个字往前走」。这里沿用 Windows 桌面歌词的做法：先按未播放色
 * 画整行，再按已播放色把「已唱宽度」以内的部分重画一遍，裁剪边界随播放时间
 * 连续推进，单个字内部同样是线性的。
 */
private class ProgressFillTextView(context: Context) : TextView(context) {
    /** 当前行的已播放色（由外层按设置同步）。 */
    var playedColor: Int = Color.WHITE

    private var drawingPlayedText = false
    private val progressColorSpan = object : CharacterStyle() {
        override fun updateDrawState(tp: TextPaint) {
            if (!drawingPlayedText) return
            // TextView.onDraw 会重置 paint.color，span 在它之后应用且不触发布局或重绘。
            tp.color = playedColor
            tp.clearShadowLayer()
        }
    }

    fun setLyricText(content: SpannableStringBuilder, mainTextLength: Int) {
        if (mainTextLength > 0) {
            content.setSpan(progressColorSpan, 0, mainTextLength, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        setText(content, BufferType.SPANNABLE)
    }

    /** 是否为当前播放行：只有它需要分段着色。 */
    private var shading = false

    /** 已唱比例（0~1，按整行文字宽度）。 */
    private var sungFraction = 0f

    fun clearProgress() {
        if (!shading && sungFraction == 0f) return
        shading = false
        sungFraction = 0f
        invalidate()
    }

    fun setProgress(fraction: Float) {
        val clamped = fraction.coerceIn(0f, 1f)
        if (shading && abs(clamped - sungFraction) < 0.0008f) return
        shading = true
        sungFraction = clamped
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val layout = layout
        if (!shading || layout == null || layout.lineCount == 0) {
            super.onDraw(canvas)
            return
        }
        // 第一遍：整行按「未播放」色铺底（阴影、翻译 / 罗马音都在这一遍里）。
        super.onDraw(canvas)
        val fraction = sungFraction.coerceIn(0f, 1f)
        if (fraction <= 0f) return

        val contentWidth =
            (width - compoundPaddingLeft - compoundPaddingRight).toFloat()
        val lineWidth = layout.getLineWidth(0)
        // 已唱宽度：普通行从文字实际起点（居中时由 Layout 给出偏移）算起；
        // 超长行会被系统跑马灯横向滚动，文字起点一直在变、无法固定裁剪，
        // 改成按可视宽度扫过，进度依旧是线性的，不会退回整字跳。
        val clipRight = when {
            // 整行唱完：直接铺满，避免最后一笔抗锯齿边缘残留未播放色。
            fraction >= 1f -> width.toFloat()
            lineWidth <= contentWidth + 0.5f ->
                compoundPaddingLeft + layout.getLineLeft(0) + lineWidth * fraction
            else -> width * fraction
        }

        // 只重画主歌词那一行：翻译 / 罗马音保持未播放色（与 Windows 一致）。
        // 上下各多留 2px，避免行高边界把字形的顶部 / 底部切掉。
        val innerHeight = height - compoundPaddingTop - compoundPaddingBottom
        val voffset =
            if (layout.height < innerHeight) (innerHeight - layout.height) / 2 else 0
        val bandTop =
            (compoundPaddingTop + voffset + layout.getLineTop(0) - 2).toFloat()
        val bandBottom =
            (compoundPaddingTop + voffset + layout.getLineBottom(0) + 2).toFloat()

        val saveCount = canvas.save()
        canvas.clipRect(0f, bandTop, clipRight, bandBottom)
        drawingPlayedText = true
        try {
            super.onDraw(canvas)
        } finally {
            drawingPlayedText = false
            canvas.restoreToCount(saveCount)
        }
    }
}

/**
 * 只画字形轮廓的 TextView，与填充层叠在同一个 FrameLayout 里形成文字描边。
 *
 * 之所以单独一层：填充层的进度着色会临时改写 TextPaint.color，若在同一层里
 * 先画描边就会被染成歌词色，描边颜色无法自定义。
 * 这一层的文本不带任何颜色 span，onDraw 里临时切成 STROKE 即可。
 */
private class StrokeTextView(context: Context) : TextView(context) {
    var strokeColor: Int = Color.TRANSPARENT
    var strokeWidthPx: Float = 0f

    override fun onDraw(canvas: Canvas) {
        // 透明色 / 宽度 0 = 不描边：整层不绘制，零额外开销。
        if (Color.alpha(strokeColor) == 0 || strokeWidthPx <= 0f) return
        val textPaint = paint
        val oldStyle = textPaint.style
        val oldWidth = textPaint.strokeWidth
        val oldColor = textPaint.color
        textPaint.style = Paint.Style.STROKE
        textPaint.strokeWidth = strokeWidthPx
        textPaint.color = strokeColor
        super.onDraw(canvas)
        textPaint.style = oldStyle
        textPaint.strokeWidth = oldWidth
        textPaint.color = oldColor
    }
}
