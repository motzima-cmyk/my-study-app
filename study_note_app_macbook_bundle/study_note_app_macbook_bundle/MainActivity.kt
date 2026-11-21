package com.example.adaptive_tablet_study_note

import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * ============================================================================
 * Android 태블릿 (Galaxy Tab S 시리즈) S펜 측면 버튼 & 에어액션 네이티브 브리지
 * 위치: android/app/src/main/kotlin/com/example/adaptive_tablet_study_note/MainActivity.kt
 * ============================================================================
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.studynote.stylus/pencil_interactions"
    private var stylusChannel: MethodChannel? = null
    private var lastStylusButtonTriggerMs: Long = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        stylusChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        )
    }

    /**
     * 1. 갤럭시 S펜 호버 상태에서 측면 버튼(BUTTON_STYLUS_PRIMARY) 클릭 감지
     */
    override fun dispatchGenericMotionEvent(ev: MotionEvent?): Boolean {
        if (ev != null && ev.isFromSource( android.view.InputDevice.SOURCE_STYLUS )) {
            val isStylusButtonPressed =
                (ev.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY) != 0 ||
                (ev.buttonState and MotionEvent.BUTTON_STYLUS_SECONDARY) != 0

            val now = System.currentTimeMillis()
            if (isStylusButtonPressed && (now - lastStylusButtonTriggerMs) > 350L) {
                lastStylusButtonTriggerMs = now
                stylusChannel?.invokeMethod(
                    "onSPenButtonClicked",
                    mapOf("source" to "hover_stylus_button", "timestampMs" to now)
                )
                return true
            }
        }
        return super.dispatchGenericMotionEvent(ev)
    }

    /**
     * 2. 삼성 S펜 블루투스 에어액션(Air Action 원격 버튼) KeyEvent 매핑 감지
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_F19 || keyCode == KeyEvent.KEYCODE_F20) {
            stylusChannel?.invokeMethod(
                "onSPenButtonClicked",
                mapOf(
                    "source" to "spen_air_action_key",
                    "keyCode" to keyCode,
                    "timestampMs" to System.currentTimeMillis()
                )
            )
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}
