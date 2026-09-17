// ============================================================================
//  Orbit — 3D live satellite tracker (WebView front-end)
//  Real positions: TLE data (fetched natively from Celestrak) + SGP4 (satellite.js)
//  Native bridge: window.Android.*  (JS -> native) and window.SatBridge.* (native -> JS)
//  THREE, THREE.OrbitControls and satellite are provided by the bundled <script> tags.
// ============================================================================
const DEG = Math.PI / 180;
const EARTH_R_KM = 6371;          // mean Earth radius
const SCENE_R = 1;                // Earth radius in scene units
const sat = window.satellite;     // UMD global from satellite.js

// Simulation-time multiplier. 1 = real time (true current positions). Increase (e.g. 30-60)
// to time-lapse the motion so it's visibly moving. Kept at real-time per user preference.
let SIM_SPEED = 1;
const _realStart = Date.now(), _perfStart = (window.performance ? performance.now() : 0);
function simDate(){ return new Date(_realStart + (performance.now() - _perfStart) * SIM_SPEED); }

// GNSS constellation -> toggleable category id (used to filter the "communication" beams).
const CONST_TO_CAT = { GPS:'gps', GLONASS:'glonass', Galileo:'galileo', BeiDou:'beidou' };

// ---- Categories the user can toggle. group = Celestrak GROUP param. -------------
const CATEGORIES = [
  { id:'stations', group:'stations', label:'ISS & Stations', color:'#ffffff', cap:40,  on:true  },
  { id:'gps',      group:'gps-ops',  label:'GPS',            color:'#38E1FF', cap:40,  on:true,  gnss:true },
  { id:'glonass',  group:'glo-ops',  label:'GLONASS',        color:'#ff7b7b', cap:40,  on:false, gnss:true },
  { id:'galileo',  group:'galileo',  label:'Galileo',        color:'#8affc1', cap:40,  on:false, gnss:true },
  { id:'beidou',   group:'beidou',   label:'BeiDou',         color:'#ffcb5b', cap:60,  on:false, gnss:true },
  { id:'starlink', group:'starlink', label:'Starlink',       color:'#b58bff', cap:300, on:false },
  { id:'weather',  group:'weather',  label:'Weather',        color:'#5bd0ff', cap:40,  on:false },
  { id:'science',  group:'science',  label:'Science',        color:'#ff9edb', cap:40,  on:false },
];

// ---- Metadata resolver: name + group -> {country, operator, purpose} -----------
function resolveMeta(name, group){
  const n = (name||'').toUpperCase();
  const base = {
    'gps-ops': ['USA','US Space Force','Navigation (GPS)'],
    'glo-ops': ['Russia','Roscosmos / VKS','Navigation (GLONASS)'],
    'galileo': ['European Union','EUSPA / ESA','Navigation (Galileo)'],
    'beidou':  ['China','CNSA','Navigation (BeiDou)'],
    'starlink':['USA','SpaceX','Broadband internet'],
    'stations':['International','Multiple agencies','Crewed space station'],
    'weather': ['Various','Meteorological agencies','Weather observation'],
    'science': ['Various','Research institutions','Scientific research'],
  }[group] || ['Unknown','Unknown','—'];
  let [country, operator, purpose] = base;
  if (n.includes('ISS')||n.includes('ZARYA')){country='International';operator='NASA / Roscosmos / ESA / JAXA / CSA';purpose='Crewed space station';}
  else if (n.includes('CSS')||n.includes('TIANHE')){country='China';operator='CMSA';purpose='Crewed space station';}
  else if (n.includes('NOAA')){country='USA';operator='NOAA';purpose='Weather observation';}
  else if (n.includes('METEOR')){country='Russia';operator='Roshydromet';purpose='Weather observation';}
  else if (n.includes('METOP')){country='European Union';operator='EUMETSAT';purpose='Weather observation';}
  else if (n.includes('HUBBLE')||n.includes('HST')){country='USA';operator='NASA / ESA';purpose='Space telescope';}
  else if (n.includes('TERRA')||n.includes('AQUA')||n.includes('LANDSAT')){country='USA';operator='NASA / USGS';purpose='Earth observation';}
  return { country, operator, purpose };
}

// ============================================================================
//  State
// ============================================================================
const state = {
  sats: [],                 // {name, satrec, cat, norad}
  observer: null,           // {lat, lon, alt(km)}
  gnss: null,               // last GNSS payload
  selected: -1,
  loadingGroups: new Set(),
  loadedGroups: new Set(),
};

// ============================================================================
//  three.js scene
// ============================================================================
let renderer, scene, camera, controls, earth, satPoints, satGeom, selRing, obsMarker;
let posAttr, colAttr;
const MAX_SATS = 4000;
const _v = new THREE.Vector3();

function initScene(){
  const host = document.getElementById('scene');
  renderer = new THREE.WebGLRenderer({ antialias:true, alpha:false });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.setSize(innerWidth, innerHeight);
  host.appendChild(renderer.domElement);

  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(45, innerWidth/innerHeight, 0.01, 100);
  camera.position.set(0, 1.2, 3.0);

  controls = new THREE.OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.dampingFactor = 0.08;
  controls.rotateSpeed = 0.55;
  controls.minDistance = 1.25;
  controls.maxDistance = 34;      // zoom out far enough for GPS/GEO-altitude satellites
  controls.zoomSpeed = 1.15;
  controls.enablePan = false;
  controls.autoRotate = true;
  controls.autoRotateSpeed = 0.3;

  scene.add(new THREE.AmbientLight(0xffffff, 0.55));
  const sun = new THREE.DirectionalLight(0xffffff, 1.1);
  sun.position.set(5, 3, 5);
  scene.add(sun);

  buildEarth();
  buildStars();
  buildSatSystem();
  buildSelectionRing();
  buildComm();

  addEventListener('resize', onResize);
  renderer.domElement.addEventListener('pointerdown', onPointerDown);
  renderer.domElement.addEventListener('pointerup', onPointerUp);
}

function buildEarth(){
  const geo = new THREE.SphereGeometry(SCENE_R, 96, 96);
  const mat = new THREE.MeshPhongMaterial({ color:0x120a26, emissive:0x0b0720, shininess:12, specular:0x2a1a55 });
  earth = new THREE.Mesh(geo, mat);
  // No rotation: three's SphereGeometry UV maps Greenwich (lon 0) to +X and lon -90 to +Z,
  // which exactly matches llToVec3() used for satellites/markers — so they all line up.
  earth.rotation.y = 0;
  scene.add(earth);

  // Earth texture. Prefer the embedded data: URI (window.EARTH_TEX) — a file:// image can't be
  // uploaded to WebGL from a file:// page (blocked as cross-origin), but a data: URI always works.
  const img = new Image();
  img.onload = () => {
    const tex = new THREE.Texture(img);
    if (THREE.SRGBColorSpace) tex.colorSpace = THREE.SRGBColorSpace;
    tex.needsUpdate = true;
    mat.map = tex; mat.color.set(0x9a86c8); mat.emissive.set(0x0a0722); mat.needsUpdate = true;
  };
  img.onerror = () => {};
  img.src = window.EARTH_TEX || 'lib/earth-dark.jpg';

  // Graticule (lat/lon grid) — subtle violet.
  const grat = new THREE.Group();
  const lineMat = new THREE.LineBasicMaterial({ color:0x6a4bb0, transparent:true, opacity:0.22 });
  for (let lat=-60; lat<=60; lat+=30){
    const pts=[]; for (let lon=-180; lon<=180; lon+=5) pts.push(llToVec3(lat,lon,SCENE_R*1.001));
    grat.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), lineMat));
  }
  for (let lon=-180; lon<180; lon+=30){
    const pts=[]; for (let lat=-90; lat<=90; lat+=5) pts.push(llToVec3(lat,lon,SCENE_R*1.001));
    grat.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), lineMat));
  }
  earth.add(grat);

  // Purple atmosphere glow
  const atm = new THREE.Mesh(
    new THREE.SphereGeometry(SCENE_R*1.035, 64, 64),
    new THREE.ShaderMaterial({
      transparent:true, side:THREE.BackSide, blending:THREE.AdditiveBlending,
      vertexShader:`varying vec3 vN; void main(){ vN=normalize(normalMatrix*normal); gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);} `,
      fragmentShader:`varying vec3 vN; void main(){ float i=pow(0.62-dot(vN,vec3(0,0,1.0)),3.0); gl_FragColor=vec4(0.60,0.35,1.0,1.0)*i; }`
    })
  );
  scene.add(atm);
}

function buildStars(){
  const n=1800, arr=new Float32Array(n*3), col=new Float32Array(n*3);
  const tints=[[1,1,1],[0.75,0.68,1],[1,0.7,0.95],[0.6,0.8,1],[0.85,0.75,1]];
  for (let i=0;i<n;i++){
    const r=34+Math.random()*40, t=Math.random()*Math.PI*2, p=Math.acos(2*Math.random()-1);
    arr[i*3]=r*Math.sin(p)*Math.cos(t); arr[i*3+1]=r*Math.cos(p); arr[i*3+2]=r*Math.sin(p)*Math.sin(t);
    const c=tints[(Math.random()*tints.length)|0], b=0.5+Math.random()*0.5;
    col[i*3]=c[0]*b; col[i*3+1]=c[1]*b; col[i*3+2]=c[2]*b;
  }
  const g=new THREE.BufferGeometry();
  g.setAttribute('position',new THREE.BufferAttribute(arr,3));
  g.setAttribute('color',new THREE.BufferAttribute(col,3));
  scene.add(new THREE.Points(g, new THREE.PointsMaterial({ size:0.07, sizeAttenuation:true, vertexColors:true, transparent:true, map:discTexture(), depthWrite:false })));

  // Faint nebula clouds for a galaxy backdrop.
  const nebColors=[0x6a2cff,0xb02cff,0x2c66ff];
  for (let i=0;i<3;i++){
    const s=new THREE.Sprite(new THREE.SpriteMaterial({ map:discTexture(), color:nebColors[i], transparent:true, opacity:0.12, depthWrite:false, blending:THREE.AdditiveBlending }));
    const r=45, t=Math.random()*Math.PI*2, p=Math.acos(2*Math.random()-1);
    s.position.set(r*Math.sin(p)*Math.cos(t), r*Math.cos(p), r*Math.sin(p)*Math.sin(t));
    s.scale.setScalar(30+Math.random()*20);
    scene.add(s);
  }
}

let _disc;
function discTexture(){
  if (_disc) return _disc;
  const c=document.createElement('canvas'); c.width=c.height=128; const x=c.getContext('2d');
  const g=x.createRadialGradient(64,64,0,64,64,64);
  // crisp bright core, tight mid, soft halo -> reads as a clean modern dot
  g.addColorStop(0.00,'rgba(255,255,255,1)');
  g.addColorStop(0.18,'rgba(255,255,255,1)');
  g.addColorStop(0.32,'rgba(255,255,255,0.65)');
  g.addColorStop(0.60,'rgba(255,255,255,0.18)');
  g.addColorStop(1.00,'rgba(255,255,255,0)');
  x.fillStyle=g; x.beginPath(); x.arc(64,64,64,0,7); x.fill();
  _disc=new THREE.CanvasTexture(c); if (THREE.SRGBColorSpace) _disc.colorSpace=THREE.SRGBColorSpace; return _disc;
}
// Crisp satellite dot: solid core + thin soft edge, minimal halo. Used with NORMAL blending so
// dense clusters (e.g. Starlink) don't additively blow out into one bright glowing ball.
let _dot;
function dotTexture(){
  if(_dot) return _dot;
  const c=document.createElement('canvas'); c.width=c.height=64; const x=c.getContext('2d');
  const g=x.createRadialGradient(32,32,0,32,32,32);
  g.addColorStop(0.00,'rgba(255,255,255,1)');
  g.addColorStop(0.42,'rgba(255,255,255,1)');
  g.addColorStop(0.55,'rgba(255,255,255,0.5)');
  g.addColorStop(0.78,'rgba(255,255,255,0.12)');
  g.addColorStop(1.00,'rgba(255,255,255,0)');
  x.fillStyle=g; x.beginPath(); x.arc(32,32,32,0,7); x.fill();
  _dot=new THREE.CanvasTexture(c); if(THREE.SRGBColorSpace)_dot.colorSpace=THREE.SRGBColorSpace; return _dot;
}

let trailGeom, trailLines, trailPos, trailCol;
const TRAIL_N = 40;   // samples per orbit arc

function buildSatSystem(){
  // Orbit trails (drawn under the satellite dots)
  const maxSeg = MAX_SATS * TRAIL_N;
  trailGeom = new THREE.BufferGeometry();
  trailPos = new THREE.BufferAttribute(new Float32Array(maxSeg*2*3),3).setUsage(THREE.DynamicDrawUsage);
  trailCol = new THREE.BufferAttribute(new Float32Array(maxSeg*2*3),3).setUsage(THREE.DynamicDrawUsage);
  trailGeom.setAttribute('position', trailPos);
  trailGeom.setAttribute('color', trailCol);
  trailGeom.setDrawRange(0,0);
  trailLines = new THREE.LineSegments(trailGeom, new THREE.LineBasicMaterial({
    vertexColors:true, transparent:true, opacity:0.75, depthWrite:false, blending:THREE.AdditiveBlending
  }));
  scene.add(trailLines);

  // Satellite dots — constant on-screen size (sizeAttenuation:false) so high-altitude
  // satellites stay visible when you zoom out.
  satGeom=new THREE.BufferGeometry();
  posAttr=new THREE.BufferAttribute(new Float32Array(MAX_SATS*3),3).setUsage(THREE.DynamicDrawUsage);
  colAttr=new THREE.BufferAttribute(new Float32Array(MAX_SATS*3),3);
  satGeom.setAttribute('position',posAttr);
  satGeom.setAttribute('color',colAttr);
  satGeom.setDrawRange(0,0);
  satPoints=new THREE.Points(satGeom, new THREE.PointsMaterial({
    size:16, map:dotTexture(), vertexColors:true, transparent:true,
    depthWrite:false, blending:THREE.NormalBlending, sizeAttenuation:false
  }));
  scene.add(satPoints);
}

let obsRing;
function buildSelectionRing(){
  selRing=new THREE.Mesh(
    new THREE.RingGeometry(0.055,0.085,40),
    new THREE.MeshBasicMaterial({ color:0xc39bff, side:THREE.DoubleSide, transparent:true, opacity:0.95 })
  );
  selRing.visible=false; scene.add(selRing);

  // "You are here": a glow sprite + bright dot + animated pulse ring, so it's unmistakable.
  obsMarker=new THREE.Group();
  const glow=new THREE.Sprite(new THREE.SpriteMaterial({
    map:discTexture(), color:0x5effb0, transparent:true, depthWrite:false, blending:THREE.AdditiveBlending
  }));
  glow.scale.setScalar(0.11);
  const dot=new THREE.Mesh(
    new THREE.SphereGeometry(0.02,18,18),
    new THREE.MeshBasicMaterial({ color:0xd7ffe9 })
  );
  obsRing=new THREE.Mesh(
    new THREE.RingGeometry(0.03,0.045,40),
    new THREE.MeshBasicMaterial({ color:0x4ee39a, side:THREE.DoubleSide, transparent:true, opacity:0.85 })
  );
  obsMarker.add(glow); obsMarker.add(dot); obsMarker.add(obsRing);
  obsMarker.visible=false; scene.add(obsMarker);
}

// geographic lat/lon (deg) + radius(scene units) -> Vector3
function llToVec3(latDeg, lonDeg, r){
  const lat=latDeg*DEG, lon=lonDeg*DEG;
  return new THREE.Vector3(
    r*Math.cos(lat)*Math.cos(lon),
    r*Math.sin(lat),
    -r*Math.cos(lat)*Math.sin(lon)
  );
}

function onResize(){
  camera.aspect=innerWidth/innerHeight; camera.updateProjectionMatrix();
  renderer.setSize(innerWidth,innerHeight);
}

// ============================================================================
//  Satellite propagation
// ============================================================================
function eciToScene(posEci, gmst){
  // ECI (km) -> geodetic -> scene units, keeping true altitude scaled.
  const gd=sat.eciToGeodetic(posEci, gmst);
  const latDeg=sat.degreesLat(gd.latitude), lonDeg=sat.degreesLong(gd.longitude);
  const r=SCENE_R*(1 + gd.height/EARTH_R_KM);
  return { v:llToVec3(latDeg,lonDeg,r), latDeg, lonDeg, heightKm:gd.height };
}

// Recompute EVERY frame so satellites move smoothly in real time. SGP4 is cheap; guarded
// per-satellite so one bad TLE can never throw and freeze the whole render loop.
function propagate(now){
  const date=simDate();
  let gmst; try { gmst=sat.gstime(date); } catch(e){ return; }
  const pos=posAttr.array, col=colAttr.array;
  let count=0;
  for (const s of state.sats){
    if (count>=MAX_SATS) break;
    let pv; try { pv=sat.propagate(s.satrec, date); } catch(e){ s.alive=false; continue; }
    if (!pv || !pv.position){ s.alive=false; continue; }
    let t; try { t=eciToScene(pv.position, gmst); } catch(e){ s.alive=false; continue; }
    if (!isFinite(t.v.x) || !isFinite(t.v.y) || !isFinite(t.v.z)){ s.alive=false; continue; }
    s.pos=t.v; s.latDeg=t.latDeg; s.lonDeg=t.lonDeg; s.heightKm=t.heightKm;
    s.vel=pv.velocity ? Math.hypot(pv.velocity.x,pv.velocity.y,pv.velocity.z) : null;
    s.alive=true; s.index=count;
    pos[count*3]=t.v.x; pos[count*3+1]=t.v.y; pos[count*3+2]=t.v.z;
    const c=s.cat.rgb; col[count*3]=c[0]; col[count*3+1]=c[1]; col[count*3+2]=c[2];
    count++;
  }
  satGeom.setDrawRange(0,count);
  posAttr.needsUpdate=true; colAttr.needsUpdate=true;
  satGeom.boundingSphere=null;   // positions moved; let picking recompute when needed

  if (state.selected>=0){
    const s=state.sats.find(x=>x.norad===state.selected && x.alive);
    if (s && s.pos){ selRing.position.copy(s.pos); selRing.lookAt(camera.position); selRing.visible=true; }
    else selRing.visible=false;
  }
}

// ============================================================================
//  Look angles / passes (relative to observer)
// ============================================================================
function observerGd(){
  if (!state.observer) return null;
  return { longitude:state.observer.lon*DEG, latitude:state.observer.lat*DEG, height:(state.observer.alt||0)/1000 };
}
function lookAnglesAt(satrec, date, obs){
  const pv=sat.propagate(satrec, date); if (!pv.position) return null;
  const gmst=sat.gstime(date);
  const ecf=sat.eciToEcf(pv.position, gmst);
  const la=sat.ecfToLookAngles(obs, ecf);
  return { az:la.azimuth/DEG, el:la.elevation/DEG, range:la.rangeSat };
}
// Next time a satellite rises above `maskDeg`, scanning up to `horizonMin` minutes.
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
// Next pass details for a specific satellite (AOS, peak elevation, duration).
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

// ============================================================================
//  UI
// ============================================================================
const $ = s=>document.querySelector(s);

function buildChips(){
  const box=$('#cats'); box.innerHTML='';
  for (const c of CATEGORIES){
    const el=document.createElement('button');
    el.className='chip'+(c.on?' on':''); el.style.setProperty('--c',c.color);
    el.innerHTML=`<span class="swatch"></span>${c.label}`;
    el.onclick=()=>toggleCategory(c, el);
    c.el=el; box.appendChild(el);
  }
}

function toggleCategory(cat, el){
  cat.on=!cat.on; el.classList.toggle('on',cat.on);
  if (cat.on){ requestGroup(cat); }
  else {
    state.sats=state.sats.filter(s=>s.cat.id!==cat.id);
    state.loadedGroups.delete(cat.group);
  }
  rebuildBeams();   // communication beams only show for enabled constellations
}

function requestGroup(cat){
  if (state.loadingGroups.has(cat.group)) return;
  state.loadingGroups.add(cat.group);
  cat.el && cat.el.classList.add('loading');
  window.Android && window.Android.requestTle(cat.group);
}

function ingestTle(group, text){
  state.loadingGroups.delete(group);
  const cat=CATEGORIES.find(c=>c.group===group); if(!cat) return;
  cat.el && cat.el.classList.remove('loading');
  state.sats=state.sats.filter(s=>s.cat.id!==cat.id);   // replace this group
  const col=new THREE.Color(cat.color); cat.rgb=[col.r,col.g,col.b];
  const lines=(text||'').split(/\r?\n/); let added=0;
  for (let i=0;i+2<lines.length && added<cat.cap;i+=3){
    const name=lines[i].trim(), l1=lines[i+1], l2=lines[i+2];
    if (!l1 || l1[0]!=='1' || !l2 || l2[0]!=='2') { i-=2; continue; } // resync if header missing
    try{
      const satrec=sat.twoline2satrec(l1,l2);
      const norad=parseInt(l2.substring(2,7),10);
      state.sats.push({ name, satrec, cat, norad, alive:false });
      added++;
    }catch(e){}
  }
  state.loadedGroups.add(group);
  hideBoot();
}

// ---- selection / raycast ----
const ray=new THREE.Raycaster(); ray.params.Points.threshold=0.04;
let down=null;
function onPointerDown(e){ down={x:e.clientX,y:e.clientY,t:performance.now()}; controls.autoRotate=false; }
function onPointerUp(e){
  if (!down) return;
  const moved=Math.hypot(e.clientX-down.x, e.clientY-down.y), dt=performance.now()-down.t;
  down=null;
  if (moved>10 || dt>400) return;          // it was a drag, not a tap
  const ndc=new THREE.Vector2((e.clientX/innerWidth)*2-1, -(e.clientY/innerHeight)*2+1);
  ray.setFromCamera(ndc, camera);

  // Priority: the blinking "communicating" GNSS satellites (generous pick radius, they're small/far).
  if (commSat && commSat.geometry.drawRange.count>0){
    ray.params.Points.threshold=0.18;
    commSat.geometry.boundingSphere=null;
    const ch=ray.intersectObject(commSat);
    ray.params.Points.threshold=0.04;
    if (ch.length){
      const bi=ch[0].index;
      if (commBeams[bi] && commBeams[bi].sat){ showGnssSat(commBeams[bi].sat); return; }
    }
  }

  // Otherwise the catalog satellite dots.
  const hits=ray.intersectObject(satPoints);
  if (hits.length){
    const idx=hits[0].index;
    const s=state.sats.find(x=>x.index===idx && x.alive);
    if (s) selectSat(s);
  }
}

// Populate the info card's 8-cell grid with arbitrary [label,value] pairs.
function setGrid(pairs){
  const cells=document.querySelectorAll('#info .grid .kv');
  cells.forEach((cell,i)=>{
    if(i<pairs.length){ cell.style.display=''; cell.querySelector('.k').textContent=pairs[i][0]; cell.querySelector('.v').textContent=pairs[i][1]; }
    else cell.style.display='none';
  });
}

function selectSat(s){
  state.selected=s.norad;
  trailDirty=true;                 // draw this satellite's orbit trail immediately
  const meta=resolveMeta(s.name, s.cat.group);
  $('#iName').textContent=s.name||'Unknown';
  $('#iTag').textContent=s.cat.label; $('#iTag').style.background=s.cat.color;

  let lookStr='enable location';
  const obs=observerGd();
  if (obs){ const la=lookAnglesAt(s.satrec, simDate(), obs); lookStr = la ? (la.el>0?`▲ ${la.el.toFixed(0)}° up, az ${la.az.toFixed(0)}°`:'below horizon') : '—'; }
  setGrid([
    ['Country', meta.country],
    ['Operator', meta.operator],
    ['Purpose', meta.purpose],
    ['NORAD ID', s.norad||'—'],
    ['Altitude', s.heightKm?Math.round(s.heightKm)+' km':'—'],
    ['Speed', s.vel?(s.vel).toFixed(2)+' km/s':'—'],
    ['Sub-point', (s.latDeg!=null)?`${s.latDeg.toFixed(1)}°, ${s.lonDeg.toFixed(1)}°`:'—'],
    ['From you', lookStr],
  ]);
  $('#info .pass').style.display='';
  $('#iMore').style.display='';
  $('#iMore').onclick=(ev)=>{ ev.preventDefault(); window.Android && window.Android.openUrl('https://www.n2yo.com/satellite/?s='+s.norad); };
  if (obs){
    $('#iPass').textContent='calculating…';
    setTimeout(()=>{
      const p=nextPass(s.satrec, obs, new Date());
      $('#iPass').textContent = p ? `${fmtClock(p.aos)} · peak ${p.peakEl}°${p.durMin?` · ~${p.durMin} min`:''}` : 'no pass in next 4 h';
    },20);
  } else $('#iPass').textContent='enable location for passes';
  $('#info').classList.add('show');
}

// Info for a GNSS satellite the phone is USING right now (real GnssStatus data).
function gnssMeta(cst){
  return ({
    GPS:{country:'USA',operator:'US Space Force',purpose:'Navigation (GPS)',alt:'~20,200 km'},
    GLONASS:{country:'Russia',operator:'Roscosmos / VKS',purpose:'Navigation (GLONASS)',alt:'~19,100 km'},
    Galileo:{country:'European Union',operator:'EUSPA / ESA',purpose:'Navigation (Galileo)',alt:'~23,200 km'},
    BeiDou:{country:'China',operator:'CSNO / CNSA',purpose:'Navigation (BeiDou)',alt:'~21,500 km'},
    QZSS:{country:'Japan',operator:'QZSS / JAXA',purpose:'Navigation (QZSS)',alt:'~32,000–39,000 km'},
    SBAS:{country:'Various',operator:'Regional augmentation',purpose:'GNSS augmentation',alt:'~35,786 km'},
    NavIC:{country:'India',operator:'ISRO',purpose:'Navigation (NavIC)',alt:'~36,000 km'},
  })[cst] || {country:'—',operator:'—',purpose:'Navigation satellite',alt:'—'};
}
function showGnssSat(sd){
  state.selected=-1; selRing.visible=false;         // not a catalog object
  const m=gnssMeta(sd.constellation);
  const col=CONST_COLORS[sd.constellation]||'#39E3FF';
  $('#iName').textContent=`${sd.constellation} · SV ${sd.svid}`;
  $('#iTag').textContent='● Transmitting to your phone'; $('#iTag').style.background=col;
  setGrid([
    ['Country', m.country],
    ['Operator', m.operator],
    ['Purpose', m.purpose],
    ['Signal C/N0', (sd.cn0!=null && sd.cn0>0)? sd.cn0.toFixed(1)+' dB-Hz':'—'],
    ['Elevation', sd.elevation!=null? Math.round(sd.elevation)+'°':'—'],
    ['Azimuth', sd.azimuth!=null? Math.round(sd.azimuth)+'°':'—'],
    ['Altitude', m.alt],
    ['Used in fix', sd.usedInFix?'✓ yes':'no'],
  ]);
  $('#info .pass').style.display='none';
  $('#iMore').style.display='none';
  $('#info').classList.add('show');
}
$('#infoClose').onclick=()=>{ $('#info').classList.remove('show'); state.selected=-1; selRing.visible=false; };

// ============================================================================
//  GNSS panel (real "satellite in use" data from the phone)
// ============================================================================
const CONST_COLORS={GPS:'#39E3FF',GLONASS:'#ff7b7b',Galileo:'#8affc1',BeiDou:'#ffcb5b',QZSS:'#b58bff',SBAS:'#5bd0ff',NavIC:'#ff9edb',Unknown:'#93a7c4'};
function renderGnss(){
  const g=state.gnss;
  if(!g){ return; }
  $('#gnssUsed').textContent=g.used; $('#gnssTotal').textContent=g.total;
  const sats=g.sats||[];
  // status line
  const status=$('#gnssStatus');
  if (g.total===0){ status.textContent='Acquiring satellites… (go outdoors)'; status.style.color='var(--warn)'; }
  else if (g.used===0){ status.textContent='Signals found, computing fix…'; status.style.color='var(--warn)'; }
  else { status.textContent='📍 Position locked'; status.style.color='var(--good)'; }
  // per-constellation counts (used in fix)
  const counts={};
  for (const s of sats){ if(!counts[s.constellation]) counts[s.constellation]={u:0,t:0}; counts[s.constellation].t++; if(s.usedInFix) counts[s.constellation].u++; }
  const box=$('#consts'); box.innerHTML='';
  Object.keys(counts).sort().forEach(k=>{
    const el=document.createElement('span'); el.className='cst';
    el.style.borderColor=(CONST_COLORS[k]||'#93a7c4')+'55';
    el.innerHTML=`${k} <b>${counts[k].u}</b>/${counts[k].t}`;
    box.appendChild(el);
  });
  drawSkyplot(sats);
}
function drawSkyplot(sats){
  const c=$('#skyplot'), x=c.getContext('2d'), W=c.width, H=c.height, cx=W/2, cy=H/2, R=W/2-6;
  x.clearRect(0,0,W,H);
  x.strokeStyle='rgba(150,110,220,.34)'; x.lineWidth=1;
  [1,0.66,0.33].forEach(f=>{ x.beginPath(); x.arc(cx,cy,R*f,0,7); x.stroke(); });
  x.beginPath(); x.moveTo(cx-R,cy); x.lineTo(cx+R,cy); x.moveTo(cx,cy-R); x.lineTo(cx,cy+R); x.stroke();
  x.fillStyle='#b9a6e6'; x.font='9px sans-serif'; x.textAlign='center'; x.fillText('N',cx,cy-R+9);
  const colors=CONST_COLORS;
  for (const s of sats){
    if (s.elevation<0 || s.azimuth==null) continue;
    const rr=R*(1-s.elevation/90), a=(s.azimuth-90)*DEG;
    const px=cx+rr*Math.cos(a), py=cy+rr*Math.sin(a);
    x.beginPath(); x.arc(px,py,s.usedInFix?4:2.6,0,7);
    x.fillStyle=colors[s.constellation]||'#8aa2ba'; x.globalAlpha=s.usedInFix?1:0.45; x.fill(); x.globalAlpha=1;
    if (s.usedInFix){ x.strokeStyle='rgba(255,255,255,.7)'; x.lineWidth=1; x.stroke(); }
  }
}

// Next GNSS satellite to rise over the observer (independent of which the phone tracks).
let lastRiseCalc=0;
function updateNextRise(now){
  if (now-lastRiseCalc<15000) return; lastRiseCalc=now;
  const obs=observerGd(); if(!obs){ $('#nextRise').textContent='enable location'; return; }
  const gnssSats=state.sats.filter(s=>s.cat.gnss);
  if (!gnssSats.length){ $('#nextRise').textContent='loading GNSS…'; return; }
  const from=new Date(); let best=null;
  for (const s of gnssSats){
    const la=lookAnglesAt(s.satrec, from, obs);
    if (la && la.el>=5) continue;                 // already up
    const r=nextRise(s.satrec, obs, from);
    if (r && (!best || r.secs<best.secs)) best={secs:r.secs, name:s.name};
  }
  riseTarget = best ? { at: Date.now()+best.secs*1000, name:best.name } : null;
}
let riseTarget=null;
function tickRise(){
  if (!riseTarget){ return; }
  const left=Math.max(0,(riseTarget.at-Date.now())/1000);
  $('#nextRise').textContent = left<1 ? 'now' : fmtDur(left);
}

// ============================================================================
//  Formatting helpers
// ============================================================================
function fmtDur(s){ s=Math.round(s); const m=Math.floor(s/60), ss=s%60; return m>0?`${m}m ${ss}s`:`${ss}s`; }
function fmtClock(d){ return d.toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'}); }

// ============================================================================
//  Native bridge  (native -> JS)
// ============================================================================
window.SatBridge = {
  onTle(group, text, source){
    ingestTle(group, text);
    const cat=CATEGORIES.find(c=>c.group===group), name=cat?cat.label:group;
    if (source==='offline') toast(`${name}: showing offline data (couldn't reach Celestrak)`);
    else if (source==='none') toast(`${name}: no live data — check connection`);
  },
  onGnss(json){ try{ state.gnss=JSON.parse(json); renderGnss(); rebuildBeams(); logStatus(state.gnss); }catch(e){} },
  onMeasurements(json){ try{ logMeasurements(JSON.parse(json)); }catch(e){} },
  onLocation(lat, lon, alt){
    state.observer={ lat, lon, alt:alt||0 };
    obsMarker.position.copy(llToVec3(lat,lon,SCENE_R*1.02)); obsMarker.visible=true;
    // On the first fix, smoothly swing the camera so YOU are front-and-center.
    if (!state._centered){
      state._centered=true;
      const n=llToVec3(lat,lon,1).normalize();
      const d=camera.position.length();
      camGoal=n.multiplyScalar(d); camGoal.y+=0.35; camGoalDist=camGoal.length();
      controls.autoRotate=false;
    }
    rebuildBeams();
    lastRiseCalc=0;
  },
  onPermission(granted){ if(!granted) toast('Location off — GNSS & passes disabled'); },
  onUpdate(json){ try{ renderUpdate(JSON.parse(json)); }catch(e){} },
};

// ============================================================================
//  About sheet
// ============================================================================
function openSheet(){ $('#sheet').classList.add('show'); $('#backdrop').classList.add('show'); }
function closeSheet(){ $('#sheet').classList.remove('show'); $('#backdrop').classList.remove('show'); }
$('#settingsBtn').onclick=openSheet;
$('#closeSheet').onclick=closeSheet;
document.querySelectorAll('[data-ext]').forEach(a=>a.onclick=e=>{
  e.preventDefault(); window.Android && window.Android.openUrl(a.dataset.ext);
});
$('#backdrop').onclick=closeSheet;
$('#updAuto').onchange=e=>{ window.Android && window.Android.updateSetAuto(e.target.checked); };

// ---- updates -------------------------------------------------------------
// Redrawn from scratch on every state push. Nothing here remembers anything:
// the phase decides the sentence, the bar and the buttons, so the sheet can
// never disagree with what the app is actually doing.
function fmtBytes(n){
  if (!n || n <= 0) return '';
  return n < 1048576 ? `${Math.ceil(n/1024)} kB` : `${(n/1048576).toFixed(1)} MB`;
}

function renderUpdate(u){
  const msg=$('#updMsg'), notes=$('#updNotes'), bar=$('#updBar'), row=$('#updActions');
  $('#updInstalled').textContent=`Orbit ${u.installed||''}`.trim();
  $('#updAuto').checked=!!u.auto;

  msg.className='updmsg';
  msg.textContent='';
  notes.textContent='';
  bar.classList.remove('show');
  row.innerHTML='';

  if (!u.canSelfUpdate){
    msg.textContent='This build cannot replace itself.';
    return;
  }

  const button=(label,fn,id)=>{
    const b=document.createElement('button');
    b.className='btn'; b.textContent=label; if(id) b.id=id; b.onclick=fn;
    row.appendChild(b);
    return b;
  };
  const check=()=>button('Check for updates',()=>window.Android&&window.Android.updateCheck());

  switch(u.phase){
    case 'checking':
      msg.textContent='Checking n3d-store.com…';
      break;

    case 'current':
      msg.textContent='This is the newest version.';
      check();
      break;

    case 'available': {
      // The size goes in the sentence, not on the button: at phone width two
      // buttons share the row, and "Download and install - 2.3 MB" wraps to two
      // lines inside its pill while "Not now" stays one, which reads as a
      // mistake rather than as emphasis.
      const size=fmtBytes(u.size);
      msg.className='updmsg new';
      msg.textContent=size?`Version ${u.version} is out \u00b7 ${size}`:`Version ${u.version} is out.`;
      if (u.notes) notes.textContent=u.notes;
      button('Download and install',
        ()=>window.Android&&window.Android.updateDownload()).classList.add('active');
      button('Not now',()=>window.Android&&window.Android.updateDismiss());
      break;
    }

    case 'downloading': {
      msg.textContent='Downloading…';
      bar.classList.add('show');
      const pct=u.total>0 ? Math.min(100,(u.bytes/u.total)*100) : 0;
      bar.firstElementChild.style.width=`${pct}%`;
      button('Cancel',()=>window.Android&&window.Android.updateCancel());
      break;
    }

    case 'allow':
      msg.textContent='The update is downloaded and checked. Android will not let an app '
        +'install anything until you switch Orbit on under \u201cInstall unknown apps\u201d '
        +'\u2014 one switch, on the screen this button opens.';
      button('Open that setting',
        ()=>window.Android&&window.Android.updateGrantInstall()).classList.add('active');
      break;

    case 'installing':
      msg.textContent='Opening Android\u2019s installer…';
      break;

    case 'failed':
      msg.className='updmsg bad';
      msg.textContent=[u.error,u.detail].filter(Boolean).join(' ');
      check();
      break;

    default:
      check();
  }
}

$('#gnssHead').onclick=()=>$('#gnss').classList.toggle('collapsed');
$('#gnssToggle').onclick=()=>{
  const p=$('#gnss'); p.classList.toggle('hidden');
  $('#gnssToggle').classList.toggle('active', !p.classList.contains('hidden'));
};
$('#logToggle').onclick=()=>{
  const p=$('#log'); p.classList.toggle('show');
  $('#logToggle').classList.toggle('active', p.classList.contains('show'));
};
$('#logClose').onclick=()=>{ $('#log').classList.remove('show'); $('#logToggle').classList.remove('active'); };

let toastT;
function toast(msg){ const t=$('#toast'); t.textContent=msg; t.classList.add('show'); clearTimeout(toastT); toastT=setTimeout(()=>t.classList.remove('show'),2600); }
function hideBoot(){ const b=$('#boot'); if(b && !b.classList.contains('hide')){ b.classList.add('hide'); setTimeout(()=>b.remove(),600);} }

// ---- live signal log (real raw GNSS data received from satellites) ----
const LOG_MAX=260;
let lastStatusLog=0;
function fmtTime(ms){ return new Date(ms).toTimeString().slice(0,8); }
function logRow(html, cls){
  const body=$('#logBody'); if(!body) return;
  const first=body.firstElementChild;
  if(first && first.classList.contains('logmuted')) body.removeChild(first);
  const div=document.createElement('div'); div.className='logrow'+(cls?' '+cls:''); div.innerHTML=html;
  body.insertBefore(div, body.firstChild);
  while(body.childElementCount>LOG_MAX) body.removeChild(body.lastChild);
  const cnt=$('#logCount'); if(cnt) cnt.textContent=body.childElementCount;
}
function logMeasurements(d){
  const t=fmtTime(d.t||Date.now());
  (d.m||[]).forEach(m=>{
    const col=CONST_COLORS[m.constellation]||'#9fb0d0';
    logRow(`<span class="lt">${t}</span> <span class="lc" style="color:${col}">${m.constellation}-${m.svid}</span> `+
      `C/N0 <b>${m.cn0}</b> · PRR ${m.prr} m/s`+(m.freqMHz?` · ${m.freqMHz} MHz`:''));
  });
}
function logStatus(g){
  const now=Date.now(); if(now-lastStatusLog<1500) return; lastStatusLog=now;
  const parts={};
  (g.sats||[]).forEach(s=>{ if(s.usedInFix) parts[s.constellation]=(parts[s.constellation]||0)+1; });
  const brk=Object.keys(parts).sort().map(k=>`${k}×${parts[k]}`).join(' ');
  logRow(`<span class="lt">${fmtTime(now)}</span> <span class="lfix">◉ FIX</span> ${g.used}/${g.total} sats${brk?' · '+brk:''}`, 'logfix');
}

// ============================================================================
//  Main loop
// ============================================================================
// Orbit trail — shown ONLY for the currently selected satellite (one full orbit, centered on now).
let lastTrail=0, trailDirty=false;
function updateSelectedTrail(now){
  if (state.selected<0){ if(trailGeom.drawRange.count!==0) trailGeom.setDrawRange(0,0); return; }
  if (!trailDirty && now-lastTrail<800) return;
  lastTrail=now; trailDirty=false;
  const s=state.sats.find(x=>x.norad===state.selected);
  if (!s || !s.satrec || !s.satrec.no){ trailGeom.setDrawRange(0,0); return; }
  const periodMin=(2*Math.PI)/s.satrec.no;
  if (!isFinite(periodMin)||periodMin<=0){ trailGeom.setDrawRange(0,0); return; }
  const base=simDate(), tp=trailPos.array, tc=trailCol.array, c=s.cat.rgb;
  const N=120, span=periodMin;
  let seg=0, prev=null, pf=0;
  for (let i=0;i<=N;i++){
    const tmin=-span*0.5 + span*(i/N);
    const d=new Date(base.getTime()+tmin*60000);
    let pv; try{ pv=sat.propagate(s.satrec,d);}catch(e){ prev=null; continue; }
    if(!pv || !pv.position){ prev=null; continue; }
    let v; try{ v=eciToScene(pv.position, sat.gstime(d)).v;}catch(e){ prev=null; continue; }
    const f=Math.max(0.12, 1-Math.abs(i/N-0.5)*2);   // brightest at 'now'
    if(prev){
      tp[seg*6]=prev.x;tp[seg*6+1]=prev.y;tp[seg*6+2]=prev.z;
      tp[seg*6+3]=v.x;tp[seg*6+4]=v.y;tp[seg*6+5]=v.z;
      tc[seg*6]=c[0]*pf;tc[seg*6+1]=c[1]*pf;tc[seg*6+2]=c[2]*pf;
      tc[seg*6+3]=c[0]*f;tc[seg*6+4]=c[1]*f;tc[seg*6+5]=c[2]*f;
      seg++;
    }
    prev=v; pf=f;
  }
  trailGeom.setDrawRange(0,seg*2);
  trailPos.needsUpdate=true; trailCol.needsUpdate=true;
}

// ---- "Communication" beams: your phone <-> the GNSS satellites it is USING right now ----
// Real data: each used-in-fix satellite's live azimuth/elevation (GnssStatus) becomes a 3D beam
// from your location, with a pulse travelling inbound (satellite -> phone) and a blinking dot at
// the transmitting satellite. Only constellations whose category is enabled are shown.
let commLines, commPos, commCol, commPulse, commPulsePos, commPulseCol,
    commSat, commSatPos, commSatCol, commBeams=[];
const MAX_BEAMS=40;
function buildComm(){
  const lg=new THREE.BufferGeometry();
  commPos=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*2*3),3).setUsage(THREE.DynamicDrawUsage);
  commCol=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*2*3),3).setUsage(THREE.DynamicDrawUsage);
  lg.setAttribute('position',commPos); lg.setAttribute('color',commCol); lg.setDrawRange(0,0);
  commLines=new THREE.LineSegments(lg,new THREE.LineBasicMaterial({vertexColors:true,transparent:true,opacity:0.6,depthWrite:false,blending:THREE.AdditiveBlending}));
  scene.add(commLines);
  // travelling signal pulse (satellite -> phone)
  const pg=new THREE.BufferGeometry();
  commPulsePos=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*3),3).setUsage(THREE.DynamicDrawUsage);
  commPulseCol=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*3),3).setUsage(THREE.DynamicDrawUsage);
  pg.setAttribute('position',commPulsePos); pg.setAttribute('color',commPulseCol); pg.setDrawRange(0,0);
  commPulse=new THREE.Points(pg,new THREE.PointsMaterial({size:11,map:discTexture(),vertexColors:true,transparent:true,depthWrite:false,blending:THREE.AdditiveBlending,sizeAttenuation:false}));
  scene.add(commPulse);
  // blinking dot at each transmitting satellite
  const sg=new THREE.BufferGeometry();
  commSatPos=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*3),3).setUsage(THREE.DynamicDrawUsage);
  commSatCol=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*3),3).setUsage(THREE.DynamicDrawUsage);
  sg.setAttribute('position',commSatPos); sg.setAttribute('color',commSatCol); sg.setDrawRange(0,0);
  commSat=new THREE.Points(sg,new THREE.PointsMaterial({size:28,map:discTexture(),vertexColors:true,transparent:true,depthWrite:false,blending:THREE.AdditiveBlending,sizeAttenuation:false}));
  scene.add(commSat);
}
function beamConstEnabled(constName){
  const catId=CONST_TO_CAT[constName];
  if(!catId) return true;                       // QZSS/SBAS/NavIC have no toggle -> always shown
  const cat=CATEGORIES.find(c=>c.id===catId);
  return !cat || cat.on;
}
function rebuildBeams(){
  commBeams=[];
  const o=state.observer, g=state.gnss;
  if (commLines){ commLines.geometry.setDrawRange(0,0); commPulse.geometry.setDrawRange(0,0); commSat.geometry.setDrawRange(0,0); }
  if(!o || !g || !g.sats) return;
  const lat=o.lat*DEG, lon=o.lon*DEG;
  const cLat=Math.cos(lat), sLat=Math.sin(lat), cLon=Math.cos(lon), sLon=Math.sin(lon);
  const up=new THREE.Vector3(cLat*cLon, sLat, -cLat*sLon);          // local ENU basis in world space
  const east=new THREE.Vector3(-sLon,0,-cLon);
  const north=new THREE.Vector3(-sLat*cLon, cLat, sLat*sLon);
  const obsPos=llToVec3(o.lat,o.lon,SCENE_R*1.02);                  // start AT the "you are here" dot
  const lp=commPos.array, lc=commCol.array, sp=commSatPos.array, scc=commSatCol.array;
  for(const s of g.sats){
    if(commBeams.length>=MAX_BEAMS) break;
    if(!s.usedInFix || s.elevation==null || s.elevation<0 || s.azimuth==null) continue;
    if(!beamConstEnabled(s.constellation)) continue;                // respect category toggles
    const az=s.azimuth*DEG, el=s.elevation*DEG;
    const dir=new THREE.Vector3()
      .addScaledVector(east, Math.cos(el)*Math.sin(az))
      .addScaledVector(north, Math.cos(el)*Math.cos(az))
      .addScaledVector(up, Math.sin(el)).normalize();
    const far=obsPos.clone().addScaledVector(dir, 3.1);             // ~GNSS shell distance
    const cc=new THREE.Color(CONST_COLORS[s.constellation]||'#39E3FF');
    const i=commBeams.length;
    commBeams.push({a:obsPos.clone(), b:far, c:[cc.r,cc.g,cc.b], sat:s});
    lp[i*6]=obsPos.x;lp[i*6+1]=obsPos.y;lp[i*6+2]=obsPos.z;
    lp[i*6+3]=far.x;lp[i*6+4]=far.y;lp[i*6+5]=far.z;
    lc[i*6]=cc.r*0.25;lc[i*6+1]=cc.g*0.25;lc[i*6+2]=cc.b*0.25;      // dim at phone
    lc[i*6+3]=cc.r;lc[i*6+4]=cc.g;lc[i*6+5]=cc.b;                   // bright at satellite
    sp[i*3]=far.x;sp[i*3+1]=far.y;sp[i*3+2]=far.z;
    scc[i*3]=cc.r;scc[i*3+1]=cc.g;scc[i*3+2]=cc.b;
  }
  commLines.geometry.setDrawRange(0,commBeams.length*2);
  commPos.needsUpdate=true; commCol.needsUpdate=true;
  commPulse.geometry.setDrawRange(0,commBeams.length);
  commSat.geometry.setDrawRange(0,commBeams.length);
  commSatPos.needsUpdate=true; commSatCol.needsUpdate=true;
}
function updateComm(now){
  if(!commBeams.length) return;
  const pp=commPulsePos.array, pc=commPulseCol.array, scc=commSatCol.array;
  const phase=(now*0.0009)%1;
  const blink=0.28+0.72*(0.5+0.5*Math.sin(now*0.007));   // transmitting-satellite dots blink
  commBeams.forEach((bm,i)=>{
    const u=(phase + i*0.11)%1;                           // 0 = at satellite, 1 = at phone (inbound)
    pp[i*3]=bm.b.x+(bm.a.x-bm.b.x)*u;
    pp[i*3+1]=bm.b.y+(bm.a.y-bm.b.y)*u;
    pp[i*3+2]=bm.b.z+(bm.a.z-bm.b.z)*u;
    const br=0.5+0.5*Math.sin(u*Math.PI);
    pc[i*3]=bm.c[0]*br; pc[i*3+1]=bm.c[1]*br; pc[i*3+2]=bm.c[2]*br;
    scc[i*3]=bm.c[0]*blink; scc[i*3+1]=bm.c[1]*blink; scc[i*3+2]=bm.c[2]*blink;
  });
  commPulsePos.needsUpdate=true; commPulseCol.needsUpdate=true; commSatCol.needsUpdate=true;
}

let camGoal=null, camGoalDist=0;
function animate(now){
  requestAnimationFrame(animate);
  // All logic guarded so a single stray error can NEVER freeze the render loop.
  try {
    // Smooth camera swing toward the observer on first fix.
    if (camGoal){
      camera.position.lerp(camGoal, 0.06);
      camera.position.setLength(camGoalDist);       // keep constant distance -> pure swing
      if (camera.position.distanceTo(camGoal) < 0.03){ camGoal=null; controls.autoRotate=true; }
    }
    controls.update();
    propagate(now);
    updateSelectedTrail(now);
    updateComm(now);
    updateNextRise(now);
    tickRise();
    // Keep markers a roughly constant on-screen size, and pulse the "you are here" ring.
    const camDist=camera.position.length();
    const ms=Math.max(0.55, Math.min(camDist*0.34, 7));
    satPoints.material.size = Math.max(7, Math.min(18, 22 - camDist*1.0));  // smaller when zoomed out
    selRing.scale.setScalar(ms);
    if (obsMarker.visible){
      obsMarker.scale.setScalar(ms);
      obsRing.lookAt(camera.position);
      const p=1+0.6*(0.5+0.5*Math.sin(now*0.004));
      obsRing.scale.setScalar(p);
      obsRing.material.opacity=0.6*(2-p);
    }
  } catch(e){ /* swallow; keep animating */ }
  try { renderer.render(scene, camera); } catch(e){}
}

// ============================================================================
//  Boot
// ============================================================================
function boot(){
  if (!sat){ document.querySelector('#boot .t').textContent='Failed to load orbit engine (offline?)'; return; }
  initScene();
  // Localhost-only debug handle (harmless; never reachable from file:///android_asset in the app).
  if (location.hostname==='localhost'){
    window.__orbit={ state, THREE, selectSat, showGnssSat, ray, camera:()=>camera, satPoints:()=>satPoints, commSat:()=>commSat, commBeams:()=>commBeams };
  }
  buildChips();
  requestAnimationFrame(animate);
  // Tell native we're ready, then load the default-on categories.
  window.Android && window.Android.ready();
  for (const c of CATEGORIES) if (c.on) requestGroup(c);
  // Safety: if native never answers (e.g. running in a plain browser), stop the spinner.
  setTimeout(hideBoot, 8000);
}
boot();
