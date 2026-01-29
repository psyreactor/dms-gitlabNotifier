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
        // remove trailing slashes
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
        // Attempt to fetch the authenticated username from glab API
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

    function parseJsonArrayLen(stdout) {
        const raw = (stdout || "").trim();
        if (!raw) return 0;

        // 1) Try parse as full JSON
        try {
            const data = JSON.parse(raw);
            if (Array.isArray(data)) return data.length;
            if (Array.isArray(data.items)) return data.items.length;
            if (Array.isArray(data.data)) return data.data.length;
            // If it's an object but contains count-like fields
            if (typeof data === "object" && data !== null) {
                if (typeof data.total_count === "number") return data.total_count;
                if (typeof data.total === "number") return data.total;
            }
        } catch (e) {
            // not a single JSON blob - continue to NDJSON attempt
        }

        // 2) Try NDJSON (one JSON object per line)
        try {
            const lines = raw.split(/\r?\n/).map(s => s.trim()).filter(s => s.length > 0);
            let count = 0;
            for (let i = 0; i < lines.length; i++) {
                const line = lines[i];
                try {
                    const obj = JSON.parse(line);
                    if (obj !== null && typeof obj === "object") count++;
                } catch (e) {
                    // not JSON line - skip
                }
            }
            if (count > 0) return count;
        } catch (e) {
            // ignore
        }

        // 3) If output is a plain number (e.g., user piped through jq), return it
        const num = parseInt(raw, 10);
        if (!isNaN(num)) return num;

        return 0;
    }

    function fetchCounts() {
        // reset first to avoid stale counts if a command fails
        root.issuesCount = 0;
        root.mrsCount = 0;
        root.incidentsCount = 0;

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
                    root.mrsCount = parseJsonArrayLen(stdout);
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
                    root.incidentsCount = parseJsonArrayLen(stdout);
                } else {
                    // If command exists but fails, avoid spamming errors; show soft warning.
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
                // keep lastError if previously set
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
                    root.issuesCount = parseJsonArrayLen(stdout);
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
                visible: !root.loading && root.totalCount > 0
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "…"
                visible: root.loading
                color: Theme.surfaceVariantText
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
                text: root.loading ? "…" : root.totalCount.toString()
                color: root.lastError ? Theme.error : Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    component StatRow: Row {
        property string title: ""
        property int count: 0
        property string openUrl: ""
        property bool enabled: true

        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            text: title
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            width: 120
        }

        Badge {
            value: count
            label: ""
            badgeColor: count > 0 ? Theme.primary : Theme.surfaceVariantText
        }

        // small spacer
        Item { width: Theme.spacingS; height: 1 }

        Rectangle {
            width: 90
            height: 30
            radius: Theme.cornerRadius
            color: openMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
            visible: openUrl.length > 0 && enabled

            Row {
                anchors.centerIn: parent
                spacing: Theme.spacingS
                DankIcon { name: "open_in_new"; size: 18; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
                StyledText { text: "Open"; color: Theme.primary; font.pixelSize: Theme.fontSizeMedium; anchors.verticalCenter: parent.verticalCenter }
            }

            MouseArea {
                id: openMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openUrl(parent.parent.openUrl)
            }
        }
    }

    popoutContent: Component {
        Column {
            anchors.fill: parent
            anchors.margins: Theme.spacingXS
            spacing: Theme.spacingM

            Row {
                width: parent.width
                spacing: Theme.spacingM

                StyledText {
                    text: root.faGitlabGlyph
                    font.family: root.faFamily
                    font.pixelSize: 26
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
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
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }
            }

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

            StatRow {
                title: "Issues"
                count: root.issuesCount
                enabled: root.showIssues
                openUrl: root.scopeWebBase() + "/-/issues?state=opened&assignee_username=" + (root.username && root.username.length ? root.username : "@me")
                visible: root.showIssues
            }

            StatRow {
                title: "Merge Requests"
                count: root.mrsCount
                enabled: root.showMRs
                openUrl: root.scopeWebBase() + "/-/merge_requests?state=opened&assignee_username=" + (root.username && root.username.length ? root.username : "@me")
                visible: root.showMRs
            }

            StatRow {
                title: "Incidents"
                count: root.incidentsCount
                enabled: root.showIncidents && root.incidentsSupported
                openUrl: root.scopeWebBase() + "/-/issues?state=opened&type[]=INCIDENT&assignee_username=" + (root.username && root.username.length ? root.username : "@me")
                visible: root.showIncidents
            }

            // bottom spacing
            Item {
                width: parent.width
                height: Theme.spacingM
            }
        }
    }

    // Popup narrow and with a bit of bottom padding
    popoutWidth: 300
    popoutHeight: 380
}

