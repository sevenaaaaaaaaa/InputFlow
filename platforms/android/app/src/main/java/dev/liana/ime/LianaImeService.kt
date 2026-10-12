package dev.liana.ime

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject

/**
 * 全平台统一设计 Token（docs/design/UNIFIED-DESIGN.md 为单一事实源）。
 */
object LianaTheme {
    const val BG = 0xFF1C1C22.toInt()
    const val KEY = 0xFF2A2A33.toInt()
    const val KEY_PRESSED = 0xFF33333E.toInt()
    const val TEXT = 0xFFE8E8EC.toInt()
    const val SECONDARY = 0xFF9A9AA5.toInt()
    const val ACCENT = 0xFF337BFF.toInt()
    const val RADIUS_KEY = 8f          // dp
    const val FONT_CANDIDATE = 17f
    const val FONT_KEY = 16f
    const val KEY_HEIGHT = 46          // dp
    const val PAD_SPLIT_MIN_WIDTH = 600 // dp，Pad 分体键盘阈值
}

/**
 * 松萝 Android 输入法服务。
 *
 * 与 macOS 端同构：Swift 外壳的职责（会话管理 / 候选栏 / 键盘）在这里用
 * framework API 重写，引擎逻辑全部来自同一份 Rust 内核（libliana_jni.so）。
 *
 * 触控创新（统一设计语言 §3）：
 * - 全键触觉反馈（§3.1）
 * - 候选上滑直上屏（§3.2）
 * - 退格长按连删 + 左滑整段清除（§3.3）
 * - Pad 宽度 ≥ 600dp 自动分体键盘（§3.4）
 */
class LianaImeService : InputMethodService() {

    private var session: Long = 0
    private var modeIdx = 0
    private var candidates: List<String> = emptyList()
    private var rawInput: String = ""

    private lateinit var candidateStrip: LinearLayout
    private lateinit var modeButton: TextView
    private lateinit var tradButton: TextView
    private val repeatHandler = Handler(Looper.getMainLooper())
    private var inputViewRef: View? = null

    // ---- 生命周期 ----

    override fun onCreate() {
        super.onCreate()
        val dictFile = getFileStreamPath("base.ifd")
        if (!dictFile.exists()) {
            try {
                assets.open("base.ifd").use { input ->
                    dictFile.outputStream().use { input.copyTo(it) }
                }
            } catch (_: Exception) {
                // 词典缺失时回退内核内置词典
            }
        }
        val dictPath = if (dictFile.exists()) dictFile.absolutePath else null
        session = (dictPath?.let { LianaJni.newWithDict("pinyin", it) } ?: 0L)
            .takeIf { it != 0L } ?: LianaJni.new("pinyin")
        importUserLexicon()
    }

    override fun onDestroy() {
        repeatHandler.removeCallbacksAndMessages(null)
        saveUserLexicon()
        if (session != 0L) LianaJni.free(session)
        session = 0L
        super.onDestroy()
    }

    private fun importUserLexicon() {
        val f = getFileStreamPath("user_dict.tsv")
        if (f.exists() && session != 0L) {
            try {
                LianaJni.userImport(session, f.readText())
            } catch (_: Exception) {
            }
        }
    }

    private fun saveUserLexicon() {
        if (session == 0L) return
        try {
            LianaJni.userExport(session)?.let { getFileStreamPath("user_dict.tsv").writeText(it) }
        } catch (_: Exception) {
        }
    }

    // ---- 键盘 UI（程序化构建，无 XML 布局） ----

    override fun onCreateInputView(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(LianaTheme.BG)
        }

        // 候选栏
        candidateStrip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(4), dp(8), dp(4))
        }
        val candidateScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(candidateStrip, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(40)))
        }
        root.addView(candidateScroll)

        buildLetterRows(root)

        // 底部功能行（Pad 上也保持通栏，便于双手公共区）
        val fnRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        modeButton = keyView("中", weight = 1.2f) { onModeToggle() }
        fnRow.addView(modeButton)
        tradButton = keyView("简", weight = 1f) { onTraditionalToggle() }
        fnRow.addView(tradButton)
        fnRow.addView(keyView(",", weight = 1f) { commitText(",") })
        fnRow.addView(keyView("空格", weight = 4f) { onSpace() })
        fnRow.addView(keyView(".", weight = 1f) { commitText(".") })
        fnRow.addView(keyView("回车", weight = 1.6f) { onEnter() })
        root.addView(fnRow, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(48)))

        refreshCandidates()
        inputViewRef = root
        return root
    }

    /** 字母区：手机通栏；Pad（宽度 ≥ 600dp）自动左右分体，向拇指收拢。 */
    private fun buildLetterRows(root: LinearLayout) {
        val rows = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
        if (!isPadWidth()) {
            rows.forEachIndexed { i, keys ->
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER
                }
                keys.forEach { ch -> row.addView(keyView(ch.toString(), weight = 1f) { onLetter(ch) }) }
                if (i == 2) row.addView(backspaceView())
                root.addView(row, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(LianaTheme.KEY_HEIGHT)))
            }
            return
        }

        // Pad 分体：每行从中间拆开，两半各自贴边，中缝留空
        val halves = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val left = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; weightSum = 1f }
        val right = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; weightSum = 1f }
        rows.forEachIndexed { i, keys ->
            val mid = if (i == 2) (keys.length + 1) / 2 else (keys.length + 1) / 2
            val rowL = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(dp(6), 0, 0, 0)
            }
            val rowR = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, 0, dp(6), 0)
            }
            keys.take(mid).forEach { ch -> rowL.addView(keyView(ch.toString(), weight = 1f) { onLetter(ch) }) }
            if (i == 2 && mid <= keys.length) {
                // 退格键归属右半（右手习惯）
            }
            keys.drop(mid).forEach { ch -> rowR.addView(keyView(ch.toString(), weight = 1f) { onLetter(ch) }) }
            if (i == 2) rowR.addView(backspaceView())
            left.addView(rowL, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(LianaTheme.KEY_HEIGHT)))
            right.addView(rowR, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(LianaTheme.KEY_HEIGHT)))
        }
        halves.addView(left, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        val gap = View(this).apply { setBackgroundColor(Color.TRANSPARENT) }
        halves.addView(gap, LinearLayout.LayoutParams(0, 1, 0.08f))
        halves.addView(right, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        root.addView(halves, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    private fun isPadWidth(): Boolean {
        val widthDp = resources.displayMetrics.widthPixels / resources.displayMetrics.density
        return widthDp >= LianaTheme.PAD_SPLIT_MIN_WIDTH
    }

    // ---- 按键视图工厂 ----

    private fun keyView(label: String, weight: Float, onClick: () -> Unit): TextView {
        return baseKey(label).apply {
            val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, weight)
            lp.setMargins(dp(3), dp(4), dp(3), dp(4))
            layoutParams = lp
            setOnClickListener {
                haptic(HapticFeedbackConstants.KEYBOARD_TAP)
                onClick()
            }
        }
    }

    /** 退格键：点击退一码；长按连删（§3.3）；左滑整段清除。 */
    private fun backspaceView(): TextView {
        val swipeThreshold = dp(64)
        var downX = 0f
        var swiped = false
        return baseKey("⌫").apply {
            val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f)
            lp.setMargins(dp(3), dp(4), dp(3), dp(4))
            layoutParams = lp

            val repeatRunnable = object : Runnable {
                override fun run() {
                    if (rawInput.isNotEmpty()) {
                        LianaJni.backspace(session)
                        refreshCandidates()
                    } else {
                        sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
                    }
                    repeatHandler.postDelayed(this, 65)
                }
            }
            setOnTouchListener { v, ev ->
                when (ev.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downX = ev.x; swiped = false
                        v.isPressed = true
                        repeatHandler.postDelayed(repeatRunnable, 300)
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        if (!swiped && downX - ev.x > swipeThreshold) {
                            swiped = true
                            repeatHandler.removeCallbacks(repeatRunnable)
                            // 左滑 = 整段组合清除（退格版的 Esc）
                            LianaJni.clear(session)
                            v.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            refreshCandidates()
                        }
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        v.isPressed = false
                        repeatHandler.removeCallbacks(repeatRunnable)
                        if (!swiped) {
                            v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                            onBackspace()
                        }
                        true
                    }
                    else -> false
                }
            }
        }
    }

    private fun baseKey(label: String): TextView {
        return TextView(this).apply {
            text = label
            gravity = Gravity.CENTER
            textSize = LianaTheme.FONT_KEY
            setTextColor(LianaTheme.TEXT)
            typeface = Typeface.DEFAULT_BOLD
            background = GradientDrawable().apply {
                cornerRadius = dp(8).toFloat()
                setColor(LianaTheme.KEY)
            }
        }
    }

    private fun haptic(constant: Int) {
        inputViewRef?.performHapticFeedback(constant)
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    // ---- 按键行为（与 macOS 端行为约定一致） ----

    private fun onLetter(ch: Char) {
        if (session == 0L) return
        if (currentMode() == "en") {
            commitText(ch.toString())
            return
        }
        LianaJni.feed(session, ch.toString())
        refreshCandidates()
    }

    private fun onBackspace() {
        if (session == 0L) return
        if (rawInput.isNotEmpty()) {
            LianaJni.backspace(session)
            refreshCandidates()
        } else {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
        }
    }

    private fun onSpace() {
        if (candidates.isNotEmpty()) {
            selectCandidate(0, strong = true)
        } else {
            commitText(" ")
        }
    }

    private fun onEnter() {
        if (rawInput.isNotEmpty()) {
            commitRaw()
        } else {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
        }
    }

    private fun onModeToggle() {
        modeIdx = (modeIdx + 1) % MODES.size
        applyMode()
    }

    private fun onTraditionalToggle() {
        val on = !LianaJni.traditional(session)
        LianaJni.setTraditional(session, on)
        tradButton.text = if (on) "繁" else "简"
        refreshCandidates()
    }

    private fun applyMode() {
        val mode = MODES[modeIdx]
        LianaJni.setMode(session, mode)
        LianaJni.clear(session)
        modeButton.text = when (mode) {
            "pinyin" -> "中"
            "en" -> "EN"
            else -> mode
        }
        refreshCandidates()
    }

    private fun currentMode(): String = MODES[modeIdx]

    private fun selectCandidate(index: Int, strong: Boolean = false) {
        val text = LianaJni.select(session, index) ?: return
        commitText(text)
        // 上屏加强触觉：形成"上屏了"的身体确认（§3.1）
        haptic(HapticFeedbackConstants.LONG_PRESS)
    }

    private fun commitRaw() {
        val text = LianaJni.commitRaw(session) ?: return
        commitText(text)
        haptic(HapticFeedbackConstants.LONG_PRESS)
    }

    private fun commitText(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    // ---- 候选刷新 ----

    private fun refreshCandidates() {
        if (session == 0L) return
        candidateStrip.removeAllViews()

        val json = LianaJni.compositionJson(session)
        if (json == null) {
            candidates = emptyList()
            rawInput = ""
            return
        }
        val obj = JSONObject(json)
        rawInput = obj.optString("raw", "")
        val preedit = obj.optString("preedit", "")

        if (rawInput.isEmpty()) {
            candidates = emptyList()
            return
        }

        // 组合中提示：raw › preedit
        val composing = TextView(this).apply {
            text = if (preedit.isNotEmpty()) "$rawInput › $preedit" else rawInput
            textSize = 14f
            setTextColor(LianaTheme.SECONDARY)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(12), 0)
        }
        candidateStrip.addView(composing)

        val arr = obj.optJSONArray("candidates") ?: return
        candidates = (0 until minOf(arr.length(), MAX_CANDIDATES)).mapNotNull { i ->
            arr.optJSONObject(i)?.optString("text")?.takeIf { it.isNotEmpty() }
        }
        candidates.forEachIndexed { i, text ->
            candidateStrip.addView(candidateView(text, i))
        }
    }

    /** 候选条目：点击选中；上滑 ≥ 24dp 直接着该候选上屏（§3.2）。 */
    private fun candidateView(text: String, index: Int): TextView {
        val swipeUpThreshold = dp(24)
        var downY = 0f
        var swiped = false
        return TextView(this).apply {
            this.text = text
            textSize = LianaTheme.FONT_CANDIDATE
            setTextColor(LianaTheme.TEXT)
            typeface = Typeface.DEFAULT_BOLD
            background = GradientDrawable().apply {
                cornerRadius = dp(6).toFloat()
                setColor(LianaTheme.KEY_PRESSED)
            }
            gravity = Gravity.CENTER
            setPadding(dp(12), 0, dp(12), 0)
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT)
            lp.setMargins(dp(3), 0, dp(3), 0)
            layoutParams = lp
            setOnTouchListener { v, ev ->
                when (ev.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downY = ev.y; swiped = false
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        if (!swiped && downY - ev.y > swipeUpThreshold) {
                            swiped = true
                            selectCandidate(index)
                        }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        if (!swiped) selectCandidate(index)
                        true
                    }
                    else -> false
                }
            }
        }
    }

    companion object {
        private const val MAX_CANDIDATES = 9
        private val MODES = arrayOf("pinyin", "en")
    }
}