// lx-music 桥接运行时（P1-A3 / P1-A4）
//
// 独立 Node 进程：为 lx-music 协议插件（刀源 / 念心等）提供
//   - globalThis.lx 适配层（EVENT_NAMES / on / send / request）
//   - 与服务端隔离的独立端口（默认 58083），健康端口 58084
//   - HTTP 桥接接口，供 iOS 端 LXBridgeEngine 调用
//
// 协议（lx-music 插件新规范）：
//   const { EVENT_NAMES, request, on, send } = globalThis.lx
//   on(EVENT_NAMES.request, async ({source, action, info}) => { ... return result })
//   send(EVENT_NAMES.inited, { name, version, sources: { <platform>: {name,type,actions,qualitys,...} } })
//
// 每个插件在独立的 vm 上下文内执行，其 on/send 事件互不串扰。
// 桥接接口（POST，body JSON）：
//   /lx/{pluginKey}/list      -> { plugin: {name,version,sources} }
//   /lx/{pluginKey}/search    -> body {name, page}; result [{id,name,singer,picture,duration}]
//   /lx/{pluginKey}/musicUrl  -> body {source, id, quality}; result {url}
//   /lx/{pluginKey}/lyric     -> body {source, id}; result {lyric|lrc}
//   /health                  -> {status:'ok', plugins:[...]}

"use strict";

const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const LX_PORT = process.env.LX_PORT || "58083";
const LX_HEALTH_PORT = process.env.LX_HEALTH_PORT || "58084";
// 插件目录：默认 ./plugins，可经环境变量覆盖（iOS 注入 Documents/noderuntime/plugins/lx）
const DEFAULT_PLUGIN_DIR = path.join(__dirname, "plugins");
const PLUGIN_DIR = process.env.LX_PLUGINS_DIR || DEFAULT_PLUGIN_DIR;

// ============ lx request 适配：把 lx 的 request(url, opts, cb) 映射到 Node http/https ============
function lxRequest(urlStr, options, callback) {
    if (typeof options === "function") { callback = options; options = {}; }
    options = options || {};
    const method = (options.method || "GET").toUpperCase();
    const timeout = options.timeout || 15000;
    const headers = Object.assign({}, options.headers);
    let bodyBuffer = Buffer.alloc(0);
    const hasBody = options.body !== undefined && options.body !== null;
    if (hasBody) {
        if (Buffer.isBuffer(options.body)) bodyBuffer = options.body;
        else if (typeof options.body === "string") bodyBuffer = Buffer.from(options.body, "utf8");
        else bodyBuffer = Buffer.from(JSON.stringify(options.body), "utf8");
        if (!headers["Content-Type"] && bodyBuffer.length > 0
            && !String(headers["Content-Type"])) headers["Content-Type"] = "application/json";
        headers["Content-Length"] = String(bodyBuffer.length);
    }
    if (!headers["User-Agent"]) headers["User-Agent"] = "lx-bridge/1.0";

    let req;
    try {
        const u = new URL(urlStr);
        const isHttps = u.protocol === "https:";
        const lib = isHttps ? https : http;
        const defaultPort = isHttps ? 443 : 80;
        const port = u.port ? Number(u.port) : defaultPort;
        req = lib.request({
            hostname: u.hostname,
            port,
            path: u.pathname + u.search,
            method,
            headers,
            protocol: u.protocol,
        }, (res) => {
            const chunks = [];
            res.on("data", (c) => chunks.push(c));
            res.on("end", () => {
                const raw = Buffer.concat(chunks);
                const text = raw.toString("utf8");
                let body = text;
                const ct = (res.headers["content-type"] || "").toString().toLowerCase();
                if (ct.includes("json")) {
                    try { body = JSON.parse(text); } catch (e) { body = text; }
                } else if (raw.length > 0 && /^[\s]*[\[{]/.test(text)) {
                    try { body = JSON.parse(text); } catch (e) { body = text; }
                }
                callback(null, {
                    statusCode: res.statusCode || 200,
                    statusMessage: res.statusMessage || "",
                    headers: res.headers,
                    body,
                });
            });
        });
        req.setTimeout(timeout, () => { req.destroy(new Error("timeout")); });
        req.on("error", (err) => callback(err, null));
        if (hasBody) req.write(bodyBuffer);
        req.end();
    } catch (err) {
        if (callback) callback(err, null);
    }
}

// ============ 事件注册器（每插件一个） ============
function createLXSandbox(onInit) {
    const handlers = {};           // eventName -> fn
    const inited = { inited: false, payload: null };

    const lx = {
        EVENT_NAMES: { inited: "init", request: "request" },
        request: lxRequest,
        on(eventName, handler) { handlers[eventName] = handler; },
        send(eventName, payload) {
            if (eventName === "init") {
                inited.inited = true;
                inited.payload = payload || {};
                if (typeof onInit === "function") onInit(inited.payload);
            }
            // 其余事件（如 update 提示）仅记录，不阻塞。
        },
    };

    function invoke(action, data) {
        const h = handlers["request"];
        if (typeof h !== "function") {
            const e = new Error("plugin has no request handler");
            e.code = "NO_HANDLER";
            return Promise.reject(e);
        }
        data = data || {};

        // ---- 参数归一化（关键）：桥接方 Swift LXBridgeEngine 发送扁平 {source, action-deps}，
        // 而各插件按 lx-music 规范从 info 读取。这里统一映射成兼容两种形态的 info：
        //   刀源: search→info.keyword / musicUrl→info.musicInfo + info.type
        //   念心: musicUrl→扁平 info.id + info.quality
        const base = data.info && typeof data.info === "object" ? Object.assign({}, data.info) : {};
        let info = base;
        if (action === "search") {
            info.keyword = data.name || data.keyword || base.keyword || "";
            info.name = data.name || base.name || "";
            if (data.page != null) info.page = data.page;
            if (data.limit != null) info.limit = data.limit;
            info.type = "search";
        } else if (action === "musicUrl") {
            const id = data.id || base.id || "";
            const q = data.quality || base.quality || base.type || "128k";
            info.id = id;
            info.quality = q;
            info.type = q;
            info.source = data.source;   // 平台（wy/kw…）
            // P1-A7：优先采用 Swift 原样回传的搜索原始 musicInfo（含 hash/songmid/name/singer/…，念心等靠它解析），
            // 否则用 id/name/singer 兜底组装（刀源可用 name+singer 搜索匹配）。
            const rawMusicInfo = data.musicInfo || base.musicInfo || null;
            if (rawMusicInfo && typeof rawMusicInfo === "object") {
                info.musicInfo = Object.assign({}, rawMusicInfo);
                if (!info.musicInfo.id) info.musicInfo.id = id;
            } else {
                info.musicInfo = {
                    id,
                    name: data.name || base.name || "",
                    singer: data.singer || base.singer || "",
                    albumName: data.albumName || base.albumName || "",
                };
            }
            // 把 musicInfo 平台专有字段并到 info 顶层（flat 形态），兼容读 info.hash / info.songmid / info.id 的插件
            Object.keys(info.musicInfo).forEach((k) => {
                if (info[k] === undefined) info[k] = info.musicInfo[k];
            });
        } else if (action === "lyric") {
            info.id = data.id || base.id || "";
            info.quality = data.quality || base.quality || "";
            info.source = data.source;
        }

        const ctx = { source: data.source || base.source || "", action, info };
        try {
            const r = h(ctx);
            return Promise.resolve(r).then((v) => ({ ok: true, result: v, action, source: data.source }))
                .catch((err) => ({ ok: false, error: String(err && err.message || err), action, source: data.source }));
        } catch (err) {
            return Promise.resolve({ ok: false, error: String(err && err.message || err), action, source: data.source });
        }
    }

    return { lx, invoke, inited };
}

// ============ 插件容器 ============
const loadedPlugins = {};   // key -> {key, file, name, version, sources, invoke, initialized}

// 等待插件异步 init（部分插件在 checkUpdate 网络回调后才 send('init')）
function waitForInit(sandbox, timeoutMs) {
    return new Promise((resolve, reject) => {
        if (sandbox.inited.inited) return resolve(sandbox.inited.payload);
        const deadline = Date.now() + timeoutMs;
        const timer = setInterval(() => {
            if (sandbox.inited.inited) { clearInterval(timer); resolve(sandbox.inited.payload); }
            else if (Date.now() >= deadline) { clearInterval(timer); resolve(null); }
        }, 30);
    });
}

async function loadPlugin(filePath) {
    const key = path.basename(filePath, path.extname(filePath));
    let code;
    try { code = fs.readFileSync(filePath, "utf8"); }
    catch (e) { return { key, error: "read fail: " + e.message }; }

    // onInit：init 可能晚到（checkUpdate 网络回调后），即使晚到也更新元数据。
    function applyInit(payload) {
        const p = payload || {};
        if (!loadedPlugins[key]) return;
        loadedPlugins[key].name = p.name || (loadedPlugins[key].name || "");
        loadedPlugins[key].version = p.version || (loadedPlugins[key].version || "");
        loadedPlugins[key].sources = p.sources || (loadedPlugins[key].sources || {});
    }
    const sandbox = createLXSandbox(applyInit);
    // 先注册（request 处理函数在脚本期内同步注册，功能立即可用）
    loadedPlugins[key] = { key, file: path.basename(filePath), name: "", version: "", sources: {}, invoke: sandbox.invoke };
    try {
        const ctx = vm.createContext(boxFor(sandbox));
        const script = new vm.Script(code, { filename: path.basename(filePath) });
        script.runInContext(ctx, { timeout: 8000 });
    } catch (e) {
        loadedPlugins[key].error = String(e && e.message || e);
        return { key, error: "load fail: " + (e && e.message || e) };
    }

    // 尽力等一段 init；即使等不到，功能仍可用，元数据由 onInit 晚到补齐。
    const payload = await waitForInit(sandbox, 2500);   // 若已 inited 立即返回
    applyInit(payload);
    const p = loadedPlugins[key];
    return { key, name: p.name, version: p.version, sources: p.sources };
}

function boxFor(sandbox) {
    // vm 上下文：传入的对象即全局对象。插件使用 globalThis.lx / window.lx，
    // 因此必须把 lx 挂在全局属性上（不能试图覆盖 globalThis 本身）。
    return {
        lx: sandbox.lx,
        window: sandbox.lx,
        self: sandbox.lx,
        console, setTimeout, clearTimeout, setInterval, clearInterval, URL, URLSearchParams, Buffer,
    };
}

async function loadAllPlugins() {
    if (!fs.existsSync(PLUGIN_DIR)) {
        try { fs.mkdirSync(PLUGIN_DIR, { recursive: true }); } catch (e) {}
        return [];
    }
    const files = fs.readdirSync(PLUGIN_DIR).filter((f) => f.endsWith(".js"));
    const out = [];
    for (const f of files) {
        const r = await loadPlugin(path.join(PLUGIN_DIR, f));
        if (r.error) { out.push({ file: f, error: r.error }); }
        else out.push({ key: r.key, name: r.name, version: r.version, sources: Object.keys(r.sources || {}) });
    }
    return out;
}

// ============ HTTP 服务 ============
function sendJSON(res, code, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(code, { "Content-Type": "application/json; charset=utf-8", "Access-Control-Allow-Origin": "*", "Content-Length": Buffer.byteLength(body) });
    res.end(body);
}

function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        req.on("data", (c) => chunks.push(c));
        req.on("end", () => {
            const raw = Buffer.concat(chunks).toString("utf8");
            if (!raw) return resolve({});
            try { resolve(JSON.parse(raw)); } catch (e) { resolve({}); }
        });
        req.on("error", reject);
    });
}

const server = http.createServer(async (req, res) => {
    const u = new URL(req.url, "http://127.0.0.1:" + LX_PORT);
    const seg = u.pathname.split("/").filter(Boolean); // ['lx', key, action] 或 ['health']

    if (seg[0] === "health" || (seg.length >= 1 && seg[seg.length - 1] === "health")) {
        return sendJSON(res, 200, { status: "ok", plugins: Object.keys(loadedPlugins) });
    }
    if (seg[0] !== "lx" || seg.length < 3) {
        return sendJSON(res, 404, { ok: false, error: "not found" });
    }
    const key = seg[1];
    // action 大小写敏感（插件按精确字符串匹配，如 musicUrl / search / lyric），不做归一化。
    const action = seg[2];
    const plugin = loadedPlugins[key];
    if (!plugin) return sendJSON(res, 200, { ok: false, loading: true, error: "plugin not loaded yet: " + key });

    if (action === "list") {
        return sendJSON(res, 200, { ok: true, plugin: { key, name: plugin.name, version: plugin.version, sources: plugin.sources } });
    }

    const body = await readBody(req);
    const r = await plugin.invoke(action, body);
    return sendJSON(res, 200, r);
});

server.listen(Number(LX_PORT), "127.0.0.1", () => {
    console.log("[LX-Bridge] listen 127.0.0.1:" + LX_PORT);
    // 健康端口先行就绪，插件后台异步载入（部分插件 init 需等网络回调）
    http.createServer((req, res) => sendJSON(res, 200, { status: "ok", plugins: Object.keys(loadedPlugins) }))
        .listen(Number(LX_HEALTH_PORT), "127.0.0.1", () => {
            console.log("[LX-Bridge] health 127.0.0.1:" + LX_HEALTH_PORT);
        });
    loadAllPlugins().then((list) => {
        console.log("[LX-Bridge] plugins=" + JSON.stringify(list));
    });
});

// 崩溃保护：未捕获异常仅记录，不退出进程
process.on("uncaughtException", (e) => console.error("[LX-Bridge] uncaught:", e));
process.on("unhandledRejection", (e) => console.error("[LX-Bridge] rejection:", e));

// 供外部冷启动握手（iOS NodeRuntimeManager 写 ack 文件检测启动成功）
if (process.env.LX_ACK_PATH) {
    try { fs.writeFileSync(process.env.LX_ACK_PATH, JSON.stringify({ status: "ok", pid: process.pid })); } catch (e) {}
}