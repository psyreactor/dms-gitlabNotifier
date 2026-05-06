import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "gitlabNotifier"

    StyledText {
        width: parent.width
        text: "GitLab Notifier"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Shows a badge with Issues / MRs / Incidents assigned to the authenticated glab user."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
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
        description: "Refresh interval (in seconds)."
        defaultValue: 60
        minimum: 15
        maximum: 3600
        unit: "sec"
        leftIcon: "schedule"
    }

    Rectangle {
        width: parent.width
        height: visibilityGroup.implicitHeight + Theme.spacingM * 2
        color: Theme.surfaceContainer
        radius: Theme.cornerRadius
        border.color: Theme.outline
        border.width: 1
        opacity: 0.8

        Column {
            id: visibilityGroup
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            Row {
                width: parent.width
                spacing: Theme.spacingM
                DankIcon { name: "bug_report"; size: 22; anchors.verticalCenter: parent.verticalCenter; opacity: 0.8 }
                SelectionSetting {
                    width: parent.width - 22 - Theme.spacingM
                    settingKey: "showIssues"
                    label: "Issues"
                    description: "Include issues assigned to your user."
                    options: [
                        {label: "Visible", value: "true"},
                        {label: "Hidden", value: "false"}
                    ]
                    defaultValue: "true"
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingM
                DankIcon { name: "merge_type"; size: 22; anchors.verticalCenter: parent.verticalCenter; opacity: 0.8 }
                SelectionSetting {
                    width: parent.width - 22 - Theme.spacingM
                    settingKey: "showMRs"
                    label: "Merge Requests"
                    description: "Include merge requests assigned to your user."
                    options: [
                        {label: "Visible", value: "true"},
                        {label: "Hidden", value: "false"}
                    ]
                    defaultValue: "true"
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingM
                DankIcon { name: "warning"; size: 22; anchors.verticalCenter: parent.verticalCenter; opacity: 0.8 }
                SelectionSetting {
                    width: parent.width - 22 - Theme.spacingM
                    settingKey: "showIncidents"
                    label: "Incidents"
                    description: "Include incidents assigned to your user (if supported by glab)."
                    options: [
                        {label: "Visible", value: "true"},
                        {label: "Hidden", value: "false"}
                    ]
                    defaultValue: "true"
                }
            }
        }
    }
}

