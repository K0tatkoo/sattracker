// Writes the reference results the Swift port of satellite.js is tested
// against (ios/OrbitCore/Tests/OrbitCoreTests/Fixtures/satellitejs.json).
//
//   node ios/tools/sgp4-fixtures.mjs
//
// It runs the very satellite.min.js the Android app's page runs, and the
// page's own nextRise/nextPass (copied from globe.js below), over the TLEs the
// app bundles plus the fixture TLEs (deep-space orbits: GNSS, geostationary,
// Molniya). Run it again after changing either file.
import { createRequire } from 'node:module';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const fixtures = join(here, '..', 'OrbitCore', 'Tests', 'OrbitCoreTests', 'Fixtures');
const require = createRequire(import.meta.url);
const sat = require(join(repo, 'app', 'src', 'main', 'assets', 'lib', 'satellite.min.js'));
const DEG = Math.PI / 180;

// ---- the page's pass code, verbatim from globe.js ---------------------------
function lookAnglesAt(satrec, date, obs){
  const pv=sat.propagate(satrec, date); if (!pv.position) return null;
  const gmst=sat.gstime(date);
  const ecf=sat.eciToEcf(pv.position, gmst);
  const la=sat.ecfToLookAngles(obs, ecf);
  return { az:la.azimuth/DEG, el:la.elevation/DEG, range:la.rangeSat };
}
function nextRise(satrec, obs, fromDate, maskDeg=5, horizonMin=180){
  let prev=lookAnglesAt(satrec, fromDate, obs); if(!prev) return null;
  const step=30*1000; const end=fromDate.getTime()+horizonMin*60*1000;
  for (let t=fromDate.getTime()+step; t<=end; t+=step){
    const d=new Date(t); const la=lookAnglesAt(satrec,d,obs); if(!la) continue;
    if (prev.el<maskDeg && la.el>=maskDeg) return { time:d, secs:(t-fromDate.getTime())/1000 };
    prev=la;
  }
  return null;
}
function nextPass(satrec, obs, fromDate){
  const rise=nextRise(satrec, obs, fromDate, 0, 240);
  if (!rise) return null;
  let peak=0, tSet=null; const step=20*1000;
  for (let t=rise.time.getTime(); t<rise.time.getTime()+40*60*1000; t+=step){
    const la=lookAnglesAt(satrec,new Date(t),obs); if(!la) break;
    if (la.el>peak) peak=la.el;
    if (la.el<0){ tSet=t; break; }
  }
  const durMin = tSet ? Math.round((tSet-rise.time.getTime())/60000) : null;
  return { aos:rise.time, peakEl:Math.round(peak), durMin };
}
// -----------------------------------------------------------------------------

function readTle(path) {
  const lines = readFileSync(path, 'utf8').split(/\r?\n/);
  const out = [];
  for (let i = 0; i + 2 < lines.length; i += 3) {
    const name = lines[i].trim(), l1 = lines[i + 1], l2 = lines[i + 2];
    if (!l1 || l1[0] !== '1' || !l2 || l2[0] !== '2') { i -= 2; continue; }
    out.push({ name, line1: l1, line2: l2 });
  }
  return out;
}
function spread(list, n) {
  if (list.length <= n) return list;
  return Array.from({ length: n }, (_, i) => list[Math.round(i * (list.length - 1) / (n - 1))]);
}

const sources = [];
for (const g of ['stations', 'gps-ops', 'starlink']) {
  sources.push({ group: g, sats: spread(readTle(join(repo, 'app', 'src', 'main', 'assets', 'tle', g + '.txt')), 12) });
}
for (const f of readdirSync(join(fixtures, 'tle')).sort()) {
  sources.push({ group: f.replace(/\.txt$/, ''), file: 'tle/' + f, sats: readTle(join(fixtures, 'tle', f)) });
}

const observers = [
  { name: 'Prague', lat: 50.0755, lon: 14.4378, alt: 235 },
  { name: 'Sydney', lat: -33.8688, lon: 151.2093, alt: 20 },
];
const obsGd = o => ({ longitude: o.lon * DEG, latitude: o.lat * DEG, height: o.alt / 1000 });

// Fixed moments, whole milliseconds, as JavaScript Dates have them.
const base = Date.UTC(2026, 9, 22, 12, 0, 0, 0);
const dates = [-3 * 86400e3, -7 * 3600e3 + 123, 0, 37 * 60e3 + 456, 27 * 3600e3 + 789, 5 * 86400e3 + 1].map(d => base + d);
const tsinces = [0, 360, 1440, -1440, 4320, 10080.5];

const pv = r => (r && r.position) ? { r: [r.position.x, r.position.y, r.position.z], v: [r.velocity.x, r.velocity.y, r.velocity.z] } : null;

const satellites = [];
for (const src of sources) {
  for (const s of src.sats) {
    const satrec = sat.twoline2satrec(s.line1, s.line2);
    const entry = {
      group: src.group, name: s.name, line1: s.line1, line2: s.line2,
      norad: parseInt(s.line2.substring(2, 7), 10),
      init: {
        no: satrec.no, ecco: satrec.ecco, inclo: satrec.inclo, nodeo: satrec.nodeo, argpo: satrec.argpo,
        mo: satrec.mo, bstar: satrec.bstar, jdsatepoch: satrec.jdsatepoch, gsto: satrec.gsto,
        method: satrec.method, irez: satrec.irez || 0, isimp: satrec.isimp,
      },
      sgp4: tsinces.map(m => ({ tsince: m, result: pv(sat.sgp4(sat.twoline2satrec(s.line1, s.line2), m)) })),
      at: dates.map(ms => {
        const d = new Date(ms);
        const r = sat.propagate(satrec, d);
        const out = { ms, jd: sat.jday(d), gmst: sat.gstime(d), result: pv(r) };
        if (r && r.position) {
          const gd = sat.eciToGeodetic(r.position, out.gmst);
          out.geodetic = [gd.latitude, gd.longitude, gd.height];
          out.look = observers.map(o => {
            const la = sat.ecfToLookAngles(obsGd(o), sat.eciToEcf(r.position, out.gmst));
            return [la.azimuth, la.elevation, la.rangeSat];
          });
        }
        return out;
      }),
    };
    satellites.push(entry);
  }
}

// The page's passes for the satellites people look at: the ISS, a Starlink,
// weather and science birds, and GPS (deep space, slow).
const passes = [];
for (const entry of satellites) {
  const pick = ['stations', 'starlink', 'weather', 'science', 'gps-ops'].includes(entry.group);
  if (!pick || passes.filter(p => p.group === entry.group).length >= 6) continue;
  const satrec = sat.twoline2satrec(entry.line1, entry.line2);
  for (const o of observers) {
    for (const ms of [dates[1], dates[2], dates[3]]) {
      const from = new Date(ms);
      const rise = nextRise(satrec, obsGd(o), from);
      const p = nextPass(satrec, obsGd(o), from);
      passes.push({
        group: entry.group, norad: entry.norad, observer: o.name, from: ms,
        rise: rise ? { ms: rise.time.getTime(), secs: rise.secs } : null,
        pass: p ? { aos: p.aos.getTime(), peakEl: p.peakEl, durMin: p.durMin } : null,
      });
    }
  }
}

const calendar = [
  [2026, 10, 22, 12, 0, 0, 0], [2000, 1, 1, 12, 0, 0, 0], [1999, 12, 31, 23, 59, 59, 999],
  [2024, 2, 29, 6, 30, 15.5, 0], [2031, 7, 4, 18, 45, 1, 250],
].map(a => ({ args: a, jday: sat.jday(...a), gstime: sat.gstime(sat.jday(...a)) }));

writeFileSync(join(fixtures, 'satellitejs.json'), JSON.stringify({
  generator: 'ios/tools/sgp4-fixtures.mjs', satellitejs: '5.0.0',
  observers, satellites, passes, calendar,
}));
console.log(`${satellites.length} satellites, ${passes.length} pass checks -> Fixtures/satellitejs.json`);
const errs = satellites.filter(s => s.at.some(a => !a.result));
console.log(`${errs.length} with a propagation error somewhere (${[...new Set(errs.map(e => e.group))].join(', ')})`);
