import CoreGraphics
import Foundation
import CoreMotion
import AppKit
import ApplicationServices
import AudioToolbox

// MARK: - Permission Check

let promptOption = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
] as CFDictionary

var isAXTrusted: Bool = AXIsProcessTrustedWithOptions(promptOption)

func checkAccessibilityPermissions() {
    isAXTrusted = AXIsProcessTrustedWithOptions(promptOption)
    if !isAXTrusted {
        print("""
        ⚠️  Accessibility permissions are recommended for full functionality!
        • Window activation (NSRunningApplication) works immediately.
        • To enable mouse cursor warping & direct AX window raising:
          Grant access in: System Settings → Privacy & Security → Accessibility
        """)
    }
}


// MARK: - Screen Target Structure

struct ScreenTarget {
    let id: Int
    let screen: NSScreen
    let name: String
    let frame: CGRect       // AppKit coordinates
    let cgFrame: CGRect     // CoreGraphics coordinates
    var autoYaw: Double
    var autoPitch: Double
    var calibratedYaw: Double?
    var calibratedPitch: Double?
    var lastMouseLocation: CGPoint? // AppKit coordinates
    
    var effectiveYaw: Double {
        return calibratedYaw ?? autoYaw
    }
    
    var effectivePitch: Double {
        return calibratedPitch ?? autoPitch
    }
}

// MARK: - App State

enum AppMode: String {
    case focus = "focus"   // Switch window/typing focus to screen you look at
    case mouse = "mouse"   // Original airpodmouse: continuous cursor movement
}

var currentMode: AppMode = .focus
var screens: [ScreenTarget] = []
var activeScreenIndex: Int = 0

// Head tracking state
var centerYaw: Double = 0.0
var centerPitch: Double = 0.0
var currentYaw: Double = 0.0
var currentPitch: Double = 0.0
var currentRoll: Double = 0.0
var hasInitialAttitude: Bool = false

// Focus mode tuning
var dwellTime: Double = 0.15            // Seconds gaze must remain on target screen before switching (default 0.15s)
var hysteresisDegrees: Double = 4.0     // Angular margin to prevent flipping at borders (default 4.0°)
var warpCursorOnSwitch: Bool = true     // Move mouse cursor to screen when switching focus
var soundFeedback: Bool = false         // Play subtle click sound on screen switch

// Sensitivity & Angle tuning (Solves small neck movement for close/stacked screens)
var pitchGain: Double = 3.0             // Vertical sensitivity multiplier (default 3.0x - humans tilt neck much less than yaw)
var yawGain: Double = 1.0               // Horizontal sensitivity multiplier (default 1.0x)
var autoVerticalAngleDegrees: Double = 6.0 // Default half-angle for stacked screens (±6.0° instead of ±16°)

// Dwell filter state
var pendingScreenIndex: Int? = nil
var pendingStartTime: Double = 0.0

// Mouse mode variables (from original airpodmouse)
var lastYaw: Double?
var lastPitch: Double?
var smoothedDx: Double = 0
var smoothedDy: Double = 0
var smoothingFactor: Double = 0.2
var deadzone: Double = 0.05
var invertY: Bool = false
var sensitivityX: Double = 3000
var sensitivityY: Double = 3000

// MARK: - Coordinate Conversion

func getPrimaryScreenHeight() -> CGFloat {
    return NSScreen.screens.first?.frame.height ?? 900
}

func appKitToCG(point: CGPoint) -> CGPoint {
    let primaryHeight = getPrimaryScreenHeight()
    return CGPoint(x: point.x, y: primaryHeight - point.y)
}

func appKitToCGRect(_ rect: CGRect) -> CGRect {
    let primaryHeight = getPrimaryScreenHeight()
    return CGRect(
        x: rect.origin.x,
        y: primaryHeight - (rect.origin.y + rect.height),
        width: rect.width,
        height: rect.height
    )
}

// MARK: - Screen Setup & Auto Layout

func refreshScreens() {
    let nsScreens = NSScreen.screens
    guard !nsScreens.isEmpty else {
        screens = []
        return
    }
    
    var newScreens: [ScreenTarget] = []
    
    // Determine overall layout geometry
    let minX = nsScreens.map { $0.frame.origin.x }.min() ?? 0
    let maxX = nsScreens.map { $0.frame.maxX }.max() ?? 1000
    let minY = nsScreens.map { $0.frame.origin.y }.min() ?? 0
    let maxY = nsScreens.map { $0.frame.maxY }.max() ?? 1000
    
    let spanX = maxX - minX
    let spanY = maxY - minY
    let isHorizontal = spanX >= spanY
    
    // Sort screens based on layout
    let sortedScreens: [NSScreen]
    if isHorizontal {
        sortedScreens = nsScreens.sorted(by: { $0.frame.midX < $1.frame.midX })
    } else {
        sortedScreens = nsScreens.sorted(by: { $0.frame.midY < $1.frame.midY })
    }
    
    let count = sortedScreens.count
    
    for (idx, screen) in sortedScreens.enumerated() {
        let name = screen.localizedName
        let frame = screen.frame
        let cgFrame = appKitToCGRect(frame)
        
        var autoYaw = 0.0
        var autoPitch = 0.0
        
        if count == 1 {
            autoYaw = 0.0
            autoPitch = 0.0
        } else if isHorizontal {
            if count == 2 {
                // 2 screens: Left ~ -18° (-0.32 rad), Right ~ +18° (+0.32 rad)
                autoYaw = (idx == 0) ? -0.32 : 0.32
            } else if count == 3 {
                // 3 screens: Left ~ -26° (-0.45 rad), Center 0°, Right ~ +26° (+0.45 rad)
                if idx == 0 { autoYaw = -0.45 }
                else if idx == 1 { autoYaw = 0.0 }
                else { autoYaw = 0.45 }
            } else {
                let step = 0.9 / Double(count - 1)
                autoYaw = -0.45 + Double(idx) * step
            }
        } else {
            // Vertical arrangement: screens stacked vertically (e.g., laptop below monitor)
            let vertRad = autoVerticalAngleDegrees * (.pi / 180.0)
            if count == 2 {
                // Bottom screen (idx 0): -vertRad, Top screen (idx 1): +vertRad
                autoPitch = (idx == 0) ? -vertRad : vertRad
            } else {
                let step = (vertRad * 2.0) / Double(count - 1)
                autoPitch = -vertRad + Double(idx) * step
            }
        }
        
        // Preserve prior calibration and cursor pos if existing
        let prior = screens.first(where: { $0.name == name && $0.frame == frame })
        
        newScreens.append(ScreenTarget(
            id: idx,
            screen: screen,
            name: name,
            frame: frame,
            cgFrame: cgFrame,
            autoYaw: autoYaw,
            autoPitch: autoPitch,
            calibratedYaw: prior?.calibratedYaw,
            calibratedPitch: prior?.calibratedPitch,
            lastMouseLocation: prior?.lastMouseLocation
        ))
    }
    
    screens = newScreens
    
    // Find current active screen based on mouse
    let mouseLoc = NSEvent.mouseLocation
    if let found = screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) {
        activeScreenIndex = found.id
    } else {
        activeScreenIndex = 0
    }
}

// MARK: - Window Activation & Keyboard Focus

func getFrontmostWindow(on target: ScreenTarget) -> (pid: pid_t, name: String, title: String, bounds: CGRect)? {
    let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    
    for win in windowList {
        guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0,
              let pid = win[kCGWindowOwnerPID as String] as? Int32,
              let boundsDict = win[kCGWindowBounds as String] as? [String: Any],
              let winBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            continue
        }
        
        let owner = win[kCGWindowOwnerName as String] as? String ?? ""
        let title = win[kCGWindowName as String] as? String ?? ""
        
        // Filter out tiny overlays or background tools
        if winBounds.width < 120 || winBounds.height < 120 { continue }
        
        let intersection = winBounds.intersection(target.cgFrame)
        if !intersection.isNull && intersection.width > 60 && intersection.height > 60 {
            return (pid: pid, name: owner, title: title, bounds: winBounds)
        }
    }
    return nil
}

func raiseWindowWithAX(pid: pid_t, screenCgRect: CGRect) {
    let appRef = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else {
        return
    }
    
    for window in windows {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
           AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success {
            var point = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            let rect = CGRect(origin: point, size: size)
            if rect.intersects(screenCgRect) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                break
            }
        }
    }
}

func switchFocus(to targetIndex: Int) {
    guard targetIndex >= 0 && targetIndex < screens.count else { return }
    let target = screens[targetIndex]
    let oldIndex = activeScreenIndex
    
    // Save current mouse location to old screen
    if oldIndex >= 0 && oldIndex < screens.count {
        screens[oldIndex].lastMouseLocation = NSEvent.mouseLocation
    }
    
    activeScreenIndex = targetIndex
    
    // Look for top application window on target screen
    let front = getFrontmostWindow(on: target)
    var activatedAppName = "Finder (Desktop)"
    
    if let front = front {
        activatedAppName = front.name
        if let app = NSRunningApplication(processIdentifier: front.pid) {
            if #available(macOS 14.0, *) {
                _ = app.activate()
            } else {
                _ = app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        if isAXTrusted {
            raiseWindowWithAX(pid: front.pid, screenCgRect: target.cgFrame)
        }
    }
    
    // Warp mouse cursor if enabled
    if warpCursorOnSwitch && isAXTrusted {
        var targetCGPoint: CGPoint
        if let lastLoc = target.lastMouseLocation {
            targetCGPoint = appKitToCG(point: lastLoc)
        } else if let front = front {
            targetCGPoint = CGPoint(x: front.bounds.midX, y: front.bounds.midY)
        } else {
            targetCGPoint = CGPoint(x: target.cgFrame.midX, y: target.cgFrame.midY)
        }
        CGWarpMouseCursorPosition(targetCGPoint)
    }
    
    // Optional audio feedback
    if soundFeedback {
        AudioServicesPlaySystemSound(1057) // subtle click
    }
    
    let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(timeStr)] 👀 Looked at Screen [\(targetIndex)] (\(target.name)) ➔ Focused: \(activatedAppName)")
}

// MARK: - Focus Decision Engine

func updateFocusDecision(yaw: Double, pitch: Double) {
    guard screens.count > 1 else { return }
    
    let relYaw = yaw - centerYaw
    let relPitch = pitch - centerPitch
    
    // Calculate angular distance to each screen target
    var bestIndex = activeScreenIndex
    var bestDist = Double.infinity
    
    // Adaptively scale hysteresis based on minimum distance between screen neighbors
    var minScreenDist = Double.infinity
    for i in 0..<screens.count {
        for j in (i+1)..<screens.count {
            let dy = (screens[i].effectiveYaw - screens[j].effectiveYaw) * yawGain
            let dp = (screens[i].effectivePitch - screens[j].effectivePitch) * pitchGain
            let d = sqrt(dy * dy + dp * dp)
            if d < minScreenDist { minScreenDist = d }
        }
    }
    
    let baseHystRad = hysteresisDegrees * (.pi / 180.0)
    // Scale hysteresis so it never exceeds 30% of neighbor distance, allowing close screens to switch easily
    let effectiveHystRad = min(baseHystRad, minScreenDist.isFinite ? (minScreenDist * 0.3) : baseHystRad)
    
    // First find current screen distance
    let currentTarget = screens[activeScreenIndex]
    let curDy = (relYaw - currentTarget.effectiveYaw) * yawGain
    let curDp = (relPitch - currentTarget.effectivePitch) * pitchGain
    let currentDist = sqrt(curDy * curDy + curDp * curDp)
    
    for (idx, target) in screens.enumerated() {
        let dy = (relYaw - target.effectiveYaw) * yawGain
        let dp = (relPitch - target.effectivePitch) * pitchGain
        let dist = sqrt(dy * dy + dp * dp)
        
        if dist < bestDist {
            bestDist = dist
            bestIndex = idx
        }
    }
    
    // Apply hysteresis: only candidate if significantly closer than current screen
    let candidateIndex: Int
    if bestIndex != activeScreenIndex && bestDist < (currentDist - effectiveHystRad) {
        candidateIndex = bestIndex
    } else {
        candidateIndex = activeScreenIndex
    }
    
    let now = CACurrentMediaTime()
    
    if candidateIndex != activeScreenIndex {
        if pendingScreenIndex != candidateIndex {
            pendingScreenIndex = candidateIndex
            pendingStartTime = now
        } else {
            // Check dwell threshold
            if (now - pendingStartTime) >= dwellTime {
                switchFocus(to: candidateIndex)
                pendingScreenIndex = nil
            }
        }
    } else {
        pendingScreenIndex = nil
    }
}

// MARK: - Motion Processing

let manager = CMHeadphoneMotionManager()

func startMotionUpdates() {
    guard manager.isDeviceMotionAvailable else {
        print("❌ CoreMotion headphone motion tracking is not available on this device.")
        return
    }
    
    manager.startDeviceMotionUpdates(to: .main) { motion, error in
        guard let motion = motion else { return }
        
        let yaw = motion.attitude.yaw
        let pitch = motion.attitude.pitch
        let roll = motion.attitude.roll
        
        currentYaw = yaw
        currentPitch = pitch
        currentRoll = roll
        
        if !hasInitialAttitude {
            centerYaw = yaw
            centerPitch = pitch
            hasInitialAttitude = true
            print("✨ AirPods head tracking calibrated to initial center position.")
        }
        
        if currentMode == .focus {
            updateFocusDecision(yaw: yaw, pitch: pitch)
        } else {
            // Original Mouse Mode continuous tracking
            guard let previousYaw = lastYaw,
                  let previousPitch = lastPitch else {
                lastYaw = yaw
                lastPitch = pitch
                return
            }
            
            func applyCurve(_ value: Double, exponent: Double = 1.3) -> Double {
                let sign = value < 0 ? -1.0 : 1.0
                return sign * pow(abs(value), exponent)
            }
            
            var dx = applyCurve((previousYaw - yaw) * sensitivityX)
            var dy = applyCurve((invertY ? (pitch - previousPitch) : (previousPitch - pitch)) * sensitivityY)
            
            lastYaw = yaw
            lastPitch = pitch
            
            if abs(dx) < deadzone { dx = 0 }
            if abs(dy) < deadzone { dy = 0 }
            
            smoothedDx = smoothedDx + smoothingFactor * (dx - smoothedDx)
            smoothedDy = smoothedDy + smoothingFactor * (dy - smoothedDy)
            
            let loc = NSEvent.mouseLocation
            let cgLoc = appKitToCG(point: loc)
            let targetPoint = CGPoint(x: cgLoc.x + smoothedDx, y: cgLoc.y + smoothedDy)
            CGWarpMouseCursorPosition(targetPoint)
        }
    }
}

// MARK: - Status Display

func rad2deg(_ rad: Double) -> Double {
    return rad * (180.0 / .pi)
}

func printStatus() {
    print("--------------------------------------------------")
    print("🎧 AirPods Screen Focus Status:")
    print("  Mode:               \(currentMode.rawValue.uppercased()) (Focus on look)")
    print("  Active Screen:      [\(activeScreenIndex)] \(screens[safe: activeScreenIndex]?.name ?? "None")")
    print("  Cursor Warp:        \(warpCursorOnSwitch ? "Enabled" : "Disabled")")
    print("  Dwell Time:         \(String(format: "%.2f", dwellTime))s")
    print("  Hysteresis:         \(String(format: "%.1f", hysteresisDegrees))° (auto-scales down for close screens)")
    print("  Vertical Gain (Y):  \(String(format: "%.1f", pitchGain))x (Higher = subtler head tilt needed)")
    print("  Horizontal Gain (X):\(String(format: "%.1f", yawGain))x")
    print("  Auto Vertical Angle:±\(String(format: "%.1f", autoVerticalAngleDegrees))°")
    print("  Audio Feedback:     \(soundFeedback ? "On" : "Off")")
    
    let relYawDeg = rad2deg(currentYaw - centerYaw)
    let relPitchDeg = rad2deg(currentPitch - centerPitch)
    print("  Current Head Pose:  Yaw: \(String(format: "%+.1f", relYawDeg))°, Pitch: \(String(format: "%+.1f", relPitchDeg))°")
    
    print("\n🖥  Configured Displays (\(screens.count)):")
    for s in screens {
        let isCurrent = (s.id == activeScreenIndex) ? "👉 [Active]" : "   "
        let yawDeg = rad2deg(s.effectiveYaw)
        let pitchDeg = rad2deg(s.effectivePitch)
        let calTag = (s.calibratedYaw != nil) ? "(Calibrated)" : "(Auto)"
        print("  \(isCurrent) Screen [\(s.id)]: \(s.name)")
        print("       Resolution: \(Int(s.frame.width))x\(Int(s.frame.height)) | Target: Yaw: \(String(format: "%+.1f", yawDeg))°, Pitch: \(String(format: "%+.1f", pitchDeg))° \(calTag)")
    }
    print("--------------------------------------------------")
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

func printHelp() {
    print("""
    ================== Available Commands ==================
    status / s       Show current status, screens, and angles
    center / c       Reset head zero-angle to current position
    cal <id>         Calibrate screen <id> to where you are looking now
                     (e.g., look at bottom screen and type 'cal 0', top screen 'cal 1')
    cal auto         Reset all screen target angles to auto-layout
    gainy <num>      Adjust vertical sensitivity (e.g. 'gainy 3.5' or 'gainy 4.0')
                     Higher = much smaller head tilt needed for top/bottom screens!
    gainx <num>      Adjust horizontal sensitivity (default: 1.0)
    pitch <deg>      Set default vertical angle for stacked screens (default: 6.0°)
    dwell <sec>      Set dwell stabilization time (e.g., 'dwell 0.15')
    hyst <deg>       Set hysteresis angle threshold (e.g., 'hyst 3')
    warp             Toggle mouse cursor warp on/off (currently: \(warpCursorOnSwitch))
    sound            Toggle audio chime on screen switch (currently: \(soundFeedback))
    mode             Toggle between 'focus' (look to type) and 'mouse' (cursor move)
    sim <id>         Simulate looking at screen <id> (tests window focus)
    exit / q         Quit application
    ========================================================
    """)
}

// MARK: - App Initialization

refreshScreens()
checkAccessibilityPermissions()
startMotionUpdates()

print("""
╔════════════════════════════════════════════════════════╗
║             🎧 AirPods Screen Focus v2.0               ║
║     Look at a screen to immediately type on it!        ║
╚════════════════════════════════════════════════════════╝
""")

if screens.count <= 1 {
    print("""
    ℹ️  Notice: \(screens.count) screen detected.
    Screen-focus mode shines with multiple monitors (e.g., Mac + External Display).
    You can test window focus activation anytime with: 'sim 0'
    """)
} else {
    print("✅ Detected \(screens.count) screens. Auto-layout configured.")
}

print("Type 'status' for info, 'center' to re-center head pose, or 'help' for commands.\n")

// Observe display changes (plugging / unplugging monitors)
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil,
    queue: .main
) { _ in
    print("\n🖥  Display configuration change detected. Refreshing screens...")
    refreshScreens()
    printStatus()
}

// Background CLI loop
DispatchQueue.global(qos: .userInteractive).async {
    while let rawInput = readLine() {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = input.lowercased()
        
        if lower == "exit" || lower == "quit" || lower == "q" {
            print("Quitting AirPods Screen Focus...")
            exit(0)
        } else if lower == "help" || lower == "?" {
            printHelp()
        } else if lower == "status" || lower == "s" {
            printStatus()
        } else if lower == "center" || lower == "c" || lower == "reset" {
            centerYaw = currentYaw
            centerPitch = currentPitch
            print("🎯 Head pose re-centered to current position (Yaw: \(String(format: "%.1f", rad2deg(currentYaw)))°, Pitch: \(String(format: "%.1f", rad2deg(currentPitch)))°).")
        } else if lower.hasPrefix("cal auto") {
            for i in 0..<screens.count {
                screens[i].calibratedYaw = nil
                screens[i].calibratedPitch = nil
            }
            print("🔄 Screen angles reset to automatic layout.")
            printStatus()
        } else if lower.hasPrefix("cal") {
            let parts = lower.split(separator: " ")
            if parts.count >= 2, let id = Int(parts[1]) {
                DispatchQueue.main.async {
                    if id >= 0 && id < screens.count {
                        let relY = currentYaw - centerYaw
                        let relP = currentPitch - centerPitch
                        screens[id].calibratedYaw = relY
                        screens[id].calibratedPitch = relP
                        print("✅ Calibrated Screen [\(id)] (\(screens[id].name)) to: Yaw \(String(format: "%+.1f", rad2deg(relY)))°, Pitch \(String(format: "%+.1f", rad2deg(relP)))°")
                    } else {
                        print("❌ Invalid screen id: \(id). Valid range: 0 ..< \(screens.count)")
                    }
                }
            } else {
                print("Usage: cal <screen_id> (e.g. 'cal 0' or 'cal 1')")
            }
        } else if lower.hasPrefix("gainy") || lower.hasPrefix("gy") {
            let prefix = lower.hasPrefix("gainy") ? "gainy" : "gy"
            let valStr = lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 0.5 && val <= 15.0 {
                pitchGain = val
                print("📐 Vertical sensitivity (Pitch Gain) set to \(val)x (Higher = smaller head tilt required)")
            } else {
                print("Usage: gainy <number> (e.g. 'gainy 3.5' or 'gainy 5.0')")
            }
        } else if lower.hasPrefix("gainx") || lower.hasPrefix("gx") {
            let prefix = lower.hasPrefix("gainx") ? "gainx" : "gx"
            let valStr = lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 0.5 && val <= 10.0 {
                yawGain = val
                print("📐 Horizontal sensitivity (Yaw Gain) set to \(val)x")
            } else {
                print("Usage: gainx <number> (e.g. 'gainx 1.2')")
            }
        } else if lower.hasPrefix("pitch") {
            let valStr = lower.dropFirst("pitch".count).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 1.0 && val <= 25.0 {
                autoVerticalAngleDegrees = val
                DispatchQueue.main.async {
                    refreshScreens()
                    print("📐 Default vertical screen half-angle set to ±\(val)° (Auto-layout updated)")
                    printStatus()
                }
            } else {
                print("Usage: pitch <degrees> (e.g. 'pitch 5.0')")
            }
        } else if lower.hasPrefix("dwell") {
            let valStr = lower.dropFirst("dwell".count).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 0.05 && val <= 2.0 {
                dwellTime = val
                print("⏱ Dwell time set to \(val)s")
            } else {
                print("Usage: dwell <seconds> (e.g. 'dwell 0.20')")
            }
        } else if lower.hasPrefix("hyst") {
            let valStr = lower.dropFirst("hyst".count).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 1.0 && val <= 30.0 {
                hysteresisDegrees = val
                print("📐 Hysteresis threshold set to \(val)°")
            } else {
                print("Usage: hyst <degrees> (e.g. 'hyst 6')")
            }
        } else if lower == "warp" {
            warpCursorOnSwitch = !warpCursorOnSwitch
            print("🖱 Mouse cursor warp on switch: \(warpCursorOnSwitch ? "Enabled" : "Disabled")")
        } else if lower == "sound" {
            soundFeedback = !soundFeedback
            print("🔊 Audio switch feedback: \(soundFeedback ? "Enabled" : "Disabled")")
        } else if lower == "mode" {
            if currentMode == .focus {
                currentMode = .mouse
                print("🔄 Switched to MOUSE mode (continuous cursor movement via head tracking)")
            } else {
                currentMode = .focus
                print("🔄 Switched to FOCUS mode (look at screen to switch typing focus)")
            }
        } else if lower.hasPrefix("sim") {
            let parts = lower.split(separator: " ")
            if parts.count >= 2, let id = Int(parts[1]) {
                DispatchQueue.main.async {
                    print("🧪 Simulating gaze switch to screen \(id)...")
                    switchFocus(to: id)
                }
            } else {
                print("Usage: sim <screen_id> (e.g. 'sim 0' or 'sim 1')")
            }
        } else {
            print("Unknown command: '\(input)'. Type 'help' for command list.")
        }
    }
    // Clean exit if stdin closes (piped or redirected)
    exit(0)
}

RunLoop.main.run()
