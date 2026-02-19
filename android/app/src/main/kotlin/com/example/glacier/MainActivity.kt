package com.example.glacier

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
  companion object {
    private const val HARDWARE_KEY_EVENT_CHANNEL = "glacier/hardware_keys"
  }

  private var hardwareKeySink: EventChannel.EventSink? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HARDWARE_KEY_EVENT_CHANNEL,
        )
        .setStreamHandler(
            object : EventChannel.StreamHandler {
              override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                hardwareKeySink = events
              }

              override fun onCancel(arguments: Any?) {
                hardwareKeySink = null
              }
            },
        )
  }

  override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
    val sink = hardwareKeySink
    if (sink != null && event.repeatCount == 0) {
      when (keyCode) {
        KeyEvent.KEYCODE_VOLUME_UP -> {
          sink.success("volume_up")
          return true
        }

        KeyEvent.KEYCODE_VOLUME_DOWN -> {
          sink.success("volume_down")
          return true
        }
      }
    }
    return super.onKeyDown(keyCode, event)
  }
}
