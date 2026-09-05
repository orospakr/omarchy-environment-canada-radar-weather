import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Weather.js" as Weather

// Right-hand column of the panel: Environment Canada citypage weather for
// the active location. Current conditions on top, then the next forecast
// period's full text, a horizontally scrolling 24-hour strip, and the week
// ahead — hover a day for its textual forecast.
Item {
  id: root

  property var weather: null        // Weather.parseCitypage output, or null
  property string statusText: ""    // centered note while weather is null
  property bool stale: false        // fetch failed; showing cached data
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  implicitWidth: Style.space(400)
  implicitHeight: column.implicitHeight

  readonly property var current: weather ? weather.current : null
  readonly property var nextForecast:
    weather && weather.forecasts.length > 0 ? weather.forecasts[0] : null

  // Forecast periods alternate day / "<day> night" (the first may be a lone
  // "Tonight"). Fold them into one cell per day for the week row.
  readonly property var days: {
    if (!weather) return []
    var out = []
    var fs = weather.forecasts || []
    for (var i = 0; i < fs.length; i++) {
      var f = fs[i]
      var p = String(f.period || "")
      var isNight = p === "Tonight" || /\bnight$/i.test(p)
      var base = p === "Tonight" ? "Today" : p.replace(/\s+night$/i, "")
      var cur = out.length > 0 ? out[out.length - 1] : null
      if (isNight && cur && cur.name === base) cur.night = f
      else out.push({ name: base, day: isNight ? null : f, night: isNight ? f : null })
    }
    return out.slice(0, 8)
  }

  function dayLabel(d) { return d.name === "Today" ? "Today" : d.name.slice(0, 3) }

  function dayTooltip(d) {
    var parts = []
    if (d.day && d.day.textSummary) parts.push(d.name + ": " + d.day.textSummary)
    if (d.night && d.night.textSummary)
      parts.push((d.name === "Today" ? "Tonight" : d.name + " night") + ": " + d.night.textSummary)
    return parts.join("\n\n")
  }

  function fmtTemp(v) {
    return (v === null || v === undefined) ? "—" : Math.round(Number(v)) + "°"
  }

  readonly property string currentDetails: {
    if (!current) return ""
    var bits = []
    // Observed humidex/wind chill only — EC omits them when they wouldn't
    // differ meaningfully from the plain temperature.
    var feels = current.humidex !== null ? current.humidex : current.windChill
    if (feels !== null && feels !== undefined) bits.push("Feels " + Math.round(feels) + "°")
    if (current.humidity !== null) bits.push("Humidity " + current.humidity + "%")
    if (current.wind && current.wind.speed !== null)
      bits.push("Wind " + (current.wind.direction ? current.wind.direction + " " : "")
        + Math.round(current.wind.speed) + " km/h"
        + (current.wind.gust !== null ? " gust " + Math.round(current.wind.gust) : ""))
    return bits.join(" · ")
  }

  readonly property string footerLine: {
    if (!weather) return ""
    var bits = []
    if (stale) bits.push("Offline — cached")
    if (weather.issuedAt) bits.push("Issued " + Qt.formatTime(new Date(weather.issuedAt), "h:mm ap"))
    if (weather.sunrise) bits.push("Sunrise " + Qt.formatTime(new Date(weather.sunrise), "h:mm ap"))
    if (weather.sunset) bits.push("Sunset " + Qt.formatTime(new Date(weather.sunset), "h:mm ap"))
    return bits.join(" · ")
  }

  // Empty / loading / failed state, centered in whatever height the panel
  // gave the pane.
  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: !root.weather
    text: root.statusText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  ColumnLayout {
    id: column
    anchors.fill: parent
    visible: !!root.weather
    spacing: Style.space(14)

    // ---- Active alerts, most-salient first: all events share one row,
    // each bar an equal slice (advisory text is short), tinted by EC's
    // alert colour level (red/orange/yellow; grey and unknown render muted).
    RowLayout {
      Layout.fillWidth: true
      visible: !!root.weather && root.weather.warnings.length > 0
      spacing: Style.space(8)

      Repeater {
        model: root.weather ? root.weather.warnings : []

        Rectangle {
          id: warningBar
          required property var modelData
          readonly property color tint: {
            var c = Weather.warningColour(modelData)
            return c ? c : root.dim
          }

          Layout.fillWidth: true
          Layout.preferredWidth: 1
          implicitHeight: warningText.implicitHeight + Style.space(10)
          radius: Style.cornerRadius
          color: Qt.alpha(warningBar.tint, 0.14)
          border.width: 1
          border.color: warningBar.tint

          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              id: warningGlyph
              text: "󰀦"
              color: warningBar.tint
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              id: warningText
              width: parent.width - warningGlyph.width - parent.spacing
              elide: Text.ElideRight
              text: warningBar.modelData.description || ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }

    // ---- Current conditions.
    Row {
      visible: !!root.current && (root.current.temperature !== null || root.current.condition !== null)
      spacing: Style.space(12)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.current ? Weather.iconGlyph(root.current.iconCode) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.current ? root.fmtTemp(root.current.temperature) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.displayLarge
        font.bold: true
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
          textFormat: Text.PlainText
          text: root.current && root.current.condition !== null ? root.current.condition : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Text {
          textFormat: Text.PlainText
          text: root.currentDetails
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    // ---- The next forecast period, in Environment Canada's own words.
    Column {
      Layout.fillWidth: true
      visible: !!root.nextForecast
      spacing: Style.spacing.xxs

      Text {
        textFormat: Text.PlainText
        text: root.nextForecast ? String(root.nextForecast.period || "").toUpperCase() : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.nextForecast ? (root.nextForecast.textSummary || root.nextForecast.summary || "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
        maximumLineCount: 6
        elide: Text.ElideRight
      }
    }

    Item { Layout.fillHeight: true }

    // ---- Hourly strip, horizontally scrollable (drag or wheel).
    Column {
      Layout.fillWidth: true
      visible: !!root.weather && root.weather.hourly.length > 0
      spacing: Style.spacing.sm

      Text {
        textFormat: Text.PlainText
        text: "NEXT 24 HOURS"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }

      Item {
        width: parent.width
        height: hourlyRow.implicitHeight

        Flickable {
          id: hourlyFlick
          anchors.fill: parent
          contentWidth: hourlyRow.implicitWidth
          contentHeight: height
          flickableDirection: Flickable.HorizontalFlick
          interactive: contentWidth > width
          clip: true

          Row {
            id: hourlyRow
            spacing: Style.space(8)

            Repeater {
              model: root.weather ? root.weather.hourly : []

              Column {
                required property var modelData
                width: Style.space(56)
                spacing: Style.spacing.xxs

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: Qt.formatTime(new Date(modelData.at), "h ap")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: Weather.iconGlyph(modelData.iconCode)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.iconLarge
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: root.fmtTemp(modelData.temperature)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  // A space, not "", so every cell keeps the same height.
                  text: modelData.lop !== null && modelData.lop > 0 ? Math.round(modelData.lop) + "%" : " "
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // WheelHandler misses trackpad wheels on this build; a MouseArea
        // that only takes wheel events routes them (either axis) to the
        // strip and leaves clicks alone.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.NoButton
          onWheel: function(wheel) {
            var d = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : wheel.angleDelta.y
            hourlyFlick.contentX = Math.max(0,
              Math.min(hourlyFlick.contentWidth - hourlyFlick.width, hourlyFlick.contentX - d))
            wheel.accepted = true
          }
        }
      }
    }

    Item { Layout.fillHeight: true }

    // ---- The week ahead. Hover a day for the full textual forecast.
    Column {
      Layout.fillWidth: true
      visible: root.days.length > 0
      spacing: Style.spacing.sm

      Text {
        textFormat: Text.PlainText
        text: "WEEK AHEAD"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }

      Row {
        id: weekRow
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.days

          Item {
            id: dayCell
            required property var modelData
            width: (weekRow.width - weekRow.spacing * (root.days.length - 1)) / Math.max(1, root.days.length)
            height: dayColumn.implicitHeight

            Column {
              id: dayColumn
              width: parent.width
              spacing: Style.spacing.xxs

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.dayLabel(dayCell.modelData).toUpperCase()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: {
                  var f = dayCell.modelData.day || dayCell.modelData.night
                  return f ? Weather.iconGlyph(f.iconCode) : ""
                }
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: dayCell.modelData.day && dayCell.modelData.day.temperature
                  ? root.fmtTemp(dayCell.modelData.day.temperature.value) : " "
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: dayCell.modelData.night && dayCell.modelData.night.temperature
                  ? root.fmtTemp(dayCell.modelData.night.temperature.value) : " "
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              id: dayHover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
            }

            PanelToolTip {
              id: dayTip
              visible: dayHover.containsMouse && text !== ""
              text: root.dayTooltip(dayCell.modelData)
              fontFamily: root.fontFamily
              // The stock contentItem is single-line; a forecast is a
              // paragraph, so wrap it at a fixed width instead.
              contentWidth: Style.space(300)
              contentItem: Text {
                textFormat: Text.PlainText
                text: dayTip.text
                color: dayTip.panelForeground
                font.family: dayTip.fontFamily
                font.pixelSize: dayTip.fontSize
                wrapMode: Text.WordWrap
                leftPadding: Border.left(dayTip.panelBorderSpec) + Style.spacing.controlPaddingX
                rightPadding: Border.right(dayTip.panelBorderSpec) + Style.spacing.controlPaddingX
                topPadding: Border.top(dayTip.panelBorderSpec) + Style.spacing.controlPaddingY
                bottomPadding: Border.bottom(dayTip.panelBorderSpec) + Style.spacing.controlPaddingY
              }
            }
          }
        }
      }
    }

    Item { Layout.fillHeight: true }

    // ---- Issue time and sun times.
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: root.footerLine !== ""
      elide: Text.ElideRight
      text: root.footerLine
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
