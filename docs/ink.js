// Maple's ink on the page: answers set in Maple Hand's traced strokes (hand.js) and written back in at the app's pace
// (Written.swift: 0.04 s a letter, within 0.9–2 s, one even stroke along all the ink).
const NS = 'http://www.w3.org/2000/svg';
const CAP = .7;           // calibration knob: cap height in em, to sit beside the Maple Hand font
const BASE = 1.0;         // baseline below the line's top, in em
const LINE = 1.35;        // line height, in em
const PERSON = 1.3;       // calibration knob: the person's hand (Caveat) runs small for its cap height, so it's set this much larger
const SUB = {'₀': '0', '₁': '1', '₂': '2', 'ₛ': 's'}, SUP = {'²': '2'}, SAME = {'−': '-', '…': '...', '’': "'", '‘': "'", '“': '"', '”': '"'};
let anims = [];
const measure = document.createElement('canvas').getContext('2d');

// Characters with their size and shift; <sup> raises its letters.
function chars(node, k = 1, dy = 0, out = [], struck = false) {
  for (const n of node.childNodes) {
    if (n.nodeType === 3) {
      for (const raw of n.textContent.replace(/\s+/g, ' ')) {
        const c = SAME[raw] ?? raw;
        if (SUB[c]) out.push({c: SUB[c], k: k * .62, dy: dy + .22, struck});
        else if (SUP[c]) out.push({c: SUP[c], k: k * .62, dy: dy - .42, struck});
        else if (c === '·') out.push({c: '.', k, dy: dy - .28, struck});
        else for (const d of c) out.push({c: d, k, dy, struck});
      }
    } else if (n.classList?.contains('reply')) continue;  // Maple's answer inside your line is its own ink
    else if (n.nodeName === 'SUP') chars(n, k * .62, dy - .42, out, struck);
    else chars(n, k, dy, out, struck || n.classList?.contains('struck'));
  }
  return out;
}

// Lays characters into lines no wider than maxW, in Maple's hand or another; returns an <svg> of strokes and the strokes
// in writing order.
function set(list, fs, maxW, color, hand = window.MAPLE_HAND, weight = .075, scale = 1) {
  const s = fs * CAP * scale / 21, H = hand;
  measure.font = `${fs}px "Maple Hand", cursive`;
  for (const ch of list) {
    ch.g = H[ch.c];
    ch.w = (ch.c === '□' ? .7 * fs : ch.g ? ch.g.r * s : measure.measureText(ch.c).width) * ch.k;
  }
  const words = [];
  for (const ch of list) (ch.c === ' ' || !words.length ? words.push([ch]) : words.at(-1).push(ch));
  let x = 0, line = 0, width = 0;
  for (const word of words) {
    const lead = word[0].c === ' ' ? word[0].w : 0, w = word.reduce((a, ch) => a + ch.w, 0);
    if (x > 0 && x + w > maxW) { line++; x = -lead; }
    for (const ch of word) { ch.x = x; ch.line = line; x += ch.w; }
    width = Math.max(width, x);
  }
  const svg = document.createElementNS(NS, 'svg'), strokes = [];
  const height = (line + 1) * LINE * fs;
  svg.setAttribute('class', 'hand');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('width', Math.ceil(width + 2));
  svg.setAttribute('height', Math.ceil(height));
  svg.setAttribute('viewBox', `-1 0 ${Math.ceil(width + 2)} ${Math.ceil(height)}`);
  const g = document.createElementNS(NS, 'g');
  g.setAttribute('fill', 'none');
  g.setAttribute('stroke', color);
  g.setAttribute('stroke-width', (fs * weight).toFixed(2));
  g.setAttribute('stroke-linecap', 'round');
  g.setAttribute('stroke-linejoin', 'round');
  for (const ch of list) {
    const base = ch.line * LINE * fs + BASE * fs + ch.dy * fs;
    if (ch.c === '□') strokes.push(square(g, ch.x + .1 * fs, base, .46 * fs * ch.k));
    else if (ch.g) strokes.push(...glyph(g, ch.g, ch.x, base, s * ch.k));
    else if (ch.c !== ' ') strokes.push(letter(g, ch.c, ch.x, base, fs * ch.k, color));
  }
  svg.append(g);
  // Struck words: one coral line through them, as the edit brush left it.
  const runs = [];
  list.forEach((ch, i) => { if (ch.struck && ch.c !== ' ') (list[i - 1]?.struck && runs.at(-1)?.line === ch.line ? runs.at(-1).to = ch : runs.push({from: ch, to: ch, line: ch.line})); });
  for (const r of runs) {
    const y = r.line * LINE * fs + BASE * fs - fs * .26, line = document.createElementNS(NS, 'path');
    line.setAttribute('d', `M${r.from.x - 2} ${y + 1}Q${(r.from.x + r.to.x + r.to.w) / 2} ${y - 2} ${r.to.x + r.to.w + 2} ${y}`);
    Object.entries({fill: 'none', stroke: 'var(--color-coral)', 'stroke-width': 2.2, 'stroke-linecap': 'round', opacity: .8}).forEach(([k, v]) => line.setAttribute(k, v));
    svg.append(line);
  }
  return {svg, strokes, height, baseline: BASE * fs};
}

function glyph(parent, gl, x, base, s) {
  return gl.l.map(pts => {
    const p = document.createElementNS(NS, 'path');
    let d = pts.map(([u, v], i) => `${i ? 'L' : 'M'}${(x + u * s).toFixed(1)} ${(base + (v - 9) * s).toFixed(1)}`).join('');
    if (pts.length === 1) d += 'l.1 0';
    p.setAttribute('d', d);
    parent.append(p);
    return p;
  });
}

// An empty box, drawn the way a hand does: one stroke round, its end running a little past the start.
function square(parent, x, base, side) {
  const p = document.createElementNS(NS, 'path'), y = base - side;
  p.setAttribute('d', `M${x} ${y + .6}L${x + side} ${y}L${x + side + .4} ${base}L${x - .3} ${base + .3}L${x + .2} ${y - .8}`);
  parent.append(p);
  return p;
}

// A character Maple Hand has no strokes for (θ, π, ≈): the font's letter, faded in at its turn.
function letter(parent, c, x, base, size, color) {
  const t = document.createElementNS(NS, 'text');
  Object.entries({x, y: base, fill: color, stroke: 'none', 'font-size': size, 'font-family': 'Maple Hand, cursive'}).forEach(([k, v]) => t.setAttribute(k, v));
  t.textContent = c;
  parent.append(t);
  return t;
}

// SVG <text> inside a drawing, swapped for strokes in place.
function strokeText(t, hand = window.MAPLE_HAND, scale = 1) {
  const fs = +t.getAttribute('font-size') || +t.closest('[font-size]')?.getAttribute('font-size') || 14;
  const anchor = t.getAttribute('text-anchor') || t.closest('[text-anchor]')?.getAttribute('text-anchor') || 'start';
  const color = getComputedStyle(t).fill;
  const {svg, strokes} = set(chars(t), fs, Infinity, color, hand, .075, scale);
  const w = +svg.getAttribute('width') - 2;
  const x = +t.getAttribute('x') + (+t.getAttribute('dx') || 0) - (anchor === 'middle' ? w / 2 : anchor === 'end' ? w : 0);
  const g = svg.firstChild;
  g.setAttribute('transform', `translate(${x} ${+t.getAttribute('y') - BASE * fs})`);
  g.setAttribute('stroke-width', Math.max(1.1, fs * .075).toFixed(2));
  t.replaceWith(g);
  return strokes;
}

const len = el => el.getTotalLength?.() || 30;
const writing = letters => Math.min(Math.max(letters * .04, .9), 2);

// One job per answer in a card, written one after another: [{seconds, run(at, cycle)}].
function jobs(el, animate) {
  el.dataset.src ??= el.innerHTML;
  el.innerHTML = el.dataset.src;
  if (el.classList.contains('paint')) return paint(el, animate);
  if (el.tagName.toLowerCase() === 'svg') {
    const marks = [];
    for (const n of el.querySelectorAll('path, rect, circle, line, polyline, text')) {
      if (n.tagName === 'text') { marks.push(...strokeText(n).map(p => ({n: p, ink: true}))); continue; }
      const cs = getComputedStyle(n);
      marks.push({n, ink: cs.stroke !== 'none', fill: cs.fill !== 'none'});
    }
    const lengths = marks.map(m => m.ink ? len(m.n) : 120), total = lengths.reduce((a, b) => a + b, 0);
    return [{seconds: 2.2, run: (at, cycle, delay) => {
      let t = at;
      marks.forEach((m, i) => {
        const d = 2.2 * lengths[i] / total;
        if (m.ink && m.n.tagName !== 'text') draw(m.n, t, t + d, cycle, delay, m.fill);
        else fade(m.n, t, t + d, cycle, delay);
        t += d;
      });
    }}];
  }
  const inline = el.parentElement.classList.contains('you');
  const fs = parseFloat(getComputedStyle(el).fontSize), color = getComputedStyle(el).color;
  // An answer wraps to the box it's written in: its card, or the column it sits in.
  const box = el.parentElement, bs = getComputedStyle(box), pad = parseFloat(getComputedStyle(el).paddingLeft) + parseFloat(getComputedStyle(el).paddingRight)
    + parseFloat(getComputedStyle(el).marginLeft) + 2 * parseFloat(getComputedStyle(el).borderLeftWidth || 0);
  const maxW = inline ? Infinity : box.clientWidth - parseFloat(bs.paddingLeft) - parseFloat(bs.paddingRight) - pad - 2;
  const text = el.textContent.trim();
  const {svg, strokes, height, baseline} = set(chars(el), fs, maxW, color);
  if (inline) svg.style.verticalAlign = `${-(height - baseline)}px`;
  const said = Object.assign(document.createElement('span'), {className: 'sr-only', textContent: text});
  el.replaceChildren(svg, said);
  if (!animate) return [];
  const lengths = strokes.map(len), total = lengths.reduce((a, b) => a + b, 0) || 1, seconds = writing(text.length);
  const bubble = el.classList.contains('bubble');
  return [{seconds: seconds + (bubble ? .3 : 0), run: (at, cycle, delay) => {
    if (bubble) { fade(el, at, at + .3, cycle, delay); at += .3; }
    let t = at;
    strokes.forEach((p, i) => {
      const d = seconds * lengths[i] / total;
      p.tagName === 'text' ? fade(p, t, t + d, cycle, delay) : draw(p, t, t + d, cycle, delay);
      t += d;
    });
  }}];
}

// Your writing in a card: the person's hand from the film (Caveat traced), written in before Maple answers. A line that
// holds Maple's answer inline keeps it after your strokes; faint earlier writing (.muted-ink) just sits there.
function pen(el, animate) {
  el.dataset.src ??= el.innerHTML;
  const cs = getComputedStyle(el), fs = parseFloat(cs.fontSize);
  const replies = [...el.children].filter(n => n.classList.contains('reply'));
  const text = [...el.childNodes].filter(n => !n.classList?.contains('reply')).map(n => n.textContent).join('').trim();
  const maxW = el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight) - 2;
  const {svg, strokes, height, baseline} = set(chars(el), fs, maxW, cs.color, window.PERSON_HAND, .075, PERSON);
  svg.style.verticalAlign = `${-(height - baseline)}px`;
  el.replaceChildren(svg, ...replies, Object.assign(document.createElement('span'), {className: 'sr-only', textContent: text}));
  if (!animate || el.classList.contains('muted-ink')) return [];
  return [writeIn(strokes, Math.min(Math.max(text.length * .07, .8), 2.6))];
}

// Your mark inside a drawing (the edit brush's circle and note): drawn in, in your hand.
function mark(n, animate) {
  const strokes = n.tagName === 'text' ? strokeText(n, window.PERSON_HAND, PERSON) : [n];
  return animate ? [writeIn(strokes, n.tagName === 'text' ? 1.2 : .8)] : [];
}

// Strokes written in one after another at an even pace over `seconds`, then a rest before the next writer.
function writeIn(strokes, seconds, rest = .9) {
  const lengths = strokes.map(len), total = lengths.reduce((a, b) => a + b, 0) || 1;
  return {seconds, rest, run: (at, cycle, delay) => {
    let t = at;
    strokes.forEach((p, i) => {
      const d = seconds * lengths[i] / total;
      p.tagName === 'text' ? fade(p, t, t + d, cycle, delay) : draw(p, t, t + d, cycle, delay);
      t += d;
    });
  }};
}

// A box Maple is painting in, as Thinking.swift's Sketch does: the blue pencil traces just inside the box as soft
// graphite hatching sweeps across it, both fade, and it starts again; when the picture comes, it fades in over 500 ms.
const SK = {traceInset: 7, hatchInset: 5, gap: 6, traceWidth: 2.2, hatchWidth: 1.2, wobble: .7, drift: 120,
  trace: 1.1, hatchFrom: .2, hatch: 1.6, hold: .6, fade: .6, laps: 2, reveal: .5};
SK.cycle = SK.hatchFrom + SK.hatch + SK.hold + SK.fade;

function paint(el, animate) {
  const w = el.clientWidth, h = el.clientHeight, side = Math.min(w, h);
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
  svg.setAttribute('aria-hidden', 'true');
  const add = (d, attrs) => {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', d);
    Object.entries({fill: 'none', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', ...attrs}).forEach(([k, v]) => p.setAttribute(k, v));
    svg.append(p);
    return p;
  };
  const rect = d => [[d, d], [w - d, d], [w - d, h - d], [d, h - d]];
  let trace, hatch;
  if (animate) {
    // The trace: points every 3 px round the inset box, drifting in and out in whole waves so it closes.
    const corners = rect(Math.min(SK.traceInset, side / 6)), line = [];
    corners.forEach((a, i) => {
      const b = corners[(i + 1) % 4], n = Math.max(1, Math.round(Math.hypot(b[0] - a[0], b[1] - a[1]) / 3));
      for (let k = 0; k < n; k++) line.push([a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n]);
    });
    line.push(line[0]);
    const laps = Math.max(2, Math.round(line.length * 3 / SK.drift));
    const d = line.map(([x, y], i) => {
      const ox = x - w / 2, oy = y - h / 2, len = Math.max(Math.hypot(ox, oy), 1), a = 2 * Math.PI * laps * i / (line.length - 1);
      const shift = SK.wobble * (.7 * Math.sin(a) + .3 * Math.sin(2 * a)) / len;
      return `${i ? 'L' : 'M'}${(x + ox * shift).toFixed(1)} ${(y + oy * shift).toFixed(1)}`;
    }).join('');
    // The hatching: lines `gap` apart at -45°, cut to the inset box, swept from one side to the other.
    const poly = rect(Math.min(SK.hatchInset, side / 8)), along = [Math.SQRT1_2, -Math.SQRT1_2], across = [Math.SQRT1_2, Math.SQRT1_2];
    const offs = poly.map(([x, y]) => x * across[0] + y * across[1]);
    let hd = '';
    for (let o = Math.min(...offs) + SK.gap / 2; o < Math.max(...offs); o += SK.gap) {
      const hits = [];
      poly.forEach((a, i) => {
        const j = (i + 1) % 4, oa = offs[i] - o, ob = offs[j] - o;
        if ((oa <= 0) === (ob <= 0)) return;
        const f = oa / (oa - ob), b = poly[j];
        hits.push((a[0] + (b[0] - a[0]) * f) * along[0] + (a[1] + (b[1] - a[1]) * f) * along[1]);
      });
      if (hits.length < 2) continue;
      const [from, to] = [Math.min(...hits), Math.max(...hits)];
      const p = t => `${(across[0] * o + along[0] * t).toFixed(1)} ${(across[1] * o + along[1] * t).toFixed(1)}`;
      hd += `M${p(from)}L${p(to)}`;
    }
    hatch = add(hd, {stroke: 'oklch(28% .01 155 / .34)', 'stroke-width': SK.hatchWidth});
    trace = add(d, {stroke: 'var(--color-blue)', 'stroke-width': SK.traceWidth});
    for (const p of [hatch, trace]) { p.setAttribute('pathLength', 1); p.style.strokeDasharray = '1 2'; }
  }
  // Your box, in graphite, around where the picture goes.
  add(`M1 1H${w - 1}V${h - 1}H1Z`, {stroke: 'var(--color-ink)', 'stroke-width': 1.5});
  el.append(svg);
  if (!animate) return [];
  const img = el.querySelector('img'), seconds = SK.laps * SK.cycle + SK.reveal;
  return [{seconds, run: (start, cycle, delay) => {
    const keys = (points, easing) => {
      const frames = points.map(([t, v]) => ({offset: frac(t, cycle), ...v}));
      return [{...frames[0], offset: 0}, ...frames, {...frames.at(-1), offset: 1}].map(f => (easing ? {...f, easing} : f));
    };
    const tp = [], hp = [];
    for (let k = 0; k < SK.laps; k++) {
      const s = start + k * SK.cycle, fading = SK.hatchFrom + SK.hatch + SK.hold;
      tp.push([s, {strokeDashoffset: 1, opacity: 1}], [s + SK.trace, {strokeDashoffset: 0, opacity: 1}],
        [s + fading, {strokeDashoffset: 0, opacity: 1}], [s + SK.cycle, {strokeDashoffset: 0, opacity: 0}]);
      hp.push([s, {strokeDashoffset: 1, opacity: 1}], [s + SK.hatchFrom, {strokeDashoffset: 1, opacity: 1}],
        [s + SK.hatchFrom + SK.hatch, {strokeDashoffset: 0, opacity: 1}], [s + fading, {strokeDashoffset: 0, opacity: 1}],
        [s + SK.cycle, {strokeDashoffset: 0, opacity: 0}]);
    }
    play(trace, cycle, delay, keys(tp, 'ease-in-out'));
    play(hatch, cycle, delay, keys(hp));
    const shown = start + SK.laps * SK.cycle;
    play(img, cycle, delay, keys([[shown, {opacity: 0}], [shown + SK.reveal, {opacity: 1}], [cycle - .35, {opacity: 1}], [cycle, {opacity: 0}]]));
  }}];
}

function play(el, cycle, delay, frames) {
  anims.push(el.animate(frames, {duration: cycle * 1000, delay: -delay * 1000, iterations: Infinity, fill: 'both'}));
}
const frac = (t, cycle) => Math.min(Math.max(t / cycle, 0), 1);
const at = frac;
function draw(n, t0, t1, cycle, delay, filled) {
  n.setAttribute('pathLength', 1);
  n.style.strokeDasharray = '1 2';
  const end = at(cycle - .35, cycle);
  play(n, cycle, delay, [
    {offset: 0, strokeDashoffset: 1, fillOpacity: filled ? 0 : 1, opacity: 1},
    {offset: at(t0, cycle), strokeDashoffset: 1, fillOpacity: filled ? 0 : 1, opacity: 1},
    {offset: at(t1, cycle), strokeDashoffset: 0, fillOpacity: filled ? 0 : 1, opacity: 1},
    {offset: at(t1 + .3, cycle), strokeDashoffset: 0, fillOpacity: 1, opacity: 1},
    {offset: end, strokeDashoffset: 0, fillOpacity: 1, opacity: 1},
    {offset: 1, strokeDashoffset: 0, fillOpacity: 1, opacity: 0}]);
}
function fade(n, t0, t1, cycle, delay) {
  const end = at(cycle - .35, cycle);
  play(n, cycle, delay, [{offset: 0, opacity: 0}, {offset: at(t0, cycle), opacity: 0}, {offset: at(Math.max(t1, t0 + .2), cycle), opacity: 1},
    {offset: end, opacity: 1}, {offset: 1, opacity: 0}]);
}

// Sets every card's ink: your writing in your hand, Maple's in its own. With animate, each card plays in a loop: you
// write, rest the pen, Maple writes back, it holds, and the page clears.
function inkAll(root, animate) {
  anims.forEach(a => a.cancel());
  anims = [];
  for (const el of root.querySelectorAll('.maple:not(.reply)')) jobs(el, false);
  for (const card of root.querySelectorAll('.card')) {
    // Back to the page as written, so the list below holds the elements that will be drawn.
    for (const el of card.querySelectorAll('.you[data-src], .edit[data-src], svg[data-src]:not(.reply)')) el.innerHTML = el.dataset.src;
    for (const svg of card.querySelectorAll('svg:not(.reply):not(.hand)')) if (svg.querySelector('.mark')) svg.dataset.src ??= svg.innerHTML;
    const list = [...card.querySelectorAll('.you, .edit, .mark, .reply')].flatMap(el =>
      el.classList.contains('reply') ? jobs(el, animate) : el.classList.contains('mark') ? mark(el, animate) : pen(el, animate));
    if (!animate || !list.length) continue;
    const busy = list.reduce((a, j) => a + j.seconds + (j.rest ?? .5), .6), cycle = Math.max(12, busy + 5);
    let t = .6;
    for (const j of list) { j.run(t, cycle, +card.dataset.phase % cycle); t += j.seconds + (j.rest ?? .5); }
  }
}

// A word in Maple's hand, written once when it comes into view.
function sign(el, animate) {
  const cs = getComputedStyle(el), fs = parseFloat(cs.fontSize);
  const text = el.textContent;
  const {svg, strokes, height, baseline} = set(chars(el), fs, Infinity, cs.color);
  svg.style.verticalAlign = `${-(height - baseline)}px`;
  el.replaceChildren(svg, Object.assign(document.createElement('span'), {className: 'sr-only', textContent: text}));
  if (!animate) return;
  const lengths = strokes.map(len), total = lengths.reduce((a, b) => a + b, 0), seconds = Math.max(1.1, writing(text.length));
  strokes.forEach(p => { p.setAttribute('pathLength', 1); p.style.strokeDasharray = '1 2'; p.style.strokeDashoffset = 1; });
  new IntersectionObserver(([e], io) => {
    if (!e.isIntersecting) return;
    io.disconnect();
    let t = +(el.dataset.delay || 300);
    strokes.forEach((p, i) => {
      const d = seconds * 1000 * lengths[i] / total;
      p.animate([{strokeDashoffset: 1}, {strokeDashoffset: 0}], {duration: d, delay: t, fill: 'forwards'});
      t += d;
    });
  }, {threshold: 1}).observe(el);
}

// Words in Maple's hand, one after another: each written in at the app's pace, held, faded, then the next.
function cycle(el, animate, hold = 1600) {
  const words = el.dataset.words.split(','), cs = getComputedStyle(el), fs = parseFloat(cs.fontSize);
  let i = 0;
  const show = () => {
    const word = Object.assign(document.createElement('span'), {textContent: words[i] + '.'});
    i = (i + 1) % words.length;
    const {svg, strokes, height, baseline} = set(chars(word), fs, Infinity, cs.color);
    svg.style.verticalAlign = `${-(height - baseline)}px`;
    el.replaceChildren(svg);
    if (!animate) return;
    const lengths = strokes.map(len), total = lengths.reduce((a, b) => a + b, 0), seconds = writing(word.textContent.length) * 1000;
    let t = 0;
    strokes.forEach((p, k) => {
      const d = seconds * lengths[k] / total;
      p.setAttribute('pathLength', 1);
      p.style.strokeDasharray = '1 2';
      p.animate([{strokeDashoffset: 1}, {strokeDashoffset: 0}], {duration: d, delay: t, fill: 'both'});
      t += d;
    });
    setTimeout(() => svg.animate([{opacity: 1}, {opacity: 0}], {duration: 350, fill: 'forwards'}).finished.then(show), t + hold);
  };
  show();
}

