import QtQuick
import qs.Commons
import qs.Ui

// Location tabs: qs.Ui.ButtonGroup's chip row, re-implemented locally for
// three things the stock component doesn't surface — right-clicks (Button
// already emits rightClicked, ButtonGroup just drops it), a handle on the
// chip item so a context menu can anchor to the chip it acts on, and
// drag-to-reorder for the city chips. A Flow rather than ButtonGroup's
// Row: a long list of cities wraps to another line instead of clipping at
// the panel edge. Keyboard access goes through the panel (number keys),
// so the row itself takes no Tab focus.
Item {
  id: root

  property var options: []
  property string value: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal changed(string value)
  signal rightClicked(string value, var chip)
  // Indices into `options`, sampled before the move: take `fromIndex`'s
  // chip and insert it before `toIndex`'s.
  signal reordered(int fromIndex, int toIndex)

  implicitWidth: flow.implicitWidth
  implicitHeight: flow.implicitHeight

  // Drag-to-reorder state, as option indices. City chips occupy
  // options[1 .. length-2]: index 0 is Auto, the last is "+", and neither
  // moves.
  property int dragFrom: -1
  property int dragTo: -1
  readonly property bool dragging: dragFrom >= 0
  readonly property int cityCount: Math.max(0, options.length - 2)

  function optionValue(o) {
    return (o && typeof o === "object") ? String(o.value) : String(o)
  }
  function optionLabel(o) {
    return (o && typeof o === "object" && o.label !== undefined) ? String(o.label) : String(o)
  }
  function optionTooltip(o) {
    return (o && typeof o === "object" && o.tooltip) ? String(o.tooltip) : ""
  }

  function chipForValue(v) {
    for (var i = 0; i < chipRepeater.count; i++) {
      var chip = chipRepeater.itemAt(i)
      if (chip && optionValue(options[i]) === v) return chip
    }
    return null
  }

  // Insertion point for a cursor at (px, py) in flow coordinates: the
  // first city chip whose wrapped row the cursor hasn't passed and whose
  // midpoint it is left of. Falls through to "before the + chip" — the
  // end of the city list.
  function dropIndexAt(px, py) {
    for (var i = 1; i <= cityCount; i++) {
      var it = chipRepeater.itemAt(i)
      if (!it) continue
      if (py < it.y) return i
      if (py <= it.y + it.height && px < it.x + it.width / 2) return i
    }
    return cityCount + 1
  }

  Flow {
    id: flow
    width: root.width
    spacing: Style.spacing.md

    Repeater {
      id: chipRepeater
      model: root.options

      Item {
        id: slot
        required property var modelData
        required property int index
        readonly property string chipValue: root.optionValue(modelData)
        readonly property bool isCity: chipValue !== "auto" && chipValue !== "+add"
        width: chip.implicitWidth
        height: chip.implicitHeight

        Button {
          id: chip
          anchors.fill: parent
          text: root.optionLabel(slot.modelData)
          tooltipText: root.optionTooltip(slot.modelData)
          selected: slot.chipValue === root.value
          bordered: true
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          opacity: root.dragging && root.dragFrom === slot.index ? 0.35 : 1
          onClicked: root.changed(slot.chipValue)
          onRightClicked: root.rightClicked(slot.chipValue, slot)
        }

        // Insertion bar, drawn in the inter-chip gap the drop would land
        // in. Suppressed when the drop would be a no-op (before itself or
        // right after itself).
        Rectangle {
          visible: root.dragging && root.dragTo === slot.index
            && root.dragTo !== root.dragFrom && root.dragTo !== root.dragFrom + 1
          width: Math.max(2, Style.space(2))
          height: parent.height
          x: -Math.round((flow.spacing + width) / 2)
          radius: width / 2
          color: root.accent
        }

        // Drag layer for city chips. Left presses are claimed here — a
        // release without movement is the click — while right-clicks fall
        // through to the Button, whose hover fill and tooltip also keep
        // working. With a single city there is nothing to reorder, so the
        // Button keeps native clicks.
        MouseArea {
          anchors.fill: parent
          enabled: slot.isCity && root.cityCount > 1
          acceptedButtons: Qt.LeftButton
          cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
          property real pressX: 0
          property real pressY: 0
          onPressed: function(mouse) { pressX = mouse.x; pressY = mouse.y }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            var threshold = Application.styleHints.startDragDistance || 8
            if (!root.dragging
                && Math.abs(mouse.x - pressX) < threshold
                && Math.abs(mouse.y - pressY) < threshold) return
            root.dragFrom = slot.index
            var p = mapToItem(flow, mouse.x, mouse.y)
            root.dragTo = root.dropIndexAt(p.x, p.y)
            dragProxy.x = p.x - dragProxy.width / 2
            dragProxy.y = p.y - dragProxy.height / 2
          }
          onReleased: {
            var f = root.dragFrom
            var t = root.dragTo
            root.dragFrom = -1
            root.dragTo = -1
            if (f < 0) { root.changed(slot.chipValue); return }
            if (t !== f && t !== f + 1) root.reordered(f, t)
          }
          onCanceled: { root.dragFrom = -1; root.dragTo = -1 }
        }
      }
    }
  }

  // Ghost of the dragged chip, following the cursor above the row.
  Rectangle {
    id: dragProxy
    visible: root.dragging
    z: 10
    width: proxyLabel.implicitWidth + Style.spacing.controlPaddingX * 2
    height: proxyLabel.implicitHeight + Style.spacing.controlPaddingY * 2
    radius: Style.cornerRadius
    color: Style.hoverFillFor(root.foreground, root.accent)
    border.width: 1
    border.color: Style.normalBorderFor(root.foreground, root.accent)
    opacity: 0.9

    Text {
      id: proxyLabel
      anchors.centerIn: parent
      text: root.dragging ? root.optionLabel(root.options[root.dragFrom]) : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
