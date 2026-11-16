# 🎧 AirPodFocus (看向即打字)

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-black?style=for-the-badge&logo=apple" alt="macOS" />
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange?style=for-the-badge&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/AirPods-3%20%7C%204%20%7C%20Pro%20%7C%20Max-blue?style=for-the-badge" alt="AirPods" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License" />
</p>

<p align="center">
  <b>看向哪个屏幕，键盘焦点和鼠标就自动切换到哪个屏幕，双手不离键盘直接打字！</b><br>
  <i>Auto-switch window focus & mouse cursor to the monitor you are looking at via AirPods head tracking.</i>
</p>

---

## 📖 项目简介 (Introduction)

在多显示器（如 MacBook 笔记本屏 + 正上方外接显示器，或左右双屏）工作时，我们通常需要频繁用手握住鼠标/触控板，移动到另一个屏幕并点击窗口才能开始打字。

**AirPodFocus** 彻底改变了多屏交互体验：
利用你耳中佩戴的 **AirPods 运动传感器（CoreMotion 头部姿态追踪）**，实时识别你头部注视的屏幕方向。当你转头或抬头看向某个屏幕时，该屏幕的活动窗口**自动激活为前台输入焦点**，鼠标光标瞬间同步跳转过去。**双手全程无需离开键盘，抬头低头之间无缝流转打字！**

> 项目起源：Fork 并深度重构自 [systemsoftware/airpodmouse](https://github.com/systemsoftware/airpodmouse)。原项目用于将头部当作鼠标指针，本项目演进为针对多显示器办公场景的**原生状态栏屏幕焦点调度应用**。

---

## ✨ 核心特性 (Features)

### 1. 👀 看向即打字 (Look to Type / Focus Mode)
- **多显示器自动拓扑感知**：自动识别连接的所有显示器尺寸与几何排列（自动适配**左右并排**或**上下叠屏**）。
- **零点击窗口激活**：通过系统底层进程调度，直接将视线所在屏幕的顶层窗口设为主焦点，输入光标立即就位。
- **光标智能跳转 (Cursor Warp)**：切屏时光标自动平滑跟随到目标屏幕（支持记忆各屏幕上次光标位置），同一屏幕内完全不干扰物理鼠标滑动。

### 2. 📐 专为「上下近距离叠屏」深度调优
- **人类颈部工程学适配**：上下看屏幕时，人体自然颈部俯仰仅有 $3^\circ \sim 8^\circ$（大部分位移由眼球完成）。
- **垂直增益放大器 (Pitch Gain)**：支持在高级设置中自由调节垂直增益（默认 2.5x ~ 3.5x），微动下巴或轻微抬头即可敏锐触发切屏，彻底告别“大幅仰头累脖子”。
- **自适应迟滞滤波 (Adaptive Hysteresis)**：针对屏幕间距极小的布局，自动压缩迟滞死区，杜绝边界反复跳动与切屏卡滞。

### 3. 🖥 原生 macOS 状态栏应用 (Menu Bar App)
- **轻量隐形**：作为纯净的后台辅助工具（`LSUIElement`）运行，不占 Dock 栏，常驻顶部菜单栏，呈现原生精致耳机图标 🎧。
- **当前屏幕动态指示**：菜单内实时显示当前对焦屏幕编号（如 `[0]`）及屏幕设备型号（如 `Built-in Retina Display`、`SB243Y G0`）。

### 4. ⚡ 双模式重新校准 (Dual Calibration)
- **⚡ 自动快速居中复位**：坐姿自然看着两块屏幕中间分界处，点击立即重置 $(0^\circ, 0^\circ)$ 基准。
- **🎯 手动分屏校准**：视线自然看着屏幕 0 点击校准，再看向屏幕 1 点击校准。系统内置**冲突自动熔断机制**，自动记录最契合你桌椅高低的个性化舒适角度。

### 5. 🎛 状态栏内置高级调优面板
- **实时姿态动态监视 (Live Head Pose)**：动态实时显示当前头部的俯仰角（Pitch）与偏航角（Yaw）。
- **防抖迟滞 (Hysteresis)**：$1.0^\circ \sim 8.0^\circ$ 无级平滑调节。
- **垂直增益 (Pitch Gain)**：$1.0\text{x} \sim 6.0\text{x}$ 动态调节，大幅降低叠屏抬头疲劳。
- **注视确认 (Dwell Time)**：$0.05\text{s} \sim 0.50\text{s}$ 注视延时防误触。
- **切屏提示音 (Audio Feedback)**：提供清脆微妙的切屏反馈轻响。
- **双模式随意切换**：可在「视线聚焦打字模式」与原版「头部控制鼠标光标模式」之间一键切换。

---

## 🛠️ 系统要求 (Requirements)

- **操作系统**：macOS 14.0 (Sonoma) 或更高版本（支持 macOS 15 Sequoia）
- **硬件架构**：Apple Silicon (M1/M2/M3/M4 系列芯片) 及 Intel 芯片 Mac
- **支持耳机**：内置运动传感器且支持空间音频的 Apple / Beats 耳机：
  - AirPods 4 (支持主动降噪版 / 标准版)
  - AirPods Pro (第 1 代 / 第 2 代)
  - AirPods (第 3 代)
  - AirPods Max
  - Beats Fit Pro / Beats Studio Pro

---

## 🚀 安装方法 (Installation)

### 方式一：下载 DMG 安装包（推荐）

1. 前往本仓库 [Releases 页面](../../releases) 下载最新的 `AirPodFocus-v2.0.dmg`。
2. 双击打开 DMG，将 **AirPodFocus** 拖入右侧的 **Applications (应用程序)** 文件夹。
3. 从启动台或应用程序文件夹中启动 AirPodFocus。

### 方式二：从源码构建

在终端中执行以下命令：

```bash
git clone https://github.com/giao-haha/AirPodFocus.git
cd airpodfocus

# 运行构建脚本（编译、Ad-hoc 签名并生成 DMG）
./build_dmg.sh
```

生成的安装包将位于当前目录下的 `AirPodFocus-v2.0.dmg`。

---

## 🔐 权限配置指南 (Permissions)

为了实现读取耳机姿态数据和自动切换屏幕窗口，macOS 需要授予两项系统隐私权限：

1. **辅助功能 (Accessibility)**：
   - 用途：用于激活目标屏幕顶层窗口焦点 (`NSRunningApplication.activate`) 以及同步鼠标位置 (`CGWarpMouseCursorPosition`)。
   - 路径：`系统设置 → 隐私与安全性 → 辅助功能`，勾选允许 **AirPodFocus**。
2. **运动与健身 (Motion & Fitness)**：
   - 用途：用于读取 AirPods 4 / Pro / Max 的耳戴运动传感器（CoreMotion `CMHeadphoneMotionManager`）。
   - 路径：`系统设置 → 隐私与安全性 → 运动与健身`，勾选允许 **AirPodFocus**。

> 💡 **提示**：若耳机刚戴上，菜单栏显示 `🟡 AirPods 未入耳或未连接`，请确认耳机已戴入耳中（AirPods 需入耳检测生效才会启动运动传感器）。点击菜单栏中的 `🔄 重新检测并连接耳机传感器` 即可刷新状态。

---

## 💡 使用与校准技巧 (Usage Guide)

### 最佳校准流程（推荐）：
1. 戴好 AirPods，保持日常最舒服自然的坐姿。
2. 自然注视**下方的笔记本屏幕**，点击顶部菜单栏耳机图标 🎧 → `🎯 手动分屏校准` → 点击 `视线对准【屏幕 0】点击校准`。
3. 视线自然微抬注视**上方外接显示器**，点击 `🎯 手动分屏校准` → 点击 `视线对准【屏幕 1】点击校准`。
4. 校准完成后，系统会自动以两块屏幕的角度中线作为触发分界，现在你只需上下微动头部，即可享受极致的无缝切屏打字体验！

### 上下屏距离很近？
- 打开菜单栏 → `⚙️ 高级设置`。
- 将 **垂直增益 (Pitch Gain)** 调整到 `3.0x` 或 `4.0x`。
- 此时抬头仅需 $2^\circ \sim 3^\circ$ 的微小幅度即可灵敏切屏，长时间办公脖子毫无负担。

---

## 🤝 致谢与开源协议 (License & Credits)

- 本项目基于 [MIT License](LICENSE) 开源。
- 特别鸣谢 [systemsoftware/airpodmouse](https://github.com/systemsoftware/airpodmouse) 提供的 AirPods CoreMotion 姿态解析灵感与原型探索。
- 欢迎提交 Issue、功能建议与 Pull Request！
