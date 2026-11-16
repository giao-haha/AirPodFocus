import AppKit
import CoreGraphics
import Foundation
import CoreMotion
import ApplicationServices
import AudioToolbox
import UserNotifications

// MARK: - Debug Logging

func debugLog(_ msg: String) {
    #if DEBUG
    NSLog("[AirPodFocus] %@", msg)
    #endif
}

// MARK: - Constants & Defaults Keys

struct PrefKeys {
    static let pitchGain = "airpodfocus.pitchGain"
    static let yawGain = "airpodfocus.yawGain"
    static let hysteresis = "airpodfocus.hysteresis"
    static let dwellTime = "airpodfocus.dwellTime"
    static let warpCursor = "airpodfocus.warpCursor"
    static let soundFeedback = "airpodfocus.soundFeedback"
    static let autoVerticalAngle = "airpodfocus.autoVerticalAngle"
    static let calibratedPrefix = "airpodfocus.cal."
}

// MARK: - Screen Target

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

enum AppMode: String {
    case focus = "focus"
    case mouse = "mouse"
}

// MARK: - Focus Engine & Shared State

class FocusEngine: NSObject, CMHeadphoneMotionManagerDelegate {
    static let shared = FocusEngine()
    
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
    var hasReceivedMotionData: Bool = false
    var lastMotionTimestamp: Double = 0.0
    var lastMotionError: String? = nil
    
    // User Tunable Settings (Persisted in UserDefaults)
    var pitchGain: Double = 2.5 {
        didSet { UserDefaults.standard.set(pitchGain, forKey: PrefKeys.pitchGain) }
    }
    var yawGain: Double = 1.0 {
        didSet { UserDefaults.standard.set(yawGain, forKey: PrefKeys.yawGain) }
    }
    var hysteresisDegrees: Double = 3.0 {
        didSet { UserDefaults.standard.set(hysteresisDegrees, forKey: PrefKeys.hysteresis) }
    }
    var dwellTime: Double = 0.15 {
        didSet { UserDefaults.standard.set(dwellTime, forKey: PrefKeys.dwellTime) }
    }
    var warpCursorOnSwitch: Bool = true {
        didSet { UserDefaults.standard.set(warpCursorOnSwitch, forKey: PrefKeys.warpCursor) }
    }
    var soundFeedback: Bool = true {
        didSet { UserDefaults.standard.set(soundFeedback, forKey: PrefKeys.soundFeedback) }
    }
    var autoVerticalAngleDegrees: Double = 10.0 {
        didSet { UserDefaults.standard.set(autoVerticalAngleDegrees, forKey: PrefKeys.autoVerticalAngle) }
    }
    
    // Dwell filter state
    var pendingScreenIndex: Int? = nil
    var pendingStartTime: Double = 0.0
    
    // Motion Manager & Dedicated Queue
    let motionManager = CMHeadphoneMotionManager()
    let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.systemsoftware.airpodfocus.motionQueue"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()
    
    // Periodic heartbeat / auto-reconnect timer
    var heartbeatTimer: Timer?
    
    // Mouse mode state
    var lastYaw: Double?
    var lastPitch: Double?
    var smoothedDx: Double = 0
    var smoothedDy: Double = 0
    var smoothingFactor: Double = 0.2
    var deadzone: Double = 0.05
    var invertY: Bool = false
    var sensitivityX: Double = 3000
    var sensitivityY: Double = 3000
    
    var onScreenChanged: ((Int) -> Void)?
    var onPoseUpdated: (() -> Void)?
    var onTrackingStateChanged: (() -> Void)?
    
    override init() {
        super.init()
        motionManager.delegate = self
        loadPreferences()
        refreshScreens()
        
        debugLog("FocusEngine initialized. Detected \(screens.count) screens.")
        
        // Start connection status monitoring
        motionManager.startConnectionStatusUpdates()
        debugLog("startConnectionStatusUpdates() called.")
        
        // Setup heartbeat timer on main runloop to monitor and auto-start motion tracking
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.heartbeatCheck()
        }
    }
    
    // Delegate callbacks
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        debugLog(">>> CMHeadphoneMotionManagerDelegate: AirPods CONNECTED <<<")
        startMotionTracking(force: true)
        DispatchQueue.main.async { [weak self] in
            self?.onTrackingStateChanged?()
        }
    }
    
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        debugLog(">>> CMHeadphoneMotionManagerDelegate: AirPods DISCONNECTED <<<")
        hasReceivedMotionData = false
        DispatchQueue.main.async { [weak self] in
            self?.onTrackingStateChanged?()
        }
    }
    
    func heartbeatCheck() {
        let available = motionManager.isDeviceMotionAvailable
        let active = motionManager.isDeviceMotionActive
        let now = CACurrentMediaTime()
        let receiving = hasReceivedMotionData && (now - lastMotionTimestamp < 3.0)
        
        if available && !active {
            debugLog("Heartbeat: AirPods available but motion tracking inactive. Auto-starting tracking...")
            startMotionTracking(force: false)
        } else if active && hasReceivedMotionData && !receiving {
            debugLog("Heartbeat: Motion data stream stalled for > 3.0s. Soft-restarting motion updates...")
            startMotionTracking(force: true)
        }
    }
    
    func loadPreferences() {
        let def = UserDefaults.standard
        if def.object(forKey: PrefKeys.pitchGain) != nil {
            pitchGain = def.double(forKey: PrefKeys.pitchGain)
        }
        if def.object(forKey: PrefKeys.yawGain) != nil {
            yawGain = def.double(forKey: PrefKeys.yawGain)
        }
        if def.object(forKey: PrefKeys.hysteresis) != nil {
            hysteresisDegrees = def.double(forKey: PrefKeys.hysteresis)
        }
        if def.object(forKey: PrefKeys.dwellTime) != nil {
            dwellTime = def.double(forKey: PrefKeys.dwellTime)
        }
        if def.object(forKey: PrefKeys.warpCursor) != nil {
            warpCursorOnSwitch = def.bool(forKey: PrefKeys.warpCursor)
        }
        if def.object(forKey: PrefKeys.soundFeedback) != nil {
            soundFeedback = def.bool(forKey: PrefKeys.soundFeedback)
        }
        if def.object(forKey: PrefKeys.autoVerticalAngle) != nil {
            autoVerticalAngleDegrees = def.double(forKey: PrefKeys.autoVerticalAngle)
        }
    }
    
    // MARK: - Screen Coordinate Helpers
    
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
    
    func refreshScreens() {
        let nsScreens = NSScreen.screens
        guard !nsScreens.isEmpty else {
            screens = []
            return
        }
        
        var newScreens: [ScreenTarget] = []
        let minX = nsScreens.map { $0.frame.origin.x }.min() ?? 0
        let maxX = nsScreens.map { $0.frame.maxX }.max() ?? 1000
        let minY = nsScreens.map { $0.frame.origin.y }.min() ?? 0
        let maxY = nsScreens.map { $0.frame.maxY }.max() ?? 1000
        
        let spanX = maxX - minX
        let spanY = maxY - minY
        let isHorizontal = spanX >= spanY
        
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
                    autoYaw = (idx == 0) ? -0.32 : 0.32
                } else if count == 3 {
                    if idx == 0 { autoYaw = -0.45 }
                    else if idx == 1 { autoYaw = 0.0 }
                    else { autoYaw = 0.45 }
                } else {
                    let step = 0.9 / Double(count - 1)
                    autoYaw = -0.45 + Double(idx) * step
                }
            } else {
                // Vertical arrangement: screen 0 (bottom) = -vertRad, screen 1 (top) = +vertRad
                let vertRad = autoVerticalAngleDegrees * (.pi / 180.0)
                if count == 2 {
                    autoPitch = (idx == 0) ? -vertRad : vertRad
                } else {
                    let step = (vertRad * 2.0) / Double(count - 1)
                    autoPitch = -vertRad + Double(idx) * step
                }
            }
            
            // Restore calibration from UserDefaults
            let calKeyYaw = "\(PrefKeys.calibratedPrefix)\(name).yaw"
            let calKeyPitch = "\(PrefKeys.calibratedPrefix)\(name).pitch"
            let savedYaw = UserDefaults.standard.object(forKey: calKeyYaw) as? Double
            let savedPitch = UserDefaults.standard.object(forKey: calKeyPitch) as? Double
            
            let prior = screens.first(where: { $0.name == name && $0.frame == frame })
            
            newScreens.append(ScreenTarget(
                id: idx,
                screen: screen,
                name: name,
                frame: frame,
                cgFrame: cgFrame,
                autoYaw: autoYaw,
                autoPitch: autoPitch,
                calibratedYaw: savedYaw ?? prior?.calibratedYaw,
                calibratedPitch: savedPitch ?? prior?.calibratedPitch,
                lastMouseLocation: prior?.lastMouseLocation
            ))
            
            debugLog("Screen [\(idx)]: '\(name)', autoYaw=\(String(format: "%+.1f", rad2deg(autoYaw)))°, autoPitch=\(String(format: "%+.1f", rad2deg(autoPitch)))°, calYaw=\(savedYaw != nil ? String(format: "%+.1f°", rad2deg(savedYaw!)) : "none"), calPitch=\(savedPitch != nil ? String(format: "%+.1f°", rad2deg(savedPitch!)) : "none")")
        }
        
        screens = newScreens
        validateCalibrations()
        
        let mouseLoc = NSEvent.mouseLocation
        if let found = screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) {
            activeScreenIndex = found.id
        } else {
            activeScreenIndex = 0
        }
    }
    
    func validateCalibrations() {
        guard screens.count > 1 else { return }
        for i in 0..<screens.count {
            for j in (i+1)..<screens.count {
                let dp = abs(screens[i].effectivePitch - screens[j].effectivePitch)
                let dy = abs(screens[i].effectiveYaw - screens[j].effectiveYaw)
                if dp < 0.05 && dy < 0.05 {
                    debugLog("⚠️ Conflict detected between Screen [\(i)] and Screen [\(j)]: angles too close (dp=\(String(format: "%.1f", rad2deg(dp)))°, dy=\(String(format: "%.1f", rad2deg(dy)))°). Invalidating calibrations and resetting to auto geometric angles!")
                    for k in 0..<screens.count {
                        screens[k].calibratedYaw = nil
                        screens[k].calibratedPitch = nil
                        UserDefaults.standard.removeObject(forKey: "\(PrefKeys.calibratedPrefix)\(screens[k].name).yaw")
                        UserDefaults.standard.removeObject(forKey: "\(PrefKeys.calibratedPrefix)\(screens[k].name).pitch")
                    }
                    UserDefaults.standard.synchronize()
                    return
                }
            }
        }
    }
    
    // MARK: - Motion Updates
    
    var lastLogTime: Double = 0.0
    
    func startMotionTracking(force: Bool = false) {
        let authStatus = CMHeadphoneMotionManager.authorizationStatus()
        let available = motionManager.isDeviceMotionAvailable
        let active = motionManager.isDeviceMotionActive
        
        debugLog("startMotionTracking(force: \(force)) called. authStatus=\(authStatus.rawValue), available=\(available), active=\(active)")
        
        if active && !force {
            debugLog("Motion updates already active. No need to restart.")
            return
        }
        
        if force && active {
            debugLog("Stopping previous motion updates to perform clean restart...")
            motionManager.stopDeviceMotionUpdates()
        }
        
        guard available else {
            debugLog("⚠️ Cannot start motion updates: isDeviceMotionAvailable is false. Ensure AirPods are connected and worn in-ear.")
            return
        }
        
        debugLog("Starting startDeviceMotionUpdates on background motionQueue...")
        
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self = self else { return }
            
            if let error = error {
                self.lastMotionError = error.localizedDescription
                debugLog("❌ Motion update error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onTrackingStateChanged?()
                }
                return
            }
            
            guard let motion = motion else { return }
            
            self.lastMotionError = nil
            self.hasReceivedMotionData = true
            let now = CACurrentMediaTime()
            self.lastMotionTimestamp = now
            
            self.currentYaw = motion.attitude.yaw
            self.currentPitch = motion.attitude.pitch
            self.currentRoll = motion.attitude.roll
            
            if !self.hasInitialAttitude {
                self.centerYaw = self.currentYaw
                self.centerPitch = self.currentPitch
                self.hasInitialAttitude = true
                debugLog("🎯 Initial center attitude locked: yaw=\(String(format: "%+.1f", rad2deg(self.currentYaw)))°, pitch=\(String(format: "%+.1f", rad2deg(self.currentPitch)))°")
            }
            
            if now - self.lastLogTime > 1.0 {
                self.lastLogTime = now
                let pDeg = rad2deg(self.currentPitch - self.centerPitch)
                let yDeg = rad2deg(self.currentYaw - self.centerYaw)
                debugLog("Head Pose: ActiveScreen=[\(self.activeScreenIndex)], RelPitch=\(String(format: "%+.1f", pDeg))°, RelYaw=\(String(format: "%+.1f", yDeg))°")
            }
            
            if self.currentMode == .focus {
                self.updateFocusDecision(yaw: self.currentYaw, pitch: self.currentPitch)
            } else {
                self.updateMouseMode(yaw: self.currentYaw, pitch: self.currentPitch)
            }
            
            DispatchQueue.main.async {
                self.onPoseUpdated?()
            }
        }
        
        debugLog("startDeviceMotionUpdates invocation finished.")
    }
    
    func stopMotionTracking() {
        debugLog("stopMotionTracking called.")
        motionManager.stopDeviceMotionUpdates()
        hasReceivedMotionData = false
    }
    
    // MARK: - Calibration Actions
    
    func recenterHeadPose() {
        let now = CACurrentMediaTime()
        let isReceiving = hasReceivedMotionData && (now - lastMotionTimestamp < 2.0)
        
        guard isReceiving else {
            AudioServicesPlaySystemSound(1053)
            let auth = CMHeadphoneMotionManager.authorizationStatus()
            let reason: String
            if auth == .denied {
                reason = "运动与健身权限被拒绝，请在「系统设置 → 隐私与安全性 → 运动与健身」中允许 AirPodFocus。"
            } else if !motionManager.isDeviceMotionAvailable {
                reason = "未检测到 AirPods 运动传感器。请确认 AirPods 4 已连接 Mac 且佩戴在耳朵中。"
            } else {
                reason = "尚未收到耳机姿态数据流，请佩戴好 AirPods 并轻微转动头部。"
            }
            postNotification(title: "⚠️ 无法快速居中", body: reason)
            debugLog("recenterHeadPose failed: \(reason)")
            return
        }
        
        centerYaw = currentYaw
        centerPitch = currentPitch
        debugLog("recenterHeadPose: Center reset to (yaw=\(String(format: "%+.1f", rad2deg(centerYaw)))°, pitch=\(String(format: "%+.1f", rad2deg(centerPitch)))°)")
        
        if soundFeedback {
            AudioServicesPlaySystemSound(1057)
        }
        postNotification(title: "⚡ 快速居中已校准", body: "当前头部视线已设为正中心基准。向下看对焦屏幕 0，向上看对焦屏幕 1。")
    }
    
    func calibrateScreen(index: Int) {
        guard index >= 0 && index < screens.count else { return }
        let now = CACurrentMediaTime()
        let isReceiving = hasReceivedMotionData && (now - lastMotionTimestamp < 2.0)
        
        guard isReceiving else {
            AudioServicesPlaySystemSound(1053)
            postNotification(
                title: "⚠️ 无法校准屏幕 \(index)",
                body: "请确认 AirPods 已连接并佩戴在耳中，且运动权限已开启。"
            )
            debugLog("calibrateScreen(\(index)) failed: no recent motion data")
            return
        }
        
        let relY = currentYaw - centerYaw
        let relP = currentPitch - centerPitch
        screens[index].calibratedYaw = relY
        screens[index].calibratedPitch = relP
        
        let name = screens[index].name
        UserDefaults.standard.set(relY, forKey: "\(PrefKeys.calibratedPrefix)\(name).yaw")
        UserDefaults.standard.set(relP, forKey: "\(PrefKeys.calibratedPrefix)\(name).pitch")
        
        debugLog("calibrateScreen [\(index): \(name)]: relPitch=\(String(format: "%+.1f", rad2deg(relP)))°, relYaw=\(String(format: "%+.1f", rad2deg(relY)))°")
        
        if soundFeedback {
            AudioServicesPlaySystemSound(1057)
        }
        
        let yawDeg = rad2deg(relY)
        let pitchDeg = rad2deg(relP)
        postNotification(
            title: "🎯 屏幕校准成功",
            body: "已记录【屏幕 \(index): \(name)】视角 (俯仰: \(String(format: "%+.1f", pitchDeg))°, 偏航: \(String(format: "%+.1f", yawDeg))°)"
        )
    }
    
    func resetCalibrationToAuto() {
        for i in 0..<screens.count {
            screens[i].calibratedYaw = nil
            screens[i].calibratedPitch = nil
            let name = screens[i].name
            UserDefaults.standard.removeObject(forKey: "\(PrefKeys.calibratedPrefix)\(name).yaw")
            UserDefaults.standard.removeObject(forKey: "\(PrefKeys.calibratedPrefix)\(name).pitch")
        }
        debugLog("resetCalibrationToAuto: Cleared all custom calibrations from UserDefaults.")
        postNotification(title: "🔄 已重置为自动排布", body: "所有屏幕视线角度已恢复为系统几何自动排布")
    }
    
    // MARK: - Focus Decision
    
    func updateFocusDecision(yaw: Double, pitch: Double) {
        guard screens.count > 1 else { return }
        
        let relYaw = yaw - centerYaw
        let relPitch = pitch - centerPitch
        
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
        let effectiveHystRad = min(baseHystRad, minScreenDist.isFinite ? (minScreenDist * 0.3) : baseHystRad)
        
        let currentTarget = screens[activeScreenIndex]
        let curDy = (relYaw - currentTarget.effectiveYaw) * yawGain
        let curDp = (relPitch - currentTarget.effectivePitch) * pitchGain
        let currentDist = sqrt(curDy * curDy + curDp * curDp)
        
        var bestIndex = activeScreenIndex
        var bestDist = Double.infinity
        
        for (idx, target) in screens.enumerated() {
            let dy = (relYaw - target.effectiveYaw) * yawGain
            let dp = (relPitch - target.effectivePitch) * pitchGain
            let dist = sqrt(dy * dy + dp * dp)
            
            if dist < bestDist {
                bestDist = dist
                bestIndex = idx
            }
        }
        
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
                let target = screens[candidateIndex]
                debugLog("Gaze shifted towards Screen [\(candidateIndex)] (\(target.name))! curDist=\(String(format: "%.1f", rad2deg(currentDist)))°, bestDist=\(String(format: "%.1f", rad2deg(bestDist)))°, hyst=\(String(format: "%.1f", rad2deg(effectiveHystRad)))°. Dwell timer (\(String(format: "%.2f", dwellTime))s) started...")
            } else {
                if (now - pendingStartTime) >= dwellTime {
                    debugLog("Dwell confirmed (\(String(format: "%.2f", dwellTime))s). Triggering focus switch to Screen [\(candidateIndex)]!")
                    switchFocus(to: candidateIndex)
                    pendingScreenIndex = nil
                }
            }
        } else {
            pendingScreenIndex = nil
        }
    }
    
    func switchFocus(to targetIndex: Int) {
        guard targetIndex >= 0 && targetIndex < screens.count else { return }
        let target = screens[targetIndex]
        let oldIndex = activeScreenIndex
        
        debugLog(">>> SWITCH FOCUS: [\(oldIndex)] -> [\(targetIndex)] (\(target.name)) <<<")
        
        if oldIndex >= 0 && oldIndex < screens.count {
            screens[oldIndex].lastMouseLocation = NSEvent.mouseLocation
        }
        
        activeScreenIndex = targetIndex
        
        // Find top window on target screen
        let front = getFrontmostWindow(on: target)
        
        if let front = front {
            debugLog("Found top window on screen \(targetIndex): \(front.name) (PID: \(front.pid))")
            if let app = NSRunningApplication(processIdentifier: front.pid) {
                let success: Bool
                if #available(macOS 14.0, *) {
                    success = app.activate()
                } else {
                    success = app.activate(options: [.activateIgnoringOtherApps])
                }
                debugLog("app.activate(\(front.name)) result: \(success)")
            }
            raiseWindowWithAX(pid: front.pid, screenCgRect: target.cgFrame)
        } else {
            debugLog("No application window found on screen \(targetIndex)")
        }
        
        if warpCursorOnSwitch {
            var targetCGPoint: CGPoint
            if let lastLoc = target.lastMouseLocation {
                targetCGPoint = appKitToCG(point: lastLoc)
            } else if let front = front {
                targetCGPoint = CGPoint(x: front.bounds.midX, y: front.bounds.midY)
            } else {
                targetCGPoint = CGPoint(x: target.cgFrame.midX, y: target.cgFrame.midY)
            }
            debugLog("Warping mouse cursor to (\(String(format: "%.1f", targetCGPoint.x)), \(String(format: "%.1f", targetCGPoint.y)))")
            CGWarpMouseCursorPosition(targetCGPoint)
        }
        
        if soundFeedback {
            AudioServicesPlaySystemSound(1057) // Subtle tock/click sound
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.onScreenChanged?(targetIndex)
        }
    }
    
    // MARK: - Mouse Mode
    
    func updateMouseMode(yaw: Double, pitch: Double) {
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
    
    // MARK: - Window Inspection
    
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
    
    func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }
}

func rad2deg(_ rad: Double) -> Double {
    return rad * (180.0 / .pi)
}

// MARK: - Custom Slider Menu Item View

class SliderMenuItemView: NSView {
    let titleLabel: NSTextField
    let valueLabel: NSTextField
    let slider: NSSlider
    let formatString: String
    var onValueChanged: ((Double) -> Void)?
    
    init(title: String, initialValue: Double, minValue: Double, maxValue: Double, formatString: String, onChange: @escaping (Double) -> Void) {
        self.formatString = formatString
        self.onValueChanged = onChange
        
        let width: CGFloat = 250
        let height: CGFloat = 52
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: 18, y: 28, width: 150, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        
        valueLabel = NSTextField(labelWithString: String(format: formatString, initialValue))
        valueLabel.frame = NSRect(x: 170, y: 28, width: 62, height: 18)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        
        slider = NSSlider(value: initialValue, minValue: minValue, maxValue: maxValue, target: nil, action: nil)
        slider.frame = NSRect(x: 16, y: 6, width: 218, height: 20)
        slider.isContinuous = true
        
        super.init(frame: frame)
        
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        
        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc func sliderMoved(_ sender: NSSlider) {
        let val = sender.doubleValue
        valueLabel.stringValue = String(format: formatString, val)
        onValueChanged?(val)
    }
    
    func updateValue(_ val: Double) {
        slider.doubleValue = val
        valueLabel.stringValue = String(format: formatString, val)
    }
}

// MARK: - Status Bar Controller & Menu Manager

class StatusBarController: NSObject, NSMenuDelegate {
    let statusItem: NSStatusItem
    let engine = FocusEngine.shared
    
    var currentScreenMenuItem: NSMenuItem!
    var screenLayoutMenuItem: NSMenuItem!
    var airpodsStatusMenuItem: NSMenuItem!
    var reconnectMenuItem: NSMenuItem!
    var livePoseMenuItem: NSMenuItem!
    var manualCalSubmenu: NSMenu!
    
    var hysteresisSliderView: SliderMenuItemView!
    var pitchGainSliderView: SliderMenuItemView!
    var dwellSliderView: SliderMenuItemView!
    
    var soundMenuItem: NSMenuItem!
    var warpMenuItem: NSMenuItem!
    var modeFocusMenuItem: NSMenuItem!
    var modeMouseMenuItem: NSMenuItem!
    
    var livePoseTimer: Timer?
    
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        
        setupStatusButton()
        setupMenu()
        
        engine.onScreenChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusButton()
                self?.updateScreenStatusItems()
            }
        }
        
        engine.onTrackingStateChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusButton()
                self?.updateAirPodsStatus()
            }
        }
        
        // Listen to display changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    func setupStatusButton() {
        guard let button = statusItem.button else { return }
        
        if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: "AirPodFocus") {
            img.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeft
        } else if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "headphones", accessibilityDescription: "AirPodFocus") {
            img.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeft
        } else {
            button.image = nil
        }
        
        updateStatusButton()
    }
    
    func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let idx = engine.activeScreenIndex
        let name = engine.screens[safe: idx]?.name ?? "屏幕"
        let now = CACurrentMediaTime()
        let isReceiving = engine.hasReceivedMotionData && (now - engine.lastMotionTimestamp < 2.0)
        
        button.title = ""
        if isReceiving {
            button.toolTip = "AirPodFocus: 当前视线对准 [屏 \(idx)] \(name)"
        } else {
            button.toolTip = "AirPodFocus: 等待 AirPods 运动数据 (请戴好耳机)"
        }
    }
    
    func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        
        // 1. Current Screen Status Header
        currentScreenMenuItem = NSMenuItem(title: "🖥 当前屏幕: [0] 检测中...", action: nil, keyEquivalent: "")
        currentScreenMenuItem.isEnabled = false
        menu.addItem(currentScreenMenuItem)
        
        screenLayoutMenuItem = NSMenuItem(title: "   已连接 0 块屏幕", action: nil, keyEquivalent: "")
        screenLayoutMenuItem.isEnabled = false
        menu.addItem(screenLayoutMenuItem)
        
        airpodsStatusMenuItem = NSMenuItem(title: "   🎧 耳机状态: 检查中...", action: #selector(airpodsStatusClicked), keyEquivalent: "")
        airpodsStatusMenuItem.target = self
        menu.addItem(airpodsStatusMenuItem)
        
        reconnectMenuItem = NSMenuItem(title: "🔄 重新检测并连接耳机传感器", action: #selector(reconnectClicked), keyEquivalent: "")
        reconnectMenuItem.target = self
        menu.addItem(reconnectMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Recalibrate Section
        // A. Quick Auto Center
        let autoCenterItem = NSMenuItem(
            title: "⚡ 自动快速居中复位 (当前视线即为中心)",
            action: #selector(autoCenterClicked),
            keyEquivalent: "r"
        )
        autoCenterItem.target = self
        autoCenterItem.toolTip = "自然直视前方主屏或两屏正中，点击立即重置零位基准"
        menu.addItem(autoCenterItem)
        
        // B. Manual Multi-Screen Calibration Submenu
        let manualCalItem = NSMenuItem(title: "🎯 手动分屏校准", action: nil, keyEquivalent: "")
        manualCalSubmenu = NSMenu()
        manualCalSubmenu.autoenablesItems = false
        manualCalItem.submenu = manualCalSubmenu
        menu.addItem(manualCalItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Advanced Settings Submenu
        let advancedItem = NSMenuItem(title: "⚙️ 高级设置", action: nil, keyEquivalent: "")
        let advancedSubmenu = NSMenu()
        advancedSubmenu.autoenablesItems = false
        
        // A. Dynamic Live Pose Item
        livePoseMenuItem = NSMenuItem(title: "🎧 实时姿态: 偏航 +0.0° | 俯仰 +0.0°", action: nil, keyEquivalent: "")
        livePoseMenuItem.isEnabled = false
        advancedSubmenu.addItem(livePoseMenuItem)
        
        advancedSubmenu.addItem(NSMenuItem.separator())
        
        // B. Hysteresis Slider
        let hystItem = NSMenuItem()
        hysteresisSliderView = SliderMenuItemView(
            title: "防抖迟滞 (Hysteresis)",
            initialValue: engine.hysteresisDegrees,
            minValue: 1.0,
            maxValue: 8.0,
            formatString: "%.1f°",
            onChange: { [weak self] val in
                self?.engine.hysteresisDegrees = val
            }
        )
        hystItem.view = hysteresisSliderView
        advancedSubmenu.addItem(hystItem)
        
        // C. Pitch Gain Slider (Key for close stacked screens!)
        let pitchGainItem = NSMenuItem()
        pitchGainSliderView = SliderMenuItemView(
            title: "垂直增益 (Pitch Gain)",
            initialValue: engine.pitchGain,
            minValue: 1.0,
            maxValue: 6.0,
            formatString: "%.1fx",
            onChange: { [weak self] val in
                self?.engine.pitchGain = val
            }
        )
        pitchGainItem.view = pitchGainSliderView
        advancedSubmenu.addItem(pitchGainItem)
        
        // D. Dwell Time Slider
        let dwellItem = NSMenuItem()
        dwellSliderView = SliderMenuItemView(
            title: "注视确认 (Dwell Time)",
            initialValue: engine.dwellTime,
            minValue: 0.05,
            maxValue: 0.50,
            formatString: "%.2fs",
            onChange: { [weak self] val in
                self?.engine.dwellTime = val
            }
        )
        dwellItem.view = dwellSliderView
        advancedSubmenu.addItem(dwellItem)
        
        advancedSubmenu.addItem(NSMenuItem.separator())
        
        // E. Audio Feedback Toggle
        soundMenuItem = NSMenuItem(title: "🔊 切屏提示音 (Audio Feedback)", action: #selector(toggleSoundFeedback), keyEquivalent: "")
        soundMenuItem.target = self
        soundMenuItem.state = engine.soundFeedback ? .on : .off
        advancedSubmenu.addItem(soundMenuItem)
        
        // F. Warp Cursor Toggle
        warpMenuItem = NSMenuItem(title: "🖱 鼠标光标同步跳转 (Cursor Warp)", action: #selector(toggleWarpCursor), keyEquivalent: "")
        warpMenuItem.target = self
        warpMenuItem.state = engine.warpCursorOnSwitch ? .on : .off
        advancedSubmenu.addItem(warpMenuItem)
        
        advancedSubmenu.addItem(NSMenuItem.separator())
        
        // G. Mode switch
        modeFocusMenuItem = NSMenuItem(title: "✓ 视线聚焦模式 (Look to Type)", action: #selector(selectFocusMode), keyEquivalent: "")
        modeFocusMenuItem.target = self
        advancedSubmenu.addItem(modeFocusMenuItem)
        
        modeMouseMenuItem = NSMenuItem(title: "  头部鼠标模式 (Head Mouse)", action: #selector(selectMouseMode), keyEquivalent: "")
        modeMouseMenuItem.target = self
        advancedSubmenu.addItem(modeMouseMenuItem)
        
        advancedItem.submenu = advancedSubmenu
        menu.addItem(advancedItem)
        
        // Accessibility Warning / Check
        if !AXIsProcessTrusted() {
            let axItem = NSMenuItem(title: "⚠️ 辅助功能权限未开启 (点击前往系统设置)", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 4. Quit Action
        let quitItem = NSMenuItem(title: "❌ 退出 AirPodFocus", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        
        updateScreenStatusItems()
        populateManualCalMenu()
        updateAirPodsStatus()
    }
    
    func updateScreenStatusItems() {
        let idx = engine.activeScreenIndex
        let screens = engine.screens
        let currentScreenName = screens[safe: idx]?.name ?? "未知"
        
        let titleText = "🖥 当前屏幕: [\(idx)] \(currentScreenName)"
        let attr = NSAttributedString(
            string: titleText,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: NSColor.systemGreen
            ]
        )
        currentScreenMenuItem.attributedTitle = attr
        
        let spanX = (screens.map { $0.frame.maxX }.max() ?? 0) - (screens.map { $0.frame.origin.x }.min() ?? 0)
        let spanY = (screens.map { $0.frame.maxY }.max() ?? 0) - (screens.map { $0.frame.origin.y }.min() ?? 0)
        let layoutStr = (spanX >= spanY) ? "左右并排" : "上下叠屏"
        screenLayoutMenuItem.title = "   已连接 \(screens.count) 块屏幕 (\(layoutStr))"
    }
    
    func populateManualCalMenu() {
        manualCalSubmenu.removeAllItems()
        
        let hintItem = NSMenuItem(title: "👀 请自然注视目标屏幕并点击下方项:", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        manualCalSubmenu.addItem(hintItem)
        manualCalSubmenu.addItem(NSMenuItem.separator())
        
        for s in engine.screens {
            let isCurrent = (s.id == engine.activeScreenIndex) ? "👉 " : "   "
            let calTag = (s.calibratedYaw != nil) ? " [已校准]" : " [自动]"
            let title = "\(isCurrent)视线对准【屏幕 \(s.id): \(s.name)】点击校准\(calTag)"
            let item = NSMenuItem(title: title, action: #selector(manualCalScreenClicked(_:)), keyEquivalent: "")
            item.tag = s.id
            item.target = self
            manualCalSubmenu.addItem(item)
        }
        
        manualCalSubmenu.addItem(NSMenuItem.separator())
        let resetAutoItem = NSMenuItem(title: "🔄 恢复默认自动角度排布", action: #selector(resetAutoClicked), keyEquivalent: "")
        resetAutoItem.target = self
        manualCalSubmenu.addItem(resetAutoItem)
    }
    
    func updateAirPodsStatus() {
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        let available = engine.motionManager.isDeviceMotionAvailable
        let active = engine.motionManager.isDeviceMotionActive
        let now = CACurrentMediaTime()
        let isReceiving = engine.hasReceivedMotionData && (now - engine.lastMotionTimestamp < 2.0)
        
        if auth == .denied {
            airpodsStatusMenuItem.title = "   ❌ 运动权限已关闭 (点击前往系统设置开启)"
            airpodsStatusMenuItem.isEnabled = true
        } else if auth == .restricted {
            airpodsStatusMenuItem.title = "   ⚠️ 运动权限受系统策略限制"
            airpodsStatusMenuItem.isEnabled = false
        } else if !available {
            airpodsStatusMenuItem.title = "   🟡 AirPods 未入耳或未连接 (请佩戴好耳机)"
            airpodsStatusMenuItem.isEnabled = true
        } else if isReceiving {
            airpodsStatusMenuItem.title = "   🟢 耳机连接正常 (实时追踪中)"
            airpodsStatusMenuItem.isEnabled = false
        } else if active {
            airpodsStatusMenuItem.title = "   🟡 传感器已启动，等待首帧动作 (请转动头部)"
            airpodsStatusMenuItem.isEnabled = true
        } else {
            airpodsStatusMenuItem.title = "   🟡 耳机已就绪，点击重新连接"
            airpodsStatusMenuItem.isEnabled = true
        }
    }
    
    // MARK: - Menu Delegate
    
    func menuWillOpen(_ menu: NSMenu) {
        updateScreenStatusItems()
        populateManualCalMenu()
        updateAirPodsStatus()
        
        soundMenuItem.state = engine.soundFeedback ? .on : .off
        warpMenuItem.state = engine.warpCursorOnSwitch ? .on : .off
        
        if engine.currentMode == .focus {
            modeFocusMenuItem.title = "✓ 视线聚焦模式 (Look to Type)"
            modeMouseMenuItem.title = "  头部鼠标模式 (Head Mouse)"
        } else {
            modeFocusMenuItem.title = "  视线聚焦模式 (Look to Type)"
            modeMouseMenuItem.title = "✓ 头部鼠标模式 (Head Mouse)"
        }
        
        updateLivePose()
        livePoseTimer?.invalidate()
        livePoseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateLivePose()
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        livePoseTimer?.invalidate()
        livePoseTimer = nil
    }
    
    func updateLivePose() {
        updateAirPodsStatus()
        let now = CACurrentMediaTime()
        let isReceiving = engine.hasReceivedMotionData && (now - engine.lastMotionTimestamp < 2.0)
        if isReceiving {
            let relYawDeg = rad2deg(engine.currentYaw - engine.centerYaw)
            let relPitchDeg = rad2deg(engine.currentPitch - engine.centerPitch)
            livePoseMenuItem.title = String(
                format: "🎧 实时姿态: 偏航(Yaw) %+.1f° | 俯仰(Pitch) %+.1f°",
                relYawDeg, relPitchDeg
            )
        } else {
            livePoseMenuItem.title = "🎧 实时姿态: 等待耳机数据..."
        }
    }
    
    // MARK: - Actions
    
    @objc func airpodsStatusClicked() {
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        if auth == .denied {
            openMotionSettings()
        } else {
            reconnectClicked()
        }
    }
    
    @objc func reconnectClicked() {
        debugLog("User clicked '重新检测并连接耳机传感器'.")
        engine.startMotionTracking(force: true)
        updateAirPodsStatus()
        updateStatusButton()
        
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        let avail = engine.motionManager.isDeviceMotionAvailable
        let active = engine.motionManager.isDeviceMotionActive
        
        var msg = "权限状态: \(auth.rawValue) (0=未决, 2=拒绝, 3=允许)\n传感器可用: \(avail)\n正在追踪: \(active)"
        if auth == .denied {
            msg += "\n\n⚠️ 运动与健身权限当前处于拒绝状态，请在系统设置中允许！"
        } else if !avail {
            msg += "\n\n⚠️ 传感器不可用，请确保 AirPods 4 已连接 Mac 且佩戴在耳中！"
        }
        engine.postNotification(title: "🔄 正在尝试重新连接耳机", body: msg)
    }
    
    @objc func autoCenterClicked() {
        engine.recenterHeadPose()
    }
    
    @objc func manualCalScreenClicked(_ sender: NSMenuItem) {
        let screenId = sender.tag
        engine.calibrateScreen(index: screenId)
        populateManualCalMenu()
    }
    
    @objc func resetAutoClicked() {
        engine.resetCalibrationToAuto()
        populateManualCalMenu()
    }
    
    @objc func toggleSoundFeedback() {
        engine.soundFeedback = !engine.soundFeedback
        soundMenuItem.state = engine.soundFeedback ? .on : .off
    }
    
    @objc func toggleWarpCursor() {
        engine.warpCursorOnSwitch = !engine.warpCursorOnSwitch
        warpMenuItem.state = engine.warpCursorOnSwitch ? .on : .off
    }
    
    @objc func selectFocusMode() {
        engine.currentMode = .focus
        modeFocusMenuItem.title = "✓ 视线聚焦模式 (Look to Type)"
        modeMouseMenuItem.title = "  头部鼠标模式 (Head Mouse)"
    }
    
    @objc func selectMouseMode() {
        engine.currentMode = .mouse
        modeFocusMenuItem.title = "  视线聚焦模式 (Look to Type)"
        modeMouseMenuItem.title = "✓ 头部鼠标模式 (Head Mouse)"
    }
    
    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func openMotionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func screenParametersChanged() {
        engine.refreshScreens()
        updateScreenStatusItems()
        populateManualCalMenu()
    }
    
    @objc func quitApp() {
        debugLog("AirPodFocus exiting by user request.")
        engine.stopMotionTracking()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Application Delegate

var globalStatusBarController: StatusBarController?

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("================ AirPodFocus Launching ================")
        
        // Request Notification permission for calibration feedback
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            debugLog("Notification authorization granted: \(granted)")
        }
        
        // Request Accessibility permission prompt if needed
        let promptOption = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let axTrusted = AXIsProcessTrustedWithOptions(promptOption)
        debugLog("Accessibility trusted: \(axTrusted)")
        
        // Initialize Status Bar controller strongly
        globalStatusBarController = StatusBarController()
        
        // Start motion updates
        FocusEngine.shared.startMotionTracking()
        
        debugLog("AirPodFocus launched successfully. Status bar item active.")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        debugLog("AirPodFocus applicationWillTerminate.")
        FocusEngine.shared.stopMotionTracking()
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
