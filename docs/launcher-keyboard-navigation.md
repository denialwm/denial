# 修改说明：开始菜单全键盘导航 + 焦点修复

- 日期：2026-08-22
- 分支：main（本地开发，未提交）
- 改动文件：2 个（见「涉及文件」）

## 一、背景

在真实使用 Denial（0.2.11 发行版）时发现的问题：

1. **开始菜单（应用启动器）没有键盘导航**：搜索后只能用鼠标点击结果，无法用方向键选择 + Enter 启动。在不方便使用鼠标、只能靠键盘操作的环境下，全键盘导航是刚需。
2. **用 Super/Win 键打开开始菜单后，焦点被搜索框锁死**：打开后点击桌面上的其他程序窗口，菜单不会自动关闭、焦点移不过去、键盘输入全部被搜索框吃掉；必须手动关闭菜单（再按 Super/Esc）焦点才能释放。而鼠标触发的菜单（悬停边缘打开）因有 hover 自动关闭机制，表现正常。
3. **Esc 关闭菜单的同时会把 Esc「输入进」搜索框**：菜单能关，但搜索框被污染（控制字符），与 KDE 菜单行为不符。

## 二、改动内容

### 功能 1：全键盘导航（方向键 4 向 + Tab + Enter 启动）

**位置**：`dart_shell/lib/src/desktop/desktop_shell.dart` → `_DesktopApplicationLauncherState`

- 新增 `_selectedIndex` 状态，搜索文本变化时（`_handleSearchChanged`）归零。
- 用 `CallbackShortcuts` 包住整个面板，绑定：

  | 按键 | 行为 |
  |---|---|
  | ↑ / ↓ | 跨行移动（`_moveSelectionByRow`，按 `_crossAxisCountFor()` 推算的列数跳行），循环滚动 |
  | ← / → | 行内移动（`_moveSelection(±1)`），循环滚动 |
  | Tab / Shift+Tab | 下一个 / 上一个结果（常见启动器行为） |
  | Enter | 启动当前高亮项 |
  | Esc | 关闭菜单（见功能 3） |

- **关键原理**：Flutter 的文本编辑快捷键（`DefaultTextEditingShortcuts`，含方向键编辑绑定）和焦点遍历绑定（`NextFocusIntent`，含 Tab）都挂在 widget 树**顶层**（WidgetsApp）；`CallbackShortcuts` 位于搜索框的祖先层级、更靠近 `EditableText`，因此会**覆盖**这些默认绑定（Flutter 文档明确：位于顶层默认 Shortcuts 与 `EditableText` 之间的 `Shortcuts` 会覆盖默认绑定）。
- 选中高亮从 `searching && index == 0` 改为 `index == _selectedIndex`：打开菜单即默认高亮第一个应用，**不搜索也能直接方向键选择**。
- Enter（`onSubmitted`）从启动 `apps.first` 改为启动 `apps[_selectedIndex]`（带越界保护）。
- 新增自动滚动：`_gridController` + `_crossAxisCountFor()`（按网格宽度推算列数），选中项超出可视区时自动 `animateTo` 滚动到位。

**行为**：

| 操作 | 效果 |
|---|---|
| 打开菜单 | 第一个应用默认高亮，直接 Enter 启动 |
| ↑ / ↓ / ← / → | 4 向循环移动选择（跨行/行内），自动滚动到可视区 |
| Tab / Shift+Tab | 下一个 / 上一个结果 |
| 输入搜索词 | 结果实时过滤，选择归零到第一个，继续方向键选择 |
| Enter | 启动当前高亮的应用 |
| 鼠标 | 点击、悬停行为不变 |

### 功能 2：点击菜单外部关闭菜单 + 焦点释放

**位置**：`dart_shell/lib/src/desktop/desktop_shell.dart` → `_DesktopShellState.build` → `desktop-launcher-dismiss-barrier`

- **问题根因**（Rust 合成器指针路由）：
  - Flutter 侧发布的 `shell_regions`（`desktop_input_layout_publisher.dart`）默认 = 画布**减去客户端窗口区域** + 面板矩形（launcher 面板是 `childBounds` 指针策略）。
  - Rust 侧 `input_route()`（`compositor/.../wayland_frontend/input.rs`）命中 `shell_regions` 才把指针事件交给 Flutter，否则直接给客户端窗口。
  - 因此点击**客户端窗口区域**时，事件直接路由给客户端，Flutter 里全屏的 dismiss barrier 根本收不到 → 菜单不关闭 → 键盘捕获（`shell_captures_keyboard()`）保持 → 焦点锁死在搜索框。
- **修改**：给 dismiss barrier 包一层 `ShellInputRegion`，菜单打开时声明 fullScene 指针捕获：

  ```dart
  child: ShellInputRegion(
    debugLabel: 'Desktop launcher dismiss barrier',
    active: desktop.launcherOpen,
    pointerPolicy: ShellPointerPolicy.fullScene,   // 关键
    keyboardPolicy: ShellKeyboardPolicy.none,      // 键盘仍由面板的 capture 管理
    child: IgnorePointer(
      ignoring: !desktop.launcherOpen,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onDismissLauncher,
      ),
    ),
  ),
  ```

- **生效链路**（Flutter → Rust）：
  1. 菜单打开 → barrier 注册 fullScene → `capturesFullScene=true` → `shell_regions` = 整个画布（不再减去窗口）。
  2. Rust `input_route()` 对任何位置都返回 None（→ Flutter），所有点击进入 Flutter。
  3. 点击外部 → barrier `onTap` → `_closePanels()` → 菜单关闭 + `_applicationSearchFocusNode.unfocus()` + 面板 `keyboardPolicy`→`none` → `shell_capture=false` → **键盘还给前台客户端**。
  4. 菜单关闭 → barrier `active=false` → fullScene 移除 → 指针路由恢复正常。

- **行为对齐 KDE**：第一下点击外部 = 关闭菜单（该次点击被消费），第二下才点中窗口/激活。

### 功能 3：Esc 关闭菜单、且绝不被输入进搜索框

**位置**：
- `desktop_shell.dart` → `DesktopApplicationLauncher`（新增 `onDismiss` 参数）与 `_dismissLauncher()`
- `desktop_shell.dart` → `_DesktopAppSearchField`（`EditableText` 加 `inputFormatters`）

- **排查结论**（为什么 Esc 能关菜单却又「进」了输入框）：
  1. Rust 合成器层：`flutter_unicode_for_keysym`（`compositor/.../wayland_frontend/input.rs`）对 Esc 的 keysym 调用 `key_char()` 返回 `None` → unicode=0 → **不会**作为字符从 KeyEvent 通道进入 Flutter。所以「Esc 被输入」不是合成器 KeyEvent 路径。
  2. Flutter 框架层：`EditableText`（master 版）内部**没有任何按键处理**，按键全部走 Actions/Shortcuts 体系；KeyEvent 通道的 Esc 只被我们的 `CallbackShortcuts` 拦截（返回 handled 即停止分发）。
  3. 结论：Esc 字符只可能来自**输入法（IME/text-input）通道**——输入法把按键（或组合状态残留）当作文本 commit 给 `EditableText` 时，KeyEvent 层的拦截完全拦不住，字符直接进搜索框。
- **修改 1（消除延迟窗口）**：Esc 之前绑定在 `widget.onExit`（= hover 鼠标离开的 **220ms 延迟**关闭回调），延迟期间输入框仍活着。现新增可选参数 `onDismiss`（实例化处传 `onDismissLauncher` = 与点击外部**完全相同**的 `_closePanels`：立即关面板 + unfocus + 释放键盘捕获），Esc 改绑 `_dismissLauncher()`（`onDismiss ?? onExit`，不传时回退旧行为）：

  ```dart
  // 绑定处
  const SingleActivator(LogicalKeyboardKey.escape): _dismissLauncher,

  // 方法
  void _dismissLauncher() {
    (widget.onDismiss ?? widget.onExit)();
  }
  ```

- **修改 2（兜底 IME 通道）**：给搜索框 `EditableText` 加 `inputFormatters`，过滤全部控制字符（ESC=0x1B、TAB=0x09 及 `\u0000-\u001F`、`\u007F`）。`TextInputFormatter` 拦截的是**编辑值提交**（updateEditingValue/insertText），无论字符来自键盘还是 IME，都过不了这一关：

  ```dart
  inputFormatters: <TextInputFormatter>[
    FilteringTextInputFormatter.allow(
      RegExp(r'[^\u0000-\u001F\u007F]'),
    ),
  ],
  ```

  中文、emoji 等正常字符不受影响（不在控制字符范围）。

## 三、涉及文件

| 文件 | 改动 |
|---|---|
| `dart_shell/lib/src/desktop/desktop_shell.dart` | 功能 1 + 功能 2 + 功能 3（见上） |
| `dart_shell/test/desktop/desktop_application_launcher_test.dart` | 新增 5 个 widget 测试 |

## 四、测试

新增测试（`desktop_application_launcher_test.dart`，共 6 个全部通过）：

1. `Applications includes and launches registered local apps` — 原有：鼠标点击启动 Settings。
2. `arrow keys select a search result and Enter launches it` — 搜索后按 → 选择第二个结果，Enter 启动第二个（证明方向键选择生效）。
3. `arrow keys select an app without searching and Enter launches it` — 打开菜单不搜索，按 → 选择第二个应用，Enter 启动第二个。
4. `tab moves the selection to the next app` — Tab 移动选择而非触发焦点遍历，Enter 启动第二个。
5. `escape dismisses the launcher without polluting the search text` — 按 Esc → 关闭回调触发 + 搜索框文本不被污染。
6. `control characters submitted by an input method are filtered` — 模拟 IME 提交 `a\u001bb\u0009c`（含 ESC/TAB 控制字符）→ 被过滤成 `abc`。

跑测试命令（pinned SDK，`tools/denial-pc test` 只跑 Rust，不跑 Flutter 测试）：

```sh
cd dart_shell
~/.cache/denial/pc-dependencies/flutter/bin/flutter test test/desktop/desktop_application_launcher_test.dart
```

> 注：功能 2（fullScene barrier）位于 `_DesktopShellState.build` 层，现有 widget 测试未覆盖，需真机验证。

## 五、验证方法

```sh
tools/denial-pc build    # 编译（Rust + Flutter AOT + engine）
tools/denial-pc test     # 跑 Rust 测试
tools/denial-pc bundle   # 重新打包 Flutter bundle（改 Dart 后必须）
```

真机验证：`bundle` 后**注销 → 重登**「Denial (development)」会话（热刷新 `refresh` 偶尔不彻底，重登最保险）→

1. Super 打开开始菜单 → ↑/↓/←/→ 选择 → Enter 启动（不搜索也能选）。
2. 打开菜单后点击桌面/其他窗口 → 菜单自动关闭，键盘输入回到目标窗口（终端能打字）。
3. 搜索「fire」等 → 结果过滤后方向键选择、Enter 启动。
4. **按 Esc → 菜单立即关闭，搜索框干净**；重新打开菜单检查文本无残留。

## 六、注意事项 / 已知副作用

- 菜单打开期间，客户端窗口收不到任何指针事件（modal 行为，与 KDE 弹出菜单一致）。
- 点击外部第一下只关闭菜单，不激活窗口（KDE 同款行为）；如需「关闭同时激活窗口」需 Rust 侧转发点击，暂未实现。
- 方向键在选择模式下被菜单消费（菜单打开时 ↑/↓ 不再移动搜索框光标到行首/行尾——搜索框场景无实际损失；←/→ 光标移动不受影响）。
- 控制字符过滤对搜索框输入无副作用：正常字符（含中文/emoji）都不在过滤范围。
