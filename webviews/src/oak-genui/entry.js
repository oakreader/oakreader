// Runtime for model-written widgets ("genui"), shown in a WKWebView.
//
// ChatGPT iOS renders its model-written widgets ("DIL") the same way: a shared
// web runtime in a web view, driven by native messages (`dil-configure-widget`,
// `dil-set-theme`) and answering with `app-ready`, `dil-widget-height`,
// `dil-widget-action`, `dil-widget-error`. This runtime keeps that shape with
// OakReader's own format — a JSON component tree, close to ChatGPT's v1
// `model_dil` — because any model can write JSON, while ChatGPT's v2 programs
// need a server compiler and a sandboxed JS runner.
//
// Native → web: window.oakGenUI.configure({payload, theme, state, nativeHosts})
//               window.oakGenUI.setTheme("light" | "dark")
//               window.oakGenUI.reset()   — the web view goes back to the pool
// Web → native: {type: "app-ready" | "ready" | "height" | "action" | "state" | "error"
//                | "native-host" | "native-host-remove", ...}
//
// Native hosts: ChatGPT iOS draws charts natively over the web view
// (`DILNativeChartHostRequest`). A node whose kind the host lists in
// `nativeHosts` renders an empty slot here and reports the slot's rect and
// resolved props; the host draws over it. Without a host it falls back to SVG.
import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import htm from "htm";
import { evaluate, interpolate } from "./expr.js";

const html = htm.bind(React.createElement);

function post(message) {
  try {
    window.webkit?.messageHandlers?.oakGenUI?.postMessage(message);
  } catch {
    // No native host (opened in a browser for debugging): nothing to tell.
  }
}

// MARK: - Native hosts

let nativeKinds = new Set();
let hostSeq = 0;
const hosts = new Map();
const lastSent = new Map();

/** Report every slot whose rect or props changed since it was last sent. */
function reportHosts() {
  for (const [id, host] of hosts) {
    // A slot being unmounted is already out of the page: its rect is zero.
    if (!host.el?.isConnected) continue;
    const r = host.el.getBoundingClientRect();
    const message = {
      id,
      kind: host.kind,
      rect: { x: r.left + window.scrollX, y: r.top + window.scrollY, width: r.width, height: r.height },
      props: host.props,
    };
    const key = JSON.stringify(message);
    if (lastSent.get(id) !== key) {
      lastSent.set(id, key);
      post({ type: "native-host", ...message });
    }
  }
}

function NativeSlot({ kind, p, height }) {
  const ref = useRef(null);
  const [id] = useState(() => ++hostSeq);
  useLayoutEffect(() => {
    hosts.set(id, { el: ref.current, kind, props: p });
    reportHosts();
  });
  useEffect(() => () => {
    hosts.delete(id);
    lastSent.delete(id);
    post({ type: "native-host-remove", id });
  }, [id]);
  return html`<div ref=${ref} class="genui-native-slot" style=${{ height }}></div>`;
}

// MARK: - State

const PATH = /^state((?:\.[A-Za-z_][A-Za-z0-9_]*)+)$/;

/** `state.a.b` → ["a", "b"]; anything else is not writable. */
function writablePath(binding) {
  if (binding && typeof binding === "object" && typeof binding.$ === "string") {
    const m = PATH.exec(binding.$.trim());
    if (m) return m[1].slice(1).split(".");
  }
  if (typeof binding === "string" && /^[A-Za-z_][A-Za-z0-9_.]*$/.test(binding)) return binding.split(".");
  return null;
}

function setIn(obj, path, value) {
  if (path.length === 0) return value;
  const [head, ...rest] = path;
  const base = obj && typeof obj === "object" ? obj : {};
  return { ...base, [head]: setIn(base[head], rest, value) };
}

// MARK: - Props

function isBinding(v) {
  return v && typeof v === "object" && !Array.isArray(v) && typeof v.$ === "string" && Object.keys(v).length === 1;
}

/** Evaluate bindings and `{expr}` spans; leave actions and templates for later. */
function resolve(value, scope, key) {
  if (key === "onClick" || key === "onSubmit" || key === "onChange" || key === "template" || key === "else") return value;
  if (isBinding(value)) return evaluate(value.$, scope);
  if (typeof value === "string") return value.includes("{") ? interpolate(value, scope) : value;
  if (Array.isArray(value)) return value.map((v) => resolve(v, scope));
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = resolve(v, scope, k);
    return out;
  }
  return value;
}

/** A node's props: `props` merged over any props written on the node itself. */
function rawProps(node) {
  const { type, children, key, props, ...flat } = node; // eslint-disable-line no-unused-vars
  return { ...flat, ...(props || {}) };
}

// MARK: - Actions

function runAction(action, ctx, scope) {
  if (!action) return;
  if (Array.isArray(action)) {
    for (const a of action) runAction(a, ctx, scope);
    return;
  }
  if (typeof action !== "object") return;
  switch (action.type) {
    case "set": {
      const path = writablePath(action.path) ?? String(action.path || "").replace(/^state\./, "").split(".");
      if (!path[0]) return;
      const value = resolve(action.value, scope);
      ctx.update((s) => setIn(s, path, value));
      return;
    }
    case "send":
      post({ type: "action", action: { type: "send", text: interpolate(action.text ?? "", scope) }, state: ctx.state });
      return;
    case "open_url":
      post({ type: "action", action: { type: "open_url", url: interpolate(action.url ?? "", scope) } });
      return;
    case "copy":
      post({ type: "action", action: { type: "copy", text: interpolate(action.text ?? "", scope) } });
      return;
    default:
      post({ type: "error", message: `unsupported action: ${action.type}` });
  }
}

// MARK: - Components

const SIZES = { xs: 11, sm: 12, md: 14, lg: 16, xl: 20, "2xl": 24, "3xl": 30 };

function textStyle(p, fallbackSize) {
  return {
    fontSize: SIZES[p.size] ?? fallbackSize,
    fontWeight: p.weight === "bold" ? 600 : p.weight === "medium" ? 500 : p.weight === "semibold" ? 600 : undefined,
    color: p.color ? `var(--genui-${p.color}, ${p.color})` : undefined,
    textAlign: p.align,
    WebkitLineClamp: p.maxLines,
    display: p.maxLines ? "-webkit-box" : undefined,
    WebkitBoxOrient: p.maxLines ? "vertical" : undefined,
    overflow: p.maxLines ? "hidden" : undefined,
    fontVariantNumeric: p.tabularNums ? "tabular-nums" : undefined,
  };
}

/**
 * A spacing value as models write it: 16, "16", "16px", or a size name.
 * Anything else is undefined, so the caller's default applies — a CSS string
 * like "md" would otherwise be dropped by the browser and leave no space at all.
 */
const SPACE = { none: 0, xs: 4, sm: 8, md: 12, lg: 16, xl: 24, "2xl": 32 };
function space(v) {
  if (typeof v === "number" && Number.isFinite(v)) return Math.max(0, v);
  if (typeof v !== "string") return undefined;
  const t = v.trim().toLowerCase();
  if (t in SPACE) return SPACE[t];
  const n = /^(\d+(?:\.\d+)?)(px)?$/.exec(t);
  return n ? Number(n[1]) : undefined;
}

const ALIGN = { start: "flex-start", center: "center", end: "flex-end", stretch: "stretch" };
const JUSTIFY = { start: "flex-start", center: "center", end: "flex-end", between: "space-between", around: "space-around" };

function boxStyle(p, direction) {
  return {
    display: "flex",
    flexDirection: direction,
    gap: space(p.gap) ?? 8,
    alignItems: ALIGN[p.align] ?? (direction === "row" ? "center" : "stretch"),
    justifyContent: JUSTIFY[p.justify],
    flexWrap: p.wrap ? "wrap" : undefined,
    padding: space(p.padding),
    background: p.background ? `var(--genui-bg-${p.background}, ${p.background})` : undefined,
    borderRadius: p.radius,
    flex: p.flex,
    width: p.width,
  };
}

function Children({ nodes, scope }) {
  return (nodes || []).map((child, i) => html`<${Node} key=${child?.key ?? i} node=${child} scope=${scope} />`);
}

function Field({ label, children }) {
  return label ? html`<label class="genui-field"><span class="genui-label">${label}</span>${children}</label>` : children;
}

function Chart({ p }) {
  const data = Array.isArray(p.data) ? p.data : [];
  const series = Array.isArray(p.series) && p.series.length ? p.series : [{ key: p.yKey ?? "value" }];
  const height = p.height ?? 180;
  const width = 600;
  const pad = { l: 36, r: 8, t: 8, b: 22 };
  const values = data.flatMap((d) => series.map((s) => Number(d[s.key]))).filter(Number.isFinite);
  const max = Math.max(0, ...values);
  const min = Math.min(0, ...values);
  const span = max - min || 1;
  const x = (i) => pad.l + (data.length <= 1 ? 0 : (i * (width - pad.l - pad.r)) / (data.length - 1));
  const y = (v) => pad.t + ((max - v) * (height - pad.t - pad.b)) / span;
  const colors = ["var(--genui-chart-1)", "var(--genui-chart-2)", "var(--genui-chart-3)", "var(--genui-chart-4)"];
  const kind = p.kind ?? "line";
  const band = (width - pad.l - pad.r) / Math.max(data.length, 1);
  return html`<figure class="genui-chart">
    <svg viewBox=${`0 0 ${width} ${height}`} preserveAspectRatio="none" style=${{ height }}>
      <line x1=${pad.l} x2=${width - pad.r} y1=${y(0)} y2=${y(0)} class="genui-axis" />
      <text x=${pad.l - 6} y=${y(max) + 4} class="genui-tick" text-anchor="end">${formatTick(max)}</text>
      <text x=${pad.l - 6} y=${y(min) + 4} class="genui-tick" text-anchor="end">${formatTick(min)}</text>
      ${series.map((s, si) => {
        const color = s.color ?? colors[si % colors.length];
        if (kind === "bar") {
          const w = (band * 0.7) / series.length;
          return data.map((d, i) => {
            const v = Number(d[s.key]) || 0;
            return html`<rect key=${`${si}-${i}`} x=${pad.l + i * band + band * 0.15 + si * w} y=${Math.min(y(v), y(0))}
              width=${w} height=${Math.abs(y(v) - y(0))} rx="2" fill=${color} />`;
          });
        }
        const pts = data.map((d, i) => `${x(i)},${y(Number(d[s.key]) || 0)}`).join(" ");
        return html`<g key=${si}>
          ${kind === "area" ? html`<polygon points=${`${x(0)},${y(0)} ${pts} ${x(data.length - 1)},${y(0)}`} fill=${color} opacity="0.15" />` : null}
          <polyline points=${pts} fill="none" stroke=${color} stroke-width="2" vector-effect="non-scaling-stroke" />
        </g>`;
      })}
    </svg>
    <div class="genui-xlabels">
      ${data.length > 0 ? html`<span>${String(data[0][p.xKey] ?? "")}</span><span>${String(data[data.length - 1][p.xKey] ?? "")}</span>` : null}
    </div>
    ${series.length > 1 || series[0].label ? html`<figcaption class="genui-legend">
      ${series.map((s, si) => html`<span key=${si}><i style=${{ background: s.color ?? colors[si % colors.length] }}></i>${s.label ?? s.key}</span>`)}
    </figcaption>` : null}
  </figure>`;
}

function formatTick(v) {
  return Math.abs(v) >= 1000 ? new Intl.NumberFormat(undefined, { notation: "compact" }).format(v) : String(Math.round(v * 100) / 100);
}

function PieChart({ p }) {
  const data = Array.isArray(p.data) ? p.data : [];
  const valueKey = p.valueKey ?? "value";
  const labelKey = p.labelKey ?? "label";
  const total = data.reduce((a, d) => a + (Number(d[valueKey]) || 0), 0) || 1;
  const r = 80;
  const inner = Math.min(Math.max(Number(p.innerRadius ?? 0), 0), 0.9) * r;
  const colors = ["var(--genui-chart-1)", "var(--genui-chart-2)", "var(--genui-chart-3)", "var(--genui-chart-4)", "var(--genui-chart-5)"];
  let angle = -Math.PI / 2;
  const arcs = data.map((d, i) => {
    const sweep = ((Number(d[valueKey]) || 0) / total) * Math.PI * 2;
    const a0 = angle;
    const a1 = (angle += sweep);
    const large = sweep > Math.PI ? 1 : 0;
    const pt = (rad, a) => `${100 + rad * Math.cos(a)},${100 + rad * Math.sin(a)}`;
    const dPath = inner > 0
      ? `M${pt(r, a0)} A${r},${r} 0 ${large} 1 ${pt(r, a1)} L${pt(inner, a1)} A${inner},${inner} 0 ${large} 0 ${pt(inner, a0)} Z`
      : `M100,100 L${pt(r, a0)} A${r},${r} 0 ${large} 1 ${pt(r, a1)} Z`;
    return html`<path key=${i} d=${dPath} fill=${d.color ?? colors[i % colors.length]} />`;
  });
  return html`<figure class="genui-pie">
    <svg viewBox="0 0 200 200" width="160" height="160">${arcs}</svg>
    <figcaption class="genui-legend genui-legend-col">
      ${data.map((d, i) => html`<span key=${i}><i style=${{ background: d.color ?? colors[i % colors.length] }}></i>${String(d[labelKey] ?? "")}</span>`)}
    </figcaption>
  </figure>`;
}

function Timer({ p }) {
  const total = Math.max(0, Number(p.seconds) || 0);
  const [left, setLeft] = useState(total);
  const [running, setRunning] = useState(Boolean(p.autostart));
  useEffect(() => {
    if (!running) return undefined;
    const id = setInterval(() => setLeft((s) => (s <= 1 ? (setRunning(false), 0) : s - 1)), 1000);
    return () => clearInterval(id);
  }, [running]);
  const mm = String(Math.floor(left / 60)).padStart(2, "0");
  const ss = String(left % 60).padStart(2, "0");
  return html`<div class="genui-timer">
    ${p.label ? html`<span class="genui-label">${p.label}</span>` : null}
    <span class="genui-timer-face">${mm}:${ss}</span>
    <div class="genui-row">
      <button class="genui-button genui-soft" onClick=${() => setRunning((r) => !r)}>${running ? "Pause" : "Start"}</button>
      <button class="genui-button genui-ghost" onClick=${() => { setRunning(false); setLeft(total); }}>Reset</button>
    </div>
  </div>`;
}

function Node({ node, scope }) {
  const ctx = scope.__ctx;
  if (node == null || node === false) return null;
  if (typeof node === "string" || typeof node === "number") {
    return html`<span>${typeof node === "string" ? interpolate(node, scope) : node}</span>`;
  }
  if (typeof node !== "object" || Array.isArray(node)) return null;

  let p;
  try {
    p = resolve(rawProps(node), scope);
  } catch (error) {
    // ChatGPT's soft recovery mode `drop-node`: one bad binding hides its node,
    // not the whole widget.
    post({ type: "error", message: `${node.type}: ${error.message}` });
    return null;
  }
  const raw = rawProps(node);
  const kids = node.children;
  const bindPath = writablePath(raw.value) ?? writablePath(raw.checked) ?? writablePath(raw.bind);
  const write = (v) => bindPath && ctx.update((s) => setIn(s, bindPath, v));
  const act = (name) => () => runAction(raw[name], ctx, scope);

  switch (node.type) {
    case "col":
    case "row":
      return html`<div style=${boxStyle(p, node.type === "row" ? "row" : "column")}><${Children} nodes=${kids} scope=${scope} /></div>`;
    case "card":
      // A card's content never touches its border, whatever padding was asked for.
      return html`<section class="genui-card" style=${{ padding: Math.max(space(p.padding) ?? 16, 12), gap: space(p.gap) ?? 10 }}>
        ${p.title ? html`<h3 class="genui-card-title">${p.title}</h3>` : null}
        <${Children} nodes=${kids} scope=${scope} />
      </section>`;
    case "grid":
      return html`<div class="genui-grid" style=${{ gridTemplateColumns: `repeat(${p.columns ?? 2}, minmax(0, 1fr))`, gap: space(p.gap) ?? 8 }}>
        <${Children} nodes=${kids} scope=${scope} />
      </div>`;
    case "divider":
      return html`<hr class="genui-divider" style=${{ margin: `${space(p.spacing) ?? 4}px 0` }} />`;
    case "spacer":
      return html`<div style=${{ flex: 1, minWidth: p.minSize, minHeight: p.minSize }}></div>`;
    case "text":
      return html`<p class="genui-text" style=${textStyle(p, 14)}>${p.value ?? p.text}<${Children} nodes=${kids} scope=${scope} /></p>`;
    case "title":
      return html`<h3 class="genui-title" style=${textStyle(p, SIZES.lg)}>${p.value ?? p.text}<${Children} nodes=${kids} scope=${scope} /></h3>`;
    case "caption":
      return html`<p class="genui-caption" style=${textStyle(p, 12)}>${p.value ?? p.text}<${Children} nodes=${kids} scope=${scope} /></p>`;
    case "markdown":
      return html`<p class="genui-text genui-pre">${p.value ?? p.text}</p>`;
    case "badge":
      return html`<span class=${`genui-badge genui-badge-${p.color ?? "secondary"}`}>${p.label ?? p.value}</span>`;
    case "image":
      return html`<img class="genui-image" src=${p.src} alt=${p.alt ?? ""}
        style=${{ aspectRatio: p.aspectRatio, objectFit: p.fit ?? "cover", borderRadius: p.radius ?? 12, width: p.width ?? "100%" }}
        onError=${(e) => { e.currentTarget.style.display = "none"; }} />`;
    case "button":
      return html`<button class=${`genui-button genui-${p.variant ?? "solid"} genui-color-${p.color ?? "primary"}`}
        disabled=${Boolean(p.disabled)} onClick=${act("onClick")}>${p.label ?? p.value}</button>`;
    case "input":
      return html`<${Field} label=${p.label}><input class="genui-input" type=${p.inputType ?? "text"} placeholder=${p.placeholder ?? ""}
        value=${p.value ?? ""} onInput=${(e) => write(p.inputType === "number" ? (e.target.value === "" ? "" : Number(e.target.value)) : e.target.value)} /><//>`;
    case "textarea":
      return html`<${Field} label=${p.label}><textarea class="genui-input" rows=${p.rows ?? 3} placeholder=${p.placeholder ?? ""}
        value=${p.value ?? ""} onInput=${(e) => write(e.target.value)}></textarea><//>`;
    case "select":
      return html`<${Field} label=${p.label}><select class="genui-input" value=${p.value ?? ""} onChange=${(e) => write(optionValue(p.options, e.target.value))}>
        ${(p.options || []).map((o, i) => html`<option key=${i} value=${String(optValue(o))}>${optLabel(o)}</option>`)}
      </select><//>`;
    case "segmented":
      return html`<${Field} label=${p.label}><div class="genui-segmented" role="radiogroup">
        ${(p.options || []).map((o, i) => html`<button key=${i} role="radio" aria-checked=${optValue(o) === p.value}
          class=${optValue(o) === p.value ? "is-on" : ""} onClick=${() => write(optValue(o))}>${optLabel(o)}</button>`)}
      </div><//>`;
    case "checkbox":
      return html`<label class="genui-check"><input type="checkbox" checked=${Boolean(p.checked)} onChange=${(e) => write(e.target.checked)} />${p.label}</label>`;
    case "slider":
      return html`<${Field} label=${p.label}><div class="genui-row">
        <input class="genui-slider" type="range" min=${p.min ?? 0} max=${p.max ?? 100} step=${p.step ?? 1}
          value=${p.value ?? 0} onInput=${(e) => write(Number(e.target.value))} />
        <span class="genui-slider-value">${p.value ?? 0}</span>
      </div><//>`;
    case "date-picker":
      return html`<${Field} label=${p.label}><input class="genui-input" type="date" value=${p.value ?? ""} onInput=${(e) => write(e.target.value)} /><//>`;
    case "form":
      return html`<form class="genui-form" onSubmit=${(e) => { e.preventDefault(); act("onSubmit")(); }}>
        <${Children} nodes=${kids} scope=${scope} />
        <button class="genui-button genui-solid genui-color-primary" type="submit">${p.submitLabel ?? "Submit"}</button>
      </form>`;
    case "table": {
      const columns = Array.isArray(p.columns) ? p.columns : [];
      const rows = Array.isArray(p.rows) ? p.rows : [];
      return html`<div class="genui-table-wrap"><table class="genui-table">
        <thead><tr>${columns.map((c, i) => html`<th key=${i} style=${{ textAlign: c.align }}>${c.label ?? c.key}</th>`)}</tr></thead>
        <tbody>${rows.map((r, ri) => html`<tr key=${ri}>${columns.map((c, ci) => html`<td key=${ci} style=${{ textAlign: c.align }}>${String(r?.[c.key] ?? "")}</td>`)}</tr>`)}</tbody>
      </table></div>`;
    }
    case "chart":
      return nativeKinds.has("chart")
        ? html`<${NativeSlot} kind="chart" p=${p} height=${(p.height ?? 180) + 28} />`
        : html`<${Chart} p=${p} />`;
    case "pie-chart":
      return nativeKinds.has("pie-chart")
        ? html`<${NativeSlot} kind="pie-chart" p=${p} height=${p.height ?? 180} />`
        : html`<${PieChart} p=${p} />`;
    case "map":
      return nativeKinds.has("map")
        ? html`<${NativeSlot} kind="map" p=${p} height=${p.height ?? 220} />`
        : html`<ul class="genui-text">${(p.markers || []).map((m, i) => html`<li key=${i}>${m.title ?? `${m.lat}, ${m.lng}`}</li>`)}</ul>`;
    case "timer":
      return html`<${Timer} p=${p} />`;
    case "each": {
      const items = Array.isArray(p.items) ? p.items : [];
      const name = p.as ?? "item";
      const template = raw.template ?? (Array.isArray(kids) && kids.length === 1 ? kids[0] : { type: "col", children: kids });
      return items.map((item, index) => html`<${Node} key=${item?.id ?? index} node=${template}
        scope=${{ ...scope, [name]: item, index }} />`);
    }
    case "show":
      return p.when
        ? html`<${Children} nodes=${kids} scope=${scope} />`
        : raw.else ? html`<${Node} node=${raw.else} scope=${scope} />` : null;
    case "loading":
      return html`<div class="genui-loading" style=${{ width: p.width ?? "100%", height: p.height ?? 16 }}></div>`;
    default:
      // ChatGPT's `targeted-text-fallback`: an unknown node keeps its children.
      post({ type: "error", message: `unknown node type: ${node.type}` });
      return kids ? html`<${Children} nodes=${kids} scope=${scope} />` : null;
  }
}

const optValue = (o) => (o && typeof o === "object" ? o.value : o);
const optLabel = (o) => (o && typeof o === "object" ? o.label ?? String(o.value) : String(o));
const optionValue = (options, raw) => {
  const hit = (options || []).find((o) => String(optValue(o)) === raw);
  return hit === undefined ? raw : optValue(hit);
};

// MARK: - Root

function Widget({ payload, initialState }) {
  const [state, setState] = useState(() => ({ ...(payload.state || {}), ...(initialState || {}) }));
  const ctx = useMemo(() => ({ update: null, state: null }), []);
  ctx.update = (fn) => setState((s) => {
    const next = fn(s);
    post({ type: "state", state: next });
    return next;
  });
  ctx.state = state;
  const scope = { state, __ctx: ctx };
  return html`<div class="genui-root"><${Node} node=${payload.root} scope=${scope} /></div>`;
}

function App() {
  const [config, setConfig] = useState(null);
  const ref = useRef(null);

  useEffect(() => {
    window.oakGenUI = {
      configure(next) {
        nativeKinds = new Set(Array.isArray(next.nativeHosts) ? next.nativeHosts : []);
        setConfig(next);
        document.documentElement.dataset.theme = next.theme === "dark" ? "dark" : "light";
      },
      reset() {
        setConfig(null);
      },
      setTheme(theme) {
        document.documentElement.dataset.theme = theme === "dark" ? "dark" : "light";
      },
    };
    post({ type: "app-ready" });
  }, []);

  useLayoutEffect(() => {
    if (!ref.current) return undefined;
    let last = -1;
    const report = () => {
      const height = Math.ceil(ref.current.getBoundingClientRect().height);
      if (height !== last) {
        last = height;
        post({ type: "height", height });
      }
      // A slot moves when content above it changes size, without resizing itself.
      reportHosts();
    };
    const observer = new ResizeObserver(report);
    observer.observe(ref.current);
    report();
    if (config) post({ type: "ready" });
    return () => observer.disconnect();
  }, [config]);

  if (!config) return html`<div ref=${ref}></div>`;
  const payload = config.payload;
  if (!payload || typeof payload !== "object" || !payload.root) {
    post({ type: "error", message: "payload has no root", fatal: true });
    return html`<div ref=${ref}></div>`;
  }
  return html`<div ref=${ref}><${Widget} payload=${payload} initialState=${config.state} /></div>`;
}

window.addEventListener("error", (e) => post({ type: "error", message: String(e.message), fatal: true }));
createRoot(document.getElementById("root")).render(html`<${App} />`);
