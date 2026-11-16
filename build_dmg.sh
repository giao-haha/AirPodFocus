#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "🔨 1. Compiling AirPodFocus release binary..."
swiftc -O -o AirPodFocus AppMain.swift

echo "📦 2. Assembling AirPodFocus.app bundle..."
APP="AirPodFocus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp AirPodFocus "$APP/Contents/MacOS/AirPodFocus"
chmod +x "$APP/Contents/MacOS/AirPodFocus"
cp Info.plist "$APP/Contents/Info.plist"

if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "🔏 3. Ad-hoc signing AirPodFocus.app..."
codesign --force --deep --sign - "$APP"

echo "💿 4. Creating official release DMG..."
DMG_ROOT="dmg_root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"

cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

# Friendly README text file inside DMG
cat << 'EOF' > "$DMG_ROOT/使用说明.txt"
AirPodFocus - 看向哪个屏幕就在哪打字 (AirPods 头部追踪屏幕焦点自动切换)

【安装方法】
1. 将左侧的「AirPodFocus」拖入右侧的「Applications」文件夹中。
2. 在「启动台」或「访达 - 应用程序」中双击启动 AirPodFocus。
3. 应用启动后将驻留在 macOS 顶部菜单栏，呈现精致耳机图标 🎧。
4. 首次使用请在「系统设置 → 隐私与安全性」中允许：
   - 辅助功能（Accessibility）：用于激活目标屏幕窗口及同步鼠标。
   - 运动与健身（Motion & Fitness）：用于读取 AirPods 4 耳机实时头部姿态。

【核心功能】
1. 智能排布：自动检测多屏幕（支持左右并排、上下叠屏）。
2. 重新校准：
   - ⚡ 自动快速居中复位：直视前方自然点击，一键重置基准。
   - 🎯 手动分屏校准：分别注视各屏幕并点击校准，完美适配任意高低桌面与坐姿。
3. 高级设置：
   - 🎧 实时姿态（动态展示实时俯仰与偏航角度）。
   - 垂直增益（Pitch Gain）：专为上下近距离叠屏优化，微仰头部即可轻松切屏。
   - 防抖迟滞（Hysteresis）与注视确认（Dwell Time）滑块微调。
   - 鼠标光标跟随跳转（Cursor Warp）与提示音（Audio Feedback）开关。
EOF

DMG_NAME="AirPodFocus-v2.0.dmg"
rm -f "$DMG_NAME"
hdiutil create -volname "AirPodFocus Installer" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_NAME"
rm -rf "$DMG_ROOT"

echo "✅ DMG 构建完成: $DIR/$DMG_NAME"
ls -lh "$DMG_NAME"
