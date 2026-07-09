import Cocoa
import FlutterMacOS
import ImageIO
import CoreServices

public class MattingPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "matting", binaryMessenger: registrar.messenger)
    let instance = MattingPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    case "convertHeicToPng":
      convertHeicToPng(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Converts HEIC / HEIF / AVIF image bytes to PNG using ImageIO.
  private func convertHeicToPng(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? FlutterStandardTypedData else {
      result(FlutterError(code: "INVALID_ARGUMENT",
                          message: "Expected raw image bytes",
                          details: nil))
      return
    }

    let data = args.data as CFData
    guard let source = CGImageSourceCreateWithData(data, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      result(FlutterError(code: "DECODE_FAILED",
                          message: "Unable to decode the image with ImageIO",
                          details: nil))
      return
    }

    let mutableData = CFDataCreateMutable(nil, 0)!
    guard let destination = CGImageDestinationCreateWithData(
            mutableData, kUTTypePNG, 1, nil) else {
      result(FlutterError(code: "ENCODE_FAILED",
                          message: "Unable to create PNG destination",
                          details: nil))
      return
    }

    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      result(FlutterError(code: "FINALIZE_FAILED",
                          message: "Unable to finalize PNG encoding",
                          details: nil))
      return
    }

    result(FlutterStandardTypedData(bytes: mutableData as Data))
  }
}
