package com.example.matting

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.annotation.NonNull

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** MattingPlugin */
class MattingPlugin: FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "matting")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    if (call.method == "getPlatformVersion") {
      result.success("Android ${android.os.Build.VERSION.RELEASE}")
    } else if (call.method == "convertHeicToPng") {
      convertHeicToPng(call, result)
    } else {
      result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  /// Converts HEIC / HEIF / AVIF image bytes to PNG using Android's built-in decoder.
  private fun convertHeicToPng(call: MethodCall, result: Result) {
    try {
      val bytes = call.arguments as? ByteArray
      if (bytes == null) {
        result.error("INVALID_ARGUMENT", "Expected raw image bytes", null)
        return
      }

      val bitmap: Bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        ?: run {
          result.error("DECODE_FAILED", "Unable to decode the image on Android", null)
          return
        }

      val outputStream = java.io.ByteArrayOutputStream()
      val success = bitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)
      bitmap.recycle()

      if (!success) {
        result.error("ENCODE_FAILED", "Unable to encode to PNG", null)
        return
      }

      result.success(outputStream.toByteArray())
    } catch (e: Exception) {
      result.error("CONVERT_ERROR", e.message, null)
    }
  }
}
