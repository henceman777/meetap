// MeeTap portal 前端 —— 原生 JS，无框架、无构建步骤
//
// 两条约定：
//   1. 所有写请求必须带 X-Meetap: 1（后端据此拒绝恶意页面的表单 POST）。
//   2. 状态一律来自轮询，不在前端缓存录制态——终端里敲 meetap stop 时，
//      页面必须能自己发现并转为空闲。

const $ = (id) => document.getElementById(id);

async function api(path, opts = {}) {
  // headers 必须分别合并，不能靠 {...opts} 整体覆盖——否则调用方传自己的
  // headers（如上传时的 X-Meetap-Filename）会连带丢掉这里默认加的 X-Meetap。
  const o = { ...opts, headers: { 'X-Meetap': '1', ...(opts.headers || {}) } };
  // 只有字符串 body（JSON）才需要这个头；文件上传的 body 是 File/Blob，
  // 让浏览器自己按内容协商 Content-Type（或不发），后端只看 Content-Length。
  if (typeof o.body === 'string') o.headers['Content-Type'] = 'application/json';
  const r = await fetch(path, o);
  let data = {};
  try { data = await r.json(); } catch (_) { /* 静态或空响应 */ }
  return { ok: r.ok, code: r.status, data };
}

function msg(el, text, kind) {
  el.textContent = text || '';
  el.className = 'msg' + (kind ? ' ' + kind : '');
}

// 只用于没有专属消息位的场景（如 runAgain 报错、复制反馈）；已有 .msg
// 位的面板继续用 msg()。后台轮询的静默失败不弹 toast，不打扰用户。
function toast(text, kind, ms) {
  const t = document.createElement('div');
  t.className = 'toast' + (kind ? ' ' + kind : '');
  t.textContent = text;
  t.onclick = () => t.remove();
  $('toasts').appendChild(t);
  setTimeout(() => t.remove(), ms || 4000);
}

function fmtDur(sec) {
  if (sec == null || sec < 0) return '--:--';
  const m = Math.floor(sec / 60), s = sec % 60;
  return String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
}

// ── 定时器集中管理 ──
// 聚合成单页后所有区域同屏，四组轮询会同时跑。按需启停，页面隐藏时全停，
// 避免后台标签页持续打后端。
const timers = {};

function setTimer(name, fn, ms) {
  if (timers[name]) return;             // 幂等：反复调用不会叠加请求
  timers[name] = setInterval(fn, ms);   // 先登记再跑：loadSessions 会在自己内部
  fn();                                 // 重新调用 setTimer，否则递归
}

function clearTimer(name) {
  clearInterval(timers[name]);
  delete timers[name];
}

// ── 录制状态轮询（1s）──
let lastRecording = null;

async function pollStatus() {
  const { ok, data } = await api('/api/status');
  if (!ok) return;

  const live = !!data.recording;
  $('statusDot').className = 'dot ' + (live ? 'live' : 'idle');
  $('statusLabel').textContent = live ? '正在录制' : '空闲';
  $('elapsed').textContent = live ? fmtDur(data.elapsed) : '--:--';
  $('btnStart').disabled = live;
  $('btnStop').disabled = !live;
  // 录制中隐藏会议名输入框（改名已无意义），把横向空间让给波形
  $('meetingName').classList.toggle('hidden', live);
  $('waveHint').classList.toggle('hidden', live);
  $('wave').classList.toggle('hidden', !live);

  // 波形只在录制中轮询：空闲时 400ms 的请求纯属浪费
  if (live) setTimer('levels', pollLevels, 400);
  else clearTimer('levels');

  if (live) {
    const bits = [];
    if (data.session) bits.push(data.session);
    bits.push(data.tap_mode ? 'Process Tap' : 'BlackHole');
    if (data.playback_device) bits.push('播放：' + data.playback_device);
    if (data.autostop) bits.push('静音 ' + data.silence_grace + 's 自动停止');
    $('statusMeta').textContent = bits.join(' · ');
  } else {
    $('statusMeta').textContent = '';
  }

  // 录制刚结束（可能是终端敲的 stop，也可能是静音自停）→ 刷新历史列表
  if (lastRecording === true && !live) loadSessions();
  lastRecording = live;
}

// ── 波形（400ms，对齐电平文件刷新周期）──
const cv = $('wave');
const ctx = cv.getContext('2d');
const HIST = 60;
const hist = new Array(HIST).fill(0);

function dbToUnit(db) {
  // 映射窗口 -50..-20 dBFS，与 start_visualizer 的 RMS 档位窗口一致
  if (db == null) return 0;
  const lo = -50, hi = -20;
  return Math.max(0, Math.min(1, (db - lo) / (hi - lo)));
}

function drawWave() {
  // 逻辑尺寸取 CSS 布局尺寸，不能读 cv.height —— 它下面会被写成物理像素，
  // 再读回来就是放大过的值，第二帧起波形会画到框外。
  const w = cv.clientWidth, h = cv.clientHeight || 34;
  if (!w) return;                       // canvas 被隐藏（空闲时）
  const dpr = window.devicePixelRatio || 1;
  const pw = Math.floor(w * dpr), ph = Math.floor(h * dpr);
  if (cv.width !== pw || cv.height !== ph) { cv.width = pw; cv.height = ph; }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);

  const barW = w / HIST;
  const css = getComputedStyle(document.body);
  const accent = css.getPropertyValue('--accent').trim() || '#4a90d9';
  for (let i = 0; i < HIST; i++) {
    const v = hist[i];
    const bh = Math.max(2, v * (h - 6));
    ctx.fillStyle = accent;
    ctx.globalAlpha = 0.35 + 0.65 * v;
    ctx.fillRect(i * barW + barW * 0.18, (h - bh) / 2, barW * 0.64, bh);
  }
  ctx.globalAlpha = 1;
}

async function pollLevels() {
  const { ok, data } = await api('/api/levels');
  hist.shift();
  if (ok && data.recording) {
    // 系统音与麦克风取较大者，单波形呈现（同 start_visualizer 的合成思路）
    hist.push(Math.max(dbToUnit(data.system), dbToUnit(data.mic)));
  } else {
    hist.push(0);
  }
  drawWave();
}

// ── 开始 / 停止 ──
$('btnStart').onclick = async () => {
  const btn = $('btnStart');
  btn.disabled = true;
  msg($('recordMsg'), '正在启动…');
  const name = $('meetingName').value.trim();
  const { ok, data } = await api('/api/start', {
    method: 'POST',
    body: JSON.stringify({ name }),
  });
  if (ok && data.ok) {
    msg($('recordMsg'), '录制已开始', 'ok');
    $('meetingName').value = '';
  } else {
    msg($('recordMsg'), data.output || data.error || '启动失败', 'err');
    btn.disabled = false;
  }
  pollStatus();
};

$('btnStop').onclick = async () => {
  const btn = $('btnStop');
  btn.disabled = true;
  msg($('recordMsg'), '正在停止并启动后台转录…');
  const { ok, data } = await api('/api/stop', { method: 'POST' });
  if (ok && data.ok) {
    msg($('recordMsg'), '已停止。转录与纪要在后台进行，点左侧该场会议可看进度。', 'ok');
  } else {
    msg($('recordMsg'), data.output || data.error || '停止失败', 'err');
  }
  pollStatus();
  loadSessions();
};

// ── 历史列表 ──
let sessions = [];
let selected = null;
let sessionsLoaded = false;

async function loadSessions() {
  // 首次加载才显示骨架占位；5s 自动刷新时跳过，避免列表反复闪烁
  if (!sessionsLoaded) {
    const ul = $('sessionList');
    ul.textContent = '';
    for (let i = 0; i < 3; i++) {
      const li = document.createElement('li');
      li.className = 'skeleton';
      const t = document.createElement('span');
      t.className = 's-title';
      li.appendChild(t);
      const m = document.createElement('span');
      m.className = 's-meta';
      li.appendChild(m);
      ul.appendChild(li);
    }
  }

  const { ok, data } = await api('/api/sessions');
  if (!ok) return;
  sessionsLoaded = true;
  sessions = data.sessions || [];
  const ul = $('sessionList');
  ul.textContent = '';
  $('sessionEmpty').classList.toggle('hidden', sessions.length > 0);

  sessions.forEach((s) => {
    const li = document.createElement('li');
    if (s.id === selected) li.className = 'sel';

    const idEl = document.createElement('span');
    idEl.className = 's-id';
    idEl.textContent = s.id;
    li.appendChild(idEl);

    const t = document.createElement('span');
    t.className = 's-title';
    // textContent 而非 innerHTML：标题来自纪要正文，必须转义
    t.textContent = s.title || '（尚无纪要）';
    li.appendChild(t);

    const metaBits = [];
    const dm = s.id.match(/^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})/);
    if (dm) metaBits.push(dm[2] + '-' + dm[3] + ' ' + dm[4] + ':' + dm[5]);
    if (s.duration_seconds != null) metaBits.push(fmtDur(s.duration_seconds));
    if (s.attendees) metaBits.push(s.attendees);
    if (metaBits.length) {
      const metaEl = document.createElement('span');
      metaEl.className = 's-meta';
      metaEl.textContent = metaBits.join(' · ');
      li.appendChild(metaEl);
    }

    const badges = document.createElement('div');
    badges.className = 'badges';
    const add = (text, cls) => {
      const b = document.createElement('span');
      b.className = 'badge' + (cls ? ' ' + cls : '');
      b.textContent = text;
      badges.appendChild(b);
    };
    if (s.running) add('生成中', 'run');
    else if (s.has_notes) add('已生成纪要');
    else if (s.has_transcript) add('待生成纪要', 'warn');
    else if (s.has_audio) add('待转录', 'warn');
    if (s.materials > 0) add('资料 ' + s.materials);
    li.appendChild(badges);

    li.onclick = () => openSession(s.id);
    ul.appendChild(li);
  });

  // 有会话在跑 → 保持列表自动刷新，让徽记与进度自己更新；跑完就停
  if (sessions.some((s) => s.running)) setTimer('sessions', loadSessions, 5000);
  else clearTimer('sessions');
}

$('btnRefresh').onclick = loadSessions;

// ── 会议资料 & 补充要求面板（每场会话详情页无条件展示） ──
function fmtSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

const MATERIAL_ACCEPT = '.md,.txt,.markdown,.pdf,.docx,.doc,.rtf,.html,.htm';

function buildMaterialsPanel(id) {
  const panel = document.createElement('details');
  panel.className = 'materials-panel';
  const summary = document.createElement('summary');
  summary.textContent = '📎 会议资料与补充要求';
  panel.appendChild(summary);

  const body = document.createElement('div');
  body.className = 'materials-body';
  panel.appendChild(body);

  const listLabel = document.createElement('p');
  listLabel.className = 'meta';
  listLabel.textContent = '会议资料（辅助 LLM 重新生成纪要时理解背景/术语）';
  body.appendChild(listLabel);

  const ul = document.createElement('ul');
  ul.className = 'materials-list';
  body.appendChild(ul);

  const fileInput = document.createElement('input');
  fileInput.type = 'file';
  fileInput.accept = MATERIAL_ACCEPT;
  body.appendChild(fileInput);

  const panelMsg = document.createElement('span');
  panelMsg.className = 'msg';
  body.appendChild(panelMsg);

  async function loadMaterials() {
    ul.textContent = '';
    const { ok, data } = await api('/api/sessions/' + encodeURIComponent(id) + '/materials');
    const items = (ok && data.materials) || [];
    if (!items.length) {
      const li = document.createElement('li');
      li.className = 'meta';
      li.textContent = '暂无资料';
      ul.appendChild(li);
      return;
    }
    items.forEach((m) => {
      const li = document.createElement('li');
      li.className = 'material-row';
      const name = document.createElement('span');
      name.textContent = m.name + '（' + fmtSize(m.size) + '）';
      li.appendChild(name);
      const del = document.createElement('button');
      del.className = 'ghost icon';
      del.textContent = '✕';
      del.title = '删除';
      del.onclick = async () => {
        if (!confirm('删除资料「' + m.name + '」？')) return;
        const r = await api('/api/sessions/' + encodeURIComponent(id) +
          '/materials/' + encodeURIComponent(m.name), { method: 'DELETE' });
        if (r.ok) { msg(panelMsg, '已删除', 'ok'); loadMaterials(); }
        else msg(panelMsg, r.data.error || '删除失败', 'err');
      };
      li.appendChild(del);
      ul.appendChild(li);
    });
  }

  fileInput.onchange = async () => {
    const file = fileInput.files[0];
    if (!file) return;
    msg(panelMsg, '上传中…');
    const r = await api('/api/sessions/' + encodeURIComponent(id) + '/materials', {
      method: 'POST',
      headers: { 'X-Meetap-Filename': encodeURIComponent(file.name) },
      body: file,
    });
    if (r.ok) { msg(panelMsg, '已上传：' + r.data.saved, 'ok'); loadMaterials(); }
    else msg(panelMsg, r.data.error || '上传失败', 'err');
    fileInput.value = '';
  };

  const reqLabel = document.createElement('p');
  reqLabel.className = 'meta';
  reqLabel.style.marginTop = '16px';
  reqLabel.textContent = '补充要求（重新生成纪要时会连同资料一起交给 LLM）';
  body.appendChild(reqLabel);

  const textarea = document.createElement('textarea');
  textarea.placeholder = '例如：重点关注预算结论，发言人B的称呼统一为「产品负责人」';
  body.appendChild(textarea);

  const saveBtn = document.createElement('button');
  saveBtn.textContent = '保存补充要求';
  saveBtn.style.marginTop = '8px';
  body.appendChild(saveBtn);
  saveBtn.onclick = async () => {
    msg(panelMsg, '保存中…');
    const r = await api('/api/sessions/' + encodeURIComponent(id) + '/extra-requirements', {
      method: 'PUT',
      body: JSON.stringify({ text: textarea.value }),
    });
    if (r.ok) msg(panelMsg, '已保存', 'ok');
    else msg(panelMsg, r.data.error || '保存失败', 'err');
  };

  // 首次展开才拉取材料列表 + 补充要求文本，收起/再展开不重复请求
  panel.addEventListener('toggle', async () => {
    if (!panel.open || panel.dataset.loaded) return;
    panel.dataset.loaded = '1';
    loadMaterials();
    const r = await api('/api/sessions/' + encodeURIComponent(id) + '/extra-requirements');
    if (r.ok) textarea.value = r.data.text || '';
  });

  return panel;
}

// ── 会话详情 ──
async function openSession(id) {
  selected = id;
  document.querySelectorAll('#sessionList li').forEach((li) => {
    li.classList.toggle('sel', li.querySelector('.s-id').textContent === id);
  });

  const detail = $('detail');
  detail.textContent = '';

  const head = document.createElement('div');
  head.className = 'detail-head';
  const h = document.createElement('div');
  const strong = document.createElement('strong');
  strong.textContent = id;
  h.appendChild(strong);
  head.appendChild(h);

  const again = document.createElement('button');
  again.textContent = '重新生成纪要';
  again.onclick = () => {
    if (!confirm('重新生成纪要会覆盖当前纪要（旧版本会被归档）并调用一次 LLM，确定继续？')) return;
    runAgain(id, again);
  };
  head.appendChild(again);

  const copyBtn = document.createElement('button');
  copyBtn.textContent = '复制纪要';
  copyBtn.className = 'ghost hidden';
  head.appendChild(copyBtn);
  detail.appendChild(head);

  detail.appendChild(buildMaterialsPanel(id));

  const bodyWrap = document.createElement('div');
  const loading = document.createElement('p');
  loading.className = 'meta center loading-pulse';
  loading.textContent = '加载中…';
  bodyWrap.appendChild(loading);
  detail.appendChild(bodyWrap);

  const { ok, data } = await api('/api/sessions/' + encodeURIComponent(id));
  bodyWrap.innerHTML = '';
  if (ok && data.html) {
    // 后端用 markdown 库渲染本机自己的纪要文件，内容源可信
    bodyWrap.innerHTML = data.html;
    copyBtn.classList.remove('hidden');
    copyBtn.onclick = async () => {
      try {
        await navigator.clipboard.writeText(bodyWrap.innerText);
        toast('已复制到剪贴板', 'ok', 2000);
      } catch (e) {
        toast('复制失败：' + e.message, 'err');
      }
    };
  } else {
    const p = document.createElement('p');
    p.className = 'meta';
    p.textContent = '尚无纪要。可点「重新生成纪要」触发 meetap again。';
    bodyWrap.appendChild(p);
  }

  const s = sessions.find((x) => x.id === id);
  if (s && (s.running || !s.has_notes)) showLog(id, detail);

  if (s && s.has_transcript) {
    const t = document.createElement('details');
    t.className = 'transcript-panel';
    const sum = document.createElement('summary');
    sum.textContent = '📄 完整转录';
    t.appendChild(sum);
    const box = document.createElement('div');
    box.className = 'transcript-box';
    t.appendChild(box);
    // 首次展开才拉取，展开/收起/再展开不重复请求（dataset.loaded 标记）
    t.addEventListener('toggle', async () => {
      if (!t.open || t.dataset.loaded) return;
      t.dataset.loaded = '1';
      box.textContent = '加载中…';
      const r = await api('/api/sessions/' + encodeURIComponent(id) + '/transcript');
      // 纯文本渲染，绝不走 innerHTML——转录原文不是 markdown，不能当 HTML 用
      box.textContent = r.ok ? (r.data.text || '（空）') : (r.data.error || '加载失败');
    });
    detail.appendChild(t);
  }
}

async function runAgain(id, btn) {
  btn.disabled = true;
  const { ok, data } = await api('/api/sessions/' + encodeURIComponent(id) + '/again', {
    method: 'POST',
  });
  if (!ok && data.error) {
    btn.disabled = false;
    toast(data.error, 'err');
    return;
  }
  // 后端已放后台线程并回 202，这里立刻转去看日志，不等它跑完
  showLog(id, $('detail'), true);
  loadSessions();
}

// ── 进度日志（2s 轮询）──
function showLog(id, container, force) {
  clearTimer('log');
  let box = container.querySelector('.logbox');
  if (!box) {
    const label = document.createElement('p');
    label.className = 'meta';
    label.style.marginTop = '18px';
    label.textContent = '处理进度（log/meetap.log）';
    container.appendChild(label);
    box = document.createElement('div');
    box.className = 'logbox';
    container.appendChild(box);
  }

  const tick = async () => {
    if (selected !== id) { clearTimer('log'); return; }   // 切走了选中项
    const { ok, data } = await api('/api/sessions/' + encodeURIComponent(id) + '/log');
    if (!ok) return;
    const lines = data.lines || [];
    box.textContent = lines.length ? lines.join('\n') : '（暂无日志输出）';
    box.scrollTop = box.scrollHeight;
    // 跑完了 → 停止轮询并刷新，让纪要正文与徽记更新
    if (!data.running && !data.again_running) {
      clearTimer('log');
      if (force) { loadSessions(); openSession(id); }
    }
  };
  setTimer('log', tick, 2000);
}

// ── 配置弹窗 ──
// 用原生 <dialog> + showModal()：焦点陷阱、Esc 关闭、::backdrop 遮罩、aria-modal
// 全部由浏览器提供，自写遮罩层要几十行才做对。
const dlg = $('configDlg');

function configDirty() {
  return [...$('configForm').querySelectorAll('[data-key]')]
    .some((el) => el.value !== el.dataset.orig);
}

// 有未保存改动时拦一下，避免 Esc / 点遮罩误丢修改
function tryCloseConfig() {
  if (configDirty() && !confirm('有未保存的改动，确定关闭吗？')) return false;
  dlg.close();
  return true;
}

$('btnConfig').onclick = () => {
  dlg.showModal();
  loadConfig();   // 每次打开都重新拉取：配置可能被终端 meetap config 改过
};

$('btnCloseConfig').onclick = tryCloseConfig;

// Esc 走原生 cancel 事件，先拦截再决定是否放行
dlg.addEventListener('cancel', (e) => {
  e.preventDefault();
  tryCloseConfig();
});

// 点击 backdrop 关闭：dialog 自身是事件目标时说明点在了内容区之外
dlg.addEventListener('click', (e) => {
  if (e.target === dlg) tryCloseConfig();
});

let configMeta = null;

async function loadConfig() {
  const { ok, data } = await api('/api/config');
  if (!ok) return;
  configMeta = data;
  $('configPath').textContent = '配置文件：' + data.path;

  const form = $('configForm');
  form.textContent = '';
  data.keys.forEach((key) => {
    const val = data.config[key] != null ? data.config[key] : '';
    const row = document.createElement('div');
    row.style.marginBottom = '14px';

    const label = document.createElement('label');
    label.textContent = key;
    label.htmlFor = 'cfg-' + key;
    row.appendChild(label);

    let input;
    const enums = data.enums[key];
    const isBool = data.bools.includes(key);
    if (enums || isBool) {
      input = document.createElement('select');
      (enums || ['true', 'false']).forEach((opt) => {
        const o = document.createElement('option');
        o.value = opt;
        o.textContent = opt;
        if (opt === val) o.selected = true;
        input.appendChild(o);
      });
    } else {
      input = document.createElement('input');
      input.type = 'text';
      input.value = val;
      if (data.numeric.includes(key)) input.inputMode = 'numeric';
    }
    input.id = 'cfg-' + key;
    input.dataset.key = key;
    input.dataset.orig = val;
    row.appendChild(input);
    form.appendChild(row);
  });
  msg($('configMsg'), '');
}

$('btnReloadConfig').onclick = loadConfig;

$('btnSaveConfig').onclick = async () => {
  // 只提交真正改过的键——后端原地改写，未提交的键连行都不碰
  const updates = {};
  $('configForm').querySelectorAll('[data-key]').forEach((el) => {
    if (el.value !== el.dataset.orig) updates[el.dataset.key] = el.value;
  });
  if (!Object.keys(updates).length) {
    msg($('configMsg'), '没有改动', 'meta');
    return;
  }
  msg($('configMsg'), '保存中…');
  const { ok, data } = await api('/api/config', {
    method: 'PUT',
    body: JSON.stringify({ config: updates }),
  });
  if (ok) {
    msg($('configMsg'), '已保存：' + (data.saved || []).join('、'), 'ok');
    loadConfig();
  } else {
    msg($('configMsg'), data.error || '保存失败', 'err');
  }
};

// ── 启动 ──
window.addEventListener('resize', drawWave);

// 页面隐藏 → 全部定时器停摆；恢复 → 重启 status，其余由各自条件自动重建
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    Object.keys(timers).forEach(clearTimer);
  } else {
    setTimer('status', pollStatus, 1000);
    loadSessions();
    // 日志定时器由 openSession 创建，切回来要手动重挂到当前选中的会话上
    const box = $('detail').querySelector('.logbox');
    if (selected && box) showLog(selected, $('detail'));
  }
});

setTimer('status', pollStatus, 1000);
loadSessions();
