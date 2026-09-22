// InputFlow 桌宠 · VRM 渲染器（three.js + @pixiv/three-vrm）
// 透明背景、跟随鼠标注视、眨眼、呼吸/摇摆、状态机（idle / typing / commit）。
import * as THREE from 'three';
import { GLTFLoader } from './jsm/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMUtils } from './three-vrm.module.js';

window.__petReady = false;
window.__petErr = '';
window.addEventListener('error', (e) => {
  window.__petErr = String(e.message || e);
  try { window.webkit?.messageHandlers?.pet?.postMessage({ error: window.__petErr }); } catch (_) {}
});
window.addEventListener('unhandledrejection', (e) => {
  window.__petErr = String((e.reason && e.reason.message) || e.reason || e);
  try { window.webkit?.messageHandlers?.pet?.postMessage({ error: window.__petErr }); } catch (_) {}
});

const params = new URLSearchParams(location.search);
const modelURL = params.get('model') || './sample.vrm';
const framing = params.get('framing') || 'full';   // full | bust
const extraZoom = parseFloat(params.get('zoom') || '1') || 1;
const canvas = document.getElementById('c');

const renderer = new THREE.WebGLRenderer({
  canvas,
  alpha: true,
  antialias: true,
  premultipliedAlpha: true,
  preserveDrawingBuffer: true,   // 供离屏快照捕获
  powerPreference: 'high-performance',
});
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(26, 1, 0.05, 50);
const lookTarget = new THREE.Object3D();
scene.add(lookTarget);

scene.add(new THREE.AmbientLight(0xffffff, 0.85));
const key = new THREE.DirectionalLight(0xffffff, 1.15);
key.position.set(0.6, 1.6, 1.2);
scene.add(key);
const rim = new THREE.DirectionalLight(0xbcd4ff, 0.5);
rim.position.set(-1.0, 1.2, -0.8);
scene.add(rim);

let vrm = null;
let state = 'idle';
let gaze = { x: 0, y: 0 };
let clock = new THREE.Clock();
let elapsed = 0;
let blink = { next: 1.5, phase: -1 };
let ready = false;

const headTarget = new THREE.Vector3();
let headHeight = 1.4;

function post(message) {
  try {
    window.webkit?.messageHandlers?.pet?.postMessage(message);
  } catch (_) {}
}

function resize() {
  const w = window.innerWidth;
  const h = window.innerHeight;
  const dpr = Math.min(window.devicePixelRatio || 2, 3);
  renderer.setPixelRatio(dpr);
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}
window.addEventListener('resize', resize);

function fitCamera() {
  const box = new THREE.Box3().setFromObject(vrm.scene);
  const size = new THREE.Vector3();
  box.getSize(size);
  headHeight = box.min.y + size.y * 0.90;

  let focusY;
  let distance;
  if (framing === 'bust') {
    focusY = box.min.y + size.y * 0.80;
    distance = size.y * 1.02;
    camera.position.set(0, focusY + size.y * 0.04, distance);
  } else {
    // 全身：略低机位（显高挑），按竖直画幅精确取景
    const aspect = Math.max(0.35, camera.aspect);
    const needV = size.y * 1.06;
    const needH = Math.max(size.x, size.z) * 1.25;
    const fovRad = (camera.fov * Math.PI) / 180;
    distance = Math.max(needV / (2 * Math.tan(fovRad / 2)), needH / (2 * Math.tan(fovRad / 2) * aspect));
    distance /= extraZoom;
    focusY = box.min.y + size.y * 0.52;
    camera.position.set(0, box.min.y + size.y * 0.44, distance);
  }
  camera.near = Math.max(0.05, distance / 200);
  camera.far = distance * 8;
  camera.lookAt(0, focusY, 0);
  camera.updateProjectionMatrix();
  lookTarget.position.set(0, headHeight, distance * 0.5);
  headTarget.set(0, headHeight, 0);
}

function setExpression(name, value) {
  const em = vrm?.expressionManager;
  if (!em) return;
  if (em.getExpression(name)) {
    em.setValue(name, value);
  }
}

function updateBlink(dt) {
  const em = vrm?.expressionManager;
  if (!em) return;
  if (blink.phase < 0) {
    blink.next -= dt;
    if (blink.next <= 0) {
      blink.phase = 0;
    }
    return;
  }
  blink.phase += dt;
  const duration = 0.16;
  let v = 0;
  if (blink.phase < duration) {
    v = Math.sin((blink.phase / duration) * Math.PI);
  } else {
    blink.phase = -1;
    blink.next = 1.6 + Math.random() * 2.6;
  }
  setExpression('blink', v);
}

function applyBasePose() {
  const h = vrm.humanoid;
  const lu = h.getNormalizedBoneNode('leftUpperArm');
  const ru = h.getNormalizedBoneNode('rightUpperArm');
  const ll = h.getNormalizedBoneNode('leftLowerArm');
  const rl = h.getNormalizedBoneNode('rightLowerArm');
  if (lu) lu.rotation.z = -1.16;      // 手臂自然下垂（VRM 默认 T-pose）
  if (ru) ru.rotation.z = 1.16;
  if (ll) ll.rotation.z = -0.22;
  if (rl) rl.rotation.z = 0.22;
}

function poseIdle(t) {
  const humanoid = vrm.humanoid;
  const chest = humanoid.getNormalizedBoneNode('chest');
  const head = humanoid.getNormalizedBoneNode('head');
  if (chest) chest.rotation.x = Math.sin(t * 1.15) * 0.022;      // 呼吸
  if (head) head.rotation.y = Math.sin(t * 0.55) * 0.05;         // 轻微左右看
  vrm.scene.position.y = Math.sin(t * 1.6) * 0.004;              // 整体浮动
}

function poseTyping(t) {
  const humanoid = vrm.humanoid;
  const chest = humanoid.getNormalizedBoneNode('chest');
  const head = humanoid.getNormalizedBoneNode('head');
  if (chest) chest.rotation.x = 0.06 + Math.sin(t * 9) * 0.012;  // 前倾 + 跟手颤动
  if (head) head.rotation.x = 0.05;
  vrm.scene.position.y = Math.abs(Math.sin(t * 9)) * 0.006;
}

function poseCommit(t) {
  const humanoid = vrm.humanoid;
  const chest = humanoid.getNormalizedBoneNode('chest');
  if (chest) chest.rotation.x = -0.05;
  vrm.scene.position.y = Math.abs(Math.sin(t * 3.2)) * 0.05;     // 开心弹跳
}

function updateGaze() {
  if (!vrm || !vrm.lookAt) return;
  const dx = gaze.x * 0.28;
  const dy = gaze.y * 0.16;
  lookTarget.position.x = dx;
  lookTarget.position.y = headHeight + dy;
  vrm.lookAt.target = lookTarget;
  const head = vrm.humanoid.getNormalizedBoneNode('head');
  if (head && state === 'idle') {
    head.rotation.y += dx * 0.35;
  }
}

function ensureSize() {
  const w = window.innerWidth, h = window.innerHeight;
  const dpr = Math.min(window.devicePixelRatio || 2, 3);
  if (canvas.width !== Math.floor(w * dpr) || canvas.height !== Math.floor(h * dpr)) {
    resize();
  }
}

let lastFrameAt = 0;
function step() {
  ensureSize();
  const dt = Math.min(clock.getDelta(), 0.05);
  elapsed += dt;
  if (vrm) {
    if (state === 'typing') poseTyping(elapsed);
    else if (state === 'commit') poseCommit(elapsed);
    else poseIdle(elapsed);
    updateBlink(dt);
    updateGaze();
    vrm.update(dt);
  }
  renderer.render(scene, camera);
  lastFrameAt = performance.now();
}
function animate() {
  requestAnimationFrame(animate);
  step();
}
// WebKit 在非激活/遮挡时会节流 rAF：用定时器兜底，保证桌宠始终有动作
setInterval(() => {
  if (performance.now() - lastFrameAt > 150) step();
}, 100);

const loader = new GLTFLoader();
loader.register((parser) => new VRMLoaderPlugin(parser));
loader.load(
  modelURL,
  (gltf) => {
    vrm = gltf.userData.vrm;
    if (!vrm) {
      post({ error: 'not-a-vrm' });
      return;
    }
    VRMUtils.removeUnnecessaryVertices(gltf.scene);
    VRMUtils.combineSkeletons(gltf.scene);
    VRMUtils.rotateVRM0(vrm);
    scene.add(vrm.scene);
    vrm.scene.traverse((obj) => {
      obj.frustumCulled = false;
    });
    fitCamera();
    applyBasePose();
    if (vrm.lookAt) vrm.lookAt.target = lookTarget;
    setExpression('blink', 0);
    ready = true;
    window.__petReady = true;
    step();
    clock.start();
    post({ ready: true });
  },
  undefined,
  (err) => {
    post({ error: String(err && err.message ? err.message : err) });
  }
);

// Swift → JS 接口
window.petSetState = (value) => {
  state = value || 'idle';
  elapsed = 0;
  if (state === 'commit') {
    setExpression('happy', 1);
    setTimeout(() => setExpression('happy', 0), 900);
  }
};
window.petSetGaze = (x, y) => {
  gaze.x = Math.max(-1, Math.min(1, x));
  gaze.y = Math.max(-1, Math.min(1, y));
};
window.petInfo = () => JSON.stringify({
  ready: !!window.__petReady,
  triangles: renderer.info.render.triangles,
  calls: renderer.info.render.calls,
  canvas: [canvas.width, canvas.height],
  win: [window.innerWidth, window.innerHeight],
  cam: [camera.position.x, camera.position.y, camera.position.z],
  hasVRM: !!vrm,
});
window.petCapture = () => canvas.toDataURL('image/png');
window.petSetZoom = (factor) => {
  if (!vrm) return;
  const f = Math.max(0.6, Math.min(1.6, factor));
  camera.position.z = camera.position.z / f;
};

resize();
animate();
