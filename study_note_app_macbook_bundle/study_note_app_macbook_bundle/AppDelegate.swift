import Flutter
import UIKit
import UserNotifications
import EventKit

/// ============================================================================
/// iPadOS Apple Pencil (더블탭/스퀴즈) & 로컬 알림(UNUserNotificationCenter) + 애플 캘린더(EventKit) 네이티브 브리지
/// 위치: ios/Runner/AppDelegate.swift
/// ============================================================================
@main
@objc class AppDelegate: FlutterAppDelegate, UIPencilInteractionDelegate {
  private var stylusChannel: FlutterMethodChannel?
  private var scheduleChannel: FlutterMethodChannel?
  private let eventStore = EKEventStore()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      // 1) Apple Pencil 더블탭/스퀴즈 채널
      stylusChannel = FlutterMethodChannel(
        name: "com.studynote.stylus/pencil_interactions",
        binaryMessenger: controller.binaryMessenger
      )

      if #available(iOS 12.1, *) {
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        controller.view.addInteraction(pencilInteraction)
      }

      // 2) AI 스터디 플래너 로컬 알림 & 캘린더 일정 등록 채널
      scheduleChannel = FlutterMethodChannel(
        name: "com.studynote.schedule/calendar_alarm",
        binaryMessenger: controller.binaryMessenger
      )
      scheduleChannel?.setMethodCallHandler { [weak self] (call, result) in
        guard let self = self else { return }
        switch call.method {
        case "schedulePomodoroNotifications":
          self.handleScheduleNotifications(call: call, result: result)
        case "insertCalendarEvents":
          self.handleInsertCalendarEvents(call: call, result: result)
        case "cancelAllPomodoroNotifications":
          UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @available(iOS 12.1, *)
  func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
    stylusChannel?.invokeMethod(
      "onApplePencilDoubleTap",
      arguments: [
        "preferredAction": UIPencilInteraction.preferredTapAction.rawValue,
        "timestampMs": Int(Date().timeIntervalSince1970 * 1000)
      ]
    )
  }

  @available(iOS 17.5, *)
  func pencilInteraction(
    _ interaction: UIPencilInteraction,
    didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
  ) {
    if squeeze.phase == .ended {
      stylusChannel?.invokeMethod(
        "onApplePencilDoubleTap",
        arguments: [
          "gesture": "squeeze",
          "timestampMs": Int(Date().timeIntervalSince1970 * 1000)
        ]
      )
    }
  }

  private func handleScheduleNotifications(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let blocks = args["blocks"] as? [[String: Any]] else {
      result(0)
      return
    }
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      guard granted else {
        DispatchQueue.main.async { result(0) }
        return
      }
      var scheduledCount = 0
      let isoFormatter = ISO8601DateFormatter()
      for block in blocks {
        let id = String(describing: block["id"] ?? Int.random(in: 1000...9999))
        let title = (block["title"] as? String) ?? "뽀모도로 학습 알림"
        let body = (block["body"] as? String) ?? "오늘의 목표 분량을 시작할 시간입니다."
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var triggerDate = Date().addingTimeInterval(60)
        if let isoStr = block["scheduledAtIso"] as? String,
           let parsed = isoFormatter.date(from: isoStr),
           parsed > Date() {
          triggerDate = parsed
        }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: "pomodoro_\(id)", content: content, trigger: trigger)
        center.add(req, withCompletionHandler: nil)
        scheduledCount += 1
      }
      DispatchQueue.main.async { result(scheduledCount) }
    }
  }

  private func handleInsertCalendarEvents(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let events = args["events"] as? [[String: Any]] else {
      result(0)
      return
    }
    let registerEvents = {
      var insertedCount = 0
      let isoFormatter = ISO8601DateFormatter()
      for ev in events {
        let event = EKEvent(eventStore: self.eventStore)
        event.title = (ev["title"] as? String) ?? "[AI 스터디] 뽀모도로 세션"
        event.notes = (ev["description"] as? String) ?? ""
        event.location = (ev["location"] as? String) ?? "AI 태블릿 스터디 노트"
        if let startStr = ev["startIso"] as? String, let sDate = isoFormatter.date(from: startStr) {
          event.startDate = sDate
        } else {
          event.startDate = Date()
        }
        if let endStr = ev["endIso"] as? String, let eDate = isoFormatter.date(from: endStr) {
          event.endDate = eDate
        } else {
          event.endDate = event.startDate.addingTimeInterval(1500)
        }
        event.calendar = self.eventStore.defaultCalendarForNewEvents
        do {
          try self.eventStore.save(event, span: .thisEvent)
          insertedCount += 1
        } catch {
          continue
        }
      }
      DispatchQueue.main.async { result(insertedCount) }
    }

    if #available(iOS 17.0, *) {
      eventStore.requestFullAccessToEvents { granted, _ in
        if granted { registerEvents() } else { DispatchQueue.main.async { result(0) } }
      }
    } else {
      eventStore.requestAccess(to: .event) { granted, _ in
        if granted { registerEvents() } else { DispatchQueue.main.async { result(0) } }
      }
    }
  }
}
