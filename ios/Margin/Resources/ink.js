// Apple Pencil ink on a live page, for Margin's web preview.
// Pencil touches draw (fingers still scroll and tap); strokes live in the page,
// so they scroll with it. Each mark reports the element it circled.
(() => {
  if (window.__marginInk) return;
  const NS = "http://www.w3.org/2000/svg";
  const layer = document.createElementNS(NS, "svg");
  layer.setAttribute("aria-hidden", "true");
  layer.setAttribute("width", "1");
  layer.setAttribute("height", "1");
  layer.style.cssText = "position:absolute;left:0;top:0;overflow:visible;pointer-events:none;z-index:2147483647";
  const post = (m) => { try { window.webkit.messageHandlers.marginInk.postMessage(m); } catch (e) {} };
  const attach = () => { if (!layer.isConnected) document.documentElement.appendChild(layer); };

  let marks = [];        // {n, nodes: [svg elements], box}
  let stroke = null;     // {path, pts}
  let lastEnd = 0;

  const pen = (e) => [...e.changedTouches].find((t) => t.touchType === "stylus");

  const describe = (el) => {
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && parts.length < 4; n = n.parentElement) {
      if (n.id) { parts.unshift("#" + CSS.escape(n.id)); break; }
      let s = n.tagName.toLowerCase() + [...n.classList].slice(0, 2).map((c) => "." + CSS.escape(c)).join("");
      const same = n.parentElement ? [...n.parentElement.children].filter((c) => c.tagName === n.tagName) : [];
      if (same.length > 1) s += ":nth-of-type(" + (same.indexOf(n) + 1) + ")";
      parts.unshift(s);
    }
    const text = (el.innerText || el.getAttribute("aria-label") || el.alt || el.value || "").trim().replace(/\s+/g, " ");
    return { selector: parts.join(" > "), tag: el.tagName.toLowerCase(), text: text.slice(0, 100),
             href: el.closest("a") ? el.closest("a").getAttribute("href") : null };
  };

  const draw = () => {
    stroke.path.setAttribute("d", stroke.pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" "));
  };

  document.addEventListener("touchstart", (e) => {
    const t = pen(e);
    if (!t) return;
    e.preventDefault();
    attach();
    const path = document.createElementNS(NS, "path");
    path.setAttribute("fill", "none");
    path.setAttribute("stroke", "#e0262b");
    path.setAttribute("stroke-width", "4");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    layer.appendChild(path);
    stroke = { path, pts: [[t.pageX, t.pageY]] };
    draw();
  }, { passive: false, capture: true });

  document.addEventListener("touchmove", (e) => {
    const t = pen(e);
    if (!t || !stroke) return;
    e.preventDefault();
    stroke.pts.push([t.pageX, t.pageY]);
    draw();
  }, { passive: false, capture: true });

  const end = (e) => {
    if (!pen(e) || !stroke) return;
    e.preventDefault();
    const xs = stroke.pts.map((p) => p[0]), ys = stroke.pts.map((p) => p[1]);
    const box = { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
    const now = Date.now();
    const prev = marks[marks.length - 1];
    // Strokes in quick succession (a circle then an arrow) are one mark.
    if (prev && now - lastEnd < 900) {
      prev.nodes.push(stroke.path);
    } else {
      const n = marks.length + 1;
      const label = document.createElementNS(NS, "text");
      label.setAttribute("x", (box.x - 6).toFixed(0));
      label.setAttribute("y", (box.y - 6).toFixed(0));
      label.setAttribute("fill", "#e0262b");
      label.setAttribute("font", "bold 18px -apple-system, system-ui, sans-serif");
      label.setAttribute("font-weight", "700");
      label.setAttribute("font-size", "18");
      label.textContent = String(n);
      layer.appendChild(label);
      const cx = box.x + box.w / 2 - window.scrollX, cy = box.y + box.h / 2 - window.scrollY;
      const el = document.elementFromPoint(cx, cy) || document.body;
      marks.push({ n, nodes: [stroke.path, label] });
      post(Object.assign({ type: "mark", n, path: location.pathname + location.search }, describe(el)));
    }
    lastEnd = now;
    stroke = null;
  };
  document.addEventListener("touchend", end, { passive: false, capture: true });
  document.addEventListener("touchcancel", end, { passive: false, capture: true });

  post({ type: "context", secure: window.isSecureContext });

  window.__marginInk = {
    undo() {
      const m = marks.pop();
      if (m) m.nodes.forEach((n) => n.remove());
      post({ type: "undo" });
    },
    clear() {
      marks.forEach((m) => m.nodes.forEach((n) => n.remove()));
      marks = [];
      post({ type: "clear" });
    },
  };
})();
