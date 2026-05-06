import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "gitlab-notifier"

    // Settings
    property string group: pluginData.group || ""
    property string repo: pluginData.repo || ""
    property string glabBinary: pluginData.glabBinary || "glab"
    property string gitlabWebUrl: pluginData.gitlabWebUrl || "https://gitlab.com"
    property int refreshInterval: pluginData.refreshInterval || 60 // seconds

    // Font Awesome icon config (GitLab brand icon)
    property string faGitlabGlyph: "\uf296" // Font Awesome GitLab (brands)
    property string faFamily: "Font Awesome 6 Brands, Font Awesome 5 Brands, Font Awesome 6 Free, Font Awesome 5 Free"
    function asBool(v, defaultValue) {
        if (v === undefined || v === null)
            return defaultValue;
        if (typeof v === "boolean")
            return v;
        if (typeof v === "string")
            return v.toLowerCase() === "true";
        return !!v;
    }

    property bool showIssues: asBool(pluginData.showIssues, true)
    property bool showMRs: asBool(pluginData.showMRs, true)
    property bool showIncidents: asBool(pluginData.showIncidents, true)
    property string username: ""

    // State
    property bool loading: false
    property string lastError: ""
    property string lastUpdate: ""
    property bool glabOk: true
    property bool authOk: true
    property bool incidentsSupported: true

    property int issuesCount: 0
    property int mrsCount: 0
    property int incidentsCount: 0
    property var mrsList: []
    property var issuesList: []
    property var incidentsList: []

    readonly property int totalCount: (showIssues ? issuesCount : 0) + (showMRs ? mrsCount : 0) + (showIncidents ? incidentsCount : 0)

    Timer {
        interval: root.refreshInterval * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    onGroupChanged: refresh()
    onRepoChanged: refresh()
    onGlabBinaryChanged: refresh()
    onShowIssuesChanged: refresh()
    onShowMRsChanged: refresh()
    onShowIncidentsChanged: refresh()

    function normalizeBaseUrl(url) {
        if (!url) return "https://gitlab.com";
        return url.replace(/\/+$/, "");
    }

    function scopeWebBase() {
        const base = normalizeBaseUrl(root.gitlabWebUrl);
        const g = (root.group || "").trim();
        const r = (root.repo || "").trim();
        if (g)
            return base + "/groups/" + g;
        if (r)
            return base + "/" + r;
        return base;
    }

    function profileWebUrl() {
        if (root.username)
            return normalizeBaseUrl(root.gitlabWebUrl) + "/" + root.username;
        return normalizeBaseUrl(root.gitlabWebUrl);
    }

    function openUrl(url) {
        if (!url) return;
        Quickshell.execDetached(["xdg-open", url]);
        root.closePopout();
    }

    function openSettings() {
        Quickshell.execDetached(["dms", "ipc", "call", "settings", "openWith", "plugins"]);
        root.closePopout();
    }

    function setError(msg) {
        root.lastError = msg || "";
    }

    function refresh() {
        root.loading = true;
        root.setError("");
        root.glabOk = true;
        root.authOk = true;
        const hasGroup = root.group && root.group.trim().length > 0;
        const hasRepo = root.repo && root.repo.trim().length > 0;

        if (!hasGroup && !hasRepo) {
            root.loading = false;
            root.setError("Configure a Group or Repo in settings.");
            root.issuesCount = 0;
            root.mrsCount = 0;
            root.incidentsCount = 0;
            root.mrsList = [];
            root.issuesList = [];
            root.incidentsList = [];
            return;
        }

        // 1) Check glab
            Proc.runCommand("gitlabNotifier.glabVersion", [root.glabBinary, "--version"], (stdout, exitCode) => {
            if (exitCode !== 0) {
                root.glabOk = false;
                root.authOk = false;
                root.incidentsSupported = false;
                root.loading = false;
                root.issuesCount = 0;
                root.mrsCount = 0;
                root.incidentsCount = 0;
                root.mrsList = [];
                root.issuesList = [];
                root.incidentsList = [];
                root.setError("Could not execute glab. Is it installed and in PATH?");
                return;
            }

            // 2) Check auth
            Proc.runCommand("gitlabNotifier.authStatus", [root.glabBinary, "auth", "status"], (authOut, authExit) => {
                if (authExit !== 0) {
                    root.authOk = false;
                    root.incidentsSupported = false;
                    root.loading = false;
                    root.issuesCount = 0;
                    root.mrsCount = 0;
                    root.incidentsCount = 0;
                    root.mrsList = [];
                    root.issuesList = [];
                    root.setError("glab is not authenticated. Run: glab auth login");
                    return;
                }

                // 3) Check incidents support (only if enabled)
                if (root.showIncidents) {
                    Proc.runCommand("gitlabNotifier.incidentHelp", [root.glabBinary, "incident", "--help"], (helpOut, helpExit) => {
                        root.incidentsSupported = helpExit === 0;
                        root.loadUsername(root.fetchCounts);
                    }, 200);
                } else {
                    root.incidentsSupported = true;
                    root.loadUsername(root.fetchCounts);
                }
            }, 400);
        }, 300);
    }

    function loadUsername(cb) {
        Proc.runCommand("gitlabNotifier.getUser", [root.glabBinary, "api", "user", "--output", "json"], (stdout, exitCode) => {
            if (exitCode === 0 && stdout) {
                try {
                    const data = JSON.parse(stdout.trim());
                    if (data && (data.username || data.login)) {
                        root.username = data.username || data.login || "";
                    } else {
                        root.username = "";
                    }
                } catch (e) {
                    root.username = "";
                }
            } else {
                root.username = "";
            }
            if (typeof cb === "function") Qt.callLater(cb);
        }, 2000);
    }

    function parseJsonArray(stdout) {
        const raw = (stdout || "").trim();
        if (!raw) return [];
        try {
            const data = JSON.parse(raw);
            if (Array.isArray(data)) return data;
            if (Array.isArray(data.items)) return data.items;
            if (Array.isArray(data.data)) return data.data;
        } catch(e) {}
        try {
            const lines = raw.split(/\r?\n/).map(s => s.trim()).filter(s => s.length > 0);
            const items = [];
            for (let i = 0; i < lines.length; i++) {
                try {
                    const obj = JSON.parse(lines[i]);
                    if (obj !== null && typeof obj === "object") items.push(obj);
                } catch(e) {}
            }
            if (items.length > 0) return items;
        } catch(e) {}
        return [];
    }

    function fetchCounts() {
        const r = (root.repo || "").trim();
        const g = (root.group || "").trim();
        const useGroup = g.length > 0;

        function scopeArgs() {
            return useGroup ? ["--group", g] : ["--repo", r];
        }

        const nextAfterIssues = () => {
            if (!root.showMRs) return nextAfterMrs();
            Proc.runCommand(
                        "gitlabNotifier.mrList",
                        [root.glabBinary, "mr", "list"].concat(scopeArgs()).concat(["--assignee=@me", "--output", "json"]),
                        (stdout, exitCode) => {
                if (exitCode === 0) {
                    const list = parseJsonArray(stdout);
                    root.mrsList = list;
                    root.mrsCount = list.length;
                } else {
                    root.mrsList = [];
                }
                nextAfterMrs();
            }, 500);
        };

        const nextAfterMrs = () => {
            if (!root.showIncidents) return finish();
            if (!root.incidentsSupported) {
                root.incidentsCount = 0;
                return finish();
            }
            Proc.runCommand(
                        "gitlabNotifier.incidentList",
                        [root.glabBinary, "incident", "list"].concat(scopeArgs()).concat(["--assignee=@me","--output", "json"]),
                        (stdout, exitCode) => {
                if (exitCode === 0) {
                    const list = parseJsonArray(stdout);
                    root.incidentsList = list;
                    root.incidentsCount = list.length;
                } else {
                    root.incidentsList = [];
                    root.incidentsCount = 0;
                }
                finish();
            }, 500);
        };

        const finish = () => {
            root.loading = false;
            root.lastUpdate = new Date().toLocaleTimeString();
            if (!root.incidentsSupported && root.showIncidents) {
                root.setError("Your glab version does not support incidents.");
            } else {
                if (root.lastError && root.lastError.indexOf("Configura el repo") === 0) {
                    // no-op
                }
            }
        };

        if (root.showIssues) {
            Proc.runCommand(
                        "gitlabNotifier.issueList",
                        [root.glabBinary, "issue", "list"].concat(scopeArgs()).concat(["--assignee=@me", "--output", "json"]),
                        (stdout, exitCode) => {
                if (exitCode === 0) {
                    const list = parseJsonArray(stdout);
                    root.issuesList = list;
                    root.issuesCount = list.length;
                } else {
                    root.issuesList = [];
                }
                nextAfterIssues();
            }, 500);
        } else {
            nextAfterIssues();
        }
    }

    component Badge: StyledRect {
        property int value: 0
        property string label: ""
        property color badgeColor: Theme.primary

        height: 18
        width: Math.max(22, badgeText.implicitWidth + Theme.spacingS)
        radius: 9
        color: Qt.rgba(badgeColor.r, badgeColor.g, badgeColor.b, 0.18)
        border.width: 1
        border.color: Qt.rgba(badgeColor.r, badgeColor.g, badgeColor.b, 0.35)

        StyledText {
            id: badgeText
            anchors.centerIn: parent
            text: label.length ? (label + ":" + value) : value.toString()
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: badgeColor
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            StyledText {
                text: root.faGitlabGlyph
                font.family: root.faFamily
                font.pixelSize: Theme.iconSize - 7
                color: root.lastError ? Theme.error : (root.totalCount > 0 ? Theme.primary : (Theme.widgetIconColor || Theme.surfaceText))
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                id: barCount
                text: root.totalCount > 0 ? root.totalCount.toString() : ""
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: root.lastError ? Theme.error : Theme.primary
                anchors.verticalCenter: parent.verticalCenter
                visible: root.totalCount > 0
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2
            StyledText {
                text: root.faGitlabGlyph
                font.family: root.faFamily
                font.pixelSize: 20
                color: root.lastError ? Theme.error : (root.totalCount > 0 ? Theme.primary : (Theme.widgetIconColor || Theme.surfaceText))
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.totalCount.toString()
                color: root.lastError ? Theme.error : Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    component StatRow: Item {
        property string title: ""
        property string iconName: ""
        property int count: 0
        property string openUrl: ""
        property color accentColor: Theme.primary

        width: parent.width
        height: 40

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            Rectangle {
                width: 4
                height: 22
                radius: 2
                color: accentColor
                anchors.verticalCenter: parent.verticalCenter
            }

            DankIcon {
                name: iconName
                size: 20
                color: accentColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: title
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
                width: badgeText.width + 14
                height: 20
                radius: 10
                color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.15)
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    id: badgeText
                    text: count.toString()
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: accentColor
                    anchors.centerIn: parent
                }
            }
        }

        // Action button (View All)
        Item {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: actionBtnRow.width + Theme.spacingM * 2
            height: 30
            visible: openUrl.length > 0 && count > 0
            scale: actionBtnArea.pressed ? 0.95 : (actionBtnArea.containsMouse ? 1.05 : 1.0)
            Behavior on scale { NumberAnimation { duration: 100 } }

            MouseArea {
                id: actionBtnArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: mouse => actionRipple.trigger(mouse.x, mouse.y)
                onClicked: root.openUrl(openUrl)
            }

            Row {
                id: actionBtnRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    id: actionIcon
                    name: "open_in_new"
                    size: 14
                    color: actionBtnArea.containsMouse ? "white" : accentColor
                    anchors.verticalCenter: parent.verticalCenter

                    SequentialAnimation {
                        running: actionBtnArea.containsMouse
                        loops: Animation.Infinite
                        onStopped: actionIcon.rotation = 0
                        NumberAnimation { target: actionIcon; property: "rotation"; from: 0; to: 10; duration: 50; easing.type: Easing.InOutQuad }
                        NumberAnimation { target: actionIcon; property: "rotation"; from: 10; to: -10; duration: 100; easing.type: Easing.InOutQuad }
                        NumberAnimation { target: actionIcon; property: "rotation"; from: -10; to: 0; duration: 50; easing.type: Easing.InOutQuad }
                    }
                }

                StyledText {
                    text: "View All"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: actionBtnArea.containsMouse ? "white" : accentColor
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            DankRipple {
                id: actionRipple
                rippleColor: actionBtnArea.containsMouse ? "white" : accentColor
                cornerRadius: Theme.cornerRadius
                anchors.fill: parent
            }
        }
    }

    component GitLabIncidentItem: Item {
        property var incidentData: null
        property color accentColor: Theme.primary

        width: ListView.view.width
        height: 40

        scale: incidentItemArea.pressed ? 0.98 : 1.0
        Behavior on scale { NumberAnimation { duration: 100 } }

        MouseArea {
            id: incidentItemArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPressed: mouse => incidentItemRipple.trigger(mouse.x, mouse.y)
            onClicked: root.openUrl(incidentData.web_url)
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Theme.cornerRadius
            color: incidentItemArea.containsMouse ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.08) : "transparent"
        }

        DankRipple { id: incidentItemRipple; rippleColor: accentColor; cornerRadius: Theme.cornerRadius }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            DankIcon {
                name: "subdirectory_arrow_right"
                size: 14
                color: accentColor
                opacity: 0.6
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                width: parent.width - 20
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    width: parent.width
                    text: incidentData ? incidentData.title : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    text: incidentData ? ((incidentData.references && incidentData.references.full) || ("#" + incidentData.iid)) : ""
                    font.pixelSize: Theme.fontSizeSmall - 2
                    color: Theme.surfaceVariantText
                    opacity: 0.8
                }
            }
        }
    }

    component GitLabIssueItem: Item {
        property var issueData: null
        property color accentColor: Theme.primary

        width: ListView.view.width
        height: 40

        scale: issueItemArea.pressed ? 0.98 : 1.0
        Behavior on scale { NumberAnimation { duration: 100 } }

        MouseArea {
            id: issueItemArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPressed: mouse => issueItemRipple.trigger(mouse.x, mouse.y)
            onClicked: root.openUrl(issueData.web_url)
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Theme.cornerRadius
            color: issueItemArea.containsMouse ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.08) : "transparent"
        }

        DankRipple { id: issueItemRipple; rippleColor: accentColor; cornerRadius: Theme.cornerRadius }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            DankIcon {
                name: "subdirectory_arrow_right"
                size: 14
                color: accentColor
                opacity: 0.6
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                width: parent.width - 20
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    width: parent.width
                    text: issueData ? issueData.title : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    text: issueData ? ((issueData.references && issueData.references.full) || ("#" + issueData.iid)) : ""
                    font.pixelSize: Theme.fontSizeSmall - 2
                    color: Theme.surfaceVariantText
                    opacity: 0.8
                }
            }
        }
    }

    component GitLabMRItem: Item {
        property var mrData: null
        property color accentColor: Theme.secondary

        width: ListView.view.width
        height: 40

        scale: mrItemArea.pressed ? 0.98 : 1.0
        Behavior on scale { NumberAnimation { duration: 100 } }

        MouseArea {
            id: mrItemArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPressed: mouse => mrItemRipple.trigger(mouse.x, mouse.y)
            onClicked: root.openUrl(mrData.web_url)
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Theme.cornerRadius
            color: mrItemArea.containsMouse ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.08) : "transparent"
        }

        DankRipple { id: mrItemRipple; rippleColor: accentColor; cornerRadius: Theme.cornerRadius }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            DankIcon {
                name: "subdirectory_arrow_right"
                size: 14
                color: accentColor
                opacity: 0.6
                anchors.verticalCenter: parent.verticalCenter
            }

            Row {
                width: parent.width - 20
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                Column {
                    width: parent.width - (mergeableIcon.visible ? 16 + Theme.spacingXS : 0)
                    anchors.verticalCenter: parent.verticalCenter

                    StyledText {
                        width: parent.width
                        text: mrData ? mrData.title : ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        text: mrData ? ((mrData.references && mrData.references.full) || ("!" + mrData.iid)) : ""
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                        opacity: 0.8
                    }
                }

                DankIcon {
                    id: mergeableIcon
                    name: "check_circle"
                    size: 20
                    color: Theme.success
                    anchors.verticalCenter: parent.verticalCenter
                    visible: mrData && mrData.detailed_merge_status === "mergeable"
                }
            }
        }
    }

    popoutContent: Component {
        Column {
            width: parent.width
            spacing: Theme.spacingM
            topPadding: Theme.spacingM
            bottomPadding: Theme.spacingM

            // Header card
            Item {
                width: parent.width
                height: 68

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cornerRadius * 1.5
                    gradient: Gradient {
                        GradientStop {
                            position: 0.0
                            color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.15)
                        }
                        GradientStop {
                            position: 1.0
                            color: Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.08)
                        }
                    }
                    border.width: 1
                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.25)
                }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingM

                    // GitLab logo button
                    Item {
                        width: 40
                        height: 40
                        anchors.verticalCenter: parent.verticalCenter
                        scale: profileArea.pressed ? 0.9 : (profileArea.containsMouse ? 1.1 : 1.0)
                        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }

                        MouseArea {
                            id: profileArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: mouse => profileRipple.trigger(mouse.x, mouse.y)
                            onClicked: root.openUrl(root.profileWebUrl())
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: 20
                            color: profileArea.containsMouse ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.3) : Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2)
                        }

                        StyledText {
                            text: root.faGitlabGlyph
                            font.family: root.faFamily
                            font.pixelSize: 22
                            color: Theme.primary
                            anchors.centerIn: parent
                            scale: profileArea.containsMouse ? 1.2 : 1.0
                            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                        }

                        DankRipple {
                            id: profileRipple
                            rippleColor: Theme.surfaceText
                            cornerRadius: 20
                            anchors.fill: parent
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        StyledText {
                            text: "GitLab Notifier"
                            font.bold: true
                            font.pixelSize: Theme.fontSizeLarge
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: root.group
                                  ? ("Group: " + root.group)
                                  : (root.repo ? ("Repo: " + root.repo) : "No Group/Repo configured")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                // Refresh button
                Item {
                    width: 38
                    height: 38
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    scale: refreshArea.pressed ? 0.9 : (refreshArea.containsMouse ? 1.1 : 1.0)
                    Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }

                    MouseArea {
                        id: refreshArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: mouse => refreshRipple.trigger(mouse.x, mouse.y)
                        onClicked: root.refresh()
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.cornerRadius
                        color: refreshArea.containsMouse ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.15) : Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.4)
                        border.width: 1
                        border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, refreshArea.containsMouse ? 0.3 : 0.15)
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Behavior on border.color { ColorAnimation { duration: 150 } }
                    }

                    DankIcon {
                        id: refreshIcon
                        name: "refresh"
                        size: 20
                        color: Theme.primary
                        anchors.centerIn: parent

                        SequentialAnimation {
                            running: refreshArea.containsMouse && !root.loading
                            onStopped: refreshIcon.rotation = 0
                            NumberAnimation { target: refreshIcon; property: "rotation"; from: 0; to: 360; duration: 400; easing.type: Easing.InOutQuart }
                            NumberAnimation { target: refreshIcon; property: "rotation"; from: 360; to: 0; duration: 400; easing.type: Easing.InOutQuart }
                        }

                        RotationAnimation on rotation {
                            from: 0
                            to: 360
                            duration: 1000
                            loops: Animation.Infinite
                            running: root.loading
                        }
                    }

                    DankRipple {
                        id: refreshRipple
                        rippleColor: Theme.surfaceText
                        cornerRadius: Theme.cornerRadius
                        anchors.fill: parent
                    }
                }
            }

            // Error container
            StyledRect {
                width: parent.width
                height: root.lastError ? 60 : 0
                radius: Theme.cornerRadius
                color: Theme.errorContainer
                visible: root.lastError.length > 0

                StyledText {
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingL * 2
                    text: root.lastError
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    color: Theme.onErrorContainer
                    font.pixelSize: Theme.fontSizeSmall
                }
            }

            // Issues section
            StatRow {
                title: "Issues"
                iconName: "bug_report"
                count: root.issuesCount
                openUrl: root.scopeWebBase() + "/-/issues?state=opened&assignee_username=" + (root.username && root.username.length ? root.username : "@me")
                accentColor: Theme.primary
                visible: root.showIssues
            }

            StyledRect {
                id: issueContainer
                width: parent.width
                height: root.loading ? 54 : (root.issuesList.length > 0 ? Math.min(root.issuesList.length * 40 + (root.issuesList.length - 1) * 6 + 28, 300) : 54)
                radius: Theme.cornerRadius * 1.5
                color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.5)
                border.width: 1
                border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1)
                visible: root.showIssues
                clip: true
                Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS
                    visible: root.loading

                    DankIcon {
                        name: "sync"
                        size: 16
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                        RotationAnimation on rotation {
                            from: 0; to: 360; duration: 1000; loops: Animation.Infinite; running: parent.visible
                        }
                    }
                    StyledText { text: "Checking..."; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; anchors.verticalCenter: parent.verticalCenter }
                }

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS
                    visible: !root.loading && root.issuesList.length === 0

                    DankIcon { name: "check_circle"; size: 16; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
                    StyledText { text: "No active issues"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; anchors.verticalCenter: parent.verticalCenter }
                }

                ListView {
                    anchors.fill: parent
                    anchors.topMargin: 14
                    anchors.bottomMargin: 14
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: 6
                    model: root.issuesList
                    clip: true
                    visible: !root.loading && root.issuesList.length > 0
                    delegate: GitLabIssueItem {
                        issueData: modelData
                        accentColor: Theme.primary
                    }
                }
            }

            // Merge Requests section
            StatRow {
                title: "Merge Requests"
                iconName: "merge_type"
                count: root.mrsCount
                openUrl: root.scopeWebBase() + "/-/merge_requests?state=opened&assignee_username=" + (root.username && root.username.length ? root.username : "@me")
                accentColor: Theme.secondary
                visible: root.showMRs
            }

            StyledRect {
                id: mrContainer
                width: parent.width
                height: root.loading ? 54 : (root.mrsList.length > 0 ? Math.min(root.mrsList.length * 40 + (root.mrsList.length - 1) * 6 + 28, 300) : 54)
                radius: Theme.cornerRadius * 1.5
                color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.5)
                border.width: 1
                border.color: Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.1)
                visible: root.showMRs
                clip: true
                Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS
                    visible: root.loading

                    DankIcon {
                        name: "sync"
                        size: 16
                        color: Theme.secondary
                        anchors.verticalCenter: parent.verticalCenter
                        RotationAnimation on rotation {
                            from: 0; to: 360; duration: 1000; loops: Animation.Infinite; running: parent.visible
                        }
                    }
                    StyledText { text: "Checking..."; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; anchors.verticalCenter: parent.verticalCenter }
                }

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS
                    visible: !root.loading && root.mrsList.length === 0

                    DankIcon { name: "check_circle"; size: 16; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter }
                    StyledText { text: "No active merge requests"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; anchors.verticalCenter: parent.verticalCenter }
                }

                ListView {
                    anchors.fill: parent
                    anchors.topMargin: 14
                    anchors.bottomMargin: 14
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: 6
                    model: root.mrsList
                    clip: true
                    visible: !root.loading && root.mrsList.length > 0
                    delegate: GitLabMRItem {
                        mrData: modelData
                        accentColor: Theme.secondary
                    }
                }
            }

            // Incidents section
            StatRow {
                title: "Incidents"
                iconName: "warning"
                count: root.incidentsCount
                openUrl: root.scopeWebBase() + "/-/issues?state=opened&type[]=INCIDENT&assignee_username=" + (root.username && root.username.length ? root.username : "@me")
                accentColor: Theme.primary
                visible: root.showIncidents
            }

            StyledRect {
                id: incidentContainer
                width: parent.width
                height: root.loading ? 54 : (root.incidentsList.length > 0 ? Math.min(root.incidentsList.length * 40 + (root.incidentsList.length - 1) * 6 + 28, 300) : 54)
                radius: Theme.cornerRadius * 1.5
                color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.5)
                border.width: 1
                border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1)
                visible: root.showIncidents && root.incidentsSupported
                clip: true
                Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS
                    visible: root.loading

                    DankIcon {
                        name: "sync"
                        size: 16
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                        RotationAnimation on rotation {
                            from: 0; to: 360; duration: 1000; loops: Animation.Infinite; running: parent.visible
                        }
                    }
                    StyledText { text: "Checking..."; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; anchors.verticalCenter: parent.verticalCenter }
                }

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS
                    visible: !root.loading && root.incidentsList.length === 0

                    DankIcon { name: "check_circle"; size: 16; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
                    StyledText { text: "No active incidents"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; anchors.verticalCenter: parent.verticalCenter }
                }

                ListView {
                    anchors.fill: parent
                    anchors.topMargin: 14
                    anchors.bottomMargin: 14
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: 6
                    model: root.incidentsList
                    clip: true
                    visible: !root.loading && root.incidentsList.length > 0
                    delegate: GitLabIncidentItem {
                        incidentData: modelData
                        accentColor: Theme.primary
                    }
                }
            }

            Item {
                width: parent.width
                height: Theme.spacingXS
            }
        }
    }

    popoutWidth: 320
    popoutHeight: 0
}
