package com.kingmc.mintmusic.mintmusic

import android.content.Context
import android.view.animation.AlphaAnimation
import android.view.animation.Animation
import android.view.animation.AnimationSet
import android.view.animation.TranslateAnimation
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.ViewSwitcher

/**
 * 歌词切换容器。
 *
 * 内部持有**两份完全相同的歌词布局**；切换时先把新内容写进「另一份」，再调用
 * [showNext] —— ViewSwitcher 会同时播放旧页的 out 动画与新页的 in 动画，
 * 形成真正的交叉淡入淡出。
 *
 * 这是 lx-music 的 `LyricSwitchView`（TextSwitcher）的做法，也是它能做到
 * 「不闪」的关键。对比两种错误写法：
 *
 * 1. 对单个容器手动做 alpha 动画 —— 旧内容瞬间消失、新内容从 0 淡入，中间有
 *    空窗，且容易渲染出「新内容全亮」的一帧；
 * 2. 「淡出 -> 换文本 -> 淡入」两段式 —— 依赖 `onAnimationEnd` 启动第二段，
 *    而 `ViewPropertyAnimator.cancel()` 会同时回调 cancel 与 end，两段动画
 *    互相打断、alpha 被反复重置。
 */
class LyricSwitchView(context: Context) : ViewSwitcher(context) {

    /** 一份歌词布局：外层容器 + 若干行 TextView。 */
    class Page(val container: LinearLayout, val rows: MutableList<TextView>)

    val pages: List<Page>

    private var currentPageIndex = 0

    /// 当前页的标识（用于判断是否需要翻页）。
    private var currentKey: Any? = null

    init {
        pages = listOf(newPage(), newPage())
        for (page in pages) {
            addView(
                page.container,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
        }
        // 显式指定初始显示第 0 页（ViewAnimator 默认不会自动处理可见性）
        displayedChild = 0
        setAnimated(false)
    }

    private fun newPage(): Page {
        val container = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
        }
        return Page(container, mutableListOf())
    }

    fun currentPage(): Page = pages[currentPageIndex]
    private fun nextPage(): Page = pages[1 - currentPageIndex]

    /** 切换动画开关；关闭时 ViewSwitcher 直接切换，不做动画。 */
    fun setAnimated(enabled: Boolean, distance: Float = 0f) {
        if (enabled) {
            val d = if (distance <= 0f) 1f else distance
            setInAnimation(switchAnim(incoming = true, distance = d))
            setOutAnimation(switchAnim(incoming = false, distance = d))
        } else {
            setInAnimation(null)
            setOutAnimation(null)
        }
    }

    /**
     * 新页从下方滑入 + 淡入；旧页向上滑出 + 淡出。两者由 ViewSwitcher 并行播放。
     */
    private fun switchAnim(incoming: Boolean, distance: Float): Animation {
        val translate = if (incoming) {
            TranslateAnimation(0f, 0f, distance, 0f)
        } else {
            TranslateAnimation(0f, 0f, 0f, -distance)
        }
        translate.duration = SWITCH_DURATION

        val alpha = if (incoming) {
            AlphaAnimation(0f, 1f)
        } else {
            AlphaAnimation(1f, 0f)
        }
        alpha.duration = SWITCH_DURATION

        return AnimationSet(true).apply {
            addAnimation(translate)
            addAnimation(alpha)
        }
    }

    /**
     * 写入内容并切换。
     *
     * [animate] 为 false 时直接改当前页，不切换、不播动画 —— 用于样式变更
     * （字号/颜色/对齐/行数），避免拖动设置滑块时疯狂播放动画。
     */
    fun showPage(animate: Boolean, key: Any? = null, apply: (Page) -> Unit) {
        // key 相同说明还是同一页：只更新内容，不翻页、不播动画。
        val samePage = key != null && key == currentKey
        if (animate && !samePage) {
            apply(nextPage())
            super.showNext()
            currentPageIndex = 1 - currentPageIndex
        } else {
            apply(currentPage())
        }
        if (key != null) currentKey = key
    }

    /** 行数变化时同步重建两份布局里的 TextView。 */
    fun ensureRowCount(target: Int, create: () -> TextView) {
        for (page in pages) {
            while (page.rows.size > target) {
                page.container.removeView(page.rows.removeAt(page.rows.size - 1))
            }
            while (page.rows.size < target) {
                val tv = create()
                page.rows.add(tv)
                page.container.addView(
                    tv,
                    LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    ),
                )
            }
        }
    }

    fun setPageGravity(gravity: Int) {
        for (page in pages) page.container.gravity = gravity
    }

    companion object {
        const val SWITCH_DURATION = 300L
    }
}
