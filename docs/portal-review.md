# Web Portal 代码 Review

审阅对象：`src/meetap-portal`（672 行）、`share/meetap/portal/{index.html,app.js,style.css}`，
以及 `src/meetap` 中被 portal 间接调用的路径。

审阅日期：2026-07-30 · 结论均在本机实测验证，非静态推断。

**结论：7 个真实缺陷 + 1 个安全加固项。其中 P0-1 会让「网页点开始录制」在
正常使用下必然表现为失败**，建议修复后再提交。

| 编号 | 位置 | 问题 | 严重度 |
|---|---|---|---|
| P0-1 | `meetap-portal:351` `meetap:1288,1399` | `/api/start` 阻塞 60s 后误报超时，录制实际已在跑 | 阻塞 |
| P0-2 | `meetap-portal:566` | `/api/start` TOCTOU，并发启动毁掉第一场录制 | 阻塞 |
| P1-3 | `meetap-portal:403` | `write_config` 并发 PUT 丢更新 | 高 |
| P1-4 | `meetap-portal:358` `meetap:1309,1422` | 网页录制时波形画到 portal 所在终端 | 高 |
| P1-5 | `meetap-portal:469,504` | 请求体未排空 → keep-alive 连接错位 | 高 |
| P1-6 | `meetap-portal:303` | 纪要裸 HTML 透传进 `innerHTML` | 高 |
| P2-7 | `meetap-portal:203,285` | 软链接会话目录「列得出、点不开」 | 中 |
| P2-8 | `meetap-portal:279` | `SESSION_RE` 允许嵌入 `../`（当前不可利用） | 加固 |
| P3-9 | `meetap-portal:236` | `find_notes` 取字典序最大而非最新 | 低 |

---

## P0-1 `POST /api/start` 必然「假失败」

`run_cli`(portal:351) 用 `subprocess.run(..., capture_output=True)`。
`capture_output` 建的是管道，`subprocess.run` 等的是**管道 EOF**，
而不是 bash 主进程退出。

而 `start_recording` 拉起的 `autostop_daemon &`（meetap:1288 tap 分支 /
1399 blackhole 分支）**没有任何重定向**，继承了那根 stdout 管道，
并且它要活满整场录制（`while true` + `sleep 30`）。于是：

1. 管道永不 EOF → `subprocess.run` 卡住
2. 60s 后抛 `TimeoutExpired` → 前端收到 `{"ok": false, "output": "command timed out"}`
3. 网页弹红字「启动失败」—— **但 ffmpeg 早已起来，录制正在进行**
4. 用户以为没成功，再点一次 → 撞上 P0-2

同一个坑还波及 `start_visualizer &`（meetap:1313 / 1426），它同样无重定向。

**实测验证**

```bash
# 最小复现：disown 的长命子进程不重定向 stdout
long_lived() { sleep 25; }
long_lived &
disown $!
exit 0      # 父脚本 0.1s 就退出
```

```
subprocess.run(capture_output=True, timeout=8)
→ TIMED OUT after 8.0s   # 等的是 EOF，不是父进程退出
```

**建议修法（两处配合，都必要）**

1. `src/meetap` 根因修复：给两个后台守护进程补重定向，切断继承的管道
   ```bash
   autostop_daemon > /dev/null 2>&1 &
   start_visualizer "$TTY_DEV" 2>/dev/null &   # stdout 本来就只写 $tty_dev
   ```
   顺带让终端里直接跑 `meetap start` 的行为也更干净。
2. `src/meetap-portal` 纵深防御：`run_cli` 改用
   `stdout=PIPE, stderr=STDOUT, stdin=DEVNULL` + 显式 `communicate(timeout=…)`；
   超时时**不再判定为失败**，而是回查 `pid_alive("ffmpeg.pid")` 得到真实结果。
   这样即使将来又新增一个忘记重定向的后台进程，portal 也不会误报。

---

## P0-2 `/api/start` 的 TOCTOU：并发启动会毁掉第一场录制

portal:566 先 `pid_alive("ffmpeg.pid")` 再 `run_cli(["start"])`，两步之间无锁。
`ThreadingHTTPServer` 每请求一线程，两个标签页（或 P0-1 导致的重复点击）
同时打进来，两边都看到「未在录制」，于是执行两次 `meetap start`。

第二次会 `pkill` 掉第一次的 tap 进程，并覆盖 `session-dir` 状态文件 ——
**第一场录制的音频与会话归属直接丢失**。

**建议修法**：模块级 `_start_lock = threading.Lock()`，把 `/api/start` 与
`/api/stop` 的「检查 + 执行」整段包进 `with _start_lock:`。
录制控制天然是独占操作，串行化无副作用。

---

## P1-3 `write_config` 并发 PUT 丢更新

portal:403 的临时文件名是固定的 `p + ".portal.tmp"`。两个并发 PUT 各自
「读原文 → 改内存 → 写同一个 tmp → `os.replace`」：后者覆盖前者的 tmp，
`os.replace` 的原子性救不了 source 被共享这种情况 —— 先提交的修改被静默丢弃。

**建议修法**：整个 `write_config` 用 `_config_lock` 包住（读-改-写必须原子），
tmp 改用 `tempfile.mkstemp(dir=os.path.dirname(p))` 避免残留文件互踩。

---

## P1-4 网页触发录制时，波形画到 portal 所在的终端上

`meetap portal` 通常在真终端里跑，所以 portal 进程的 **stdin 是 TTY**。
`capture_output=True` 只重定向 stdout/stderr，**stdin 照常继承**，
于是子进程里 `tty`（meetap:1309 / 1422）返回真实设备名，
`setup_statusbar` + `start_visualizer` 就往用户那个终端写 ANSI 控制序列
（修改滚动区 + 绘制点阵波形），把 portal 的启动提示搅乱，
且录制结束前不会恢复。

**实测验证**：用 `pty.spawn` 造真 PTY，子进程内
`subprocess.run(capture_output=True)` 调探测脚本：

```
CHILD SAW: tty() => '/dev/ttys012'
=> 会启动 visualizer 并往 /dev/ttys012 写 ANSI 控制序列
```

> 注：不经 PTY 直接测会得到 `not a tty`，那是**假阴性** —— 测试环境本身没有
> 控制终端，掩盖了真实场景。所以特意用 PTY 复测。

**建议修法**：`run_cli` 显式 `stdin=subprocess.DEVNULL`。这样 `tty` 返回
`not a tty`，bash 侧现成的守卫
`[[ -n "$TTY_DEV" && "$TTY_DEV" != "not a tty" ]]` 自然生效，波形不再启动 ——
网页端本就有自己的 canvas 波形，不需要终端那一份。

---

## P1-5 请求体未排空 → keep-alive 连接错位

`protocol_version = "HTTP/1.1"`，连接默认复用。两处漏掉排空请求体：

- `_body_json`(portal:504)：`Content-Length > 1_000_000` 直接 `return None`，不读 body
- `_guard`(portal:469)：写操作被 403 拒绝时，根本没走到读 body 那步

残留字节会被 `BaseHTTPRequestHandler` 当成**下一个请求的请求行**解析。

**实测验证**：同一连接上先发一个缺 `X-Meetap` 的 PUT（带 body），再发一个正常 GET：

```
HTTP/1.1 403 Forbidden ... {"error": "missing X-Meetap header"}
HTTP/1.1 501 Unsupported method ('{"config":{"visualizer":"bar"}}GET')
```

第二个响应证实 body 被吃成了方法名，连接彻底错位。

**建议修法**：加 `_drain_body()`（按 `Content-Length` 分块丢弃，带上限保护），
在 `_guard` 返回 False 前、以及 `_body_json` 判定超限时都调用；
超限那条另外改成语义正确的 `413`。

---

## P1-6 纪要裸 HTML 透传进 `innerHTML`

`render_notes`(portal:303) 把 markdown 渲染结果交给前端 `innerHTML`
（app.js:250）。实测 `markdown` 库**原样透传裸 HTML**：

```python
输入:  <img src=x onerror="alert(1)">
       <script>fetch("/api/stop",{method:"POST",headers:{"X-Meetap":"1"}})</script>
输出:  原样透传（onerror 与 <script> 均在）
raw HTML 透传: True
```

而 `X-Meetap` 头对**同源脚本**毫无阻力 —— 页面内脚本可以调任意本地接口，
包括停止录制、改写配置。

定性：纪要由 Bedrock 依据会议转录生成，**不存在远程攻击者**，
所以这不是传统 XSS。但存在「转录内容 → 模型输出 → 浏览器执行」这条链路：
只要有人在会上念出一段 HTML 并被模型照抄进纪要，就会被执行。
风险不高，但修复成本更低。

**建议修法（两层）**

1. `_send` 给响应加 CSP 头：
   ```
   Content-Security-Policy: default-src 'none'; script-src 'self';
     style-src 'self'; img-src 'self' data:; connect-src 'self'
   ```
   内联 `<script>` 与 `onerror=` 这类内联事件处理器被浏览器直接拒绝执行，
   外部资源也无法加载（顺带杜绝纪要内容外泄到第三方域）。
   前端已是独立 `.js`/`.css`、无内联脚本，天然满足 `'self'`。
2. `render_notes` 对渲染结果做标签白名单清洗，只保留 markdown 自身会产出的
   标签集（`h1-h6/p/ul/ol/li/table/thead/tbody/tr/th/td/code/pre/blockquote/hr/em/strong/a/br`）
   与 `a[href]` 的协议白名单。用标准库 `html.parser` 实现 —— 设计约束 5
   要求不新增 pip 依赖，所以不引入 `bleach`。

两层都做：CSP 挡执行，清洗挡结构破坏（如 `<style>` 覆盖整页、
未闭合标签把纪要撑出容器）。任一层单独都有缺口。

---

## P2-7 软链接的会话目录「列得出、点不开」

`list_sessions`(portal:203) 用 `os.path.isdir` 判断，**跟随软链接**，所以
`~/Record/20260730_1430 -> /Volumes/外置盘/…` 会被列进侧栏；
而 `safe_session_dir`(portal:285) 要求 `os.path.dirname(real) == root`，
`realpath` 解到盘外后 dirname 不等于 root → 一律 404。

把旧录音挪到外置盘再软链回来是很自然的操作，届时那些会议在侧栏点开
全是「session not found」。枚举器与校验器的规则分叉了。

**建议修法**：判定改为「用**未解析**路径确认 `sid` 是 root 的直接子项」
（`os.path.dirname(os.path.join(root, sid)) == root`）+ `os.path.isdir(real)`，
不再要求 `dirname(real) == root`。穿越防护由收紧后的正则（P2-8）承担。

> ⚠️ **P2-7 与 P2-8 必须同批修改**：本条正要放宽当前实际拦住路径穿越的那一层，
> 若不同时收紧正则，会开出真实漏洞。

---

## P2-8 加固：`SESSION_RE` 允许嵌入 `../`

`SESSION_RE = ^\d{8}_\d{4}(_.+)?$`，其中 `.` 匹配斜杠，所以
`20260730_1430_../../etc` **能通过正则**（`urlparse` 不解码，
`unquote`(portal:542) 在正则捕获之后才跑，`%2F` 会还原成真斜杠）。

当前**不可利用** —— `realpath` + dirname 检查把它拦下了。但 portal:277-278
的注释写着「绝不做字符串拼路径」，而 :282 恰恰在拼路径：注释与实现不符。
真正的防线顺序与注释暗示的相反，后续维护者若据注释放宽第二层就会开洞。

**建议修法**：正则收紧为 `^\d{8}_\d{4}(_[^/\\]+)?$`，让第一层自己就足够；
同时订正注释，说明防线是「白名单正则 + root 直接子项校验」两层。

> `_static`(portal:615) 用的是更强的
> `target == root or target.startswith(root + os.sep)` 前缀式校验，无问题。

---

## P3-9 `find_notes` 取字典序最大而非最新

portal:236 `sorted(cands)[-1]`。`m`(0x6D) 大于任何数字字符（0x30–0x39），实测：

```python
sorted(['meeting-notes.md', '2026-07-30_1430_季度评审.md'])[-1]
→ 'meeting-notes.md'
```

即固定名**永远压过**日期前缀的智能命名 —— 与 :225-227 注释的意图正好相反。

正常路径下不发作：`smart_name_notes`(meetap:1053) 是 `mv` 而非 `cp`，
固定名文件被消耗掉，两者不共存。但两条路径会让它们并存：

1. `mv` 失败的回退分支（meetap:1053 `|| { ... return 0; }`）
2. 纪要已写出、重命名前进程被中断

此时 portal 会持续渲染那份**陈旧的、重命名前的内容**。属于潜在缺陷。

**建议修法**：按 `st_mtime` 取最新，并显式给字面量 `meeting-notes.md` 降权。

---

## 已核查、确认无问题的部分

记录在此以免后续重复排查：

- **`/api/levels` 不读 config** —— 400ms 轮询只打开 `/tmp` 下两个小文件，
  实测约 7.5 次 open/秒。此前担心的 `parse_config` 放大**不存在**。
- `_again_running` + `_again_lock` 加锁正确；`again` 扔后台线程 + 立即回 202
  的设计正确（`meetap again` 确实前台阻塞，见 meetap:1155,1165 无 `&`）。
- `subprocess` 全部 list 传参 + `shell=False`；会议名走 argv，
  `sanitize_title`(meetap:992) 在 bash 侧清洗 —— 此前实测 5 种注入载荷
  （`; touch /tmp/PWNED #`、`$(...)`、反引号、`../../etc/passwd`）全部中和。
- Host 白名单 / Origin 拒绝 / `X-Meetap` 写头三件套按注释所述生效（实测 403/403/403）。
- `recording_dir` 自身是软链接、或配置值带尾斜杠，都能被 `realpath` 正确处理。
- 前端除 app.js:250（后端渲染的本机纪要）外全部使用 `textContent`。
- `write_config` 逐行改写确实只动命中行 —— 实测改一项只有 1 行差异，
  注释与分区线完整保留。
- 前端按需轮询正确：空闲无 `/api/levels` 请求、页面隐藏全停、
  定时器幂等不叠加（stub DOM 驱动 app.js，13 项断言全绿）。

---

## 建议实施顺序

1. `src/meetap`：两个后台守护进程补重定向（P0-1 根因）
2. `run_cli` 重写：`stdin=DEVNULL` + 超时回查真实状态（P0-1 纵深 + P1-4）
3. `_start_lock`（P0-2）、`_config_lock` + `mkstemp`（P1-3）
4. `_drain_body` 接入 `_guard` 与 `_body_json`，超限改 413（P1-5）
5. `SESSION_RE` 收紧 + `safe_session_dir` 判定 + 注释订正（P2-8 与 P2-7 同批）、
   `find_notes` 按 mtime（P3-9）
6. CSP 头 + 纪要标签白名单清洗（P1-6）

## 验证要点

修复后除回归基线（golden test、安全三件套、config 往返、`node --check`、
轮询脚手架）外，每条缺陷都需定点实测：

- **P0-1/P1-4 是核心**：真终端里 `meetap portal`，网页点开始录制
  必须**秒回成功**（而非 60s 后超时），且 portal 所在终端不出现波形、
  滚动区不被修改；`meetap status` 确认录制中；再点停止正常收尾。
- P0-2：并发两次 `POST /api/start` → 一个 200 一个 409，`pgrep ffmpeg` 计数为 1。
- P1-3：并发 10 个 PUT 各改不同键 → `meetap config show` 应体现全部 10 项。
- P1-5：单连接上「被拒的带 body PUT」后接 GET，第二个响应须为正常 JSON 而非 501；
  `Content-Length: 2000000` 返回 413 且后续请求正常。
- P1-6：`<script>`/`onerror`/`<style>` 写进测试纪要 → 渲染结果中已无这些标签属性；
  浏览器 Console 无 CSP 违规（确认前端未被误伤）；真实纪要的表格、代码块、
  标题层级、引用块渲染不受影响。
- P2-7：软链接一个会话目录 → 侧栏点得开（当前 404）。
- P2-8：`/api/sessions/20260730_1430_..%2F..%2Fetc` 仍 404；新正则单元验证
  合法名匹配、含 `/` 与 `\` 不匹配。
- P3-9：造同时含两种命名的会话（智能命名 mtime 更新）→ 渲染智能命名那份。
