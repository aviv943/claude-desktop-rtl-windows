// ===========================================================================
// Claude RTL Patch — Smart RTL Detection & Alignment
//
// Original author: @shraga100
// Source: https://github.com/shraga100/claude-desktop-rtl-patch
// Windows port: https://github.com/soguy/claude-desktop-rtl-mac
//
// This script auto-detects Hebrew/Arabic text in Claude Desktop and sets
// proper RTL direction on elements. It handles:
//   - Chat input box: live direction switching as you type
//   - Claude's responses: processes during streaming via MutationObserver
//   - Code blocks: forced LTR regardless of surrounding text
//   - Direction decision: a word-count MAJORITY vote per block (modeled on
//     Google's goog.i18n.bidi.estimateDirection), biased toward RTL, so a
//     Hebrew sentence that merely opens with an English term ("React הוא…")
//     still reads right-to-left. Mixed English/Hebrew runs inside a block are
//     left to the browser's Unicode Bidi Algorithm instead of being split
//     into per-line pieces (which used to look broken).
//
// The code is prepended to Electron renderer JS files inside app.asar.
// It runs as an IIFE and only activates when `document` is available.
// ===========================================================================

// --- CLAUDE RTL PATCH START ---
;(function() {
    'use strict';
    if (typeof document === 'undefined') return;
    try {
        var WRITING_SEL = '[data-testid="chat-input"]';

        // Share of strongly-directional words that must be RTL for a block to be
        // treated as RTL. Deliberately below 0.5: a Hebrew sentence sprinkled
        // with English technical terms should still read right-to-left.
        var RTL_THRESHOLD = 0.4;

        function isRTL(c) {
            var code = c.charCodeAt(0);
            return (code >= 0x0590 && code <= 0x05FF) ||
                   (code >= 0x0600 && code <= 0x06FF) ||
                   (code >= 0x0750 && code <= 0x077F) ||
                   (code >= 0x08A0 && code <= 0x08FF);
        }

        function hasRTL(text) {
            if (!text) return false;
            for (var i = 0; i < text.length; i++) { if (isRTL(text[i])) return true; }
            return false;
        }

        // Collect an element's text but skip <code>/<pre> so code never sways the
        // language vote (it is also forced LTR separately).
        function textWithoutCode(el) {
            var out = '';
            var nodes = el.childNodes;
            for (var i = 0; i < nodes.length; i++) {
                var n = nodes[i];
                if (n.nodeType === 3) { out += n.textContent; }
                else if (n.nodeType === 1 && n.tagName !== 'CODE' && n.tagName !== 'PRE') {
                    out += textWithoutCode(n);
                }
            }
            return out;
        }

        // Word-count majority direction (à la goog.i18n.bidi.estimateDirection).
        // Each whitespace-separated word votes by the script it contains: a word
        // holding any Hebrew/Arabic letter counts RTL, otherwise a word holding
        // any Latin letter counts LTR; pure numbers / punctuation / emoji abstain.
        // Returns 'rtl', 'ltr', or null when there are no directional words.
        function blockDir(text) {
            if (!text) return null;
            var words = text.split(/\s+/);
            var rtl = 0, ltr = 0;
            for (var i = 0; i < words.length; i++) {
                var w = words[i];
                if (!w) continue;
                var isR = false, isL = false;
                for (var j = 0; j < w.length; j++) {
                    if (isRTL(w[j])) { isR = true; break; }
                    if (/[A-Za-z]/.test(w[j])) { isL = true; }
                }
                if (isR) rtl++;
                else if (isL) ltr++;
            }
            var total = rtl + ltr;
            if (total === 0) return null;
            return (rtl / total) >= RTL_THRESHOLD ? 'rtl' : 'ltr';
        }

        // Direction of a plain string (chat input box, inline containers).
        function detectTextDir(text) { return blockDir(text); }

        function qsa(root, sel) {
            var base = root.querySelectorAll ? root : document;
            var els = Array.from(base.querySelectorAll(sel));
            if (root.matches && root.matches(sel)) els.unshift(root);
            return els;
        }

        function forceCodeLTR(root) {
            qsa(root, 'pre, .code-block__code, .relative.group\\/copy').forEach(function(b) {
                b.dir = 'ltr'; b.style.textAlign = 'left'; b.style.unicodeBidi = 'embed';
            });
            qsa(root, 'code').forEach(function(c) {
                if (!c.closest('pre') && !c.closest('.code-block__code')) c.dir = 'ltr';
            });
        }

        // Apply a block's majority direction, then let native bidi handle the
        // mixed runs inside it. RTL wins outright; LTR is only forced when the
        // element is currently rendering RTL (e.g. it inherited RTL from a parent
        // or we set it earlier and the text has since changed) so we don't stamp
        // dir across Claude's whole English UI.
        function applyBlockDir(el) {
            var dir = blockDir(textWithoutCode(el));
            if (dir === 'rtl') {
                el.dir = 'rtl';
                el.style.direction = 'rtl';
            } else {
                if (window.getComputedStyle(el).direction === 'rtl') {
                    el.dir = 'ltr';
                    el.style.direction = 'ltr';
                } else {
                    if (el.hasAttribute('dir')) el.removeAttribute('dir');
                    el.style.direction = '';
                }
            }
        }

        function setListItemsDir(list, dir) {
            list.querySelectorAll(':scope > li').forEach(function(li) {
                li.dir = dir;
                li.style.direction = dir;
                li.style.listStylePosition = (dir === 'rtl') ? 'inside' : '';
            });
        }

        function clearListItems(list) {
            list.querySelectorAll(':scope > li').forEach(function(li) {
                if (li.hasAttribute('dir')) li.removeAttribute('dir');
                li.style.direction = '';
                li.style.listStylePosition = '';
            });
        }

        function processText(root) {
            // Lists pick ONE direction for the whole list (whole-list majority)
            // and apply it to every item, so bullets/numbers never flip
            // item-by-item.
            qsa(root, 'ul, ol').forEach(function(list) {
                if (list.closest(WRITING_SEL) || list.closest('pre')) return;
                var dir = blockDir(textWithoutCode(list));
                if (dir === 'rtl') {
                    list.dir = 'rtl';
                    list.style.direction = 'rtl';
                    var pl = getComputedStyle(list).paddingLeft;
                    if (parseFloat(pl) > 0) { list.style.paddingRight = pl; list.style.paddingLeft = '0'; }
                    setListItemsDir(list, 'rtl');
                } else if (dir === 'ltr' && window.getComputedStyle(list).direction === 'rtl') {
                    list.dir = 'ltr';
                    list.style.direction = 'ltr';
                    list.style.paddingRight = ''; list.style.paddingLeft = '';
                    setListItemsDir(list, 'ltr');
                } else {
                    if (list.hasAttribute('dir')) list.removeAttribute('dir');
                    list.style.direction = '';
                    list.style.paddingRight = ''; list.style.paddingLeft = '';
                    clearListItems(list);
                }
            });

            // Standalone block elements each decide by their own majority.
            // (List items are handled above, via their list.)
            qsa(root, 'p, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, label, dt, dd').forEach(function(el) {
                if (el.closest(WRITING_SEL) || el.closest('pre') || el.closest('.code-block__code')) return;
                applyBlockDir(el);
            });
        }

        function processContainers(root) {
            qsa(root, 'div, span, button, a, label').forEach(function(el) {
                if (el.closest('pre') || el.closest('code') || el.closest(WRITING_SEL)) return;
                if (el.querySelector('p, div, ul, ol, h1, h2, h3, h4, h5, h6, pre, table')) return;
                if (/^(P|LI|H[1-6]|BLOCKQUOTE|TD|TH|UL|OL)$/.test(el.tagName)) return;
                var text = (el.textContent || '').trim();
                if (text.length < 2) return;
                // Only touch containers that actually carry RTL text; leave the
                // English UI alone. Direction is the majority vote; native bidi
                // then orders any embedded opposite-script runs.
                if (hasRTL(text)) {
                    el.dir = blockDir(text) || 'rtl';
                    el.style.textAlign = 'start';
                } else if (el.hasAttribute('dir')) {
                    el.removeAttribute('dir');
                    el.style.textAlign = '';
                }
            });
        }

        function processInput() {
            document.querySelectorAll(WRITING_SEL).forEach(function(input) {
                var text = input.textContent || input.innerText || '';
                var dir = detectTextDir(text);
                if (dir === 'rtl') {
                    input.style.direction = 'rtl'; input.style.textAlign = 'right'; input.style.paddingRight = '25px';
                } else {
                    input.style.direction = 'ltr'; input.style.textAlign = 'left'; input.style.paddingRight = '';
                }
            });
        }

        function processAll() {
            processText(document);
            processContainers(document.body);
            processInput();
            forceCodeLTR(document.body);
        }

        function injectStyles() {
            if (document.getElementById('claude-rtl-styles')) return;
            var s = document.createElement('style');
            s.id = 'claude-rtl-styles';
            s.textContent = [
                'p:not([dir]),li:not([dir]),h1:not([dir]),h2:not([dir]),h3:not([dir]),h4:not([dir]),h5:not([dir]),h6:not([dir]),blockquote:not([dir]),td:not([dir]),th:not([dir]),summary:not([dir]),label:not([dir]),legend:not([dir]),dt:not([dir]),dd:not([dir]),figcaption:not([dir]),caption:not([dir]){unicode-bidi:plaintext!important;text-align:start!important}',
                'pre,.code-block__code,.relative.group\\/copy{unicode-bidi:embed!important;direction:ltr!important;text-align:left!important}',
                'code{unicode-bidi:isolate!important;direction:ltr!important}',
                '[dir]{text-align:start!important}[dir="rtl"]{direction:rtl!important}[dir="ltr"]{direction:ltr!important}',
                '[dir]>*:not([dir]):not(pre):not(code):not(.code-block__code){unicode-bidi:plaintext;text-align:start}'
            ].join('');
            document.head.appendChild(s);
        }

        function init() {
            injectStyles();
            processAll();

            document.addEventListener('input', function(e) {
                var t = e.target;
                if (!t || !(t.tagName === 'TEXTAREA' || t.tagName === 'INPUT' || t.isContentEditable)) return;
                var text = t.textContent || t.innerText || t.value || '';
                var dir = detectTextDir(text);
                if (dir === 'rtl') {
                    t.style.direction = 'rtl'; t.style.textAlign = 'right'; t.style.paddingRight = '25px';
                } else {
                    t.style.direction = 'ltr'; t.style.textAlign = 'left'; t.style.paddingRight = '';
                }
            }, true);

            var pendingMuts = [];
            var obs = new MutationObserver(function(muts) {
                var dominated = false;
                for (var i = 0; i < muts.length; i++) {
                    if (muts[i].addedNodes.length > 0 || muts[i].type === 'characterData') { dominated = true; break; }
                }
                if (!dominated) return;
                for (var j = 0; j < muts.length; j++) pendingMuts.push(muts[j]);
                if (window._rtlT) return;
                window._rtlT = setTimeout(function() {
                    window._rtlT = null;
                    var toProcess = pendingMuts;
                    pendingMuts = [];
                    var roots = new Set();
                    toProcess.forEach(function(m) {
                        m.addedNodes.forEach(function(n) { if (n.nodeType === 1) roots.add(n); });
                        if (m.type === 'characterData' && m.target.parentElement) roots.add(m.target.parentElement);
                    });
                    var expanded = new Set(roots);
                    roots.forEach(function(r) {
                        if (!r.closest) return;
                        var txt = r.closest('p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, label, dt, dd');
                        if (txt) expanded.add(txt);
                        var list = r.closest('ul, ol');
                        if (list) expanded.add(list);
                    });
                    roots = expanded;
                    if (roots.size > 0 && roots.size <= 30) {
                        roots.forEach(function(r) {
                            processText(r);
                            processContainers(r);
                            forceCodeLTR(r);
                        });
                        processInput();
                    } else {
                        processAll();
                    }
                }, 50);
            });
            obs.observe(document.body, { childList: true, subtree: true, characterData: true });
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else { init(); }
    } catch(e) { console.error('[Claude RTL]', e); }
})();
// --- CLAUDE RTL PATCH END ---
