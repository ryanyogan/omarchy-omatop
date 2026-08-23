# Omarchy Shell Plugin API Reference

Paths: shell root `/usr/share/omarchy/shell` (env `OMARCHY_PATH` → `/usr/share/omarchy`). Third-party plugins live at `~/.config/omarchy/plugins/<manifest.id>/`.

---

## 1. Manifest (`/home/ryan/code/omarchy-omaday/manifest.json`)

Validated by `/usr/share/omarchy/shell/services/PluginRegistry.qml:validateManifest`. Required: `id`, `name`, `version`, `kinds`, `entryPoints`. `schemaVersion` must be exactly `1`. `id` may not contain `/` or `..`. Every `entryPoints` value must be a relative path, not starting with `/`, no `..`.

```json
{
  "schemaVersion": 1,
  "id": "ryanyogan.omaday",
  "name": "Omaday",
  "version": "1.0.0",
  "author": "Ryan Yogan",
  "license": "MIT",
  "description": "...",
  "homepage": "...", "repository": "...",
  "keywords": ["calendar"],
  "kinds": ["bar-widget", "overlay", "service"],
  "entryPoints": {
    "barWidget": "BarWidget.qml",
    "overlay":   "Overlay.qml",
    "service":   "CalendarService.qml"
  },
  "keepLoaded": true,
  "barWidget": {
    "displayName": "Omaday",
    "description": "...",
    "category": "Productivity",
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": { "pollIntervalSec": 120, "notificationsEnabled": true },
    "schema": [
      { "key": "pollIntervalSec", "type": "integer", "label": "Refresh interval (seconds)",
        "min": 30, "max": 900, "step": 30, "defaultValue": 120 },
      { "key": "notificationsEnabled", "type": "boolean", "label": "...", "defaultValue": true }
    ]
  }
}
```

**Kinds** (`shell/README.md`): `bar-widget`, `panel`, `overlay`, `menu`, `service`, `bar`.
Entry-point key name == kind name, except bar-widget → **`barWidget`** (camelCase). `entryPointUrl(manifest, kind)` uses the kind string as the key; for panel/overlay/menu the loader picks `panel` > `overlay` > `menu` in that precedence (`shell.qml:computePanelEntries`).

**`keepLoaded: true`** (top-level, sibling of `entryPoints`): the panel/overlay Loader stays `active` permanently instead of only while `shell.openPanelIds[id] === true`. Required if your overlay must survive between summons or if a service pushes to it. Does not affect `service` kind (services are always mounted while enabled).

**`barWidget.*`** is only consumed for the `bar-widget` kind; `shell.qml:syncPluginWidgets` normalizes it into BarWidgetRegistry metadata:
```js
{ displayName, description, category:"Plugin", allowMultiple:false,
  defaults:{}, settingsForm:"", schema:[], pluginId, sourceDir, source:"plugin" }
```
`defaultSection` must be `"left"|"center"|"right"` or the **entire manifest is rejected**; omitted → `"center"` (`defaultBarWidgetSection`).

**Schema entry types observed in first-party manifests:** `"integer"` (`min`,`max`,`step`), `"boolean"`, `"string"`, `"enum"` (`options: [...]`), `"path"`, `"multiselect"`. Optional keys on every entry: `label`, `description`, `defaultValue`.

**Enablement:** third-party non-bar-widget plugins must appear in `shell.json` `plugins: [{ "id": "..." }]`; bar-widgets appear as a `bar.layout.<section>[]` entry. `omarchy plugin enable <id>` writes it. A plugin with kinds `["bar-widget","overlay","service"]` is enabled by its bar layout entry alone — `isEnabled()` checks `findEntryLocation` across `bar.id`, `bar.layout.*`, and `plugins[]`.

**Right-click / overlay routing:** there is no manifest field for right-click. It is code in the bar widget (see §2).

---

## 2. BarWidget (`/home/ryan/code/omarchy-omaday/BarWidget.qml`)

Extends `qs.Ui.BarWidget` (`/usr/share/omarchy/shell/Ui/BarWidget.qml`), an `Item` with:

| member | type | meaning |
|---|---|---|
| `bar` | `QtObject` | host Bar instance, injected by slot |
| `moduleName` | `string` | canonical plugin id, injected |
| `settings` | `var` | this widget's inline shell.json entry, injected |
| `vertical` | `readonly bool` | `bar.vertical` |
| `barSize` | `readonly int` | `bar.barSize` |
| `broadcast(method)` | fn | invoke `method` on every per-monitor instance via `bar.moduleWidgets(moduleName)` |
| `setting(name, fallback)` | fn | `settings[name]`, `undefined`/`null` → fallback |

Injection site: `plugins/bar/Bar.qml:1750-1752` — `if ("bar" in target) target.bar = root; if ("moduleName" in target) target.moduleName = moduleName; if ("settings" in target) target.settings = moduleSettings`.

### Contract the shell/bar expects on a bar-widget instance
```qml
readonly property bool opened          // Bar.isBarWidgetOpen()
function open()                        // Bar.summonBarWidget()
function close()                       // Bar.hideBarWidget()
readonly property bool popoutSwitchClosing
function closeForPopoutSwitch()        // Bar.requestPopout() calls this on the outgoing popout
readonly property real openPanelIndicatorWidth   // optional; "openPanelIndicatorHeight" when vertical
```

### Omaday's structure
```qml
BarWidget {
  id: root
  moduleName: "ryanyogan.omaday"

  // Service handle. bar.shell is the shell root; serviceFor re-evaluates
  // when _services is reassigned after the service loads.
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null

  // Panel is loaded eagerly, invisible, and injected imperatively.
  Loader { id: panelLoader; active: true; source: Qt.resolvedUrl("Panel.qml"); visible: false
           onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) } }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button   // the WidgetButton
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
    if (root.service && "widgetSettings" in root.service)
      root.service.widgetSettings = root.settings            // widget settings = plugin-wide truth
  }
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  // Shape contract, delegated to the Panel
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open()  { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }

  // Right-click → overlay. This is the whole mechanism.
  function toggleOverlay() { if (bar && bar.shell) bar.shell.toggle(root.moduleName, "{}") }

  // Settings read
  readonly property bool showBadge: setting("showInviteBadge", true) === true

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: content.visible ? content.width : 0
```

Icon button — uses `qs.Ui.WidgetButton` (not `BarIconButton`, because it draws a custom `Row`):
```qml
WidgetButton {
  id: button
  anchors.fill: parent
  bar: root.bar
  text: ""
  labelVisible: false          // suppress the built-in Text
  hasVisualContent: true       // otherwise visible:false / opacity:0
  fixedWidth: root.vertical ? -1 : Math.round(content.implicitWidth + Style.spaceReal(8.5) * 2)
  tooltipText: "Omaday"
  onPressed: function(b) {
    if (b === Qt.MiddleButton) root.joinHero()
    else if (b === Qt.RightButton) root.toggleOverlay()
    else root.togglePanel()
  }
  Row { id: content; anchors.centerIn: parent; spacing: 0; /* OmadayIcon + measured cells */ }
}
```
Cell-collapse idiom used for badge/countdown: an `Item` whose `width` is `Math.ceil(TextMetrics.advanceWidth) + Style.space(n)` when active, `0` otherwise, `clip: true`, `visible: width > 0`, with `Behavior on width { NumberAnimation { duration: 180-220; easing.type: Easing.OutCubic } }`, and the `Text` anchored `right: parent.right`.

`SystemClock { precision: SystemClock.Minutes; onDateChanged: ... }` (from `Quickshell`) for date ticks.

---

## 3. Panel (`/home/ryan/code/omarchy-omaday/Panel.qml`) — bar popout

Extends `qs.Ui.Panel` (`/usr/share/omarchy/shell/Ui/Panel.qml`):

| member | meaning |
|---|---|
| `bar`, `moduleName`, `settings` | injected by the host widget |
| `ipcTarget: string` | IPC target name; `""` disables |
| `manageIpc: bool` (default `true`) | auto-registers `IpcHandler` with `open/close/show/hide/toggle` |
| `controller` (alias → `PanelController`) | `.open`, `.show()`, `.hide()`, `.toggle()` |
| `popoutSwitching`, `popoutSwitchClosing` | bool |
| `opened` | `readonly` == `controller.open` |
| `barForeground` | `readonly color` == `bar.barForeground` else `Color.foreground` |
| `open()`, `close()`, `toggle()`, `closeForPopoutSwitch()` | lifecycle |
| `switchPanel(direction)` | → `bar.switchPanelFrom(root, direction)` |
| `setting(name, fallback)` | same as BarWidget |

`PanelController.qml` = `QtObject { property bool open; toggle(); show(); hide() }`.

Omaday's Panel:
```qml
Panel {
  moduleName: "ryanyogan.omaday"
  ipcTarget: "ryanyogan.omaday"   // omarchy-shell ryanyogan.omaday toggle
  property var anchorItem: null   // set to the WidgetButton by injectPanel
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root   // popout coordinator key

  function open() { root.controller.show(); if (service) service.surfaceOpened()
                    Qt.callLater(function() { focusKeys() }) }
  function openFromHotkey() { open() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }
  function openOverlay() { if (root.bar && root.bar.shell) { root.close(); root.bar.shell.toggle(root.moduleName, "{}") } }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth:  panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(Style.space(640), Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: someTextField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(d) { root.bar.switchPanelFrom(root.barIdentity, d) }
      onMoveRequested: function(dx, dy) { ... }
      onActivateRequested: { ... }
      onTextKey: function(t) { if (t === "r") root.service.refresh(true) }
      Column { anchors.fill: parent; ... }
    }
  }
}
```
Theming inside a bar popout reads the bar, not the palette directly:
```qml
readonly property color ink: root.bar ? root.bar.foreground : Color.foreground
readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
readonly property color dim: Qt.darker(ink, 1.5)
readonly property color hairline: Util.alpha(ink, 0.12)
```

---

## 4. Overlay (`/home/ryan/code/omarchy-omaday/Overlay.qml`)

Root type is a plain **`Item { visible: false }`** that contains a `PanelWindow`. Not a PanelWindow itself.

```qml
Item {
  id: root
  visible: false

  // Injected by shell.qml's panel Loader.onLoaded (see §7)
  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false     // read by shell.isPluginOpen()

  // Hot-reload-surviving state
  PersistentProperties {
    id: persisted
    reloadableId: "ryanyogan.omaday.overlay"
    property string view: ""
    property double anchorMs: 0
  }

  // Put the overlay on the monitor Hyprland has focused; captured per summon.
  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor            // import Quickshell.Hyprland
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (String(screens[i].name || "") === name) return screens[i]
    return null
  }

  function open(payloadJson) {
    // keepLoaded overlays can load before the service registers; re-resolve.
    if (!service && shell && typeof shell.serviceFor === "function")
      service = shell.serviceFor("ryanyogan.omaday")
    var screen = focusedScreen()
    if (screen) panel.screen = screen
    opened = true
    if (service) service.surfaceOpened()
    Qt.callLater(function() { frame.forceActiveFocus() })
  }
  function close() { opened = false }
  function toggle() { opened ? close() : open("{}") }

  function handleKey(keyEvent) { /* modal stack: form > detail > help > views */ }

  // theme tokens
  readonly property color ink: Color.popups.text
  readonly property color dim: Qt.darker(ink, 1.5)
  readonly property color faint: Qt.darker(ink, 2.1)
  readonly property color hairline: Util.alpha(ink, 0.1)
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: Style.font.family

  PanelWindow {
    id: panel
    visible: root.opened || frame.opacity > 0.01   // keep mapped through fade-out
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omaday-overlay"
    WlrLayershell.layer: WlrLayer.Overlay
    // Release keys on logical close, not after the fade.
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }

    Rectangle {                       // scrim
      anchors.fill: parent
      color: Color.menu.scrim
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
    MouseArea { anchors.fill: parent; enabled: root.opened; onClicked: root.close() }

    Rectangle {
      id: frame
      anchors.centerIn: parent
      width:  Math.min(Style.space(1100), panel.width  - Style.space(48))
      height: Math.min(Style.space(750),  panel.height - Style.space(48))
      radius: Style.cornerRadius
      color: Color.popups.background
      border.width: Math.max(1, Style.space(2))
      border.color: Color.popups.border
      focus: true
      opacity: root.opened ? 1 : 0
      scale:   root.opened ? 1 : 0.985
      Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
      Behavior on scale   { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
      Keys.onPressed: function(keyEvent) { root.handleKey(keyEvent) }
      MouseArea { anchors.fill: parent; onClicked: {} }   // clicks stay inside
      Row { anchors.fill: parent; anchors.margins: Style.spacing.panelPadding; ... }
    }
  }
}
```
Key dispatch pattern (`handleKey`): guard modal layers first, each `return`ing with `keyEvent.accepted = true`; then a `var handled = true` ladder over `keyEvent.text` (`h/l/j/k/d/w/m/o/n/t/J/a/x/s`) plus `Qt.Key_Left/Right`, ending `else handled = false; keyEvent.accepted = handled`.

---

## 5. Reference first-party overlay: `/usr/share/omarchy/shell/plugins/clipboard/Clipboard.qml`

Root: `Item { id: root }` (no `visible:false`; it holds no direct visual children besides the PanelWindow).

Public shape: `property bool opened`, `function open(payloadJson)`, `function close()`, `function toggle()`.

```qml
property string omarchyPath: Quickshell.env("OMARCHY_PATH")
// [menu] surface tokens — themes styling the menu also style this overlay
property color background: Color.menu.background
property color foreground: Color.menu.text
property color border:     Color.menu.border
property var   borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
property color scrim:      Color.menu.scrim
property color selectedBackground: Color.menu.selectedBackground
property color selectedText:       Color.menu.selectedText
readonly property int cornerRadius: Style.cornerRadius
property string fontFamily: Style.font.menuFamily          // NOT Style.font.family
property int contentMargin: Style.spacing.panelPadding
property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
property int contentSpacing: Style.spacing.md
property int cardWidth:  Math.min(Style.space(875), panel.width  - Style.gapsOut * 2)
property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
```

`open()` body: set `opened`, reset `filterText`/`selectedIndex`, `cursorActive = true`, `disarmPointer()`, `rebuildDisplay()`, `Qt.callLater(function(){ keyCatcher.forceActiveFocus() })`.

Window:
```qml
PanelWindow {
  id: panel
  visible: root.opened                       // no fade-out; hard hide
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "omarchy-clipboard"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive   // constant, not bound
  exclusionMode: ExclusionMode.Ignore

  Rectangle { anchors.fill: parent; color: root.scrim }
  MouseArea { anchors.fill: parent; onClicked: root.close() }

  BorderSurface {
    id: card
    width: root.cardWidth; height: root.cardHeight
    radius: root.cornerRadius
    anchors.centerIn: parent
    color: root.background
    borderSpec: root.borderSpec
    padding: root.contentMargin
    MouseArea { anchors.fill: parent; onClicked: {} }
    Item { id: keyCatcher; anchors.fill: parent; focus: true
           Keys.priority: Keys.BeforeItem; Keys.onPressed: function(event) { ... } }
    Column { anchors.fill: parent
             anchors.topMargin: card.contentTopInset;    anchors.rightMargin:  card.contentRightInset
             anchors.bottomMargin: card.contentBottomInset; anchors.leftMargin: card.contentLeftInset
             spacing: root.contentSpacing; ... }
  }
}
```
Note: `BorderSurface` exposes `contentTopInset / contentRightInset / contentBottomInset / contentLeftInset` (padding + per-side border width) — always anchor content with those margins.

Keyboard handler (order matters):
`Escape` → clear filter if any, else close · `Util.editsFilter(event, filterText)` → `setFilter(Util.editedFilter(event, filterText))` · `Delete` (Shift → clear all) · `Up/Down` → `select(∓1)` · `PageUp/PageDown` → `select(∓6)` · `Home/End` → `selectAbsolute` · `Return/Enter` (Alt→open, Shift→copy, else activate; if `!cursorActive` just arm the cursor) · printable fallback `event.text.length === 1 && charCodeAt(0) >= 32 && !== 127` → append to filter.

Cursor model: `property int selectedIndex`, `property bool cursorActive`. Rows compute `readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex` and color `hasCursor ? root.selectedBackground : "transparent"`, text `hasCursor ? root.selectedText : root.foreground`. `ListView { spacing: Style.space(4); boundsBehavior: Flickable.StopAtBounds }` + `positionViewAtIndex(i, ListView.Contain)`.

Pointer/keyboard conflict: `PointerMoveGate { id: pointerGate; referenceItem: card }` with `pointerGate.reset()` on every keyboard move and `if (!pointerGate.moved(item, mouse)) return` in `onPositionChanged`.

Modal confirm: `ConfirmDialog` nested inside `keyCatcher` with `z: 10`, and `keyCatcher.z: root.clearConfirmOpen ? 20 : 0`; the key handler short-circuits `if (root.clearConfirmOpen) { if (clearConfirm.handleKey(event)) event.accepted = true; return }`.

Animations used: **none** on the clipboard window (no Behaviors). Omaday's overlay adds the 150/160ms OutCubic fades shown above.

---

## 6. `qs.Commons` singletons

Import: `import qs.Commons` → `Border`, `Color`, `Style`, `Util` (all `pragma Singleton`).

### `Style` — `/usr/share/omarchy/shell/Commons/Style.qml`

**Geometry**
- `int cornerRadius` — mirrors Hyprland `decoration:rounding`; default `0`.
- `int gapsOut` — half of Hyprland `general:gaps_out`; default `5`. Panel/overlay-to-screen-edge distance.

**Spacing scale**
- `real spacingScale` (1.0), `bool spacingScaleWithFont` (true), `var spacingOverrides`.
- `readonly real effectiveSpacingScale` = `spacingScale * (spacingScaleWithFont ? fontScale : 1)`.
- `space(px) → int` — `Math.max(1, Math.round(px * effectiveSpacingScale))`, `0` for non-positive. **Use for all pixel geometry.**
- `spaceReal(px) → real` — unrounded, for fractional geometry.
- `spacingToken(key, fallbackPx)` — theme override or `space(fallbackPx)`.

`Style.spacing` (QtObject) — all `int`, theme-overridable; defaults in px before scaling:

| token | default | | token | default |
|---|---|---|---|---|
| `scale` (real) | `effectiveSpacingScale` | | `controlGap` | 8 |
| `hairline` | `space(1)` | | `controlPaddingX` | 10 |
| `xxs` | 2 | | `controlPaddingY` | 6 |
| `xs` | 3 | | `inputPaddingY` | 7 |
| `sm` | 4 | | `controlHeight` | 28 |
| `md` | 6 | | `popupRowHeight` | 28 |
| `lg` | 8 | | `dropdownWidth` | 240 |
| `xl` | 10 | | `searchableDropdownWidth` | 260 |
| `xxl` | 12 | | `numberFieldWidth` | 120 |
| `xxxl` | 14 | | `searchablePopupMinHeight` | 220 |
| `huge` | 18 | | `rowGap` | 8 |
| | | | `rowPaddingX` | 12 |
| | | | `labelGap` | 4 |
| | | | `panelGap` | 14 |
| | | | `panelPadding` | 18 |
| | | | `popupPadding` | 14 |

**Typography**
- `string fontFamily` (default `"monospace"` → fontconfig alias). Bind `font.family` to this.
- `string resolvedFontFamily` — concrete family from `fc-match` (display only).
- `int fontBaseSize` (default 12); `readonly real fontScale = max(1/12, fontBaseSize/12)`.
- `readonly string menuFontFamily` — `OMARCHY_MENU_FONT` env override else `fontFamily`.
- `fontPx(mult) → int`, `fontToken(key, fallback) → int`.

`Style.font` (QtObject):

| member | value @ base 12 |
|---|---|
| `family` | `Style.fontFamily` |
| `resolvedFamily` | resolved concrete family |
| `menuFamily` | menu override family |
| `baseSize` | 12 |
| `caption` | ×0.833 = 10 |
| `bodySmall` | ×0.917 = 11 |
| `body` | ×1.0 = 12 |
| `subtitle` | ×1.083 = 13 |
| `title` | ×1.167 = 14 |
| `heading` | ×1.333 = 16 |
| `display` | ×2.0 = 24 |
| `displayLarge` | ×2.333 = 28 |
| `iconSmall` | = `bodySmall` |
| `icon` | = `title` |
| `iconLarge` | ×1.5 = 18 |

`Style.bar` (QtObject, all scale with font unless `bar.scale-with-font=false`):
`sizeHorizontal` 26 · `sizeVertical` 28 · `iconSlot` 27 · `iconCanvas` 16 · `iconFont` 13 · `statusSlot` 21.

**Control-state tokens** — vocabulary: `normal`, `hover-cursor`, `selected`, `pressed`, `focus`, `selection`.
- Widths: `normalBorderWidth` (1), `hoverBorderWidth` (=normal), `selectedBorderWidth` (0), `focusBorderWidth` (=hover).
- Fill alphas: `normalFillAlpha` .04, `hoverFillAlpha` .08, `selectedFillAlpha` .18, `pressedFillAlpha` .22, `focusFillAlpha` (=hover), `selectionFillAlpha` .35.
- Border alphas: `normalBorderAlpha` .4, `hoverBorderAlpha` .25, `selectedBorderAlpha` 1.0, `focusBorderAlpha` (=hover).
- Color tokens (string, resolve to palette role or hex): `normalColorToken`, `hoverColorToken`, `selectedColorToken`, `pressedColorToken`, `focusColorToken`, `selectionColorToken`.
- Resolvers: `normalStateColor(fg,accent,urgent)`, `hoverStateColor(…)`, `selectedStateColor(…)`, `pressedStateColor(…)`, `focusStateColor(…)`, `selectionStateColor(…)`, `resolveStateColor(token,fg,accent,urgent,fallback)`, `colorFromHex(value, fallback)`.
- Composed: `normalFillFor(fg,accent,urgent)`, `hoverFillFor`, `selectedFillFor`, `pressedFillFor`, `focusFillFor`, `selectionFillFor`; `normalBorderFor`, `hoverBorderFor`, `selectedBorderFor`, `focusBorderFor`.
- Ladder helpers: `controlFill(focused, hot, fg, accent)`, `controlBorder(focused, hot, fg, accent)`, `controlBorderWidth(focused, hot)`.
- Pre-resolved colors against the palette: `normalFill`, `hoverFill`, `selectedFill`, `pressedFill`, `focusFillColor`, `normalBorderColor`, `hoverBorderColor`, `selectedBorderColor`, `focusBorderColor`, `selectedAccentFill`, `selectionFill`.
- Misc: `styleNum(key,fb)`, `styleRawNum(key)`, `styleAlpha(key,fb)`, `styleString(key,fb)`, `boolToken(v,fb)`, `refresh()`, `scheduleRefresh()`, `applyShellValues(values)`.

**No animation duration or easing tokens exist on `Style`.** Every component hardcodes its own. Observed house values: fade 140ms OutCubic (KeyboardPanel card, WidgetButton opacity, PanelSlider), 150–160ms OutCubic (Overlay frame/scrim), 110ms OutCubic (slider knob scale), 160ms ColorAnimation (WidgetButton label color), 180–220ms OutCubic (bar cell width), 120ms In/OutQuad (text swap).

### `Color` — `/usr/share/omarchy/shell/Commons/Color.qml`

Foundational: `color foreground` (#cacccc) · `background` (#101315) · `accent` (#cacccc) · `urgent` (#a55555) · `muted` (#707880).
Paths: `home`, `stateHome`, `currentThemePath`. Raw dict: `var shellValues` (`"section.key" → string`).
Helpers: `pick(key, fallback)`, `pickAlpha(key, fallback)`, `flatColor(value, fallback)`, `composed(colorKey, alphaKey, colorFallback, alphaFallback)`, `parseShell(raw)`, `loadColors/loadShell/loadUserShell/mergeShell`.

Surface groups (each a `QtObject`):

| group | properties |
|---|---|
| `Color.bar` | `background`, `text`, `active` (fallback `urgent`) |
| `Color.popups` | `background`, `text`, `border` (fallback `accent`) |
| `Color.tooltip` | `background`, `text`, `border` |
| `Color.notifications` | `background`, `text`, `border`, `countdown` |
| `Color.menu` | `background`, `text`, `border`, `scrim` (bg @0.5), `selectedBackground` (fg @0.08), `selectedText` (fallback `accent`), `selectedBorder` (fg @0.0) |
| `Color.polkit` | `background`, `text`, `textError`, `border`, `borderError`, `accent`, `scrim` |
| `Color.lock` | `background` (@0.8), `text`, `placeholder`, `textError`, `border`, `borderActive`, `borderError`, `selection` |
| `Color.imagePicker` | `scrim`, `text`, `selectedBorder`, `unselectedBorder` |

There is **no** `Color.panel.*`, no `warning`, no `danger`. Overlays use `Color.popups.*` (Omaday) or `Color.menu.*` (clipboard/emojis). "Danger" is `Color.urgent`, typically `Util.alpha(Color.urgent, 0.22)` fill / `Util.alpha(Color.urgent, 0.56)` border (see `ConfirmDialog`).

### `Border` — `/usr/share/omarchy/shell/Commons/Border.qml`

A *spec* is `{ color, widths: {top,right,bottom,left}, gradient: {colors[], angle, enabled} }`.

```qml
Border.surfaceSpec(section, token, fallbackColor, fallbackWidth, alphaKey)
//   section  – shell.toml section, e.g. "popups" | "menu" | "tooltip"
//   token    – "border" (or "border-active", "selected-border", …)
//   fallbackColor – color used when the theme doesn't set it
//   fallbackWidth – px (pass an already-scaled value: Math.max(1, Style.space(2)))
//   alphaKey – optional; defaults to token + "-alpha"
// Reads: <section>.<token>, <section>.<token>-alpha, <section>.<token>-width
//        (+ -width-top/-right/-bottom/-left, falling back to border-width*)
```

Other functions: `none()` · `flat(color, width)` · `controlSpec(state, fg, accent, urgent)` where `state ∈ "normal"|"hover"|"hot"|"selected"|"focus"` · `controlWidths(state)` · `controlHasWidth(state)` · `hyprlandActiveSpec(fallbackColor, fallbackWidth)` · `localOrSurfaceSpec(section, token, localColor, defaultColor, fallbackWidth, alphaKey)` · `withWidth(spec, width)` · `isNone(spec)` · `needsOverlay(spec)` · `canUseNative(spec)` · `top/right/bottom/left(spec)` · `uniformWidth(spec)` · `color(spec)` · `value(section,key)` · `valueOr(section, keys[])` · `alpha(section, key, fb)` · `cssColor(color, opacity)` · `resolvedGradient(raw, fallbackColor, opacity)` · `sameColor(a,b)` · `resolveValueRef(raw)` · `borderValue(raw, fallbackColor, opacity, legacyGradientRaw)`.

Specs are consumed by `qs.Ui.BorderSurface` (`borderSpec` property) and `BorderOverlay`.

### `Util` — `/usr/share/omarchy/shell/Commons/Util.qml`

`clamp(v,min,max)` · `clampAlpha(v)` · `alpha(color, opacity) → color` · `wheelSteps(accumulator, delta) → {steps, remainder}` · `fileUrl(path)` (percent-encodes segments) · `shellQuote(value)` · `execDetached(command)` (runs `bash -lc`) · `isPlainObject(v)` · `canonicalWidgetId(id)` · `decodeBase64(v)` · `cloneJson(v)` · `parseModuleJson(raw)` (waybar-style last line) · `editsFilter(event, text) → bool` (Backspace / Ctrl+Backspace / Ctrl+U) · `editedFilter(event, text) → string` · `normalizeLayoutEntry/Section/Layout`.

---

## 7. `qs.Ui` components — public surface

Import `import qs.Ui`. Full list in `/usr/share/omarchy/shell/Ui/qmldir`.

### `BarWidget` — see §2.

### `Panel` — see §3.

### `KeyboardPanel` (`Ui/KeyboardPanel.qml`) — layer-shell popout anchored to a bar icon
`PanelWindow` subclass. **Required**: `anchorItem: Item`, `bar: QtObject`.
Properties: `owner` (`var`, popout coordinator key — pass the bar widget instance) · `margin` (=`Style.gapsOut`) · `padding` (=`Style.spacing.popupPadding`) · `contentWidth` (=`Style.space(280)`) · `contentHeight` (=`Style.space(200)`) · `borderSpec` (=`Border.surfaceSpec("popups","border",Color.popups.border, Math.max(1,Style.space(2)))`) · `centerOnBar: bool` · `open: bool` · `gap` (=`Style.gapsOut`) · `popoutSwitching` · `popoutSwitchClosing` · `focusPrimed` · `focusTarget: Item` (forced active focus after map) · **default property `contentItem`** (children go into the padded card).
Readonly: `coordinatorKey`, `anchorWindow`, `barPos`, `anchorScreenPos`, `anchorW/H`, `screenW/H`, `availableCardWidth`, `availableCardHeight`, `verticalContentInset`, `barW/barH`, `cardOrigin`.
Functions: `close()` · `beginFocusPrime()` · `fittedContentWidth(width, cap)` · `fittedContentHeight(implicitHeight, cap)` · `cappedContentHeight(height)`.
Behavior: `WlrLayershell.namespace: "omarchy-keyboard-panel"`, layer Overlay, `keyboardFocus` primes `Exclusive` for 75ms then settles on `OnDemand`; full-screen surface with the card at `cardOrigin`; outside-click dismissal + per-monitor transparent dismissal twins; card opacity fades 140ms OutCubic.

### `PanelKeyCatcher` (`Ui/PanelKeyCatcher.qml`)
`Item` with `focus: true`, `Keys.priority: Keys.BeforeItem`.
Property: `bool blocked` — when true all keys pass through to descendants (set it to `someTextField.activeFocus`).
Signals: `moveRequested(int dx, int dy)` · `activateRequested()` · `returnRequested()` · `closeRequested()` · `deleteRequested()` · `tabRequested(int direction)` · `textKey(string text)`.
Mapping: `Esc`→close · `Tab`/`Backtab`→tab(±1) · `Down`/`j`→move(0,1) · `Up`/`k`→move(0,-1) · `Right`/`l`→move(1,0) · `Left`/`h`→move(-1,0) · `Return`/`Enter`→`returnRequested()` **then** `activateRequested()` · `Space`→activate · `x`/`X`→delete · any other single char→`textKey`.

### `BarIconButton` (`Ui/BarIconButton.qml`) — extends `WidgetButton`
Adds: `Component iconComponent` (null → render `text` through `OpticalGlyph`) · `real slotSize` (=`Style.bar.iconSlot`) · `real opticalSize` (=`Style.bar.iconCanvas`) · `bool debugOpticalBounds` (env `OMARCHY_DEBUG_BAR_ICONS=1`).
Readonly: `opticalCenterErrorX`, `glyphPaintedWidth`, `glyphBaselineY`, `glyphFontSize`.
Presets: `labelVisible: false`, `hasVisualContent: text !== "" || iconComponent !== null`, `fontSize: Style.bar.iconFont`, `fixedWidth: vertical ? -1 : slotSize`, `fixedHeight: vertical ? slotSize : -1`.

### `WidgetButton` (`Ui/WidgetButton.qml`) — base of BarIconButton
Properties: `bar` · `text` · `fontFamily` (=`bar.fontFamily`) · `fontSize` (=`Style.font.body`) · `foreground` (=`bar.barForeground`) · `activeColor` (=`bar.urgent`) · `active` · `horizontalMargin` (8.5) · `verticalPadding` (6) · `fixedWidth`/`fixedHeight` (-1 = auto) · `textRotation` · `keepSpace` · `dimmed` · `concealed` · `interactive` · `pressable` · `useActiveColor` · `maintainIndicatorReveal` · `labelVisible` · `hasVisualContent` · `revealHost` · `tooltipText` · `registeredBar`.
Signals: `pressed(int button)` · `wheelMoved(int delta)`.
Functions: `triggerPress(button)` · `hideOwnTooltip()` · `syncClickRegistration()`.
Readonly: `vertical`, `barSize`, `scaledHorizontalMargin`, `scaledVerticalPadding`, `tooltipHovered`, `labelWidth`.

### `PanelSlider` (`Ui/PanelSlider.qml`)
Properties: `bar` · `value` · `minimum` (0) · `maximum` (1) · `step` (0.05) · `integer: bool` · `trackColor` · `fillColor` · `knobColor` · `dragging` · `trackHeight` (=`max(4, round(controlHeight*0.11))`) · `knobSize` (=`max(14, round(controlHeight*0.38))`) · `liveValue` · `tickCount` (0 = plain track; >1 draws that many notches) · `tickColor`.
Signals: `moved(real value)` · `released(real value)` · `rightClicked()`.
Readonly: `range`, `progress`. `implicitWidth: Style.space(200)`, `implicitHeight: max(Style.space(22), knobSize + Style.spacing.md)`.
Wheel steps by `step`, emitting both `moved` and `released`.

### `ConfirmDialog` (`Ui/ConfirmDialog.qml`)
Properties: `opened` · `message` · `cancelText` ("Cancel") · `confirmText` ("Confirm") · `selectedIndex` (default `1` = confirm) · `background` · `foreground` · `scrim` (=`Util.alpha(Color.background,0.7)`) · `selectedBackground` · `selectedText` · `fontFamily` · `cornerRadius`.
Signals: `canceled()` · `confirmed()`.
Function: `handleKey(event) → bool` — call from your key handler; consumes `Esc`, `Left/Right/Tab/Backtab`, `Return/Enter`. `visible: opened`. Index 1 is styled destructive (urgent).

### `PanelSectionHeader` (`Ui/PanelSectionHeader.qml`) — a `Text`
Properties: `foreground` (=`Color.foreground`) · `fontFamily` (=`Style.font.family`) · `fontSize` (=`Style.font.caption`). Renders `Qt.darker(foreground, 1.4)`, `font.bold: true`, `topPadding: ceil(fontSize * 0.15)`. Set `text` yourself.

### `OpticalGlyph` (`Ui/OpticalGlyph.qml`) — an `Item`
Properties: `text` · `fontFamily` (=`Style.font.family`) · `fontSize` (=`Style.font.body`) · `color` (=`Color.foreground`) · `debugBounds`.
Readonly: `renderedFontSize`, `tightWidth`, `horizontalCorrection`, `paintedCenterX`, `baselineY`. Horizontally re-centers on painted bounds; `renderType: Text.NativeRendering`.

### Also available (`Ui/qmldir`)
`BarIndicator`, `BorderOverlay`, `BorderSurface`, `Button`, `ButtonGroup`, `CursorSurface`, `Dropdown`, `MultiSelect`, `NumberField`, `PanelActionButton`, `PanelController`, `PanelHero`, `PanelSeparator`, `PanelToolTip`, `PointerMoveGate`, `PopupCard`, `ScreenMoveRemap`, `SearchableDropdown`, `SpeedTestOverlay`, `TextField`, `Toggle`, `ToggleSwitch`.

`PanelHero` (used by Omaday's panel + overlay sidebar): `iconComponent: Component` · `title` · `meta` (rendered uppercase, letterSpacing 1.2, caption size) · `detail` (renders as a bordered pill) · `foreground` · `fontFamily` · `iconSize` (=`Style.font.display`) · `iconOpacity` · `metaOpacity` (alias) · `trailingControl: Component`; readonly `dim`, `trailingInset`.

`BorderSurface`: `color`, `borderSpec`, `padding`, `radius` + readonly `contentTopInset`/`contentRightInset`/`contentBottomInset`/`contentLeftInset`.

`PointerMoveGate`: `referenceItem: Item`, `reset()`, `moved(item, mouse) → bool`.

---

## 8. Service kind + host wiring (`/usr/share/omarchy/shell/shell.qml`)

`PluginRegistry.qml` **does not instantiate anything** — it only scans manifests, validates them, resolves `entryPointUrl(manifest, kind)`, and answers `isEnabled(id)` / `inBar(id)` / `resolveEnabledId(id)`. Instantiation is entirely in `shell.qml`.

### Service loading (`shell.qml:265-355`)
Entry point key: **`"service"`**. A service is an ordinary **`Item`** (not `pragma Singleton`), created once per plugin id with `Qt.createComponent(url, Component.PreferSynchronous)` + `createObject(serviceHost)` where `serviceHost` is `Item { visible: false }`.

Injected on the instance if the property exists:
```js
if ("omarchyPath" in inst)       inst.omarchyPath = shell.omarchyPath
if ("shell" in inst)             inst.shell = shell
if ("manifest" in inst)          inst.manifest = manifest
if ("barWidgetRegistry" in inst) inst.barWidgetRegistry = shell.barWidgetRegistry
if ("pluginRegistry" in inst)    inst.pluginRegistry = shell.pluginRegistry
```
Stored in `shell._services` (a plain object, **reassigned** so bindings re-evaluate). Public accessors on the shell root:
```js
shell.serviceFor(pluginId)           // → instance or null
shell.firstPartyServiceFor(pluginId) // alias
shell.ensureService(pluginId)        // create on demand
```
`_syncServices()` runs on every `pluginRegistry.onPluginsChanged`; it creates services for enabled plugins with the `service` kind and `destroy()`s ones whose plugin was disabled/removed. **Services are never handed settings** — that is why Omaday's bar widget pushes `root.service.widgetSettings = root.settings`.

**Reaching the service:**
- from a bar widget: `bar.shell.serviceFor(moduleName)` — bind it `readonly`, it re-evaluates when `_services` is reassigned.
- from an overlay/panel/menu: the panel Loader injects `item.service = shell.serviceFor(pluginId)` at `onLoaded`. With `keepLoaded: true` the overlay can load *before* the service, so re-resolve defensively in `open()`:
  `if (!service && shell && typeof shell.serviceFor === "function") service = shell.serviceFor("<id>")`.
- from a bar-widget's own Panel: injected imperatively by the widget (`injectPanel`).

### Overlay/panel/menu loading (`shell.qml:583-660`)
```qml
Loader {
  source: entryPointUrl(manifest, kind)          // kind: "panel" > "overlay" > "menu"
  active: sourceUrl !== "" && (keepLoaded || shell.openPanelIds[pluginId] === true)
  asynchronous: true
  onLoaded: {
    if ("omarchyPath" in item)       item.omarchyPath = shell.omarchyPath
    if ("shell" in item)             item.shell = shell
    if ("manifest" in item)          item.manifest = panelEntry.manifest
    if ("barWidgetRegistry" in item) item.barWidgetRegistry = shell.barWidgetRegistry
    if ("pluginRegistry" in item)    item.pluginRegistry = shell.pluginRegistry
    if ("service" in item)           item.service = shell.serviceFor(pluginId)
    shell.registerPanelLoader(pluginId, this)
  }
}
```
Overlays get **no `settings`**. Read settings via `service.widgetSettings` (Omaday's approach) or via the shell config.

### summon / hide / toggle
```js
shell.summon(pluginId, payloadJson) -> bool
shell.hide(pluginId)                -> bool
shell.toggle(pluginId, payloadJson) -> bool     // isPluginOpen ? hide : summon
shell.isPluginOpen(pluginId)        -> bool
shell.callIfLoaded(pluginId, method, arg) -> string
```
Dispatch rules:
1. `resolveEnabledId(pluginId)` maps a built-in id to its active clone.
2. If the plugin has kind `bar-widget` **and none of** `panel`/`overlay`/`menu` → routed to the live bar instance: `bar.summonBarWidget(id)` calls `item.open()`, `bar.hideBarWidget(id)` calls `item.close()`, `bar.isBarWidgetOpen(id)` reads `item.opened`. **Payload is dropped on this path.**
3. Otherwise → sets `openPanelIds[id] = true` (activating the Loader), queues `payloadJson` in `pendingPayloads[id]` (an array, so two summons before the Loader resolves both arrive in order), then `deliverIfLoaded(id)`.
4. `deliverIfLoaded` calls `loader.item.open(payload)` for each queued payload, wrapped in try/catch.
5. `hide()` calls `loader.item.close()` via `invokeIfLoaded`, then removes the id from `openPanelIds`.
6. `isPluginOpen` prefers `loader.item.opened === true` over `openPanelIds`.

**Omaday's case:** kinds include both `bar-widget` and `overlay`, so rule 2 does *not* apply (it has `overlay`), and `shell.toggle("ryanyogan.omaday", "{}")` goes to the **Overlay's** `open(payload)`/`close()`. That is why the quick-view Panel registers its own `ipcTarget: "ryanyogan.omaday"` — `omarchy-shell ryanyogan.omaday toggle` hits the panel, `omarchy-shell shell toggle ryanyogan.omaday` hits the overlay.

### IPC surface (`IpcHandler { target: "shell" }`, `shell.qml:872+`)
```qml
function summon(id: string, payloadJson: string): string   // "ok" | "unknown"
function hide(id: string): void
function toggle(id: string, payloadJson: string): void
function togglePanelAt(section: string, index: string): string   // 1-based, returns id
function call(id: string, method: string, arg: string): string
function listPlugins(): string
function listShellConfig(): string
function rescanPlugins() / enablePlugin(id, json) / …
```
CLI: `omarchy-shell shell toggle <id>` / `omarchy-shell shell summon <id> '<json>'` / `omarchy-shell -q shell togglePanelAt right <n>`.

### Hyprland keybinds
Lua bindings under `~/.local/share/omarchy/default/hypr/bindings/` (mirrored at `/usr/share/omarchy/default/hypr/bindings/`):
```lua
o.bind("SUPER + CTRL + V", "Clipboard manager", "omarchy-shell shell toggle omarchy.clipboard")
o.bind("SUPER + CTRL + E", "Emojis",   "omarchy-shell shell toggle omarchy.emojis")
o.bind("SUPER + CTRL + A", "Audio",    "omarchy-shell shell toggle omarchy.audio")
o.bind("SUPER + CTRL + ALT + D", "Calendar", "omarchy-shell shell toggle omarchy.clock")
o.bind("SUPER + CTRL + ...", ..., "omarchy-shell -q shell togglePanelAt right " .. panel)
```
Users add their own in `~/.config/hypr/bindings.conf` / a lua file: `omarchy-shell shell toggle ryanyogan.omaday`.

### Reduced motion / global animations toggle
**None exists.** Grepping `services/`, `Commons/`, and `shell.qml` for `reducedMotion` / `animationsEnabled` / `reduce-motion` returns nothing. The only related flag is `Bar.foregroundAnimationEnabled` (bool, default `true`), which only gates the `ColorAnimation` on `WidgetButton`'s label color during bar transparency transitions. If you want a motion switch, add it to your own `barWidget.schema` and gate your `Behavior { enabled: ... }` on it.

---

## 9. Service structure (`/home/ryan/code/omarchy-omaday/CalendarService.qml`)

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root
  visible: false

  property var shell: null      // injected
  property var manifest: null   // injected

  // Pushed by the bar widget; the widget's shell.json entry is plugin-wide truth.
  property var widgetSettings: ({})
  function widgetSetting(name, fallback) {
    var value = widgetSettings ? widgetSettings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
  readonly property int pollIntervalSec: Util.clamp(Number(widgetSetting("pollIntervalSec", 120)) || 120, 30, 900)
  readonly property bool notificationsEnabled: widgetSetting("notificationsEnabled", true) === true

  // Helper binary shipped in the plugin dir; resolvedUrl percent-encodes, so decode.
  readonly property string helperPath:
    decodeURIComponent(Qt.resolvedUrl("bin/gcal").toString().replace(/^file:\/\//, ""))
  readonly property string settingsDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings"

  // Disk state / cache
  property FileView stateFile:  FileView { path: ...; watchChanges: true; printErrors: false; onLoaded: ... }
  property FileView cacheFile:  FileView { ... }
  Timer { /* poll */ }
  Process { /* fetch, stdout: StdioCollector { waitForEnd: true; onStreamFinished: ... } */ }

  SystemClock { id: clock; precision: SystemClock.Minutes }
  readonly property double nowMs: clock.date.getTime()

  // Derived state consumed by widget / panel / overlay
  readonly property var  visibleEvents: ...
  readonly property var  heroMeeting: ...
  readonly property bool heroImminent: ...
  readonly property int  inviteCount: ...
  readonly property string authState: ...   // "loading"|"unconfigured"|"unauthed"|"rejected"|"ok"

  // Commands invoked from any surface
  function refresh(force) { ... }
  function surfaceOpened() { ... }         // called by panel.open() and overlay.open()
  function updateState(patch) { ... }      // persists a partial state patch (debounced by Timer)
  function joinEvent(event) { ... }
  function rsvp(event, response) { ... }
}
```
Design rule the author follows: the service owns all timers, IO, disk cache, auth, and derived state; the three UI surfaces are pure readers plus command callers. Nothing in the service touches `Style`/`Color` except `calendarColor()` (theme-derived slot mapping).

---

## 10. Minimal skeletons

**manifest.json**
```json
{ "schemaVersion": 1, "id": "you.thing", "name": "Thing", "version": "1.0.0",
  "author": "You", "description": "...",
  "kinds": ["bar-widget", "overlay", "service"],
  "entryPoints": { "barWidget": "BarWidget.qml", "overlay": "Overlay.qml", "service": "Service.qml" },
  "keepLoaded": true,
  "barWidget": { "displayName": "Thing", "category": "Utility", "allowMultiple": false,
                 "defaultSection": "right", "defaults": { "n": 1 },
                 "schema": [ { "key": "n", "type": "integer", "label": "N", "min": 1, "max": 9, "defaultValue": 1 } ] } }
```

**Service.qml** — `Item { visible: false; property var shell: null; property var manifest: null; property var widgetSettings: ({}) ; … }`

**BarWidget.qml** — `import qs.Ui` → `BarWidget { moduleName: "you.thing"; readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null; … WidgetButton { onPressed: function(b) { if (b === Qt.RightButton) bar.shell.toggle(moduleName, "{}") } } }`

**Overlay.qml** — `Item { visible: false; property var shell: null; property var service: null; property bool opened: false; function open(p){…} function close(){…} PanelWindow { WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None; … } }`

**Install/test loop**
```bash
ln -s ~/code/omarchy-thing ~/.config/omarchy/plugins/you.thing
omarchy-shell shell rescanPlugins
omarchy plugin enable you.thing
omarchy-shell shell toggle you.thing
```
`PluginRegistry` also runs `inotifywait -m -r` on `~/.config/omarchy/plugins` and emits `localPluginChanged(id)` on `close_write,create,delete,move`, so edits hot-reload.