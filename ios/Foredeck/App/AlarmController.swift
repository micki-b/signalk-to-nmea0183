import Foundation
import UserNotifications
import AVFoundation
import AudioToolbox
#if canImport(UIKit)
import UIKit
#endif

/// The anchor alarm's output side.
///
/// An alarm that only draws something on screen is useless: the phone is in a
/// bunk, face down, at three in the morning. So this fires a notification, a
/// sound, and a repeating vibration, and keeps repeating until someone
/// acknowledges it. It also broadcasts, so the whole crew wakes rather than
/// whichever phone happened to be watching.
@MainActor
final class AlarmController: ObservableObject {
    @Published private(set) var isFiring = false
    @Published private(set) var lastDistance: Double = 0

    private var repeatTimer: Timer?

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func fire(distanceMeters: Double, radiusMeters: Double) {
        lastDistance = distanceMeters
        guard !isFiring else { return }
        isFiring = true

        notify(distanceMeters: distanceMeters, radiusMeters: radiusMeters)
        alert()

        // Keep going. A single buzz gets slept through, which defeats the
        // entire purpose of an anchor alarm.
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.alert() }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    func acknowledge() {
        isFiring = false
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func alert() {
        #if canImport(UIKit)
        AudioServicesPlayAlertSoundWithCompletion(SystemSoundID(kSystemSoundID_Vibrate), nil)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
        #endif
    }

    private func notify(distanceMeters: Double, radiusMeters: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Anchor drag alarm"
        content.body = String(
            format: "%.0f m from where the anchor went down (limit %.0f m).",
            distanceMeters,
            radiusMeters
        )
        // Not .defaultCritical: that needs Apple's critical-alert entitlement,
        // which has to be applied for. Worth doing for an anchor alarm, but it
        // should not be a prerequisite for the app working at all.
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "foredeck.anchor.alarm.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
