import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Model.js" as Model

// City search popup, opened from the "+" tab chip. The guts follow
// qs.Ui.SearchableDropdown (autofocused filter field over a virtualized
// ListView, same key contract), rebuilt standalone because that component
// bakes in its own trigger and sizes the popup to it, neither of which
// fits a chip-sized "+" button.
//
// Beyond search-and-pick, the list doubles as the location manager: every
// row carries a star. Starred rows are the configured cities; clicking
// the star (or pressing `s` on the cursor row) toggles membership without
// closing the popup, while activating the row body adds-and-switches.
// Ordering is frozen when the popup opens — starred cities first — so
// toggling a star flips the glyph without yanking the row elsewhere.
QQC.Popup {
  id: root

  // Full parsed site list and a { siteCode: true } map of configured cities.
  property var sites: []
  property var addedCodes: ({})

  // Note: not named `background` — that would shadow QQC.Popup's own
  // background item and break the assignment below.
  property color foreground: Color.popups.text
  property color surfaceColor: Color.popups.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)

  // choose: activate this city (adding it first if needed) and close.
  // toggleStar: add/remove this city, popup stays open.
  signal choose(var site)
  signal toggleStar(var site)

  // Membership-at-open snapshot ordering: starred first, then the rest in
  // the site list's own (alphabetical) order.
  property var baseList: []
  property var filtered: []

  function recomputeBase() {
    var starred = []
    var rest = []
    for (var i = 0; i < sites.length; i++) {
      if (addedCodes[sites[i].siteCode]) starred.push(sites[i])
      else rest.push(sites[i])
    }
    baseList = starred.concat(rest)
  }

  function recomputeFiltered() {
    filtered = Model.filterSites(baseList, searchField.text)
  }

  padding: Style.spacing.hairline
  leftPadding: Border.left(popupBorderSpec) + Style.spacing.hairline
  rightPadding: Border.right(popupBorderSpec) + Style.spacing.hairline
  topPadding: Border.top(popupBorderSpec) + Style.spacing.hairline
  bottomPadding: Border.bottom(popupBorderSpec) + Style.spacing.hairline
  focus: true

  background: BorderSurface {
    color: root.surfaceColor
    borderSpec: root.popupBorderSpec
    radius: Style.cornerRadius
  }

  onOpened: {
    searchField.text = ""
    recomputeBase()
    recomputeFiltered()
    resultList.currentIndex = -1
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }
  onClosed: searchField.text = ""

  contentItem: Column {
    spacing: 0

    Item {
      id: searchHeader
      width: parent.width
      height: Style.spacing.popupRowHeight + Style.spacing.controlPaddingX

      TextField {
        id: searchField
        anchors.fill: parent
        anchors.margins: Style.spacing.md
        placeholderText: "Search cities…"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body

        onTextChanged: {
          root.recomputeFiltered()
          if (resultList.count > 0) resultList.currentIndex = 0
        }

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close(); event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            if (resultList.count > 0) {
              resultList.currentIndex = 0
              resultList.forceActiveFocus()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (resultList.count > 0) {
              resultList.currentIndex = 0
              resultList.selectCurrent()
            }
            event.accepted = true
          }
        }
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Util.alpha(root.foreground, 0.10)
    }

    Item {
      width: parent.width
      height: root.height - root.topPadding - root.bottomPadding - searchHeader.height - 1

      Text {
        anchors.centerIn: parent
        visible: resultList.count === 0
        text: "No matches"
        color: Qt.darker(root.foreground, 1.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      ListView {
        id: resultList
        anchors.fill: parent
        spacing: Style.spacing.labelGap
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.filtered
        currentIndex: -1
        keyNavigationEnabled: false

        function selectCurrent() {
          if (currentIndex < 0 || currentIndex >= root.filtered.length) return
          root.choose(root.filtered[currentIndex])
          root.close()
        }

        function starCurrent() {
          if (currentIndex < 0 || currentIndex >= root.filtered.length) return
          root.toggleStar(root.filtered[currentIndex])
        }

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close(); event.accepted = true
          } else if (event.key === Qt.Key_Down || event.text === "j") {
            if (resultList.currentIndex < resultList.count - 1)
              resultList.currentIndex = resultList.currentIndex + 1
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.text === "k") {
            if (resultList.currentIndex <= 0) searchField.forceActiveFocus()
            else resultList.currentIndex = resultList.currentIndex - 1
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            resultList.selectCurrent(); event.accepted = true
          } else if (event.text === "s" || event.text === "S") {
            resultList.starCurrent(); event.accepted = true
          }
        }

        delegate: Rectangle {
          required property var modelData
          required property int index
          width: resultList.width
          height: Math.max(Style.spacing.popupRowHeight, rowContent.implicitHeight + Style.spacing.rowPaddingX)
          color: index === resultList.currentIndex
            ? Style.hoverFillFor(root.foreground, root.accent)
            : "transparent"

          readonly property bool starred: root.addedCodes[modelData.siteCode] === true

          Row {
            id: rowContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            spacing: Style.spacing.controlGap

            // Star column: the add/remove affordance.
            Text {
              id: star
              anchors.verticalCenter: parent.verticalCenter
              text: starred ? "󰓎" : "󰓒" // nf-md-star / nf-md-star_outline
              color: starred ? root.accent : Qt.darker(root.foreground, 1.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.spacing.xxs
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleStar(modelData)
              }
            }

            Column {
              width: parent.width - star.width - parent.spacing
              spacing: Style.spacing.xxs

              Text {
                text: modelData.name
                color: index === resultList.currentIndex ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                text: modelData.province + " · " + modelData.latitude.toFixed(2) + ", " + modelData.longitude.toFixed(2)
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            z: -1
            onPositionChanged: resultList.currentIndex = parent.index
            onClicked: {
              resultList.currentIndex = parent.index
              resultList.selectCurrent()
            }
          }
        }
      }
    }
  }
}
