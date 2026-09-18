package com.tiger.usbmanager.ui

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import com.tiger.usbmanager.R

/** Shared visual language inspired by the supplied chooser. */
object UiStyle {
    fun dp(c: Context, value: Int) = (c.resources.displayMetrics.density * value).toInt()
    fun round(c: Context, color: Int, radius: Int = 22, stroke: Int? = null) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(c, radius).toFloat()
        if (stroke != null) setStroke(dp(c, 1), stroke)
    }
    fun card(v: View, color: Int = v.context.getColor(R.color.bg_card)) {
        v.background = round(v.context, color); v.clipToOutline = true
    }
    fun heading(c: Context, text: String, size: Float = 25f) = TextView(c).apply {
        this.text = text; textSize = size; setTextColor(c.getColor(R.color.text_primary))
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setPadding(0, dp(c, 6), 0, dp(c, 8))
    }
    fun note(c: Context, text: String) = TextView(c).apply {
        this.text = text; textSize = 13f; setTextColor(c.getColor(R.color.text_secondary))
        setLineSpacing(0f, 1.2f); setPadding(0, 0, 0, dp(c, 16))
    }
    fun option(c: Context) = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_checked), round(c, c.getColor(R.color.banner_unknown_bg), 16, c.getColor(R.color.accent)))
        addState(intArrayOf(), round(c, c.getColor(R.color.bg_page), 16))
    }
    fun polish(view: View) {
        if (view is Button && view !is android.widget.CompoundButton) {
            val c = view.context
            view.isAllCaps = false; view.textSize = 14f; view.minHeight = dp(c, 48)
            view.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            view.background = round(c, c.getColor(R.color.accent), 16)
            view.backgroundTintList = ColorStateList.valueOf(c.getColor(R.color.accent))
            val night = c.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES
            view.setTextColor(if (night) android.graphics.Color.rgb(15, 27, 45) else android.graphics.Color.WHITE)
            view.setPadding(dp(c, 18), dp(c, 10), dp(c, 18), dp(c, 10))
            (view.layoutParams as? ViewGroup.MarginLayoutParams)?.let { it.topMargin = dp(c, 6); it.bottomMargin = dp(c, 6) }
        }
        if (view is ViewGroup) for (i in 0 until view.childCount) polish(view.getChildAt(i))
    }
}
