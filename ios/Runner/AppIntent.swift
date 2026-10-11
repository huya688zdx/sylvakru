//
//  AppIntent.swift
//  Runner
//
//  Created by wuhangyu on 2026/9/27.
//

import AppIntents
import Flutter
import WidgetKit
import home_widget

var audioControlChannel: FlutterMethodChannel?

@available(iOSApplicationExtension, unavailable)
extension BackgroundIntent: ForegroundContinuableIntent {}
struct BackgroundIntent: AppIntent {
  static var title: LocalizedStringResource = "Background Intent"

  // @available(iOS 27.0, *)
  // static var allowedExecutionTargets: IntentExecutionTargets {
  //   [.main]
  // }

  @Parameter(title: "Function")
  var function: String

  public init() {
    self.function = "Null"
  }

  public init(function: String) {
    self.function = function
  }

  func perform() async throws -> some IntentResult {

    DispatchQueue.main.async {
      audioControlChannel?.invokeMethod(
        function,
        arguments: nil
      )
    }

    return .result()
  }
}
