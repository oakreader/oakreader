/**
 * OakHighlighter — bridge between web-highlighter library and OakReader native code.
 *
 * Depends on: web-highlighter.min.js (exposes window.Highlighter)
 *
 * Exposes window.OakHighlighter with:
 *   init()                          — create Highlighter instance
 *   highlightSelection(color, type) — highlight current selection, returns serialized JSON
 *   restore(id, sourcesJson, color, type) — restore a saved highlight
 *   remove(id)                      — remove highlight by ID
 */
(function () {
    'use strict';

    var highlighter = null;

    // CSS class prefix used on all highlight wrapper elements
    var HL_CLASS = 'oak-hl';

    // Inject styles once
    function injectStyles() {
        if (document.getElementById('oak-hl-styles')) return;
        var style = document.createElement('style');
        style.id = 'oak-hl-styles';
        style.textContent = [
            '.' + HL_CLASS + ' { border-radius: 2px; padding: 1px 0; cursor: default; }',
            '.' + HL_CLASS + '[data-oak-type="highlight"] { background-color: var(--oak-hl-color, rgba(255,212,0,0.35)); }',
            '.' + HL_CLASS + '[data-oak-type="underline"] { background-color: transparent; text-decoration: underline; text-decoration-color: var(--oak-hl-color, rgba(255,212,0,0.35)); text-underline-offset: 3px; text-decoration-thickness: 2px; }'
        ].join('\n');
        document.head.appendChild(style);
    }

    // Apply color + type to all DOM nodes for a given highlight ID
    function applyVisualStyle(id, color, type) {
        if (!highlighter) return;
        var doms = highlighter.getDoms(id);
        for (var i = 0; i < doms.length; i++) {
            doms[i].style.setProperty('--oak-hl-color', color);
            doms[i].setAttribute('data-oak-type', type || 'highlight');
            doms[i].setAttribute('data-oak-hl-id', id);
        }
    }

    window.OakHighlighter = {

        /**
         * Initialise the Highlighter instance. Call once after document load.
         */
        init: function () {
            if (highlighter) return;
            if (typeof Highlighter === 'undefined') {
                console.error('[OakHighlighter] web-highlighter not loaded');
                return;
            }
            injectStyles();

            highlighter = new Highlighter({
                wrapTag: 'span',
                style: { className: HL_CLASS },
                verbose: false
            });
            // Do NOT call run() — we control highlighting manually via fromRange.

            // Right-click on a highlight → notify native to show context menu
            document.addEventListener('contextmenu', function (e) {
                var el = e.target;
                while (el && el !== document.body) {
                    if (el.classList && el.classList.contains(HL_CLASS)) {
                        var hlId = el.getAttribute('data-oak-hl-id');
                        if (hlId) {
                            e.preventDefault();
                            try {
                                window.webkit.messageHandlers.highlightContextMenu.postMessage({
                                    id: hlId,
                                    x: e.clientX,
                                    y: e.clientY,
                                    vpWidth: window.innerWidth,
                                    vpHeight: window.innerHeight
                                });
                            } catch (err) {}
                            return;
                        }
                    }
                    el = el.parentElement;
                }
            });
        },

        /**
         * Highlight the current browser selection.
         * @param {string} color  CSS color value, e.g. "rgba(255,212,0,0.35)"
         * @param {string} type   "highlight" or "underline"
         * @returns {string|null} JSON string of {id, startMeta, endMeta, text} or null
         */
        highlightSelection: function (color, type) {
            if (!highlighter) return null;
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;

            var range = sel.getRangeAt(0);
            var sources = highlighter.fromRange(range);

            if (!sources || (Array.isArray(sources) && sources.length === 0)) return null;

            // fromRange returns a single HighlightSource or an array
            var source = Array.isArray(sources) ? sources[0] : sources;

            applyVisualStyle(source.id, color, type);

            sel.removeAllRanges();

            var payload = {
                id: source.id,
                startMeta: source.startMeta,
                endMeta: source.endMeta,
                text: source.text
            };

            // Notify native side
            try {
                window.webkit.messageHandlers.highlightEvent.postMessage({
                    action: 'create',
                    id: source.id,
                    color: color,
                    type: type || 'highlight',
                    sources: JSON.stringify(payload)
                });
            } catch (e) {
                // message handler may not be registered yet
            }

            return JSON.stringify(payload);
        },

        /**
         * Restore a previously saved highlight.
         * @param {string} id         Highlight ID
         * @param {string} sourcesJson JSON string with {startMeta, endMeta, text, id}
         * @param {string} color       CSS color
         * @param {string} type        "highlight" or "underline"
         */
        restore: function (id, sourcesJson, color, type) {
            if (!highlighter) return;
            try {
                var src = JSON.parse(sourcesJson);
                highlighter.fromStore(
                    src.startMeta,
                    src.endMeta,
                    src.text,
                    src.id || id
                );
                applyVisualStyle(src.id || id, color, type || 'highlight');
            } catch (e) {
                console.error('[OakHighlighter] restore failed:', e);
            }
        },

        /**
         * Remove a highlight by ID.
         * @param {string} id Highlight ID
         */
        remove: function (id) {
            if (!highlighter) return;
            highlighter.remove(id);
        }
    };
})();
