#!/usr/bin/env python3
"""Keep the polished macOS surfaces on the shared type, radius and color scale."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
surfaces = (
    'AssistantCommandBar', 'AutomationSettingsSection', 'ClimatePanelModule',
    'ControlCenterPanel', 'DeviceCardView', 'EnergySettingsSection',
    'HotkeyShortcutRecorder', 'MiAccountSection', 'SensorCardView',
    'SettingsWindowView', 'SettingsCategoryPicker', 'ThemeAndMotion', 'UpdateSection', 'PanelDesign',
)
rules = (
    (r'\.system\(size:\s*\d', '字号请使用 DesignTokens.TypeSize'),
    (r'cornerRadius:\s*\d', '圆角请使用 DesignTokens.Radius'),
    (r'Color\(\s*(?:red|hue|white):', '自定义颜色请移入 DesignTokens 调色板'),
)
errors = []
for name in surfaces:
    path = root / 'Sources/MenuBarMijiaApp' / (name + '.swift')
    text = path.read_text()
    start = 0
    end = len(text)
    first_line = 1
    assistant_start = text[:text.index('struct AssistantSettingsSection:')].count('\n') + 1 if name == 'AssistantCommandBar' else None
    for number, line in enumerate(text[start:end].splitlines(), first_line):
        if line.lstrip().startswith('//'):
            continue
        settings_control = name in {
            'SettingsWindowView', 'MiAccountSection', 'AutomationSettingsSection',
            'EnergySettingsSection', 'UpdateSection',
        } or (name == 'AssistantCommandBar' and assistant_start is not None and number >= assistant_start)
        if settings_control and re.search(r'\.controlSize\(\.(?:small|mini)\)', line):
            errors.append(f'{path.relative_to(root)}:{number}: 设置表单请统一使用 regular 控件规格')
        for pattern, message in rules:
            if re.search(pattern, line):
                errors.append(f'{path.relative_to(root)}:{number}: {message}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('✅ macOS 字号、圆角和自定义颜色变量检查通过')
