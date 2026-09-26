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
 *   setStyle(id, color, type)       — re-apply color/type to an existing highlight
 *   setHasNote(id, hasNote)         — toggle the "has a note" marker on a highlight
 *   focusHighlight(id)              — scroll to + flash a highlight, then post its
 *                                     screen rect so native can anchor the note editor
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
            '.' + HL_CLASS + '[data-oak-type="underline"] { background-color: transparent; text-decoration: underline; text-decoration-color: var(--oak-hl-color, rgba(255,212,0,0.35)); text-underline-offset: 3px; text-decoration-thickness: 2px; }',
            // A note marker: a small pencil superscript appended after the *last*
            // DOM node of a highlight that carries a comment.
            '.' + HL_CLASS + '[data-oak-has-note="1"][data-oak-hl-last="1"]::after { content: "🖉"; font-size: 0.72em; vertical-align: super; margin-left: 1px; opacity: 0.65; cursor: pointer; }',
            // A short-lived flash used by focusHighlight() to draw the eye.
            '.' + HL_CLASS + '.oak-hl-flash { animation: oak-hl-flash 1.1s ease-out; }',
            '@keyframes oak-hl-flash { 0% { box-shadow: 0 0 0 3px rgba(255,193,7,0.0); } 25% { box-shadow: 0 0 0 3px rgba(255,193,7,0.65); } 100% { box-shadow: 0 0 0 3px rgba(255,193,7,0.0); } }'
        ].join('\n');
        document.head.appendChild(style);
    }

    // Apply color + type to all DOM nodes for a given highlight ID. The last node
    // is tagged so the note marker (::after) renders once, at the end.
    function applyVisualStyle(id, color, type) {
        if (!highlighter) return;
        var doms = highlighter.getDoms(id);
        for (var i = 0; i < doms.length; i++) {
            doms[i].style.setProperty('--oak-hl-color', color);
            doms[i].setAttribute('data-oak-type', type || 'highlight');
            doms[i].setAttribute('data-oak-hl-id', id);
            if (i === doms.length - 1) {
                doms[i].setAttribute('data-oak-hl-last', '1');
            } else {
                doms[i].removeAttribute('data-oak-hl-last');
            }
        }
    }

    // Post a highlight's on-screen rect to native so it can anchor the note
    // editor. Payload shape matches `textSelected`. Shared by click-to-open and
    // focusHighlight (sidebar).
    function postFocus(id, el) {
        var r = el.getBoundingClientRect();
        try {
            window.webkit.messageHandlers.highlightFocus.postMessage({
                id: id,
                x: r.left + r.width / 2,
                y: r.top,
                bottomY: r.bottom,
                vpWidth: window.innerWidth,
                vpHeight: window.innerHeight
            });
        } catch (e) {}
    }

    // Walk up from an event target to the enclosing highlight span, returning its id.
    function highlightIdFromEvent(target) {
        var el = target;
        while (el && el !== document.body) {
            if (el.classList && el.classList.contains(HL_CLASS)) {
                var id = el.getAttribute('data-oak-hl-id');
                if (id) return { id: id, el: el };
            }
            el = el.parentElement;
        }
        return null;
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
                var hit = highlightIdFromEvent(e.target);
                if (!hit) return;
                e.preventDefault();
                try {
                    window.webkit.messageHandlers.highlightContextMenu.postMessage({
                        id: hit.id,
                        x: e.clientX,
                        y: e.clientY,
                        vpWidth: window.innerWidth,
                        vpHeight: window.innerHeight
                    });
                } catch (err) {}
            });

            // Left-click on a highlight → open its note editor (anchored to it).
            // Skipped while a text selection is in progress so dragging a new
            // selection over a highlight still goes through the selection popup.
            document.addEventListener('click', function (e) {
                var sel = window.getSelection();
                if (sel && !sel.isCollapsed) return;
                var hit = highlightIdFromEvent(e.target);
                if (!hit) return;
                postFocus(hit.id, hit.el);
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
        },

        /**
         * Re-apply color + type to an existing highlight (e.g. the note editor
         * changed the swatch or toggled highlight/underline).
         * @param {string} id    Highlight ID
         * @param {string} color CSS color
         * @param {string} type  "highlight" or "underline"
         */
        setStyle: function (id, color, type) {
            applyVisualStyle(id, color, type);
        },

        /**
         * Toggle the "has a note" marker on a highlight.
         * @param {string} id      Highlight ID
         * @param {boolean} hasNote Whether the highlight carries a comment
         */
        setHasNote: function (id, hasNote) {
            if (!highlighter) return;
            var doms = highlighter.getDoms(id);
            for (var i = 0; i < doms.length; i++) {
                if (hasNote) {
                    doms[i].setAttribute('data-oak-has-note', '1');
                } else {
                    doms[i].removeAttribute('data-oak-has-note');
                }
            }
        },

        /**
         * Scroll a highlight into view, flash it, and post its on-screen rect so
         * native can anchor the note editor to it. Payload matches `textSelected`.
         * @param {string} id Highlight ID
         */
        focusHighlight: function (id) {
            if (!highlighter) return;
            var doms = highlighter.getDoms(id);
            if (!doms || doms.length === 0) return;

            var el = doms[0];
            el.scrollIntoView({ behavior: 'smooth', block: 'center' });

            for (var i = 0; i < doms.length; i++) {
                (function (node) {
                    node.classList.add('oak-hl-flash');
                    setTimeout(function () { node.classList.remove('oak-hl-flash'); }, 1200);
                })(doms[i]);
            }

            // Post the rect after the smooth scroll settles so coords are final.
            setTimeout(function () { postFocus(id, el); }, 320);
        }
    };
})();
