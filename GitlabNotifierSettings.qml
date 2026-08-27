import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "gitlabNotifier"

    // Section header: icon, title and a one-line explanation of the group.
    component GroupHeader: RowLayout {
        property string iconName: ""
        property string title: ""
        property string subtitle: ""

        width: parent.width
        spacing: Theme.spacingM

        DankIcon {
            name: iconName
            size: 22
            color: Theme.primary
            Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            StyledText {
                text: title
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                Layout.fillWidth: true
            }

            StyledText {
                text: subtitle
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }
        }
    }

    // Card wrapper matching the popout's cards.
    component SettingsGroup: StyledRect {
        default property alias content: groupCol.data

        width: parent.width
        height: Math.max(0, groupCol.implicitHeight + Theme.spacingM * 2)
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
        border.width: 1
        border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.15)

        Column {
            id: groupCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingL
        }
    }

    Column {
        width: parent.width
        spacing: Theme.spacingL

        SettingsGroup {
            GroupHeader {
                iconName: "workspaces"
                title: "Scope"
                subtitle: "Where to look for your assigned work. Group takes precedence over Repo."
            }

            StringSetting {
                settingKey: "group"
                label: "Group"
                description: "E.g.: myGroup or myOrg/myGroup. When set, --group is used and Repo is ignored."
                placeholder: "group"
                defaultValue: ""
            }

            StringSetting {
                settingKey: "repo"
                label: "Repo (group/project)"
                description: "E.g.: myGroup/myRepo. Used with --repo when Group is not configured."
                placeholder: "group/project"
                defaultValue: ""
            }
        }

        SettingsGroup {
            GroupHeader {
                iconName: "terminal"
                title: "GitLab CLI"
                subtitle: "The glab executable and the instance its links point at. Requires glab authenticated."
            }

            StringSetting {
                settingKey: "glabBinary"
                label: "glab binary"
                description: "Binary name or path to the glab executable (default: glab)."
                placeholder: "glab"
                defaultValue: "glab"
            }

            StringSetting {
                settingKey: "gitlabWebUrl"
                label: "GitLab Web URL"
                description: "Base URL to open links in the browser (default: https://gitlab.com)."
                placeholder: "https://gitlab.com"
                defaultValue: "https://gitlab.com"
            }

            SliderSetting {
                settingKey: "refreshInterval"
                label: "Refresh Interval"
                description: "Frequency of GitLab data background updates in seconds (minimum: 15s)."
                defaultValue: 60
                minimum: 15
                maximum: 3600
                unit: "sec"
                leftIcon: "schedule"
            }
        }

        SettingsGroup {
            GroupHeader {
                iconName: "visibility"
                title: "Categories"
                subtitle: "Which sections appear in the popout and count towards the bar badge."
            }

            ToggleSetting {
                settingKey: "showIssues"
                label: "Show Issues"
                description: "Include issues assigned to your user."
                defaultValue: true
            }

            ToggleSetting {
                settingKey: "showMRs"
                label: "Show Merge Requests"
                description: "Include merge requests assigned to your user."
                defaultValue: true
            }

            ToggleSetting {
                settingKey: "showIncidents"
                label: "Show Incidents"
                description: "Include incidents assigned to your user, when glab supports them."
                defaultValue: true
            }
        }

        SettingsGroup {
            GroupHeader {
                iconName: "schedule"
                title: "Display"
                subtitle: "How timestamps are rendered in the popout header."
            }

            SelectionSetting {
                settingKey: "timeFormat"
                label: "Time Format"
                description: "Choose time format for the last-updated indicator."
                options: [
                    {label: "System Default", value: "system"},
                    {label: "12-Hour", value: "12h"},
                    {label: "24-Hour", value: "24h"}
                ]
                defaultValue: "system"
            }
        }
    }
}
