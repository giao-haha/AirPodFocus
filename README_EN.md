# 🎧 AirPodFocus (Look to Type)

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-black?style=for-the-badge&logo=apple" alt="macOS" />
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange?style=for-the-badge&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/AirPods-3%20%7C%204%20%7C%20Pro%20%7C%20Max-blue?style=for-the-badge" alt="AirPods" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License" />
</p>

<p align="center">
  <b>Auto-switch window focus & mouse cursor to the monitor you are looking at via AirPods head tracking.</b><br>
  <i>Keep both hands on your keyboard and start typing immediately on whichever screen you face.</i>
</p>

<p align="center">
  <a href="README.md">中文文档 (Chinese)</a> | <b>English</b>
</p>

---

## 📖 Overview

When working with multi-monitor setups (e.g., MacBook display on the bottom and a large external display stacked above, or side-by-side monitors), moving your hand away from the keyboard to grab the mouse and click a window just to focus it is tedious.

**AirPodFocus** solves this seamlessly:
Using the built-in motion sensors inside your **AirPods (CoreMotion head tracking)**, AirPodFocus continuously detects which display you are looking at. When you tilt or turn your head toward a display, the top application window on that screen is **instantly brought to the foreground and focused for keyboard typing**, and your mouse cursor warps there smoothly.

> **Heritage**: Forked and evolved from [systemsoftware/airpodmouse](https://github.com/systemsoftware/airpodmouse). While the original project used head movement as a continuous mouse pointer, AirPodFocus is a full-featured native macOS menu bar app tailored for high-efficiency multi-display productivity.

---

## ✨ Key Features

### 1. 👀 Look to Type (Focus Mode)
- **Automatic Display Layout Perception**: Automatically detects all connected monitors and determines whether they are arranged horizontally (side-by-side) or vertically (stacked).
- **Zero-Click Window Focusing**: Activates the top application window on the targeted screen with zero delay.
- **Intelligent Cursor Warping**: Moves the mouse cursor to the active window or preserves the screen's prior cursor position. Inside the screen, your physical mouse/trackpad operates normally without interference.

### 2. 📐 Tuned for Closely-Stacked Vertical Displays
- **Human Ergonomics Optimization**: Humans naturally only tilt their neck $3^\circ \sim 8^\circ$ when looking between vertical monitors (most movement is eye saccades).
- **Pitch Gain Multiplier**: Includes an adjustable Vertical Gain slider (default 2.5x ~ 3.5x) in advanced settings, allowing you to switch screens with a subtle chin nod instead of heavy neck movement.
- **Adaptive Hysteresis Filtering**: Automatically compresses hysteresis dead-zones for close screens, preventing jitter or switching lockouts.

### 3. 🖥 Native macOS Menu Bar Utility
- **Lightweight & Discreet**: Runs as a background status accessory (`LSUIElement`) with no Dock clutter, living quietly in the menu bar with a sleek headphone icon 🎧.
- **Dynamic Screen Badge**: The menu displays your currently active display index (e.g., `[0]`) and localized hardware monitor name (e.g., `Built-in Retina Display`, `SB243Y G0`).

### 4. ⚡ Dual Recalibration Options
- **⚡ Quick Auto-Center**: Look straight ahead between your screens and click once to reset $(0^\circ, 0^\circ)$ baseline.
- **🎯 Manual Per-Screen Calibration**: Look at Screen 0, click calibrate; look at Screen 1, click calibrate. Built-in conflict auto-mitigation prevents identical-angle deadlocks.

### 5. 🎛 Comprehensive Settings Panel
- **Live Dynamic Head Pose**: Real-time display of current Pitch and Yaw degrees.
- **Hysteresis Slider**: $1.0^\circ \sim 8.0^\circ$ continuous adjustment.
- **Pitch Gain Slider**: $1.0\text{x} \sim 6.0\text{x}$ sensitivity multiplier.
- **Dwell Time Slider**: $0.05\text{s} \sim 0.50\text{s}$ confirmation delay.
- **Audio Feedback**: Subtle click sound on screen switch.
- **Dual Modes**: Easily switch between Focus Mode (Look to Type) and Head Mouse Mode.

---

## 🛠️ System Requirements

- **Operating System**: macOS 14.0 (Sonoma) or later (fully compatible with macOS 15 Sequoia)
- **Architecture**: Apple Silicon (M1/M2/M3/M4) and Intel Macs
- **Supported Headphones**: Apple / Beats headphones with motion sensors & Spatial Audio support:
  - AirPods 4 (with ANC / Standard)
  - AirPods Pro (1st & 2nd Generation)
  - AirPods (3rd Generation)
  - AirPods Max
  - Beats Fit Pro / Beats Studio Pro

---

## 🚀 Installation

### Option 1: Pre-built DMG Installer (Recommended)

1. Download `AirPodFocus-v2.0.dmg` from the [Releases](../../releases) section.
2. Open the DMG and drag **AirPodFocus** into your **Applications** folder.
3. Launch AirPodFocus from Launchpad or Finder.

### Option 2: Build From Source

```bash
git clone https://github.com/systemsoftware/airpodmouse.git
cd airpodmouse

# Build release DMG
./build_dmg.sh
```

---

## 🔐 Permissions Setup

AirPodFocus requires two standard macOS privacy permissions:

1. **Accessibility**:
   - Needed to programmatically bring windows to focus (`NSRunningApplication.activate`) and position the mouse cursor (`CGWarpMouseCursorPosition`).
   - Location: `System Settings → Privacy & Security → Accessibility` → Enable **AirPodFocus**.
2. **Motion & Fitness**:
   - Needed to receive headphone attitude data via CoreMotion (`CMHeadphoneMotionManager`).
   - Location: `System Settings → Privacy & Security → Motion & Fitness` → Enable **AirPodFocus**.

---

## 🤝 License & Acknowledgments

- Released under the [MIT License](LICENSE).
- Special thanks to [systemsoftware/airpodmouse](https://github.com/systemsoftware/airpodmouse) for the original proof-of-concept exploration of CoreMotion headphone tracking on macOS.
