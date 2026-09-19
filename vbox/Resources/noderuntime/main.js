// CatVod Node.js bootstrap shared by Android, iOS, and macOS.
// vbox 宿主改造版 (P1-02/P1-18):
//   1) 运行时文件路径 (NODE_PATH/BUNDLE_PATH) 不再硬编码 iOS 容器路径，
//      统一从外部环境变量注入，由 NodeRuntimeManager 在启动前 setenv。
//   2) 端口 (PORT/DART_PORT) 从环境变量读取，默认 kstore=58080 / catpaw=2333。
//   3) 保留原始 relisten / bundle-switch / startup ack 文件握手协议不变。

// Polyfill WebAssembly for JIT-less V8 (iOS) — prevents undici crash
if (typeof globalThis.WebAssembly === 'undefined') {
    const fakeModule = { exports: { instances: {} } };
    const fakeInstance = { exports: {} };
    globalThis.WebAssembly = {
        compile: () => Promise.resolve(fakeModule),
        instantiate: (mod, imports) => Promise.resolve({ module: fakeModule, instance: fakeInstance }),
        validate: () => true,
        Module: function() { return fakeModule; },
        Instance: function() { return fakeInstance; },
        Memory: function(opts) { this.buffer = new ArrayBuffer(opts.initial * 65536); },
        Table: function() {},
    };
}

// ---- P1-18: 端口与路径统一由环境变量注入（未设置时回退默认） ----
// 默认: kstore bundle → 58080; catpaw bundle → 2333 (由 NodeRuntimeManager 按 bundle 设定)
process.env.PORT = process.env.PORT || "58080";
process.env.DEV_HTTP_PORT = process.env.DEV_HTTP_PORT || process.env.PORT;
process.env.DART_PORT = process.env.DART_PORT || "58081";
process.env.BUNDLE_PATH = process.env.BUNDLE_PATH || "";
process.env.NODE_PATH = process.env.NODE_PATH || ".";
process.env.HEALTH_PORT = process.env.HEALTH_PORT || "58082";

if (!process.env.BUNDLE_PATH) {
    console.error('[NodeBridge] BUNDLE_PATH 未设置，无法加载 bundle');
    process.exit(1);
}

require(process.env.NODE_PATH + '/node-intl-polyfill.js');

const http = require('http');
const https = require('https');
const { AsyncLocalStorage } = require('async_hooks');

// 上游 AppV6 现将 ext 改为 AppV6Dxs/AppV6Tg 符号键，但当前
// Node bundle 仍按旧格式解码，最终只得到 "(" 或空串。仅对精确命中的
// v6 路由和失败特征补回官方动态 ext.jar 解析出的配置。
const appV6Configs = {
    v6dashixiong: {
        host: 'http://fuck1.arkplansuk.com/dsx.php',
        headers: {
            'User-Agent': 'Dart/2.18 (dart:io)',
            'platform-version': 'PJZ110_15.0.0.821(CN01)',
            signature: '7456F662A198C6149A071A8A908D89327DCEBE58',
            'build-time': '1746323374099',
            'version-number': '3309',
            version: '3.3.9',
            platform: 'android',
            'client-name': '5aSn5biI5YWE5b2x6KeG',
        },
        ek: 'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC8bW42CwWrw0UjJmbqPv7ZoRTNDzNk97klPQgWmSndz5PldC92/kB/WWau+zDimbyhTre7yMBhLe+asNU0KE2iVccxMMVtSyb3PsPbKa4D+vdazpddeX6BOoh1OMuzgokoVmxyxBeArWo/Bb+YQ6l9LWC0PTgEyO34CbNHvpMZ/wIDAQAB',
        dk: 'MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAO9omsi+ys7fmBH3w1d0DfvRAQlj0wLB1BI3Xsb9WSiu4lEc1Me+XubnzTxaQPCBbnuZURerRrO981n9GhsQkDcWmtW+X1mpCllOWt8bbnWwKPsHqemRFxncDWE/d0nA9yrZn6nLVy/J7DJ3cVJlIs9bNLArqEi8KkVrAf1PNSLXAgMBAAECgYBGPn3z2q8s5cP7uaOSHFYiBZ/1PlniXDa6JY7ked9YJX/35qqz9LJps6evRpf5OTDOiRyXAkUbZedqBu5K9KArSGVyxp/Vym4b0siEVeM8qq9Gbf74lHPH+L+X/NmXemydwZHR1lU9PiLJVMsh8o6aAazkB8ijZcsNMyYZUSH36QJBAPvHq511Uz45lx5BtVSZClcUnqPRFSmNnRdjATikDzFTObemnGJU3eL/7VIPWtjEj9LvGP/WyX6gyo1zKc8BRtUCQQDza9oFnSmMHPkvrll/zMxcy3FeOTW0hctBhdIMbBmjJJyhlfTmBOvxwm8I91F05ydkSZ1yLuLhAjLxbjqs2fD7AkB/KOHQvW+UTqu22ULGfiCNyFkyrSc9/EqphBQa0ijmJX1R9nCm7Ou/eLgYKK8eKW/l/WGn3IeZT4XdGJu185QdAkBthqmivQRktuSoP5qlllCdsCxiaPtxLoI2CTBpxnoCngab7g0zMiO3s/Sh5CYSo69lwHnHVrFe7M5fM2nTPHzhAkEAiJETUvYFwCVKNGTYMzUg7v3QblqYXB+IhzcU37sHZOn6a46V5eJDadavIvuEmoxJHWTybi+1ZkN7LeUUg4ylCw==',
        rsaM5: 'a4090dbb07edb70d7637955c498b7c37',
        apkLength: '62571922',
        pkid: 'com.yzzy.qsd.app.a',
    },
    v6tegou: {
        host: 'http://23.224.122.234:520/tegou.php',
        headers: {
            'User-Agent': 'Dart/2.18 (dart:io)',
            'platform-version': 'TKQ1.220829.002 test-keys',
            signature: 'EAF39B0EF005CF3E0DCEA0C90B4028463B03CB90',
            'build-time': '1684859097929',
            'version-number': '3002',
            version: '3.0.2',
            platform: 'android',
            'client-name': '54m554uXQVBQ',
        },
        ek: 'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDWWB5LOh2P1oj0p056Xqn/bQ2QTLaXFshxXE44OFUQ3v0xilphG8dc3UEtW2pP3y0AgiLhYnZgF+M6R6b1BH1YNO9CBqIdLbh04KKgto8ZVH/CaShR+hMe9jS4mQzz7AtUttykcfDAsWXD0Ub6qwwg3mkYN2/uEdHhP8FuUXunwIDAQAB',
        dk: 'MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAL3/oZU+GQXRvRS89TUClffrNJ9wWgZn7yqei6uq3Vk9xbiF05x5HgQYpSw1c3akycUCSdTkEtQg6//o078ahnxhOYmeU28i1KnZhbD9Qc3b+1b3+345lnD/++47mh7E4akPmp71Hbrl/KHv2y4soLUWJm7Ty1HAGRT3cMLIJMPAgMBAAECgYEAtoiKwgjAnXicwPmwUddEIMRU8ABOXO0pNrbO1IP4162i8N2RKTiq/6B1vv0zCn7SYXULXX4oIKfoUxlppKVlIRtfBqNJ/Cb1sSInI+qcze38YRBkZlDSV2gMWmzCARFQTRilOv+8t9o7XpN8VI3FdrGRSBoMexFwEES2oanRdKECQQD1FZB8AXcoHOBj8P3C7Rz84qAg+NPtpLONKyTBWmnfqYbtWIwUynxVg0XA6M+mthWipJOJIJE3hId0P3zfJ1J5AkEAxnX7telUbU4UhGuiP92fH92j0JrT7QT321UJ9+0QWHNVJwC4wYxNW10R4IPhKpGUaw66iBGXKljU8RcMIfVvxwJARy0pFepzCZJBVKUTfX3RUlwatxisq7KOdqwV85VndA5O4jU6EXuw2kDSjDDQxZDR/bcgJc3wfpgdopQhlslbuQJAT5ywts69EYQK8vwCgEA1PyE4P8xS0585z173Dr7HaBWfmjptKrFtWrmavw8bUktEq074q27yD8OXRBzy4ObrQJAAw7olxJ+mp+Jg8EGuKRZc9lJdWujcamWrmL4Q2AxPwH+dq6vvrvxg+21CubKTrpz1uxUAdUmzTHURHxY3HDaCA==',
        rsaM5: '14855994d0bb80d883010a2ee274d016',
        apkLength: '47426980',
        pkid: 'com.yunxiang.wuyu',
    },
};
const appV6DecodeFailures = {
    v6dashixiong: '(',
    v6tegou: '',
};
const appV6RemoteConfigMigrations = {
    v6dashixiong: {
        legacyKey: 'AppV6Dxs',
        successorKey: 'AppV7Dsx',
    },
};
const spiderRequestContext = new AsyncLocalStorage();
const originalJsonParse = JSON.parse;
JSON.parse = function(text, reviver) {
    const context = spiderRequestContext.getStore();
    try {
        const parsed = originalJsonParse.call(this, text, reviver);
        const migration = appV6RemoteConfigMigrations[context?.siteKey];
        const sites = parsed?.sites;
        if (migration
            && Array.isArray(sites)
            && !sites.some(site => site?.key === migration.legacyKey)
            && sites.some(site => site?.key === migration.successorKey)) {
            sites.push({
                key: migration.legacyKey,
                api: 'csp_AppV6Amns',
                ext: migration.legacyKey,
            });
            console.log(
                '[NodeBridge] restored legacy AppV6 config entry for '
                + context.siteKey,
            );
        }
        return parsed;
    } catch (error) {
        if (!(error instanceof SyntaxError)
            || !context?.appV6Config
            || typeof text !== 'string'
            || text.trim() !== context.appV6DecodeFailure) {
            throw error;
        }
        console.log(
            '[NodeBridge] applied AppV6 symbolic-ext compatibility for '
            + context.siteKey,
        );
        return originalJsonParse.call(
            this,
            JSON.stringify(context.appV6Config),
            reviver,
        );
    }
};

// 修复 spider 构造的异常 URL
function fixUrl(opts) {
    if (!opts || !opts.path) return opts;
    let path = opts.path;
    let changed = false;
    // 189 云盘：shareCode 含中文注释 "（访问码：xxx）" → 提取纯 shareCode + accessCode
    if (opts.hostname && opts.hostname.includes('cloud.189.cn')) {
        const m = path.match(/(shareCode=)([^&（]+)[（(]访问码[：:]([^）)]+)[）)]/);
        if (m) {
            path = path.replace(m[0], m[1] + m[2] + '&accessCode=' + m[3]);
            changed = true;
        }
        // URL 编码版: %EF%BC%88 = （, %EF%BC%89 = ）
        const em = path.match(/(shareCode=)([^&%]+)(%EF%BC%88|%28).*?(%EF%BC%9A|%3A)([^%&]+?)(%EF%BC%89|%29)/);
        if (em) {
            path = path.replace(em[0], em[1] + em[2] + '&accessCode=' + em[5]);
            changed = true;
        }
    }
    // undefined 参数 → 移除
    if (path.includes('=undefined')) {
        path = path.replace(/[&?][^&]*=undefined/g, '');
        if (!path.includes('?') && path.includes('&')) path = path.replace('&', '?');
        changed = true;
    }
    // tingyou.fm → www.tingyou.fm（避免 307 重定向导致响应 body 为空）
    if (opts.hostname === 'tingyou.fm') {
        opts.hostname = 'www.tingyou.fm';
        if (opts.host) opts.host = opts.host.replace('tingyou.fm', 'www.tingyou.fm');
        changed = true;
    }
    if (changed) {
        console.log('[HTTP-FIX] ' + opts.hostname + path.substring(0, 100));
        opts.path = path;
    }
    return opts;
}
function patchRequest(mod) {
    const orig = mod.request;
    mod.request = function(...args) {
        if (typeof args[0] === 'object' && args[0] !== null) {
            args[0] = fixUrl(args[0]);
            const h = args[0].hostname || '';
            if (h.includes('baidu')) {
                console.log('[HTTP-BAIDU]', h + (args[0].path || '').substring(0, 150));
            }
        }
        const reqOpts = typeof args[0] === 'object' ? args[0] : {};
        const host = reqOpts.hostname || reqOpts.host || '';
        const path = (reqOpts.path || '').substring(0, 100);
        console.log('[HTTP-REQ]', (reqOpts.method || 'GET'), host + path);
        return orig.apply(this, args);
    };
}
patchRequest(http);
patchRequest(https);

globalThis.__catServers = [];
globalThis.catServerFactory = function(handler, opts) {
    const server = http.createServer((req, res) => {
        const requestPath = String(req.url || '').split('?', 1)[0];
        const pathSegments = requestPath.split('/');
        const siteKey = pathSegments.length >= 5
            && pathSegments[1] === 'spider'
            && pathSegments[3] === '3'
            ? pathSegments[2]
            : '';
        return spiderRequestContext.run(
            {
                appV6Config: appV6Configs[siteKey],
                appV6DecodeFailure: appV6DecodeFailures[siteKey],
                path: requestPath,
                siteKey,
            },
            () => handler(req, res),
        );
    });
    globalThis.__catServers.push(server);
    return server;
};
globalThis.catDartServerPort = function() { return parseInt(process.env.DART_PORT) || 0; };

// CatVod spider 依赖的全局代理 URL（用于代理 HTTP 请求）
globalThis.jsProxy = 'http://127.0.0.1:' + process.env.PORT + '/proxy?do=js&url=';

// 某些 spider 用 local 对象读写配置
if (!globalThis.local) {
    const _store = {};
    globalThis.local = {
        get: (key, def) => _store[key] !== undefined ? _store[key] : (def || ''),
        set: (key, val) => { _store[key] = val; },
    };
}

// 防止未捕获的 Promise 错误崩溃 spider
process.on('unhandledRejection', () => {});
process.on('uncaughtException', () => {});

// macOS runs Node.js as a signed child process. Exit promptly if the Flutter
// parent is killed without receiving applicationWillTerminate.
const parentPid = Number.parseInt(process.env.TVS_PARENT_PID || '', 10);
if (Number.isInteger(parentPid) && parentPid > 0) {
    const parentWatchdog = setInterval(() => {
        try {
            process.kill(parentPid, 0);
        } catch (error) {
            if (error?.code === 'EPERM') return;
            console.log('[NodeBridge] parent process exited; stopping Node.js');
            process.exit(0);
        }
    }, 500);
    parentWatchdog.unref();
}

process.chdir(process.env.NODE_PATH);

// Ensure db.json exists with required structure
const fs = require('fs');
const path = require('path');
const dbPath = path.join(process.env.NODE_PATH, 'db.json');
try {
    const existing = JSON.parse(fs.readFileSync(dbPath, 'utf8'));
    if (!existing.pans) existing.pans = { list: [] };
    if (!existing.pans.list) existing.pans.list = [];
    fs.writeFileSync(dbPath, JSON.stringify(existing));
} catch(e) {
    fs.writeFileSync(dbPath, JSON.stringify({
        pans: { list: [] },
        sites: { list: [] },
        flags: [],
    }));
}

// iOS 挂起后监听 socket 可能失效。宿主写入唯一 token，Node 在
// 原端口完成安全重监听后写 ack；HTTP probe 仍是最终成功依据。
const relistenNodeDir = process.env.NODE_PATH || '.';
const startupAckPath = path.join(relistenNodeDir, '.startup.ack');
const relistenPath = path.join(relistenNodeDir, '.relisten');
const relistenAckPath = path.join(relistenNodeDir, '.relisten.ack');
const bundleSwitchPath = path.join(relistenNodeDir, '.bundle-switch');
const bundleSwitchAckPath = path.join(
    relistenNodeDir,
    '.bundle-switch.ack',
);
let lastRelistenToken = '';
let relistenInFlight = false;
let lastBundleSwitchToken = '';
let bundleSwitchInFlight = false;

function parseRelistenCommand(raw) {
    try {
        const command = JSON.parse(raw);
        if (command && typeof command.token === 'string') {
            return {
                token: command.token,
                dartPort: Number.isInteger(command.dartPort)
                    ? command.dartPort
                    : null,
            };
        }
    } catch (_) {}
    return { token: raw, dartPort: null };
}

try {
    const raw = fs.readFileSync(relistenPath, 'utf8').trim();
    lastRelistenToken = parseRelistenCommand(raw).token;
} catch (_) {}

function writeRelistenAck(token, status, error) {
    const ack = { token, status };
    if (error) ack.error = String(error.message || error);
    fs.writeFileSync(relistenAckPath, JSON.stringify(ack));
}

function closeServer(server) {
    if (!server.listening) return Promise.resolve();
    return new Promise((resolve, reject) => {
        const timer = setTimeout(
            () => reject(new Error('server.close timed out')),
            4000,
        );
        server.close((error) => {
            clearTimeout(timer);
            if (error) reject(error); else resolve();
        });
        if (server.closeAllConnections) server.closeAllConnections();
    });
}

function listenServer(server, port) {
    return new Promise((resolve, reject) => {
        const onError = (error) => {
            server.off('listening', onListening);
            reject(error);
        };
        const onListening = () => {
            server.off('error', onError);
            resolve();
        };
        server.once('error', onError);
        server.once('listening', onListening);
        server.listen(port);
    });
}

async function relistenServers(command) {
    const token = command.token;
    if (command.dartPort !== null && command.dartPort >= 0) {
        process.env.DART_PORT = String(command.dartPort);
    }
    const port = parseInt(process.env.PORT) || 0;
    const servers = globalThis.__catServers || [];
    try {
        await Promise.all(servers.map(async (server) => {
            await closeServer(server);
            await listenServer(server, port);
        }));
        writeRelistenAck(token, 'ok');
        console.log(
            '[NodeBridge] relisten ok token=' + token
            + ' port=' + port
            + ' dartPort=' + process.env.DART_PORT,
        );
    } catch (error) {
        writeRelistenAck(token, 'error', error);
        console.log('[NodeBridge] relisten failed token=' + token + ': ' + error.message);
    }
}

function checkRelistenCommand() {
    if (relistenInFlight) return;
    let raw = '';
    try {
        raw = fs.readFileSync(relistenPath, 'utf8').trim();
    } catch (_) {
        return;
    }
    const command = parseRelistenCommand(raw);
    if (!command.token || command.token === lastRelistenToken) return;
    lastRelistenToken = command.token;
    relistenInFlight = true;
    relistenServers(command).finally(() => {
        relistenInFlight = false;
    });
}

function parseBundleSwitchCommand(raw) {
    try {
        const command = JSON.parse(raw);
        if (command
            && typeof command.token === 'string'
            && typeof command.bundlePath === 'string'
            && command.bundlePath) {
            return {
                token: command.token,
                bundlePath: command.bundlePath,
                dartPort: Number.isInteger(command.dartPort)
                    ? command.dartPort
                    : null,
            };
        }
    } catch (_) {}
    return null;
}

try {
    const raw = fs.readFileSync(bundleSwitchPath, 'utf8').trim();
    lastBundleSwitchToken = parseBundleSwitchCommand(raw)?.token || '';
} catch (_) {}

function writeBundleSwitchAck(token, status, error) {
    const ack = { token, status };
    if (error) ack.error = String(error.message || error);
    fs.writeFileSync(bundleSwitchAckPath, JSON.stringify(ack));
}

function writeStartupAck(status, error) {
    const ack = { status };
    if (error) ack.error = String(error.message || error);
    try {
        fs.writeFileSync(startupAckPath, JSON.stringify(ack));
    } catch (ackError) {
        console.error(
            '[NodeBridge] startup ack failed:',
            ackError.message,
        );
    }
}

async function closeServersStrictly(servers) {
    for (const server of servers) {
        await closeServer(server);
    }
}

async function switchBundle(command) {
    const previousBundlePath = process.env.BUNDLE_PATH;
    const previousDartPort = process.env.DART_PORT;
    try {
        await closeServersStrictly(globalThis.__catServers || []);
        globalThis.__catServers = [];
        if (command.dartPort !== null && command.dartPort >= 0) {
            process.env.DART_PORT = String(command.dartPort);
        }
        process.env.BUNDLE_PATH = command.bundlePath;
        await startBundle(command.bundlePath);
        writeBundleSwitchAck(command.token, 'ok');
        console.log(
            '[NodeBridge] bundle switch ok token=' + command.token
            + ' bundle=' + command.bundlePath,
        );
    } catch (error) {
        try {
            await closeServersStrictly(globalThis.__catServers || []);
            globalThis.__catServers = [];
            process.env.BUNDLE_PATH = previousBundlePath;
            process.env.DART_PORT = previousDartPort;
            await startBundle(previousBundlePath);
            writeBundleSwitchAck(command.token, 'error', error);
            console.log(
                '[NodeBridge] bundle switch rolled back token=' + command.token
                + ': ' + error.message,
            );
        } catch (rollbackError) {
            writeBundleSwitchAck(
                command.token,
                'fatal',
                new Error(
                    String(error.message || error)
                    + '; rollback: '
                    + String(rollbackError.message || rollbackError),
                ),
            );
            console.log(
                '[NodeBridge] bundle rollback failed token=' + command.token
                + ': ' + rollbackError.message,
            );
        }
    }
}

function checkBundleSwitchCommand() {
    if (bundleSwitchInFlight) return;
    let raw = '';
    try {
        raw = fs.readFileSync(bundleSwitchPath, 'utf8').trim();
    } catch (_) {
        return;
    }
    const command = parseBundleSwitchCommand(raw);
    if (!command
        || !command.token
        || command.token === lastBundleSwitchToken) return;
    lastBundleSwitchToken = command.token;
    bundleSwitchInFlight = true;
    switchBundle(command).finally(() => {
        bundleSwitchInFlight = false;
    });
}

try {
    const watcher = fs.watch(relistenNodeDir, () => {
        checkRelistenCommand();
        checkBundleSwitchCommand();
    });
    watcher.on('error', (error) => {
        console.log('[NodeBridge] command watch error: ' + error.message);
    });
} catch (error) {
    console.log('[NodeBridge] command watch unavailable: ' + error.message);
}
setInterval(checkRelistenCommand, 500);
setInterval(checkBundleSwitchCommand, 500);

// 拦截 axios 响应，记录外部 API 返回内容（调试用）
try {
    const axiosPath = require.resolve('axios', {
        paths: [process.env.BUNDLE_PATH, process.env.NODE_PATH],
    });
    const axios = require(axiosPath);
    if (axios && axios.interceptors) {
        axios.interceptors.response.use(
            resp => {
                const u = resp.config?.url || '';
                if (u.includes('play_url') || u.includes('vod/play')) {
                    const d = resp.data;
                    const dataField = typeof d === 'object' ? (d.data || '').toString().substring(0, 100) : String(d).substring(0, 100);
                    console.log('[AXIOS-PLAY] url=' + u.substring(0, 80) + ' status=' + resp.status + ' data.data=' + dataField);
                }
                return resp;
            },
            err => { return Promise.reject(err); }
        );
        console.log('[NodeBridge] axios interceptor installed');
    }
} catch(e) {
    console.log('[NodeBridge] axios interceptor skip: ' + e.message);
}

let tolerantPromiseAllInstalled = false;
async function startBundle(bundlePath) {
    const resolvedBundlePath = require.resolve(bundlePath);
    delete require.cache[resolvedBundlePath];
    const bundle = require(resolvedBundlePath);
    // websiteBundle 是函数，模板 ${globalThis.websiteBundle} 输出函数源码
    // 会导致浏览器语法错误。转为字符串后模板直接输出可执行的 JS 代码。
    if (typeof globalThis.websiteBundle === 'function') {
        globalThis.websiteBundle = globalThis.websiteBundle();
    }

    if (!bundle || typeof bundle.start !== 'function') {
        throw new Error('No start() export found: ' + bundlePath);
    }

    // CatVod 会 structuredClone 启动参数，因此这里只能传普通可克隆对象。
    // 显式提供各服务的空配置，兼容未配置 cookie/账号时的直接属性读取。
    const startOpts = {
        color: [],
        sites: { list: [] },
        pans: { list: [] },
        ali: { token: '' },
        baidu: { cookie: '' },
        bilibili_all: { cookie: '', classes_all: '', filters_all: '' },
        cms: {},
        danmu: {},
        dudb: {},
        guazi: { url: '', token: '' },
        live: [],
        mycloud: { text: '' },
        pan123: { username: '', password: '' },
        pikpak: {
            username: '',
            email: '',
            password: '',
            refresh_token: '',
            device_id: '',
            user_id: '',
        },
        quark: { cookie: '' },
        server: {},
        sharemount: { text: '', batchTiers: {} },
        t4: {},
        tgsou: {},
        tianyi: { username: '', password: '' },
        uc: { cookie: '', token: '', ut: '' },
        xunlei: { username: '', password: '' },
        y115: { cookie: '', offline: {} },
    };
    await bundle.start(startOpts);
    console.log(
        '[NodeBridge] CatVod server started on port ' + process.env.PORT,
    );

    // fastify 启动完成后，让 Promise.all 容错化
    // 解决 spider detail 处理多云盘源时，一个失败导致全部崩溃
    if (!tolerantPromiseAllInstalled) {
        tolerantPromiseAllInstalled = true;
        const originalAll = Promise.all.bind(Promise);
        Promise.all = function(promises) {
            const arr = Array.from(promises);
            return originalAll(arr.map(p => Promise.resolve(p).catch(e => {
                console.log(
                    '[Promise.all] tolerated:',
                    String(e.message || e).substring(0, 100),
                );
                return undefined;
            })));
        };
    }
}

startBundle(process.env.BUNDLE_PATH)
    .then(() => writeStartupAck('ok'))
    .catch((error) => {
        writeStartupAck('error', error);
        console.error('[NodeBridge] start failed:', error.message, error.stack);
    });
