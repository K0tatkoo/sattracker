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
// GNSS constellation -> the colour token it is drawn in (styles.css, --c-<key>).
const CONST_KEY = { GPS:'gps', GLONASS:'glonass', Galileo:'galileo', BeiDou:'beidou', QZSS:'qzss', SBAS:'sbas', NavIC:'navic' };
function constKey(c){ return CONST_KEY[c] || 'unknown'; }

// ---- Categories the user can toggle. group = Celestrak GROUP param. -------------
// Colours are not here: each one is the --c-<id> token in styles.css, which
// has a dark and a light value. See applyTheme().
const CATEGORIES = [
  { id:'stations', group:'stations', label:'ISS & Stations', cap:40,  on:true  },
  { id:'gps',      group:'gps-ops',  label:'GPS',            cap:40,  on:true,  gnss:true },
  { id:'glonass',  group:'glo-ops',  label:'GLONASS',        cap:40,  on:false, gnss:true },
  { id:'galileo',  group:'galileo',  label:'Galileo',        cap:40,  on:false, gnss:true },
  { id:'beidou',   group:'beidou',   label:'BeiDou',         cap:60,  on:false, gnss:true },
  { id:'starlink', group:'starlink', label:'Starlink',       cap:300, on:false },
  { id:'weather',  group:'weather',  label:'Weather',        cap:40,  on:false },
  { id:'science',  group:'science',  label:'Science',        cap:40,  on:false },
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
  observer: null,           // {lat, lon, alt(m)}
  gnss: null,               // last GNSS payload
  selected: -1,
  loadingGroups: new Set(),
  loadedGroups: new Set(),
};

// ============================================================================
//  Theme
// ============================================================================
// The page follows the phone's dark/light setting: native stamps data-theme
// before first paint and calls SatBridge.onTheme() when it changes. Every
// colour the scene uses is read back from the CSS tokens, so the globe, the
// chips and the panels can never disagree about what "GPS" or "the surface"
// looks like.
const root = document.documentElement;
function cssVar(name){ return getComputedStyle(root).getPropertyValue(name).trim(); }
function isLight(){
  const t = root.getAttribute('data-theme');
  if (t) return t === 'light';
  return !!(window.matchMedia && matchMedia('(prefers-color-scheme: light)').matches);
}
const THEME = { light:false };

// ============================================================================
//  three.js scene
// ============================================================================
let renderer, scene, camera, controls, earth, earthMat, earthImg, gratMat, atm, plinth, ambient, lamp,
    stars, nebulae=[], satPoints, satGeom, selRing, obsDot;
let posAttr, colAttr;
const MAX_SATS = 4000;
const _v = new THREE.Vector3(), _w = new THREE.Vector3(), _p = new THREE.Vector3();

function initScene(){
  const host = document.getElementById('scene');
  renderer = new THREE.WebGLRenderer({ antialias:true, alpha:false });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.setSize(innerWidth, innerHeight);
  host.appendChild(renderer.domElement);

  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(45, innerWidth/innerHeight, 0.01, 100);
  camera.position.set(0, 1.2, 3.0);
  scene.add(camera);             // so the lamp hanging off it is part of the scene

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

  // The light is fixed at the top-left of the SCREEN, like on every other n3d
  // surface: the lamp rides on the camera, so however the globe is turned the
  // lit side faces the same way as the light on the panels above it. (It is
  // not the Sun — the old world-fixed light was not the Sun either.)
  ambient = new THREE.AmbientLight(0xffffff, 0.78);
  scene.add(ambient);
  lamp = new THREE.DirectionalLight(0xffffff, 0.5);
  lamp.position.set(-2.2, 2.4, 1.2);
  camera.add(lamp);
  // Its target has to ride along too: left at the world origin, the light's
  // direction swings toward the view axis as you zoom out and the highlight
  // slides off the top-left.
  lamp.target.position.set(0, 0, -3);
  camera.add(lamp.target);

  buildPlinth();
  buildEarth();
  buildStars();
  buildSatSystem();
  buildSelectionRing();
  buildComm();

  addEventListener('resize', onResize);
  const el = renderer.domElement;
  el.addEventListener('pointerdown', onPointerDown);
  el.addEventListener('pointerup', onPointerUp);
  el.addEventListener('pointercancel', onPointerCancel);
}

// ---- the globe ---------------------------------------------------------------
// The bundled texture is a greyscale map: land ~0, deep ocean ~12-17, shelves
// ~25-30 (of 255). Rather than tint it — which can only ever make it darker —
// it is repainted once per theme into that theme's own land / ocean colours,
// keeping the shelf gradient. On the light theme that turns it into a light
// globe with the continents still readable, which a multiplied tint cannot do.
const EARTH_PALETTE = {
  dark:  { land:[0x19,0x1b,0x21], deep:[0x2e,0x2e,0x41], shelf:[0x3d,0x38,0x5a] },
  light: { land:[0xf1,0xf3,0xf7], deep:[0xb8,0xbe,0xd6], shelf:[0xcc,0xd1,0xe3] },
};
const earthTex = {};

function buildEarth(){
  const geo = new THREE.SphereGeometry(SCENE_R, 96, 96);
  earthMat = new THREE.MeshLambertMaterial({ color:0x2a2c38 });
  earth = new THREE.Mesh(geo, earthMat);
  // No rotation: three's SphereGeometry UV maps Greenwich (lon 0) to +X and lon -90 to +Z,
  // which exactly matches llToVec3() used for satellites/markers — so they all line up.
  earth.rotation.y = 0;
  scene.add(earth);

  // Prefer the embedded data: URI (window.EARTH_TEX) — a file:// image can't be
  // uploaded to WebGL from a file:// page (blocked as cross-origin), and can't be
  // read back for repainting either; a data: URI always can.
  earthImg = new Image();
  earthImg.onload = () => setEarthTexture();
  earthImg.onerror = () => {};
  earthImg.src = window.EARTH_TEX || 'lib/earth-dark.jpg';

  // Graticule (lat/lon grid) in the accent, faint.
  const grat = new THREE.Group();
  gratMat = new THREE.LineBasicMaterial({ color:0x9b7cff, transparent:true, opacity:0.14, depthWrite:false });
  for (let lat=-60; lat<=60; lat+=30){
    const pts=[]; for (let lon=-180; lon<=180; lon+=5) pts.push(llToVec3(lat,lon,SCENE_R*1.001));
    grat.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), gratMat));
  }
  for (let lon=-180; lon<180; lon+=30){
    const pts=[]; for (let lat=-90; lat<=90; lat+=5) pts.push(llToVec3(lat,lon,SCENE_R*1.001));
    grat.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), gratMat));
  }
  earth.add(grat);

  // Atmosphere: a soft accent rim on the dark theme. On the light theme an
  // additive glow over a light surface is invisible, so it is hidden there.
  atm = new THREE.Mesh(
    new THREE.SphereGeometry(SCENE_R*1.035, 64, 64),
    new THREE.ShaderMaterial({
      transparent:true, side:THREE.BackSide, blending:THREE.AdditiveBlending, depthWrite:false,
      uniforms:{ uColor:{ value:new THREE.Color(0x9b7cff) } },
      vertexShader:`varying vec3 vN; void main(){ vN=normalize(normalMatrix*normal); gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);} `,
      fragmentShader:`uniform vec3 uColor; varying vec3 vN; void main(){ float i=pow(0.62-dot(vN,vec3(0,0,1.0)),3.0); gl_FragColor=vec4(uColor*0.85,1.0)*i; }`
    })
  );
  scene.add(atm);
}

function setEarthTexture(){
  const key = THEME.light ? 'light' : 'dark';
  if (!earthImg || !earthImg.complete || !earthImg.naturalWidth){
    earthMat.color.set(key==='light' ? 0xdfe2ec : 0x2a2c38);
    return;
  }
  if (earthTex[key] === undefined) earthTex[key] = paletteTexture(earthImg, EARTH_PALETTE[key]);
  if (earthTex[key]){
    earthMat.map = earthTex[key]; earthMat.color.set(0xffffff);
  } else {
    // Could not repaint (a tainted canvas): fall back to the plain map, tinted.
    if (!earthTex.raw){ earthTex.raw = new THREE.Texture(earthImg); earthTex.raw.needsUpdate = true; }
    earthMat.map = earthTex.raw; earthMat.color.set(key==='light' ? 0xffffff : 0x9a86c8);
  }
  earthMat.needsUpdate = true;
}

function paletteTexture(img, pal){
  try {
    const w = img.naturalWidth, h = img.naturalHeight;
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const x = c.getContext('2d'); x.drawImage(img, 0, 0);
    const im = x.getImageData(0, 0, w, h), d = im.data;
    const L = pal.land, D = pal.deep, S = pal.shelf;
    // Two lookup tables over the 256 grey levels, so the per-pixel loop is a read.
    const lut = new Uint8ClampedArray(256*3);
    for (let g=0; g<256; g++){
      const sea = Math.min(1, Math.max(0, (g-3)/6));          // land -> ocean over 3..9
      const t = Math.min(1, Math.max(0, (g-11)/18));          // deep -> shelf over 11..29
      for (let k=0; k<3; k++){
        const ocean = D[k] + (S[k]-D[k])*t;
        lut[g*3+k] = L[k] + (ocean-L[k])*sea;
      }
    }
    for (let i=0; i<d.length; i+=4){
      const g = (d[i] + d[i+1] + d[i+2]) / 3 | 0;
      d[i] = lut[g*3]; d[i+1] = lut[g*3+1]; d[i+2] = lut[g*3+2];
    }
    x.putImageData(im, 0, 0);
    const tex = new THREE.CanvasTexture(c);
    tex.anisotropy = Math.min(4, renderer.capabilities.getMaxAnisotropy());
    return tex;
  } catch (e) { return null; }
}

// ---- the raised globe --------------------------------------------------------
// The globe is a raised n3d surface too: the same pair of soft shadows as a
// card (dark bottom-right, light top-left), drawn on a camera-facing plane
// through the Earth's centre. The sphere occludes the middle; what shows is the
// rim of shadow around it. Sized to the sphere's true silhouette at that
// plane, and proportional to it, so it holds at every zoom.
function buildPlinth(){
  plinth = new THREE.Mesh(
    new THREE.PlaneGeometry(3.4, 3.4),
    new THREE.ShaderMaterial({
      transparent:true, depthWrite:false,
      uniforms:{
        uDark:{ value:new THREE.Color(0x171920) }, uLight:{ value:new THREE.Color(0x2d313a) },
        uOff:{ value:0.07 }, uBlur:{ value:0.15 }, uAlpha:{ value:1 },
      },
      vertexShader:`varying vec2 vP; void main(){ vP=position.xy; gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);} `,
      fragmentShader:`uniform vec3 uDark, uLight; uniform float uOff, uBlur, uAlpha; varying vec2 vP;
        float disc(vec2 c){ return 1.0 - smoothstep(1.0 - uBlur, 1.0 + uBlur, length(vP - c)); }
        void main(){
          float d = disc(vec2(uOff, -uOff));      // dark: away from the light
          float l = disc(vec2(-uOff, uOff));      // light: facing it
          float a = d + l*(1.0 - d);              // dark drawn over light, as CSS stacks them
          if (a < 0.002) discard;
          vec3 col = (uDark*d + uLight*l*(1.0 - d)) / a;
          gl_FragColor = vec4(col, a*uAlpha);
        }`
    })
  );
  plinth.renderOrder = -10;       // under everything that is transparent
  scene.add(plinth);
}

function buildStars(){
  const n=1800, arr=new Float32Array(n*3), col=new Float32Array(n*3);
  const tints=[[1,1,1],[0.75,0.68,1],[1,0.7,0.95],[0.6,0.8,1],[0.85,0.75,1]];
  for (let i=0;i<n;i++){
    const r=34+Math.random()*40, t=Math.random()*Math.PI*2, p=Math.acos(2*Math.random()-1);
    arr[i*3]=r*Math.sin(p)*Math.cos(t); arr[i*3+1]=r*Math.cos(p); arr[i*3+2]=r*Math.sin(p)*Math.sin(t);
    const c=tints[(Math.random()*tints.length)|0], b=0.45+Math.random()*0.5;
    col[i*3]=c[0]*b; col[i*3+1]=c[1]*b; col[i*3+2]=c[2]*b;
  }
  const g=new THREE.BufferGeometry();
  g.setAttribute('position',new THREE.BufferAttribute(arr,3));
  g.setAttribute('color',new THREE.BufferAttribute(col,3));
  stars=new THREE.Points(g, new THREE.PointsMaterial({ size:0.07, sizeAttenuation:true, vertexColors:true, transparent:true, map:discTexture(), depthWrite:false }));
  stars.renderOrder = -20;
  scene.add(stars);

  // Faint nebula clouds for a galaxy backdrop.
  const nebColors=[0x6a2cff,0xb02cff,0x2c66ff];
  for (let i=0;i<3;i++){
    const s=new THREE.Sprite(new THREE.SpriteMaterial({ map:discTexture(), color:nebColors[i], transparent:true, opacity:0.07, depthWrite:false, blending:THREE.AdditiveBlending }));
    const r=45, t=Math.random()*Math.PI*2, p=Math.acos(2*Math.random()-1);
    s.position.set(r*Math.sin(p)*Math.cos(t), r*Math.cos(p), r*Math.sin(p)*Math.sin(t));
    s.scale.setScalar(30+Math.random()*20);
    s.renderOrder = -20;
    nebulae.push(s); scene.add(s);
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
  _disc=new THREE.CanvasTexture(c); return _disc;
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
  _dot=new THREE.CanvasTexture(c); return _dot;
}
// A plain solid disc with an anti-aliased edge and no halo at all: the
// "you are here" dot, which used to be a glow sprite, a white sphere and a
// pulsing ring stacked on top of each other.
let _solid;
function solidDotTexture(){
  if(_solid) return _solid;
  const c=document.createElement('canvas'); c.width=c.height=64; const x=c.getContext('2d');
  x.fillStyle='#fff'; x.beginPath(); x.arc(32,32,27,0,Math.PI*2); x.fill();
  _solid=new THREE.CanvasTexture(c); return _solid;
}

let trailGeom, trailLines, trailPos, trailCol;
const TRAIL_SEG = 128;   // one orbit, N=120 segments (updateSelectedTrail)

function buildSatSystem(){
  // Orbit trail (drawn under the satellite dots). RGBA vertex colours: the fade
  // is carried in alpha, so it fades out on the light theme too instead of
  // fading to black the way a darkened colour would.
  // Sized for the one trail that is ever drawn: r147 re-uploads the whole
  // buffer on every needsUpdate, and this used to be sized for 4,000 trails.
  const maxSeg = TRAIL_SEG;
  trailGeom = new THREE.BufferGeometry();
  trailPos = new THREE.BufferAttribute(new Float32Array(maxSeg*2*3),3).setUsage(THREE.DynamicDrawUsage);
  trailCol = new THREE.BufferAttribute(new Float32Array(maxSeg*2*4),4).setUsage(THREE.DynamicDrawUsage);
  trailGeom.setAttribute('position', trailPos);
  trailGeom.setAttribute('color', trailCol);
  trailGeom.setDrawRange(0,0);
  trailLines = new THREE.LineSegments(trailGeom, new THREE.LineBasicMaterial({
    vertexColors:true, transparent:true, opacity:0.8, depthWrite:false, blending:THREE.AdditiveBlending
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

function buildSelectionRing(){
  selRing=new THREE.Mesh(
    new THREE.RingGeometry(0.055,0.085,40),
    new THREE.MeshBasicMaterial({ color:0x9b7cff, side:THREE.DoubleSide, transparent:true, opacity:0.95, depthWrite:false })
  );
  selRing.visible=false; scene.add(selRing);

  // "You are here": one green dot, a constant size on screen, breathing gently.
  // Depth-tested by hand (hiddenByEarth) rather than by the GPU: a flat sprite
  // sitting on a curved surface gets half of itself clipped near the horizon.
  const g=new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(new Float32Array(3),3));
  obsDot=new THREE.Points(g, new THREE.PointsMaterial({
    size:11, map:solidDotTexture(), color:0x4ade80, transparent:true,
    depthTest:false, depthWrite:false, sizeAttenuation:false
  }));
  obsDot.renderOrder = -1;        // after the globe, before the satellites that may pass in front
  obsDot.visible=false; scene.add(obsDot);
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

// ---- theme -> scene ------------------------------------------------------------
function applyTheme(){
  THEME.light = isLight();
  if (!renderer) return;
  const col = n => new THREE.Color(cssVar(n) || '#888888');

  // The scene is the surface the panels float over, so it is cleared to --bg.
  renderer.setClearColor(col('--bg'), 1);
  for (const c of CATEGORIES){ const k=col('--c-'+c.id); c.rgb=[k.r,k.g,k.b]; }

  setEarthTexture();
  // Light surfaces need less light: the dark theme's lamp clips a light globe
  // to white and takes the continents with it.
  ambient.intensity = THEME.light ? 0.8 : 0.78;
  lamp.intensity = THEME.light ? 0.26 : 0.5;
  // Dots: a soft-edged glow on the slate; on a light surface that soft edge
  // reads as a smudge, so they are crisp there, and a little smaller, because
  // a dark dot weighs more than a bright one of the same size.
  satPoints.material.map = THEME.light ? solidDotTexture() : dotTexture();
  satPoints.material.needsUpdate = true;
  THEME.dotScale = THEME.light ? 0.72 : 1;
  gratMat.color.copy(col('--accent')); gratMat.opacity = THEME.light ? 0.13 : 0.14;
  atm.visible = !THEME.light;
  atm.material.uniforms.uColor.value.copy(col('--accent'));
  stars.visible = !THEME.light;
  for (const n of nebulae) n.visible = !THEME.light;

  plinth.material.uniforms.uDark.value.copy(col('--dark'));
  plinth.material.uniforms.uLight.value.copy(col('--light'));
  plinth.material.uniforms.uAlpha.value = THEME.light ? 1 : 0.9;

  // Additive glow reads as light on the dark slate and as nothing at all on a
  // light surface, so the light theme draws the same things with plain alpha.
  const glow = THEME.light ? THREE.NormalBlending : THREE.AdditiveBlending;
  for (const m of [trailLines.material, commLines.material, commPulse.material, commSat.material]){
    if (m.blending !== glow){ m.blending = glow; m.needsUpdate = true; }
  }
  trailLines.material.opacity = THEME.light ? 0.9 : 0.8;
  commLines.material.opacity = THEME.light ? 0.7 : 0.6;
  commSat.material.size = THEME.light ? 24 : 28;

  selRing.material.color.copy(col('--accent'));
  obsDot.material.color.copy(col('--good'));

  trailDirty = true;
  rebuildBeams();
  renderGnss();
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
    const c=s.cat.rgb||[1,1,1]; col[count*3]=c[0]; col[count*3+1]=c[1]; col[count*3+2]=c[2];
    count++;
  }
  satGeom.setDrawRange(0,count);
  satPoints.visible=count>0;      // an empty draw is a WebGL warning per frame
  posAttr.needsUpdate=true; colAttr.needsUpdate=true;
  satGeom.boundingSphere=null;

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
    el.className='chip'+(c.on?' on':''); el.style.setProperty('--c',`var(--c-${c.id})`);
    el.setAttribute('aria-pressed', c.on?'true':'false');
    el.innerHTML=`<span class="swatch"></span>${c.label}`;
    el.onclick=()=>toggleCategory(c, el);
    c.el=el; box.appendChild(el);
  }
}

function toggleCategory(cat, el){
  cat.on=!cat.on; el.classList.toggle('on',cat.on); el.setAttribute('aria-pressed', cat.on?'true':'false');
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
  if (!cat.on) return;                                  // switched off while it was downloading
  state.sats=state.sats.filter(s=>s.cat.id!==cat.id);   // replace this group
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

// ---- selection: picking in SCREEN space ----
// The dots are drawn at a fixed size in pixels (7-18 px, whatever the zoom),
// so the hit test has to be in pixels too. It used to be a three.js raycast
// with a fixed threshold in WORLD units, which is ~13 px at the default zoom
// but under 2 px once zoomed out to see GPS — hence "zoom in to be able to hit
// it" — and it took the hit nearest the camera rather than nearest the finger.
// Now: every visible dot is projected to the screen and the one closest to the
// tap wins, inside a finger-sized radius.
const PICK_R_PX = 24;         // a 48 dp touch target, the Android minimum
const PICK_R_GNSS_PX = 28;    // the connected satellites' glow is drawn larger
function toScreen(v, out){
  _p.copy(v).project(camera);
  if (_p.z < -1 || _p.z > 1) return false;          // behind the camera / past far plane
  out.x=(_p.x+1)/2*innerWidth; out.y=(1-_p.y)/2*innerHeight;
  return true;
}
// Is the straight line from the camera to `v` blocked by the globe? The same
// occlusion the depth buffer applies to the dots, so what cannot be seen cannot
// be tapped through the Earth.
function hiddenByEarth(v, r=SCENE_R){
  const c=camera.position;
  _w.subVectors(v, c); const len=_w.length(); if (len<=0) return false; _w.divideScalar(len);
  const b=c.dot(_w), q=c.lengthSq()-r*r, disc=b*b-q;
  if (disc<=0) return false;
  const t=-b-Math.sqrt(disc);
  return t>0 && t<len;
}
// Dots closer together than this are one dot to a finger (the ISS and the
// ships docked to it share a position): the first in the catalogue wins, which
// is the station itself, not whichever visitor happens to be 0.1 px nearer.
const PICK_TIE_PX = 2;
const _scr={x:0,y:0};
function pickAt(x, y){
  let best=null, bestPx=Infinity;
  const consider=(px, radius, hit)=>{
    if (px<radius && px<bestPx-PICK_TIE_PX){ best=hit; bestPx=px; }
  };
  const linked=new Set();
  for (const bm of commBeams){
    if (bm.cat) linked.add(bm.cat);
    if (hiddenByEarth(bm.b) || !toScreen(bm.b,_scr)) continue;
    consider(Math.hypot(_scr.x-x,_scr.y-y), PICK_R_GNSS_PX, { beam:bm });
  }
  for (const s of state.sats){
    if (!s.alive || !s.pos || linked.has(s)) continue;    // a linked one is picked as its beam
    if (hiddenByEarth(s.pos) || !toScreen(s.pos,_scr)) continue;
    consider(Math.hypot(_scr.x-x,_scr.y-y), PICK_R_PX, { sat:s });
  }
  return best;
}

// A tap is one finger that went down and up again without travelling: a pinch
// lifting its second finger is not a tap, and neither is a drag.
const pointers=new Set(); let down=null;
function onPointerDown(e){
  pointers.add(e.pointerId);
  if (pointers.size===1) down={x:e.clientX,y:e.clientY,t:performance.now(),multi:false};
  else if (down) down.multi=true;
  controls.autoRotate=false;
}
function onPointerCancel(e){ pointers.delete(e.pointerId); down=null; }
function onPointerUp(e){
  pointers.delete(e.pointerId);
  const d=down; if (pointers.size===0) down=null;
  if (!d || d.multi) return;
  const moved=Math.hypot(e.clientX-d.x, e.clientY-d.y), dt=performance.now()-d.t;
  if (moved>10 || dt>400) return;          // it was a drag, not a tap
  const hit=pickAt(e.clientX, e.clientY);
  if (!hit){ closeInfo(); return; }                    // a tap on nothing puts the card away
  if (hit.beam) showGnssSat(hit.beam.sat, hit.beam.cat);
  else selectSat(hit.sat);
}

// Populate the info card's 8-cell grid with arbitrary [label,value] pairs.
function setGrid(pairs){
  const cells=document.querySelectorAll('#info .grid .kv');
  cells.forEach((cell,i)=>{
    if(i<pairs.length){ cell.style.display=''; cell.querySelector('.k').textContent=pairs[i][0]; cell.querySelector('.v').textContent=pairs[i][1]; }
    else cell.style.display='none';
  });
}
function setTag(text, colorKey, live){
  const t=$('#iTag'); t.textContent=text; t.style.setProperty('--c',`var(--c-${colorKey})`);
  t.classList.toggle('live', !!live);
}
function showMore(norad){
  const m=$('#iMore');
  if (!norad){ m.style.display='none'; return; }
  m.style.display='';
  m.onclick=(ev)=>{ ev.preventDefault(); window.Android && window.Android.openUrl('https://www.n2yo.com/satellite/?s='+norad); };
}

function selectSat(s){
  state.selected=s.norad;
  trailDirty=true;                 // draw this satellite's orbit trail immediately
  const meta=resolveMeta(s.name, s.cat.group);
  $('#iName').textContent=s.name||'Unknown';
  setTag(s.cat.label, s.cat.id, false);

  let lookStr='enable location';
  const obs=observerGd();
  if (obs){ const la=lookAnglesAt(s.satrec, simDate(), obs); lookStr = la ? (la.el>0?`${la.el.toFixed(0)}° up, az ${la.az.toFixed(0)}°`:'below horizon') : '—'; }
  setGrid([
    ['Country', meta.country],
    ['Operator', meta.operator],
    ['Purpose', meta.purpose],
    ['NORAD ID', s.norad||'—'],
    ['Altitude', s.heightKm?Math.round(s.heightKm).toLocaleString()+' km':'—'],
    ['Speed', s.vel?(s.vel).toFixed(2)+' km/s':'—'],
    ['Sub-point', (s.latDeg!=null)?`${s.latDeg.toFixed(1)}°, ${s.lonDeg.toFixed(1)}°`:'—'],
    ['From you', lookStr],
  ]);
  $('#info .pass').style.display='';
  showMore(s.norad);
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
// `cat` is the catalogue satellite this signal was matched to (see
// rebuildBeams), when there is one: then the card names the real spacecraft,
// its real altitude, and draws its orbit.
function showGnssSat(sd, cat){
  const m=gnssMeta(sd.constellation);
  if (cat){ state.selected=cat.norad; trailDirty=true; }
  else { state.selected=-1; selRing.visible=false; }
  $('#iName').textContent = cat ? cat.name : `${sd.constellation} · SV ${sd.svid}`;
  setTag('Transmitting to your phone', constKey(sd.constellation), true);
  const sig=(sd.cn0!=null && sd.cn0>0)? sd.cn0.toFixed(1)+' dB-Hz':'—';
  const el=sd.elevation!=null? Math.round(sd.elevation)+'°':'—';
  const az=sd.azimuth!=null? Math.round(sd.azimuth)+'°':'—';
  setGrid(cat ? [
    ['Signal C/N0', sig],
    ['Used in fix', sd.usedInFix?'Yes':'No'],
    ['Elevation', el],
    ['Azimuth', az],
    ['Altitude', cat.heightKm?Math.round(cat.heightKm).toLocaleString()+' km':m.alt],
    ['NORAD ID', cat.norad||'—'],
    ['Operator', m.operator],
    ['Signal ID', `${sd.constellation} ${sd.svid}`],
  ] : [
    ['Country', m.country],
    ['Operator', m.operator],
    ['Purpose', m.purpose],
    ['Signal C/N0', sig],
    ['Elevation', el],
    ['Azimuth', az],
    ['Altitude', m.alt],
    ['Used in fix', sd.usedInFix?'Yes':'No'],
  ]);
  $('#info .pass').style.display='none';
  showMore(cat ? cat.norad : 0);
  $('#info').classList.add('show');
}
function closeInfo(){ $('#info').classList.remove('show'); state.selected=-1; selRing.visible=false; }
$('#infoClose').onclick=closeInfo;

// ============================================================================
//  GNSS panel (real "satellite in use" data from the phone)
// ============================================================================
function renderGnss(){
  const g=state.gnss;
  drawSkyplot(g ? (g.sats||[]) : []);
  if(!g){ return; }
  $('#gnssUsed').textContent=g.used; $('#gnssTotal').textContent=g.total;
  const sats=g.sats||[];
  const status=$('#gnssStatus');
  if (g.total===0){ status.textContent='Acquiring satellites… (go outdoors)'; status.style.color='var(--warn)'; }
  else if (g.used===0){ status.textContent='Signals found, computing fix…'; status.style.color='var(--warn)'; }
  else { status.textContent='Position locked'; status.style.color='var(--good)'; }
  // per-constellation counts (used in fix)
  const counts={};
  for (const s of sats){ if(!counts[s.constellation]) counts[s.constellation]={u:0,t:0}; counts[s.constellation].t++; if(s.usedInFix) counts[s.constellation].u++; }
  const box=$('#consts'); box.innerHTML='';
  Object.keys(counts).sort().forEach(k=>{
    const el=document.createElement('span'); el.className='cst';
    el.style.setProperty('--c',`var(--c-${constKey(k)})`);
    el.innerHTML=`${k} <b>${counts[k].u}</b>/${counts[k].t}`;
    box.appendChild(el);
  });
}
function drawSkyplot(sats){
  const c=$('#skyplot'), x=c.getContext('2d'), W=c.width, H=c.height;
  const k=W/146, cx=W/2, cy=H/2, R=W/2-6*k;             // drawn at 2x for a sharp plot
  x.clearRect(0,0,W,H);
  x.strokeStyle=cssVar('--text-faint'); x.globalAlpha=0.45; x.lineWidth=1*k;
  [1,0.66,0.33].forEach(f=>{ x.beginPath(); x.arc(cx,cy,R*f,0,7); x.stroke(); });
  x.beginPath(); x.moveTo(cx-R,cy); x.lineTo(cx+R,cy); x.moveTo(cx,cy-R); x.lineTo(cx,cy+R); x.stroke();
  x.globalAlpha=1;
  x.fillStyle=cssVar('--text-dim'); x.font=`600 ${9*k}px system-ui, sans-serif`; x.textAlign='center'; x.textBaseline='middle';
  x.fillText('N',cx,cy-R+8*k);
  const ring=cssVar('--bg');
  for (const s of sats){
    if (s.elevation<0 || s.azimuth==null) continue;
    const rr=R*(1-s.elevation/90), a=(s.azimuth-90)*DEG;
    const px=cx+rr*Math.cos(a), py=cy+rr*Math.sin(a);
    x.beginPath(); x.arc(px,py,(s.usedInFix?4:2.6)*k,0,7);
    x.fillStyle=cssVar('--c-'+constKey(s.constellation)); x.globalAlpha=s.usedInFix?1:0.45; x.fill(); x.globalAlpha=1;
    if (s.usedInFix){ x.strokeStyle=ring; x.lineWidth=1.2*k; x.stroke(); }
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
    obsDot.geometry.attributes.position.array.set([...llToVec3(lat,lon,SCENE_R*1.003).toArray()]);
    obsDot.geometry.attributes.position.needsUpdate=true;
    obsDot.geometry.boundingSphere=null;
    obsDot.visible=true;
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
  // The phone switched between dark and light while the app was open.
  onTheme(mode){
    if (mode!=='dark' && mode!=='light') return;
    root.setAttribute('data-theme', mode);
    applyTheme();
  },
};
// A plain browser (no native bridge) follows its own colour-scheme setting live.
if (!window.Android && window.matchMedia){
  const mq=matchMedia('(prefers-color-scheme: light)');
  const onChange=()=>{ if(!root.hasAttribute('data-theme')) applyTheme(); };
  if (mq.addEventListener) mq.addEventListener('change', onChange); else if (mq.addListener) mq.addListener(onChange);
}

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
      msg.textContent=size?`Version ${u.version} is out · ${size}`:`Version ${u.version} is out.`;
      if (u.notes) notes.textContent=u.notes;
      button('Download and install',
        ()=>window.Android&&window.Android.updateDownload()).classList.add('primary');
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
        +'install anything until you switch Orbit on under “Install unknown apps” '
        +'— one switch, on the screen this button opens.';
      button('Open that setting',
        ()=>window.Android&&window.Android.updateGrantInstall()).classList.add('primary');
      break;

    case 'installing':
      msg.textContent='Opening Android’s installer…';
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

function setToggle(btn, on){ btn.classList.toggle('on', on); btn.setAttribute('aria-pressed', on?'true':'false'); }
$('#gnssHead').onclick=()=>$('#gnss').classList.toggle('collapsed');
$('#gnssToggle').onclick=()=>{
  const p=$('#gnss'); p.classList.toggle('hidden');
  setToggle($('#gnssToggle'), !p.classList.contains('hidden'));
};
$('#logToggle').onclick=()=>{
  const p=$('#log'); p.classList.toggle('show');
  setToggle($('#logToggle'), p.classList.contains('show'));
};
$('#logClose').onclick=()=>{ $('#log').classList.remove('show'); setToggle($('#logToggle'), false); };

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
    logRow(`<span class="lt">${t}</span> <span class="lc" style="color:var(--c-${constKey(m.constellation)})">${m.constellation}-${m.svid}</span> `+
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
  trailLines.visible=trailGeom.drawRange.count>0;
  if (state.selected<0){ if(trailGeom.drawRange.count!==0) trailGeom.setDrawRange(0,0); trailLines.visible=false; return; }
  if (!trailDirty && now-lastTrail<800) return;
  lastTrail=now; trailDirty=false;
  const s=state.sats.find(x=>x.norad===state.selected);
  if (!s || !s.satrec || !s.satrec.no){ trailGeom.setDrawRange(0,0); return; }
  const periodMin=(2*Math.PI)/s.satrec.no;
  if (!isFinite(periodMin)||periodMin<=0){ trailGeom.setDrawRange(0,0); return; }
  const base=simDate(), tp=trailPos.array, tc=trailCol.array, c=s.cat.rgb||[1,1,1];
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
      tc[seg*8]=c[0];tc[seg*8+1]=c[1];tc[seg*8+2]=c[2];tc[seg*8+3]=pf;
      tc[seg*8+4]=c[0];tc[seg*8+5]=c[1];tc[seg*8+6]=c[2];tc[seg*8+7]=f;
      seg++;
    }
    prev=v; pf=f;
  }
  trailGeom.setDrawRange(0,seg*2);
  trailLines.visible=seg>0;
  trailPos.needsUpdate=true; trailCol.needsUpdate=true;
}

// ---- "Communication" beams: your phone <-> the GNSS satellites it is USING right now ----
// Real data: each used-in-fix satellite's live azimuth/elevation (GnssStatus) becomes a 3D beam
// from your location, with a pulse travelling inbound (satellite -> phone) and a blinking glow at
// the transmitting satellite. Only constellations whose category is enabled are shown.
//
// The glow has to sit ON the satellite's dot. It used to be put a fixed 3.1 globe-radii along
// the line of sight, which is only right for a GPS satellite straight overhead; anywhere lower
// it landed short of the dot, and since the glow was also the hit area, tapping the dot missed.
// Now each signal is matched to the catalogue satellite sending it — by the PRN in its Celestrak
// name where it has one (GPS "(PRN 22)", BeiDou "(C19)"), else by which catalogue satellite sits
// in that exact direction (GLONASS "COSMOS 2433 (720)" and Galileo "GSAT0101 (GALILEO-PFM)"
// carry no PRN) — and the glow follows that dot
// every frame. With no catalogue satellite to match (QZSS, SBAS, NavIC, or the category's TLEs
// not loaded), it goes where the line of sight actually meets that constellation's orbit.
let commLines, commPos, commCol, commPulse, commPulsePos, commPulseCol,
    commSat, commSatPos, commSatCol, commBeams=[];
const MAX_BEAMS=40;
function buildComm(){
  const lg=new THREE.BufferGeometry();
  commPos=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*2*3),3).setUsage(THREE.DynamicDrawUsage);
  commCol=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*2*4),4).setUsage(THREE.DynamicDrawUsage);
  lg.setAttribute('position',commPos); lg.setAttribute('color',commCol); lg.setDrawRange(0,0);
  commLines=new THREE.LineSegments(lg,new THREE.LineBasicMaterial({vertexColors:true,transparent:true,opacity:0.6,depthWrite:false,blending:THREE.AdditiveBlending}));
  scene.add(commLines);
  // travelling signal pulse (satellite -> phone)
  const pg=new THREE.BufferGeometry();
  commPulsePos=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*3),3).setUsage(THREE.DynamicDrawUsage);
  commPulseCol=new THREE.BufferAttribute(new Float32Array(MAX_BEAMS*4),4).setUsage(THREE.DynamicDrawUsage);
  pg.setAttribute('position',commPulsePos); pg.setAttribute('color',commPulseCol); pg.setDrawRange(0,0);
  commPulse=new THREE.Points(pg,new THREE.PointsMaterial({size:11,map:discTexture(),vertexColors:true,transparent:true,depthWrite:false,blending:THREE.AdditiveBlending,sizeAttenuation:false}));
  scene.add(commPulse);
  // blinking glow at each transmitting satellite
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

// Orbit radius (km) each constellation flies at: where a line of sight meets it.
const SHELL_KM={ GPS:26560, GLONASS:25508, Galileo:29600, BeiDou:27906, QZSS:42164, SBAS:42164, NavIC:42164 };
// BeiDou's geostationary and inclined-geosynchronous satellites, by PRN.
const BEIDOU_GEO_IGSO=new Set([1,2,3,4,5,6,7,8,9,10,13,16,31,38,39,40,56,59,60,61,62,63]);
function shellKm(sd){
  if (sd.constellation==='BeiDou' && BEIDOU_GEO_IGSO.has(sd.svid)) return 42164;
  return SHELL_KM[sd.constellation] || 26560;
}
// The PRN a Celestrak name carries, if it carries one.
function prnOf(s){
  if (s._prn!==undefined) return s._prn;
  const m=/\(PRN\s*[A-Z]?0*(\d+)\)/i.exec(s.name)
       || (s.cat.id==='beidou' && /\(C0*(\d+)\)/.exec(s.name));
  return (s._prn = m ? parseInt(m[1],10) : null);
}
// Angle (deg) between the unit vector `dir` and the direction from `from` to `to`.
function angleTo(from, to, dir){
  _w.subVectors(to, from).normalize();
  return Math.acos(Math.min(1, Math.max(-1, _w.dot(dir)))) / DEG;
}
const MATCH_PRN_DEG=10;   // a PRN match is trusted if it is anywhere near that direction
const MATCH_SKY_DEG=3;    // a direction-only match has to be tight
function matchCatalog(sd, obsGeo, dir, taken){
  const catId=CONST_TO_CAT[sd.constellation]; if(!catId) return null;
  let byPrn=null, best=null, bestAng=Infinity;
  for (const s of state.sats){
    if (s.cat.id!==catId || !s.alive || !s.pos || taken.has(s)) continue;
    const ang=angleTo(obsGeo, s.pos, dir);
    if (prnOf(s)===sd.svid && ang<MATCH_PRN_DEG){ byPrn=s; break; }
    if (ang<bestAng){ bestAng=ang; best=s; }
  }
  if (byPrn) return byPrn;
  return (best && bestAng<MATCH_SKY_DEG) ? best : null;
}

function rebuildBeams(){
  commBeams=[];
  if (commLines){ commLines.geometry.setDrawRange(0,0); commPulse.geometry.setDrawRange(0,0); commSat.geometry.setDrawRange(0,0); showBeams(false); }
  const o=state.observer, g=state.gnss;
  if(!o || !g || !g.sats || !commLines) return;
  const lat=o.lat*DEG, lon=o.lon*DEG;
  const cLat=Math.cos(lat), sLat=Math.sin(lat), cLon=Math.cos(lon), sLon=Math.sin(lon);
  const up=new THREE.Vector3(cLat*cLon, sLat, -cLat*sLon);          // local ENU basis in world space
  const east=new THREE.Vector3(-sLon,0,-cLon);
  const north=new THREE.Vector3(-sLat*cLon, cLat, sLat*sLon);
  const obsPos=llToVec3(o.lat,o.lon,SCENE_R*1.003);                 // start AT the "you are here" dot
  const obsGeo=llToVec3(o.lat,o.lon,SCENE_R*(1+(o.alt||0)/1000/EARTH_R_KM));   // the phone itself
  const taken=new Set();
  // A dual-frequency phone lists each satellite once per signal (L1 and L5,
  // E1 and E5a…), same svid and same direction. One satellite is one beam;
  // the card shows its stronger signal.
  const beamOf=new Map();
  for(const s of g.sats){
    if(!s.usedInFix || s.elevation==null || s.elevation<0 || s.azimuth==null) continue;
    if(!beamConstEnabled(s.constellation)) continue;                // respect category toggles
    const key=s.constellation+':'+s.svid;
    if (beamOf.has(key)){
      const bm=commBeams[beamOf.get(key)];
      if ((s.cn0||0)>(bm.sat.cn0||0)) bm.sat=s;
      continue;
    }
    if(commBeams.length>=MAX_BEAMS) break;
    const az=s.azimuth*DEG, el=s.elevation*DEG;
    const dir=new THREE.Vector3()
      .addScaledVector(east, Math.cos(el)*Math.sin(az))
      .addScaledVector(north, Math.cos(el)*Math.cos(az))
      .addScaledVector(up, Math.sin(el)).normalize();
    const cat=matchCatalog(s, obsGeo, dir, taken);
    let far;
    if (cat){ taken.add(cat); far=cat.pos.clone(); }
    else {
      // |obs + t*dir| = R, the far root: where the line of sight crosses the orbit.
      const R=shellKm(s)/EARTH_R_KM, b=obsGeo.dot(dir), q=obsGeo.lengthSq()-R*R;
      far=obsGeo.clone().addScaledVector(dir, -b+Math.sqrt(Math.max(0,b*b-q)));
    }
    const cc=new THREE.Color(cssVar('--c-'+constKey(s.constellation)) || '#39E3FF');
    commBeams.push({ a:obsPos.clone(), b:far, c:[cc.r,cc.g,cc.b], sat:s, cat });
    beamOf.set(key, commBeams.length-1);
  }
  writeBeams();
  commLines.geometry.setDrawRange(0,commBeams.length*2);
  commPulse.geometry.setDrawRange(0,commBeams.length);
  commSat.geometry.setDrawRange(0,commBeams.length);
  showBeams(commBeams.length>0);
}
function showBeams(on){ commLines.visible=commPulse.visible=commSat.visible=on; }
// Beam geometry into the buffers. Called on rebuild, and every frame while a
// matched satellite moves.
function writeBeams(){
  const lp=commPos.array, lc=commCol.array, sp=commSatPos.array, scc=commSatCol.array;
  commBeams.forEach((bm,i)=>{
    const a=bm.a, b=bm.b, c=bm.c;
    lp[i*6]=a.x;lp[i*6+1]=a.y;lp[i*6+2]=a.z;
    lp[i*6+3]=b.x;lp[i*6+4]=b.y;lp[i*6+5]=b.z;
    lc[i*8]=c[0];lc[i*8+1]=c[1];lc[i*8+2]=c[2];lc[i*8+3]=0.25;      // faint at the phone
    lc[i*8+4]=c[0];lc[i*8+5]=c[1];lc[i*8+6]=c[2];lc[i*8+7]=1;       // full at the satellite
    sp[i*3]=b.x;sp[i*3+1]=b.y;sp[i*3+2]=b.z;
    scc[i*3]=c[0];scc[i*3+1]=c[1];scc[i*3+2]=c[2];
  });
  commPos.needsUpdate=true; commCol.needsUpdate=true; commSatPos.needsUpdate=true; commSatCol.needsUpdate=true;
  commSat.geometry.boundingSphere=null;
}
function updateComm(now){
  if(!commBeams.length) return;
  // Matched glows ride on their satellite's dot.
  let moved=false;
  for (const bm of commBeams){
    if (bm.cat && bm.cat.alive && bm.cat.pos && !bm.b.equals(bm.cat.pos)){ bm.b.copy(bm.cat.pos); moved=true; }
  }
  if (moved) writeBeams();
  const pp=commPulsePos.array, pc=commPulseCol.array;
  const phase=(now*0.0009)%1;
  commBeams.forEach((bm,i)=>{
    const u=(phase + i*0.11)%1;                           // 0 = at satellite, 1 = at phone (inbound)
    pp[i*3]=bm.b.x+(bm.a.x-bm.b.x)*u;
    pp[i*3+1]=bm.b.y+(bm.a.y-bm.b.y)*u;
    pp[i*3+2]=bm.b.z+(bm.a.z-bm.b.z)*u;
    pc[i*4]=bm.c[0]; pc[i*4+1]=bm.c[1]; pc[i*4+2]=bm.c[2]; pc[i*4+3]=0.5+0.5*Math.sin(u*Math.PI);
  });
  // The glows blink together, so the blink is the material's opacity: it fades
  // the same way under additive (dark) and plain (light) blending.
  commSat.material.opacity=0.28+0.72*(0.5+0.5*Math.sin(now*0.007));
  commPulsePos.needsUpdate=true; commPulseCol.needsUpdate=true;
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
    const camDist=camera.position.length();
    // The raised-globe shadow: face the camera, sized to the silhouette at the centre plane.
    plinth.quaternion.copy(camera.quaternion);
    plinth.scale.setScalar(camDist/Math.sqrt(Math.max(1e-4, camDist*camDist-SCENE_R*SCENE_R)));
    // Keep markers a roughly constant on-screen size.
    const ms=Math.max(0.55, Math.min(camDist*0.34, 7));
    satPoints.material.size = Math.max(7, Math.min(18, 22 - camDist*1.0)) * (THEME.dotScale||1);  // smaller when zoomed out
    selRing.scale.setScalar(ms);
    // "You are here": one green dot that breathes, on the same 1.6 s beat as
    // the live dots in the panels. No ring, no glow.
    if (state.observer){
      const p=obsDot.geometry.attributes.position.array;
      _v.set(p[0],p[1],p[2]);
      obsDot.visible=!hiddenByEarth(_v, SCENE_R*0.999);
      const b=0.5+0.5*Math.sin(now*0.0039);
      obsDot.material.opacity=0.5+0.5*b;
      obsDot.material.size=9.5+2*b;
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
  // Read the phone's theme again: a switch while the libraries were loading
  // was pushed before SatBridge existed, and would otherwise be lost.
  try { if (window.Android && Android.theme){ const t=String(Android.theme()); if (t==='dark'||t==='light') root.setAttribute('data-theme', t); } } catch(e){}
  applyTheme();
  // Localhost-only debug handle (harmless; never reachable from file:///android_asset in the app).
  if (location.hostname==='localhost'){
    window.__orbit={ state, THREE, selectSat, showGnssSat, pickAt, toScreen, hiddenByEarth, applyTheme,
      camera:()=>camera, controls:()=>controls, satPoints:()=>satPoints, commSat:()=>commSat, commBeams:()=>commBeams, obsDot:()=>obsDot };
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
