import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Shapes
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
    property string timeFormat: pluginData.timeFormat || "system"
    property string gitlabWebUrl: pluginData.gitlabWebUrl || "https://gitlab.com"
    property int refreshInterval: pluginData.refreshInterval || 60 // seconds

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
    property string avatarUrl: ""

    // State
    property bool loading: false
    property bool refreshPending: false
    // Bumped on every refresh() so callbacks from an abandoned cycle (watchdog
    // timeout, overlapping refresh) can be discarded instead of completing it.
    property int refreshEpoch: 0
    property string lastError: ""
    property var lastUpdated: null
    // Set by the manual refresh button so the toast only fires for a refresh
    // the user actually asked for, not for every periodic tick.
    property bool manualRefresh: false
    property string toastText: ""
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
        interval: Math.max(15, root.refreshInterval) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        id: toastTimer
        interval: 1800
    }

    function showToast(msg) {
        root.toastText = msg;
        toastTimer.restart();
    }

    function getEffectiveTimeFormat() {
        if (root.timeFormat === "12h") return "12h";
        if (root.timeFormat === "24h") return "24h";

        const sysFmt = Qt.locale().timeFormat(Locale.ShortFormat);
        return (sysFmt.indexOf("H") !== -1 || sysFmt.indexOf("k") !== -1) ? "24h" : "12h";
    }

    function formatHeaderTime(dateObj) {
        if (!dateObj) return "";
        return Qt.formatTime(dateObj, getEffectiveTimeFormat() === "24h" ? "HH:mm" : "h:mm AP");
    }

    // If a Proc callback never fires, `loading` would latch true forever and
    // refresh() would early-return for the rest of the session ("Checking...").
    // 60s is above the worst legitimate case: glabVersion, authStatus, the
    // prerequisites and the count queries carry a 10s Proc timeout each and run
    // back to back, so a healthy refresh tops out around 40s.
    Timer {
        id: loadingWatchdog
        interval: 60000
        repeat: false
        running: root.loading
        onTriggered: {
            root.refreshEpoch++;
            root.refreshPending = false;
            root.manualRefresh = false;
            root.loading = false;
            root.setError("Timed out talking to glab. Will retry.");
        }
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

    function setError(msg) {
        root.lastError = msg || "";
    }

    function completeRefresh() {
        const shouldRefresh = root.refreshPending;
        const wasManual = root.manualRefresh;
        root.refreshPending = false;
        root.manualRefresh = false;
        root.loading = false;
        root.lastUpdated = new Date();

        if (wasManual && !root.lastError)
            root.showToast("Refreshed GitLab Data");

        if (shouldRefresh)
            root.refresh();
    }

    function refresh() {
        if (root.loading) {
            root.refreshPending = true;
            return;
        }

        root.loading = true;
        const gen = ++root.refreshEpoch;
        root.setError("");
        root.glabOk = true;
        root.authOk = true;
        const hasGroup = root.group && root.group.trim().length > 0;
        const hasRepo = root.repo && root.repo.trim().length > 0;

        if (!hasGroup && !hasRepo) {
            root.setError("Configure a Group or Repo in settings.");
            root.issuesCount = 0;
            root.mrsCount = 0;
            root.incidentsCount = 0;
            root.mrsList = [];
            root.issuesList = [];
            root.incidentsList = [];
            root.completeRefresh();
            return;
        }

        // Proc.runCommand() is a singleton that keeps one entry per id and reads
        // entry.callback at completion time, so two widget instances (one per
        // bar/monitor) sharing an id clobber each other and only the last one
        // registered ever fires. A null id makes Proc mint a private id per call
        // and drop the entry once it completes.

        // 1) Check glab
        Proc.runCommand(null, [root.glabBinary, "--version"], (stdout, exitCode) => {
            if (!root || gen !== root.refreshEpoch)
                return;

            if (exitCode !== 0) {
                root.glabOk = false;
                root.authOk = false;
                root.incidentsSupported = false;
                root.issuesCount = 0;
                root.mrsCount = 0;
                root.incidentsCount = 0;
                root.mrsList = [];
                root.issuesList = [];
                root.incidentsList = [];
                root.setError("Could not execute glab. Is it installed and in PATH?");
                root.completeRefresh();
                return;
            }

            // 2) Check auth
            Proc.runCommand(null, [root.glabBinary, "auth", "status"], (authOut, authExit) => {
                if (!root || gen !== root.refreshEpoch)
                    return;

                if (authExit !== 0) {
                    root.authOk = false;
                    root.incidentsSupported = false;
                    root.issuesCount = 0;
                    root.mrsCount = 0;
                    root.incidentsCount = 0;
                    root.mrsList = [];
                    root.issuesList = [];
                    root.setError("glab is not authenticated. Run: glab auth login");
                    root.completeRefresh();
                    return;
                }

                // 3) Gather prerequisites (incidents support + username) in
                // parallel, then fetch counts once both have completed.
                let pending = 1; // loadUsername
                if (root.showIncidents) pending++;
                const afterPrereqs = () => {
                    // loadUsername defers this through Qt.callLater, so the
                    // refresh can be superseded between its guard and here.
                    if (!root || gen !== root.refreshEpoch)
                        return;

                    if (--pending === 0) root.fetchCounts(gen);
                };

                if (root.showIncidents) {
                    Proc.runCommand(null, [root.glabBinary, "incident", "--help"], (helpOut, helpExit) => {
                        if (!root || gen !== root.refreshEpoch)
                            return;

                        root.incidentsSupported = helpExit === 0;
                        afterPrereqs();
                    }, 0, 10000);
                } else {
                    root.incidentsSupported = true;
                }

                root.loadUsername(gen, afterPrereqs);
            }, 0, 10000);
        }, 0, 10000);
    }

    // `cb` gates fetchCounts(), so a callback from an abandoned refresh must not
    // run it: that would drive a second, parallel cycle to completeRefresh().
    function loadUsername(gen, cb) {
        Proc.runCommand(null, [root.glabBinary, "api", "user", "--output", "json"], (stdout, exitCode) => {
            if (!root || gen !== root.refreshEpoch)
                return;

            if (exitCode === 0 && stdout) {
                try {
                    const data = JSON.parse(stdout.trim());
                    if (data && (data.username || data.login)) {
                        root.username = data.username || data.login || "";
                        root.avatarUrl = data.avatar_url || "";
                    }
                } catch (e) {
                    root.username = "";
                }
            }
            if (typeof cb === "function") Qt.callLater(cb);
        }, 0, 10000);
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

    function fetchCounts(gen) {
        const r = (root.repo || "").trim();
        const g = (root.group || "").trim();
        const useGroup = g.length > 0;

        function scopeArgs() {
            return useGroup ? ["--group", g] : ["--repo", r];
        }

        // Unsupported incidents used to raise a global error here. The
        // incidents card now says so itself, which leaves the error banner for
        // failures that actually block the whole refresh.
        const finish = () => {
            root.completeRefresh();
        };

        const runIncidents = root.showIncidents && root.incidentsSupported;
        if (root.showIncidents && !root.incidentsSupported)
            root.incidentsCount = 0;

        const tasks = [];
        if (root.showIssues) tasks.push("issue");
        if (root.showMRs) tasks.push("mr");
        if (runIncidents) tasks.push("incident");

        if (tasks.length === 0) {
            finish();
            return;
        }

        let remaining = tasks.length;
        const done = () => {
            if (--remaining === 0) finish();
        };

        if (root.showIssues) {
            Proc.runCommand(
                        null,
                        [root.glabBinary, "issue", "list"].concat(scopeArgs()).concat(["--assignee=@me", "--output", "json"]),
                        (stdout, exitCode) => {
                if (!root || gen !== root.refreshEpoch)
                    return;

                if (exitCode === 0) {
                    const list = parseJsonArray(stdout);
                    root.issuesList = list;
                    root.issuesCount = list.length;
                } else {
                    root.issuesList = [];
                }
                done();
            }, 0, 10000);
        }

        if (root.showMRs) {
            Proc.runCommand(
                        null,
                        [root.glabBinary, "mr", "list"].concat(scopeArgs()).concat(["--assignee=@me", "--output", "json"]),
                        (stdout, exitCode) => {
                if (!root || gen !== root.refreshEpoch)
                    return;

                if (exitCode === 0) {
                    const list = parseJsonArray(stdout);
                    root.mrsList = list;
                    root.mrsCount = list.length;
                } else {
                    root.mrsList = [];
                }
                done();
            }, 0, 10000);
        }

        if (runIncidents) {
            Proc.runCommand(
                        null,
                        [root.glabBinary, "incident", "list"].concat(scopeArgs()).concat(["--assignee=@me","--output", "json"]),
                        (stdout, exitCode) => {
                if (!root || gen !== root.refreshEpoch)
                    return;

                if (exitCode === 0) {
                    const list = parseJsonArray(stdout);
                    root.incidentsList = list;
                    root.incidentsCount = list.length;
                } else {
                    root.incidentsList = [];
                    root.incidentsCount = 0;
                }
                done();
            }, 0, 10000);
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankSVGIcon {
                source: Qt.resolvedUrl("gitlab.svg")
                size: Theme.iconSize - 7
                anchors.verticalCenter: parent.verticalCenter
                colorOverride: root.lastError ? Theme.error : (root.totalCount > 0 ? Theme.primary : (Theme.widgetIconColor || Theme.surfaceText))
            }

            StyledText {
                id: barCount
                text: root.totalCount.toString()
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: root.lastError ? Theme.error : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // A bare Column reports no implicit size in this slot, which renders the
    // vertical pill broken. Same wrapper that fixed it in the GitHub plugin.
    verticalBarPill: Component {
        Item {
            implicitWidth: verticalCol.implicitWidth
            implicitHeight: verticalCol.implicitHeight

            Column {
                id: verticalCol
                anchors.centerIn: parent
                spacing: 2

                DankSVGIcon {
                    source: Qt.resolvedUrl("gitlab.svg")
                    size: root.iconSize
                    anchors.horizontalCenter: parent.horizontalCenter
                    colorOverride: root.lastError ? Theme.error : (root.totalCount > 0 ? Theme.primary : (Theme.widgetIconColor || Theme.surfaceText))
                }

                StyledText {
                    text: root.totalCount.toString()
                    color: root.lastError ? Theme.error : Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    // One card per category (Issues / MRs / Incidents). All three lists share
    // the same shape — title, references.full or #iid, web_url — so the whole
    // card, its empty/loading/unsupported states and its row delegate live here
    // once instead of being spelled out three times.
    component CategoryCard: StyledRect {
        id: card

        property string title: ""
        property string iconName: ""
        property string webUrl: ""
        property var items: []
        property string emptyText: ""
        property string loadingText: ""
        property bool unsupported: false
        property string unsupportedText: ""
        property color accentColor: Theme.primary

        width: parent.width
        height: Math.max(0, cardCol.implicitHeight + Theme.spacingM * 2)
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
        border.width: 1
        border.color: Qt.rgba(card.accentColor.r, card.accentColor.g, card.accentColor.b, 0.15)

        Column {
            id: cardCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            // Section header, opens the category on GitLab
            Item {
                width: parent.width
                height: headerRow.implicitHeight

                RowLayout {
                    id: headerRow
                    anchors.fill: parent
                    spacing: Theme.spacingXS

                    DankIcon {
                        name: card.iconName
                        size: 14
                        color: headerMa.containsMouse ? card.accentColor : Theme.surfaceText
                        Layout.alignment: Qt.AlignVCenter
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    StyledText {
                        text: card.title
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: headerMa.containsMouse ? card.accentColor : Theme.surfaceText
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    StyledText {
                        text: card.items.length.toString()
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: card.accentColor
                        opacity: 0.7
                        Layout.alignment: Qt.AlignVCenter
                        visible: !card.unsupported && card.items.length > 0
                    }

                    DankIcon {
                        name: "open_in_new"
                        size: 14
                        color: headerMa.containsMouse ? card.accentColor : Theme.surfaceVariantText
                        opacity: headerMa.containsMouse ? 0.9 : 0.4
                        Layout.alignment: Qt.AlignVCenter
                        Behavior on opacity { NumberAnimation { duration: 150 } }
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }
                }

                MouseArea {
                    id: headerMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openUrl(card.webUrl)
                }
            }

            // Unsupported state, only reachable by the incidents card
            StyledRect {
                width: parent.width
                height: 44
                radius: Theme.cornerRadius
                color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.05)
                border.width: 1
                border.color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.12)
                visible: card.unsupported

                RowLayout {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "info"
                        size: 18
                        color: Theme.surfaceVariantText
                        Layout.alignment: Qt.AlignVCenter
                    }

                    StyledText {
                        text: card.unsupportedText
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                        Layout.alignment: Qt.AlignVCenter
                    }
                }
            }

            // Empty state
            StyledRect {
                width: parent.width
                height: 44
                radius: Theme.cornerRadius
                color: Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.05)
                border.width: 1
                border.color: Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.12)
                visible: !card.unsupported && !root.loading && card.items.length === 0

                RowLayout {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "check_circle"
                        size: 18
                        color: Theme.surfaceVariantText
                        Layout.alignment: Qt.AlignVCenter
                    }

                    StyledText {
                        text: card.emptyText
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                        Layout.alignment: Qt.AlignVCenter
                    }
                }
            }

            // Loading state
            StyledRect {
                width: parent.width
                height: 44
                radius: Theme.cornerRadius
                color: Qt.rgba(card.accentColor.r, card.accentColor.g, card.accentColor.b, 0.05)
                border.width: 1
                border.color: Qt.rgba(card.accentColor.r, card.accentColor.g, card.accentColor.b, 0.12)
                visible: !card.unsupported && root.loading

                RowLayout {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS

                    DankSpinner {
                        size: 18
                        color: card.accentColor
                        Layout.alignment: Qt.AlignVCenter
                    }

                    StyledText {
                        text: card.loadingText
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                        Layout.alignment: Qt.AlignVCenter
                    }
                }
            }

            // The list itself, scrollable past three items
            Item {
                width: parent.width
                height: card.items.length > 3 ? 166 : itemsColumn.implicitHeight
                visible: !card.unsupported && !root.loading && card.items.length > 0

                ScrollView {
                    id: cardScrollView
                    anchors.fill: parent
                    contentWidth: availableWidth

                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                    ScrollBar.vertical: ScrollBar {
                        id: cardScrollBar
                        policy: card.items.length > 3 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                        active: true
                        width: 6

                        contentItem: Rectangle {
                            implicitWidth: 6
                            radius: 3
                            color: cardScrollBar.pressed
                                   ? card.accentColor
                                   : (cardScrollBar.hovered
                                      ? Qt.rgba(card.accentColor.r, card.accentColor.g, card.accentColor.b, 0.7)
                                      : Qt.rgba(card.accentColor.r, card.accentColor.g, card.accentColor.b, 0.4))
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }

                        background: Rectangle {
                            implicitWidth: 6
                            radius: 3
                            color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.2)
                        }
                    }

                    Column {
                        id: itemsColumn
                        width: cardScrollView.availableWidth
                        spacing: 4

                        Repeater {
                            model: card.items

                            delegate: Item {
                                id: rowDelegate
                                width: parent.width
                                height: Math.max(56, rowLayout.implicitHeight + Theme.spacingS * 2)

                                readonly property bool isHovered: rowMa.containsMouse
                                readonly property bool isFirst: index === 0
                                readonly property bool isLast: index === card.items.length - 1

                                Shape {
                                    id: rowBg
                                    anchors.fill: parent

                                    readonly property real innerRadius: 6
                                    readonly property real outerRadius: Theme.cornerRadius || 12
                                    readonly property real topR: rowDelegate.isHovered ? (height / 2) : (rowDelegate.isFirst ? outerRadius : innerRadius)
                                    readonly property real bottomR: rowDelegate.isHovered ? (height / 2) : (rowDelegate.isLast ? outerRadius : innerRadius)

                                    property real topRAnim: topR
                                    Behavior on topRAnim { NumberAnimation { duration: 600; easing.type: Easing.OutExpo } }
                                    property real bottomRAnim: bottomR
                                    Behavior on bottomRAnim { NumberAnimation { duration: 600; easing.type: Easing.OutExpo } }

                                    ShapePath {
                                        fillColor: rowDelegate.isHovered
                                                   ? Qt.rgba(card.accentColor.r, card.accentColor.g, card.accentColor.b, 0.1)
                                                   : Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.04)
                                        strokeColor: rowDelegate.isHovered
                                                     ? Qt.rgba(card.accentColor.r, card.accentColor.g, card.accentColor.b, 0.4)
                                                     : Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.15)
                                        strokeWidth: 1

                                        startX: rowBg.topRAnim + 1; startY: 1
                                        PathLine { x: rowBg.width - rowBg.topRAnim - 1; y: 1 }
                                        PathArc { x: rowBg.width - 1; y: rowBg.topRAnim + 1; radiusX: rowBg.topRAnim; radiusY: rowBg.topRAnim; direction: PathArc.Clockwise }
                                        PathLine { x: rowBg.width - 1; y: rowBg.height - rowBg.bottomRAnim - 1 }
                                        PathArc { x: rowBg.width - rowBg.bottomRAnim - 1; y: rowBg.height - 1; radiusX: rowBg.bottomRAnim; radiusY: rowBg.bottomRAnim; direction: PathArc.Clockwise }
                                        PathLine { x: rowBg.bottomRAnim + 1; y: rowBg.height - 1 }
                                        PathArc { x: 1; y: rowBg.height - rowBg.bottomRAnim - 1; radiusX: rowBg.bottomRAnim; radiusY: rowBg.bottomRAnim; direction: PathArc.Clockwise }
                                        PathLine { x: 1; y: rowBg.topRAnim + 1 }
                                        PathArc { x: rowBg.topRAnim + 1; y: 1; radiusX: rowBg.topRAnim; radiusY: rowBg.topRAnim; direction: PathArc.Clockwise }
                                    }
                                }

                                DankRipple {
                                    id: rowRipple
                                    anchors.fill: parent
                                    cornerRadius: rowBg.topRAnim
                                    rippleColor: card.accentColor
                                }

                                RowLayout {
                                    id: rowLayout
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: card.iconName
                                        size: 18
                                        color: card.accentColor
                                        Layout.alignment: Qt.AlignVCenter
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: 2

                                        StyledText {
                                            text: modelData.title || ""
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                            Layout.fillWidth: true
                                            wrapMode: Text.WordWrap
                                            maximumLineCount: 2
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            text: (modelData.references && modelData.references.full) || ("#" + modelData.iid)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: rowDelegate.isHovered ? card.accentColor : Theme.surfaceVariantText
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                            Behavior on color { ColorAnimation { duration: 150 } }
                                        }
                                    }

                                    DankIcon {
                                        name: "open_in_new"
                                        size: 16
                                        color: Theme.surfaceVariantText
                                        opacity: rowDelegate.isHovered ? 0.9 : 0.0
                                        Layout.alignment: Qt.AlignVCenter
                                        Behavior on opacity { NumberAnimation { duration: 150 } }
                                    }
                                }

                                MouseArea {
                                    id: rowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPressed: m => rowRipple.trigger(m.x, m.y)
                                    onClicked: root.openUrl(modelData.web_url)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popoutColumn
            headerText: ""
            showCloseButton: false

            Item {
                width: parent.width
                height: mainCol.implicitHeight

                Column {
                    id: mainCol
                    width: parent.width
                    spacing: Theme.spacingM
                    topPadding: 0
                    bottomPadding: 2

                    // Header card: identity on the left, refresh on the right
                    StyledRect {
                        width: parent.width
                        height: 72
                        radius: Theme.cornerRadius * 1.5
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                        border.width: 1
                        border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.15)

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: headerRefreshBtn.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingM

                            Item {
                                width: 42
                                height: 42
                                anchors.verticalCenter: parent.verticalCenter

                                MouseArea {
                                    id: profileArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPressed: m => profileRipple.trigger(m.x, m.y)
                                    onClicked: root.openUrl(root.profileWebUrl())
                                }

                                DankCircularImage {
                                    anchors.fill: parent
                                    imageSource: root.avatarUrl
                                    fallbackIcon: ""
                                    border.width: profileArea.containsMouse ? 2 : 0
                                    border.color: Theme.primary

                                    DankSVGIcon {
                                        source: Qt.resolvedUrl("gitlab.svg")
                                        size: 22
                                        anchors.centerIn: parent
                                        colorOverride: Theme.primary
                                        visible: parent.imageStatus !== Image.Ready
                                    }
                                }

                                DankRipple {
                                    id: profileRipple
                                    rippleColor: Theme.primary
                                    cornerRadius: 21
                                    anchors.fill: parent
                                }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                StyledText {
                                    text: root.username ? root.username : "GitLab Notifier"
                                    font.bold: true
                                    font.pixelSize: Theme.fontSizeLarge
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    text: root.lastUpdated
                                          ? (root.totalCount + " Active Items • Updated " + root.formatHeaderTime(root.lastUpdated))
                                          : (root.totalCount + " Active Items")
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.primary
                                    opacity: 0.85
                                }
                            }
                        }

                        Rectangle {
                            id: headerRefreshBtn
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            width: 38
                            height: 38
                            radius: Theme.cornerRadius
                            color: refreshMa.containsMouse
                                   ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.15)
                                   : Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.08)
                            border.width: 1
                            border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, refreshMa.containsMouse ? 0.3 : 0.15)

                            scale: refreshMa.pressed ? 0.92 : (refreshMa.containsMouse ? 1.05 : 1.0)
                            Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }
                            Behavior on color { ColorAnimation { duration: 150 } }

                            DankRipple { id: refreshRipple; anchors.fill: parent; cornerRadius: Theme.cornerRadius; rippleColor: Theme.primary }

                            DankSpinner {
                                size: 20
                                color: Theme.primary
                                anchors.centerIn: parent
                                visible: root.loading
                            }

                            DankIcon {
                                name: "refresh"
                                size: 20
                                color: Theme.primary
                                anchors.centerIn: parent
                                visible: !root.loading

                                rotation: refreshMa.containsMouse ? 180 : 0
                                Behavior on rotation { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
                            }

                            MouseArea {
                                id: refreshMa
                                anchors.fill: parent
                                hoverEnabled: !root.loading
                                cursorShape: Qt.PointingHandCursor
                                onPressed: m => refreshRipple.trigger(m.x, m.y)
                                onClicked: {
                                    root.manualRefresh = true;
                                    root.refresh();
                                }
                            }
                        }
                    }

                    StyledRect {
                        width: parent.width
                        visible: root.lastError.length > 0
                        height: Math.max(0, errText.implicitHeight + Theme.spacingM * 2)
                        radius: Theme.cornerRadius
                        color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.12)
                        border.width: 1
                        border.color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.4)

                        StyledText {
                            id: errText
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            text: root.lastError
                            color: Theme.error
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    CategoryCard {
                        title: "Issues"
                        iconName: "bug_report"
                        accentColor: Theme.primary
                        items: root.issuesList
                        emptyText: "No assigned issues"
                        loadingText: "Refreshing issues..."
                        webUrl: root.scopeWebBase() + "/-/issues?state=opened&assignee_username=" + (root.username && root.username.length ? root.username : "@me")
                        visible: root.showIssues
                    }

                    CategoryCard {
                        title: "Merge Requests"
                        iconName: "merge_type"
                        accentColor: Theme.secondary
                        items: root.mrsList
                        emptyText: "No assigned merge requests"
                        loadingText: "Refreshing merge requests..."
                        webUrl: root.scopeWebBase() + "/-/merge_requests?state=opened&assignee_username=" + (root.username && root.username.length ? root.username : "@me")
                        visible: root.showMRs
                    }

                    CategoryCard {
                        title: "Incidents"
                        iconName: "e911_emergency"
                        accentColor: Theme.error
                        items: root.incidentsList
                        emptyText: "No assigned incidents"
                        loadingText: "Refreshing incidents..."
                        unsupported: !root.incidentsSupported
                        unsupportedText: "This glab version has no incident support"
                        webUrl: root.scopeWebBase() + "/-/issues?state=opened&type[]=INCIDENT&assignee_username=" + (root.username && root.username.length ? root.username : "@me")
                        visible: root.showIncidents
                    }
                }

                // Toast, shown only for a refresh the user asked for
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.spacingS
                    height: 32
                    width: toastLayout.implicitWidth + Theme.spacingM * 2
                    radius: height / 2
                    color: Qt.rgba(Theme.surfaceContainerHighest.r, Theme.surfaceContainerHighest.g, Theme.surfaceContainerHighest.b, 0.95)
                    border.width: 1
                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.4)
                    z: 999
                    opacity: toastTimer.running ? 1.0 : 0.0
                    scale: toastTimer.running ? 1.0 : 0.75

                    Behavior on opacity { NumberAnimation { duration: 200 } }
                    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }

                    RowLayout {
                        id: toastLayout
                        anchors.centerIn: parent
                        spacing: Theme.spacingXS

                        DankIcon { name: "info"; size: 16; color: Theme.primary }

                        StyledText {
                            text: root.toastText
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 420
    popoutHeight: 0
}
