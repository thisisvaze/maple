const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync(`${__dirname}/orb-options.html`, 'utf8');
const main = fs.readFileSync(`${__dirname}/index.html`, 'utf8');
const shared = fs.readFileSync(`${__dirname}/orb.js`, 'utf8');
new vm.Script(shared);
for (const page of [html, main]) {
  for (const script of page.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)) new vm.Script(script[1]);
  assert(page.includes('<script src="orb.js"></script>'));
  const ids = [...page.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
  assert.equal(new Set(ids).size, ids.length, 'HTML IDs must be unique.');
}
const geometry = shared + html.match(/<script id="orb-geometry">([\s\S]*?)<\/script>/)[1];
vm.runInNewContext(geometry + `
  assert.equal(orbOptions.length, 4);
  for (const option of orbOptions) {
    for (const t of [0, .6, 1, 5, 20, 100]) {
      const dots = orbDots(option, t);
      assert.equal(dots.length, option.lanes * option.segments);
      for (const [i, dot] of dots.entries()) {
        for (const value of Object.values(dot)) assert(Number.isFinite(value));
        assert(dot.radius > 0 && dot.alpha > 0 && dot.alpha <= 1);
        assert(dot.x - dot.radius > 0 && dot.x + dot.radius < 64);
        assert(dot.y - dot.radius > 0 && dot.y + dot.radius < 64);
        if (i) assert(dots[i - 1].z <= dot.z);
        for (const dark of [false, true]) for (const channel of orbColor(dot, t, dark)) assert(channel >= 0 && channel <= 255);
      }
    }
  }
  const openings = orbOptions.map(option => Math.min(...orbDots(option, .6).map(dot => Math.hypot(dot.x - 32, dot.y - 32) - dot.radius)));
  for (let i = 1; i < openings.length; i++) assert(openings[i] < openings[i - 1]);
  assert(openings[3] > 2, 'The fullest option must retain an opening.');
`, {assert});
const circles = [];
const document = {
  documentElement: {dataset: {theme: 'light'}},
  createElementNS: () => ({attributes: {}, setAttribute(name, value) { this.attributes[name] = value; }})
};
const context = vm.createContext({assert, document, $: () => ({appendChild: circle => circles.push(circle)})});
const renderer = main.slice(main.indexOf('  let orbTime='), main.indexOf('  function animateOrb('));
vm.runInContext(geometry + renderer + `
  const selected = orbOptions.find(option => option.id === 'a');
  for (const dark of [false, true]) {
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    for (const t of [.6, 3, 10]) {
      drawOrb(t);
      orbDots(selected, t).forEach((dot, i) => {
        const attrs = orbCircles[i].attributes;
        assert.equal(attrs.cx, dot.x.toFixed(3));
        assert.equal(attrs.cy, dot.y.toFixed(3));
        assert.equal(attrs.r, dot.radius.toFixed(3));
        assert.equal(attrs.opacity, dot.alpha.toFixed(3));
        assert.equal(attrs.fill, 'rgb(' + orbColor(dot, t, dark).join(',') + ')');
      });
    }
  }
`, context);
assert.equal(circles.length, 484);
assert(main.includes('<symbol id="orb-symbol" viewBox="0 0 64 64">'));
assert(!main.includes('orb-strands'));
const scheduled = new Map(), seen = [];
const flowContext = vm.createContext({
  assert, seen,
  $: () => ({}), document: {querySelector: () => ({})}, tab: () => {},
  showState: state => seen.push(state),
  setTimeout: fn => { const id = Symbol(); scheduled.set(id, fn); return id; },
  clearTimeout: id => scheduled.delete(id), clearInterval: () => {}
});
const flowFunctions = ['cancelTasks', 'later', 'playImage'].map(name => main.match(new RegExp('  function ' + name + '\\([^\\n]+'))[0]).join('\n');
vm.runInContext('let tasks=[],timer=null,playing=false;\n' + flowFunctions + '\nplayImage();', flowContext);
assert.equal(seen.at(-1), 'painting');
vm.runInContext('cancelTasks();', flowContext);
assert.equal(scheduled.size, 0, 'Cancelling must remove the scheduled image reveal.');
vm.runInContext('playImage(true);', flowContext);
assert.equal(seen.at(-1), 'repainting');
for (const finish of scheduled.values()) finish();
assert.equal(seen.at(-1), 'image-ready');
console.log('Orb geometry, light/dark parity, scripts, IDs and image flow completion/cancellation passed.');
