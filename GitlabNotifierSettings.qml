import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "./translations.js" as L

PluginSettings {
    id: root
    pluginId: "gitlabNotifier"

    readonly property string lang: L.resolve(languageSetting.value, SessionData.locale || Qt.locale().name)

    function tr(key) {
        return L.tr(root.lang, key);
    }

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
                title: root.tr("scopeTitle")
                subtitle: root.tr("scopeDesc")
            }

            StringSetting {
                settingKey: "group"
                label: root.tr("groupLabel")
                description: root.tr("groupDesc")
                placeholder: "group"
                defaultValue: ""
            }

            StringSetting {
                settingKey: "repo"
                label: root.tr("repoLabel")
                description: root.tr("repoDesc")
                placeholder: "group/project"
                defaultValue: ""
            }
        }

        SettingsGroup {
            GroupHeader {
                iconName: "terminal"
                title: root.tr("cliTitle")
                subtitle: root.tr("cliDesc")
            }

            StringSetting {
                settingKey: "glabBinary"
                label: root.tr("glabLabel")
                description: root.tr("glabDesc")
                placeholder: "glab"
                defaultValue: "glab"
            }

            StringSetting {
                settingKey: "gitlabWebUrl"
                label: root.tr("webUrlLabel")
                description: root.tr("webUrlDesc")
                placeholder: "https://gitlab.com"
                defaultValue: "https://gitlab.com"
            }

            SliderSetting {
                settingKey: "refreshInterval"
                label: root.tr("intervalLabel")
                description: root.tr("intervalDesc")
                defaultValue: 60
                minimum: 15
                maximum: 3600
                unit: root.tr("unitSec")
                leftIcon: "schedule"
            }
        }

        SettingsGroup {
            GroupHeader {
                iconName: "visibility"
                title: root.tr("categoriesTitle")
                subtitle: root.tr("categoriesDesc")
            }

            ToggleSetting {
                settingKey: "showIssues"
                label: root.tr("showIssuesLabel")
                description: root.tr("showIssuesDesc")
                defaultValue: true
            }

            ToggleSetting {
                settingKey: "showMRs"
                label: root.tr("showMRsLabel")
                description: root.tr("showMRsDesc")
                defaultValue: true
            }

            ToggleSetting {
                settingKey: "showIncidents"
                label: root.tr("showIncidentsLabel")
                description: root.tr("showIncidentsDesc")
                defaultValue: true
            }
        }

        SettingsGroup {
            GroupHeader {
                iconName: "schedule"
                title: root.tr("displayTitle")
                subtitle: root.tr("displayDesc")
            }

            SelectionSetting {
                settingKey: "timeFormat"
                label: root.tr("timeFormatLabel")
                description: root.tr("timeFormatDesc")
                options: [
                    {label: root.tr("systemDefault"), value: "system"},
                    {label: root.tr("hour12"), value: "12h"},
                    {label: root.tr("hour24"), value: "24h"}
                ]
                defaultValue: "system"
            }
        }

        SettingsGroup {
            GroupHeader {
                iconName: "translate"
                title: root.tr("languageTitle")
                subtitle: root.tr("languageDesc")
            }

            SelectionSetting {
                id: languageSetting
                settingKey: "language"
                label: root.tr("languageLabel")
                description: root.tr("languageHint")
                options: [{label: root.tr("languageAuto"), value: "auto"}].concat(L.languages)
                defaultValue: "auto"
            }
        }
    }
}
