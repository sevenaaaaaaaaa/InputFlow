package dev.liana.ime

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject

/**
 * 松萝 Android 输入法服务。
 *
 * 与 macOS 端同构：Swift 外壳的职责（会话管理 / 候选栏 / 键盘）在这里用
 * framework API 重写，引擎逻辑全部来自同一份 Rust 内核（libliana_jni.so）。
 *
 * 阶段 1 MVP：拼音 QWERTY + 候选栏 + 中英切换 + 简繁切换 + 用户词持久化。
 */
class LianaImeService : InputMethodService() {

    private var session: Long = 0
    private var modeIdx = 0
    private var candidates: List<String> = emptyList()
    private var rawInput: String = ""

    private lateinit var candidateStrip: LinearLayout
    private lateinit var modeButton: TextView
    private lateinit var tradButton: TextView

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
            setBackgroundColor(0xF51C1C22.toInt())
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

        // QWERTY 三行
        val rows = listOf(
            "qwertyuiop",
            "asdfghjkl",
            "zxcvbnm",
        )
        rows.forEachIndexed { i, keys ->
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
            }
            keys.forEach { ch -> row.addView(keyView(ch.toString(), weight = 1f) { onLetter(ch) }) }
            if (i == 2) {
                row.addView(keyView("⌫", weight = 1f) { onBackspace() })
            }
            root.addView(row, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(46)))
        }

        // 底部功能行
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
        return root
    }

    private fun keyView(label: String, weight: Float, onClick: () -> Unit): TextView {
        return TextView(this).apply {
            text = label
            gravity = Gravity.CENTER
            textSize = 16f
            setTextColor(0xFFE8E8EC.toInt())
            typeface = Typeface.DEFAULT_BOLD
            background = GradientDrawable().apply {
                cornerRadius = dp(8).toFloat()
                setColor(0xFF2A2A33.toInt())
            }
            val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, weight)
            lp.setMargins(dp(3), dp(4), dp(3), dp(4))
            layoutParams = lp
            setOnClickListener { onClick() }
        }
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
            selectCandidate(0)
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

    private fun selectCandidate(index: Int) {
        val text = LianaJni.select(session, index) ?: return
        commitText(text)
    }

    private fun commitRaw() {
        val text = LianaJni.commitRaw(session) ?: return
        commitText(text)
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
            setTextColor(0xFF9A9AA5.toInt())
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(12), 0)
        }
        candidateStrip.addView(composing)

        val arr = obj.optJSONArray("candidates") ?: return
        candidates = (0 until minOf(arr.length(), MAX_CANDIDATES)).mapNotNull { i ->
            arr.optJSONObject(i)?.optString("text")?.takeIf { it.isNotEmpty() }
        }
        candidates.forEachIndexed { i, text ->
            val tv = TextView(this).apply {
                this.text = text
                textSize = 17f
                setTextColor(0xFFE8E8EC.toInt())
                typeface = Typeface.DEFAULT_BOLD
                background = GradientDrawable().apply {
                    cornerRadius = dp(6).toFloat()
                    setColor(0xFF33333E.toInt())
                }
                gravity = Gravity.CENTER
                setPadding(dp(12), 0, dp(12), 0)
                val lp = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT)
                lp.setMargins(dp(3), 0, dp(3), 0)
                layoutParams = lp
                setOnClickListener { selectCandidate(i) }
            }
            candidateStrip.addView(tv)
        }
    }

    companion object {
        private const val MAX_CANDIDATES = 9
        private val MODES = arrayOf("pinyin", "en")
    }
}