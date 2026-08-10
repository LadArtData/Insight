/**
 * INSIGHT_apex_ai_matrix_26.js
 * Oracle APEX Static Application File. Renders the 26-node grid and drives
 * the 2-way writeback to pkg_insight_board_engine (lives in ITERIA_AI).
 *
 * Two call paths, both real -- neither fabricates data, and both hit the
 * same PL/SQL package:
 *   1. Inside Oracle APEX: apex.server.process('HANDLE_EDL_EVENT'/
 *      'GET_MATRIX_STATE', ...) runs the Application Processes that call
 *      pkg_insight_board_engine.
 *   2. Outside APEX: fetch() calls the native ORDS module defined in
 *      sql/INSIGHT_06_ords_rest_module.sql (base path /insight-hooks/),
 *      registered under ADMIN -- there is only one Oracle login in this
 *      environment -- which reaches into ITERIA_AI for the real call, so
 *      there's no separate application server to stand up.
 *
 * Set window.INSIGHT_CONFIG = { ordsBaseUrl: '...' } before this script
 * loads to point path 2 at your ORDS instance, e.g.
 * "https://<db>-<tenancy>.adb.<region>.oraclecloudapps.com/ords/admin/insight-hooks".
 * Defaults to a same-origin relative path, which works if this file is
 * served from the same domain as ORDS.
 */
(function (global) {
    "use strict";

    var config = global.INSIGHT_CONFIG || {};
    var ORDS_BASE = (config.ordsBaseUrl || "/ords/admin/insight-hooks").replace(/\/$/, "");
    var BOARD_ID = config.boardId || 1;
    var API_KEY = config.apiKey || null;

    var NODE_NAMES = [
        "Control Interface Node", "Master Controller", "Matrix Coordinator", "EDL Business Rules",
        "Pipeline Evaluator", "Event Classifier", "Priority Queue Manager", "State Inspector",
        "Signal Normalizer", "Validation Engine", "Data Stream Router", "Batch Processor",
        "Threshold Monitor", "State Cache Manager", "Telemetry Collector", "Audit Logger",
        "Schema A Table Buffer", "PL/SQL Package Cache", "CLOB Payload Repo", "Writeback Dispatcher",
        "ORDS Gateway Node", "REST Service Bridge", "Security Guard", "Session State Sync",
        "Metrics Visualizer", "Recovery Monitor"
    ];

    function inApexRuntime() {
        return typeof global.apex !== "undefined" && global.apex.server && typeof global.apex.server.process === "function";
    }

    function ordsUrl(path) {
        var url = ORDS_BASE + path;
        if (API_KEY) url += (url.indexOf("?") === -1 ? "?" : "&") + "api_key=" + encodeURIComponent(API_KEY);
        return url;
    }

    var logCounter = 0;
    function addLog(message) {
        var logContainer = document.getElementById("log-content");
        var countEl = document.getElementById("log-count");
        if (!logContainer) return;
        logCounter++;
        if (countEl) countEl.innerText = logCounter + " Event(s) Logged";
        var now = new Date().toLocaleTimeString();
        var div = document.createElement("div");
        div.className = "log-entry";
        div.innerHTML = '<span class="log-time">[' + now + "]</span> " + message;
        logContainer.prepend(div);
    }

    var ApexAIMatrix = {
        boardId: BOARD_ID,

        init: function () {
            this.renderGridSkeleton();
            var badge = document.getElementById("env-badge");
            if (badge) badge.innerText = inApexRuntime() ? "LIVE — Oracle APEX Runtime" : "LIVE — Native ORDS (insight-hooks)";
            this.loadMatrixState();
        },

        renderGridSkeleton: function () {
            var container = document.getElementById("apex-matrix-grid");
            if (!container) return;
            var html = "";
            for (var i = 1; i <= 26; i++) {
                var letter = String.fromCharCode(64 + i);
                var name = NODE_NAMES[i - 1] || "Node " + i + " Engine";
                html += '<div class="node-card" onclick="ApexAIMatrix.triggerNodeEvent(' + i + ')">';
                html += '  <div class="node-header">';
                html += '    <span class="node-code">N' + (i < 10 ? "0" + i : i) + " (" + letter + ')</span>';
                html += '    <span class="node-status" id="node-status-' + i + '">…</span>';
                html += "  </div>";
                html += '  <div class="node-name">' + name + "</div>";
                html += '  <div class="value-bar"><div class="value-fill" id="node-fill-' + i + '" style="width: 0%;"></div></div>';
                html += "</div>";
            }
            container.innerHTML = html;
        },

        loadMatrixState: function () {
            if (inApexRuntime()) {
                global.apex.server.process(
                    "GET_MATRIX_STATE",
                    { x01: this.boardId },
                    {
                        dataType: "json",
                        success: function (pData) {
                            addLog("Loaded live matrix state from Oracle APEX.");
                            ApexAIMatrix.updateUI(pData);
                        },
                        error: function (pjqXHR, pTextStatus, pErrorThrown) {
                            addLog("Failed to load matrix state: " + pErrorThrown);
                        }
                    }
                );
                return;
            }
            fetch(ordsUrl("/matrix/" + this.boardId))
                .then(function (res) { return res.json().then(function (body) { return { ok: res.ok, body: body }; }); })
                .then(function (r) {
                    if (!r.ok || !r.body.ok) throw new Error((r.body && r.body.error) || "request failed");
                    addLog("Loaded live matrix state from /insight-hooks/matrix/" + ApexAIMatrix.boardId + ".");
                    ApexAIMatrix.updateUI(r.body.nodes);
                })
                .catch(function (err) {
                    addLog("Failed to load matrix state from ORDS: " + err.message);
                });
        },

        triggerNodeEvent: function (nodeId, eventCode) {
            addLog("Firing Node #" + nodeId + " -> Event: " + (eventCode || "ON_USER_TRIGGER"));

            if (inApexRuntime()) {
                global.apex.server.process(
                    "HANDLE_EDL_EVENT",
                    {
                        x01: this.boardId,
                        x02: nodeId,
                        x03: eventCode || "ON_USER_TRIGGER",
                        x04: JSON.stringify({
                            client_time: new Date().toISOString(),
                            user_agent: navigator.userAgent,
                            trigger_source: "APEX_STATIC_UI"
                        })
                    },
                    {
                        dataType: "json",
                        success: function (pData) {
                            addLog("Writeback succeeded for Node #" + nodeId + ".");
                            ApexAIMatrix.updateUI(pData);
                        },
                        error: function (pjqXHR, pTextStatus, pErrorThrown) {
                            addLog("APEX writeback error: " + pErrorThrown);
                        }
                    }
                );
                return;
            }

            fetch(ordsUrl("/nodes/" + nodeId + "/trigger"), {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    board_id: this.boardId,
                    event_code: eventCode || "ON_USER_TRIGGER",
                    payload: {
                        client_time: new Date().toISOString(),
                        trigger_source: "STANDALONE_ORDS_UI"
                    }
                })
            })
                .then(function (res) { return res.json().then(function (body) { return { ok: res.ok, body: body }; }); })
                .then(function (r) {
                    if (!r.ok || !r.body.ok) throw new Error((r.body && r.body.error) || "request failed");
                    addLog("Writeback succeeded for Node #" + nodeId + " via /insight-hooks/nodes/" + nodeId + "/trigger.");
                    ApexAIMatrix.updateUI(r.body.nodes);
                })
                .catch(function (err) {
                    addLog("ORDS writeback error for Node #" + nodeId + ": " + err.message);
                });
        },

        updateUI: function (nodesArray) {
            if (!Array.isArray(nodesArray)) return;
            nodesArray.forEach(function (node) {
                var statusEl = document.getElementById("node-status-" + node.node_id);
                var fillEl = document.getElementById("node-fill-" + node.node_id);
                if (statusEl) {
                    statusEl.innerText = node.current_status;
                    statusEl.className = "node-status status-" + node.current_status;
                }
                if (fillEl && typeof node.state_value === "number") {
                    fillEl.style.width = Math.min(100, Math.max(0, node.state_value)) + "%";
                }
            });
        }
    };

    global.ApexAIMatrix = ApexAIMatrix;

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", function () { ApexAIMatrix.init(); });
    } else {
        ApexAIMatrix.init();
    }
})(window);
