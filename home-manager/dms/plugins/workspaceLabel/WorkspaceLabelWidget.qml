import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "workspace-label"

    // pluginData.labelMap: { "term-left": "Terminal", ... }
    // Niri requires unique workspace names, but each bar is per-monitor and
    // only ever shows one (its own active workspace) — so the same display
    // string is fine for term-left and term-right.
    readonly property var labelMap: pluginData?.labelMap ?? ({})

    // The active (visible) workspace on this bar's monitor.
    readonly property var activeWorkspace: {
        const screenName = parentScreen?.name ?? "";
        if (!screenName)
            return null;
        const list = NiriService.allWorkspaces ?? [];
        for (var i = 0; i < list.length; i++) {
            const w = list[i];
            if (w && w.output === screenName && w.is_active)
                return w;
        }
        return null;
    }

    readonly property string displayText: {
        if (!activeWorkspace)
            return "";
        const name = activeWorkspace.name ?? "";
        if (name && labelMap && labelMap[name] !== undefined)
            return labelMap[name];
        if (name)
            return name;
        // Unnamed (the trailing empty workspace niri auto-creates): show idx.
        return String(activeWorkspace.idx ?? 0);
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: pill.implicitWidth
            implicitHeight: pill.implicitHeight

            Rectangle {
                id: pill
                anchors.centerIn: parent
                radius: height / 2
                color: Theme.primary
                implicitWidth: label.implicitWidth + Theme.spacingM * 2
                implicitHeight: label.implicitHeight + Theme.spacingXS * 2

                StyledText {
                    id: label
                    anchors.centerIn: parent
                    text: root.displayText
                    color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.95)
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    font.weight: Font.DemiBold
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: pillV.implicitWidth
            implicitHeight: pillV.implicitHeight

            Rectangle {
                id: pillV
                anchors.centerIn: parent
                radius: width / 2
                color: Theme.primary
                implicitWidth: labelV.implicitWidth + Theme.spacingXS * 2
                implicitHeight: labelV.implicitHeight + Theme.spacingS * 2

                StyledText {
                    id: labelV
                    anchors.centerIn: parent
                    // Vertical bars: first character only (matches DMS convention).
                    text: (root.displayText ?? "").charAt(0)
                    color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.95)
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    font.weight: Font.DemiBold
                }
            }
        }
    }
}
