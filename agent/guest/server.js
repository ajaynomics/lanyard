// Pi desktop guest control server (Sprites, Alpine-compatible).
//
// One authenticated HTTP server on $PORT (default 8080):
//   GET  /health  -> 200 only when the display, capture and input paths work
//   POST /action  -> validated {screenshot,click,type,key,scroll,drag,wait}
//                    always answered with an observed screenshot
//
// Pi remains the agent: this server owns no model, no conversation, no stream.
// Actions run sequentially; model text only ever travels as argv, never shell.
// Every route requires the per-desktop bearer in PI_DESKTOP_TOKEN.
import http from "node:http";
import { execFile, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readlinkSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { readFile, unlink } from "node:fs/promises";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { pathToFileURL } from "node:url";

export const WIDTH = Number(process.env.PI_DESKTOP_WIDTH || 1280);
export const HEIGHT = Number(process.env.PI_DESKTOP_HEIGHT || 800);
export const PORT = Number(process.env.PORT || 8080);
// Bind address. Pi desktops are reached on the guest IP; an existing browser desktop keeps
// every listener on guest loopback behind its SSH relay (PI_DESKTOP_HOST=127.0.0.1).
export const HOST = process.env.PI_DESKTOP_HOST || "0.0.0.0";
export const DISPLAY = process.env.DISPLAY || ":99";
export const VNC_PORT = 5900;

const MAX_BODY_BYTES = 64 * 1024;
const MAX_TEXT_LEN = 1024;
const MAX_WAIT_MS = 20000;
// Input actions get a fixed budget; wait gets its own so a long wait does
// not eat the capture budget that follows it.
const EXEC_TIMEOUT_MS = 15000;
const MAX_SCROLL_CLICKS = 20;
const MUTATING_ACTIONS = new Set(["click", "type", "key", "scroll", "drag"]);

class ActionOutcomeUnknownError extends Error {
  constructor(action, detail) {
    super(`desktop ${action} outcome unknown — it may have executed. Take a fresh screenshot before deciding whether to retry. (${detail})`);
    this.name = "ActionOutcomeUnknownError";
    this.status = 504;
    this.outcomeUnknown = true;
  }
}
// agent: VNC view-only. operator: agent input refused. shared: both drive.
const CONTROL_OWNERS = new Set(["agent", "operator", "shared"]);

const ACTION_SCHEMAS = {
  screenshot: { allow: ["action"] },
  click: { allow: ["action", "x", "y"], need: ["x", "y"] },
  type: { allow: ["action", "text"], need: ["text"] },
  key: { allow: ["action", "key"], need: ["key"] },
  scroll: { allow: ["action", "x", "y", "dx", "dy"], need: [] },
  drag: { allow: ["action", "x", "y", "x2", "y2"], need: ["x", "y", "x2", "y2"] },
  wait: { allow: ["action", "ms"], need: ["ms"] },
};

function isInt(n) {
  return typeof n === "number" && Number.isInteger(n);
}

function inRange(n, lo, hi) {
  return isInt(n) && n >= lo && n <= hi;
}

// validateAction is pure: shape errors before anything touches the display.
export function validateAction(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const schema = ACTION_SCHEMAS[body.action];
  if (!schema) {
    return { ok: false, error: "unknown action (screenshot|click|type|key|scroll|drag|wait)" };
  }
  for (const k of Object.keys(body)) {
    if (!schema.allow.includes(k)) {
      return { ok: false, error: `unknown field ${JSON.stringify(k)}` };
    }
  }
  for (const k of schema.need || []) {
    if (body[k] === undefined) {
      return { ok: false, error: `missing field ${k}` };
    }
  }
  const coord = (v, name, max) =>
    v === undefined || inRange(v, 0, max) ? null : `${name} must be an integer 0..${max}`;
  let bad =
    coord(body.x, "x", WIDTH - 1) ||
    coord(body.y, "y", HEIGHT - 1) ||
    coord(body.x2, "x2", WIDTH - 1) ||
    coord(body.y2, "y2", HEIGHT - 1);
  if (bad) return { ok: false, error: bad };
  if (body.text !== undefined && (typeof body.text !== "string" || body.text.length < 1 || body.text.length > MAX_TEXT_LEN)) {
    return { ok: false, error: `text must be 1..${MAX_TEXT_LEN} chars` };
  }
  if (body.key !== undefined && (typeof body.key !== "string" || !/^[A-Za-z0-9_+-]{1,64}$/.test(body.key))) {
    return { ok: false, error: "key must match [A-Za-z0-9_+-]{1,64} (xdotool names, + joins modifiers)" };
  }
  if (body.ms !== undefined && !inRange(body.ms, 0, MAX_WAIT_MS)) {
    return { ok: false, error: `ms must be an integer 0..${MAX_WAIT_MS}` };
  }
  for (const k of ["dx", "dy"]) {
    if (body[k] !== undefined && !inRange(body[k], -10, 10)) {
      return { ok: false, error: `${k} must be an integer -10..10` };
    }
  }
  if (body.action === "scroll" && (body.dx || 0) === 0 && (body.dy || 0) === 0) {
    return { ok: false, error: "scroll needs a nonzero dx or dy" };
  }
  // Scroll may target a point; the pointer is moved there first. Both
  // coordinates or neither, so a half-specified target cannot scroll the
  // wrong element silently.
  if (body.action === "scroll" && (body.x === undefined) !== (body.y === undefined)) {
    return { ok: false, error: "scroll needs both x and y or neither" };
  }
  return { ok: true, action: body };
}

function withTimeout(promise, ms, what) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} timed out after ${ms}ms`)), ms);
  });
  return Promise.race([promise.finally(() => clearTimeout(timer)), timeout]);
}

function waitForProcessExit(proc, timeoutMs, label) {
  if ((proc?.exitCode !== null && proc?.exitCode !== undefined) || proc?.signalCode) return Promise.resolve();
  if (typeof proc?.once !== "function") {
    return Promise.reject(new Error(`${label} process has no exit event`));
  }
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer;
    const cleanup = () => {
      clearTimeout(timer);
      proc.removeListener?.("exit", finish);
      proc.removeListener?.("close", finish);
      proc.removeListener?.("error", fail);
    };
    const finish = () => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve();
    };
    const fail = (err) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error(`${label} process reported an error before exit: ${String(err?.message || err)}`));
    };
    proc.once("exit", finish);
    proc.once("close", finish);
    proc.once("error", fail);
    if ((proc.exitCode !== null && proc.exitCode !== undefined) || proc.signalCode) {
      finish();
      return;
    }
    timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error(`${label} process did not exit within ${timeoutMs}ms`));
    }, timeoutMs);
  });
}

async function terminateProcess(proc, label, timeoutMs = 1000) {
  try {
    proc.kill("SIGTERM");
  } catch {}
  try {
    await waitForProcessExit(proc, timeoutMs, label);
    return;
  } catch (firstErr) {
    try {
      proc.kill("SIGKILL");
    } catch {}
    try {
      await waitForProcessExit(proc, timeoutMs, label);
    } catch (secondErr) {
      throw new Error(`${label} process could not be stopped: ${secondErr.message || firstErr.message}`);
    }
  }
}

function abortableDelay(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error("input cancelled"));
      return;
    }
    // Define both callbacks before arming the timer: setTimeout(done) above
    // `const done` hit the temporal dead zone and every wait threw.
    let timer;
    const onAbort = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      reject(new Error("input cancelled"));
    };
    const done = () => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    };
    signal?.addEventListener("abort", onAbort, { once: true });
    timer = setTimeout(done, ms);
  });
}

async function runInputWithTimeout(backend, action, budget) {
  const controller = new AbortController();
  const input = Promise.resolve().then(() => doInput(backend, action, controller.signal));
  try {
    return await withTimeout(input, budget, "action");
  } catch (err) {
    if (/timed out|timeout/i.test(String(err?.message || err))) controller.abort();
    // Do not release the serialized display queue until every underlying
    // input subprocess has observed cancellation and settled. Otherwise a
    // queued takeover could race a late scroll/drag step.
    await input.catch(() => {});
    if (MUTATING_ACTIONS.has(action.action)) {
      throw new ActionOutcomeUnknownError(action.action, String(err?.message || err).slice(0, 200));
    }
    throw err;
  }
}

async function runCaptureWithTimeout(backend, budget) {
  const controller = new AbortController();
  const capture = Promise.resolve().then(() => backend.capture({ signal: controller.signal }));
  try {
    return await withTimeout(capture, budget, "capture");
  } catch (err) {
    if (/timed out|timeout/i.test(String(err?.message || err))) controller.abort();
    // A timed-out capture must settle before the serialized display queue is
    // released, just like input. Otherwise a late scrot can overlap the next
    // action and produce a screenshot of the wrong state.
    await capture.catch(() => {});
    throw err;
  }
}

// Default backend: real X11 tools via argv (never a shell).
export function realBackend(env = process.env) {
  const displayEnv = { ...env, DISPLAY: env.DISPLAY || DISPLAY };
  const run = (cmd, args, { signal } = {}) =>
    new Promise((resolve, reject) => {
      execFile(cmd, args, { env: displayEnv, timeout: EXEC_TIMEOUT_MS, signal }, (err, stdout, stderr) => {
        if (err) reject(new Error(`${cmd} failed: ${String(stderr || err.message).slice(0, 500)}`));
        else resolve({ stdout: String(stdout), stderr: String(stderr) });
      });
    });
  return {
    async geometry() {
      const { stdout } = await run("xdotool", ["getdisplaygeometry"]);
      return stdout.trim();
    },
    async capture({ signal } = {}) {
      const path = join(tmpdir(), `shot-${process.pid}-${randomBytes(4).toString("hex")}.png`);
      try {
        await run("scrot", ["-z", path], { signal });
        const png = await readFile(path);
        return { png, width: WIDTH, height: HEIGHT, mime: "image/png" };
      } finally {
        await unlink(path).catch(() => {});
      }
    },
    run,
  };
}

async function doInput(backend, action, signal) {
  const { run } = backend;
  const runInput = (cmd, args) => run(cmd, args, { signal });
  switch (action.action) {
    case "click":
      await runInput("xdotool", ["mousemove", String(action.x), String(action.y), "click", "1"]);
      return `clicked ${action.x},${action.y}`;
    case "type":
      await runInput("xdotool", ["type", "--clearmodifiers", "--delay", "12", "--", action.text]);
      return `typed ${action.text.length} chars`;
    case "key":
      await runInput("xdotool", ["key", "--clearmodifiers", action.key]);
      return `pressed ${action.key}`;
    case "scroll": {
      if (action.x !== undefined) {
        await runInput("xdotool", ["mousemove", String(action.x), String(action.y)]);
      }
      const clicks = [];
      const push = (n, btn) => {
        for (let i = 0; i < Math.min(Math.abs(n), 10); i++) clicks.push(btn);
      };
      if (action.dy) push(action.dy, action.dy > 0 ? "5" : "4");
      if (action.dx) push(action.dx, action.dx > 0 ? "7" : "6");
      for (const btn of clicks.slice(0, MAX_SCROLL_CLICKS)) {
        await runInput("xdotool", ["click", btn]);
      }
      const at = action.x !== undefined ? ` at ${action.x},${action.y}` : "";
      return `scrolled dx=${action.dx || 0} dy=${action.dy || 0}${at}`;
    }
    case "drag":
      try {
        await runInput("xdotool", ["mousemove", String(action.x), String(action.y), "mousedown", "1"]);
        await runInput("xdotool", ["mousemove", String(action.x2), String(action.y2)]);
        return `dragged ${action.x},${action.y} to ${action.x2},${action.y2}`;
      } finally {
        // Release the button even when cancellation interrupted the drag.
        await run("xdotool", ["mouseup", "1"]).catch(() => {});
      }
    case "wait":
      await abortableDelay(action.ms, signal);
      return `waited ${action.ms}ms`;
    case "screenshot":
      return "captured";
    default:
      throw new Error("unreachable");
  }
}

// One display, one actor: serialize everything so two screenshots can never
// guide two competing users of the same pixels.
export function serialize() {
  let tail = Promise.resolve();
  return (fn) => {
    const run = tail.then(fn, fn);
    tail = run.catch(() => {});
    return run;
  };
}

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function buildHandler({ token, backend, control = {}, actionTimeoutMs = EXEC_TIMEOUT_MS }) {
  if (!token) throw new Error("PI_DESKTOP_TOKEN is required");
  const submit = serialize();
  let inputOwner = "agent";
  const status = () => ({
    input_owner: inputOwner,
    vnc: control.status ? control.status() : { state: "disabled", view_only: true },
  });
  const setInputOwner = async (owner, { capture = false } = {}) => submit(async () => {
    if (!CONTROL_OWNERS.has(owner)) throw new HttpError(400, "owner must be agent, operator or shared");
    if (capture && owner !== "agent") throw new HttpError(400, "capture is only valid when resuming agent control");
    if (owner === inputOwner && !capture) return status();
    const previousOwner = inputOwner;
    let viewChanged = false;
    try {
      // VNC is writable for everyone but the agent-only owner.
      if ((owner === "agent") !== (inputOwner === "agent") && control.setViewOnly) {
        await control.setViewOnly(owner === "agent");
        viewChanged = true;
      }
      const shot = capture ? await runCaptureWithTimeout(backend, EXEC_TIMEOUT_MS) : null;
      // Do not publish agent ownership until the VNC mode and requested
      // handoff screenshot have both completed.
      inputOwner = owner;
      return {
        ...status(),
        ...(shot ? { result: "captured", width: shot.width, height: shot.height, mime: shot.mime, image_b64: shot.png.toString("base64") } : {}),
      };
    } catch (err) {
      if (viewChanged && control.setViewOnly) {
        try {
          await control.setViewOnly(previousOwner === "agent");
        } catch {}
      }
      throw err;
    }
  });
  const authed = (req) => {
    const header = req.headers["authorization"] || "";
    const prefix = "Bearer ";
    if (!header.startsWith(prefix)) return false;
    const given = Buffer.from(header.slice(prefix.length));
    const want = Buffer.from(token);
    return given.length === want.length && timingSafeEqual(given, want);
  };
  const readBody = (req) =>
    new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      req.on("data", (c) => {
        size += c.length;
        if (size > MAX_BODY_BYTES) {
          reject(new Error("body too large"));
          req.destroy();
          return;
        }
        chunks.push(c);
      });
      req.on("end", () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
        } catch {
          reject(new Error("body must be JSON"));
        }
      });
      req.on("error", reject);
    });
  const send = (res, code, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(code, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
    res.end(body);
  };
  const failure = (err) => ({
    status: Number.isInteger(err?.status) ? err.status : 500,
    error: String(err?.message || err).slice(0, 500),
    ...(err?.outcomeUnknown ? { outcome_unknown: true } : {}),
  });
  return async (req, res) => {
    if (!authed(req)) {
      send(res, 401, { ok: false, error: "unauthorized" });
      return;
    }
    if (req.method === "GET" && req.url === "/health") {
      try {
        const geom = await withTimeout(backend.geometry(), 5000, "display check");
        send(res, 200, { ok: true, width: WIDTH, height: HEIGHT, display: geom, ...status() });
      } catch (err) {
        send(res, 503, { ok: false, error: String(err.message || err), ...status() });
      }
      return;
    }
    if (req.method === "GET" && req.url === "/control") {
      send(res, 200, { ok: true, ...status() });
      return;
    }
    if (req.method === "POST" && req.url === "/control") {
      let body;
      try {
        body = await readBody(req);
      } catch (err) {
        send(res, 400, { ok: false, error: String(err.message || err) });
        return;
      }
      if (
        body === null ||
        typeof body !== "object" ||
        Array.isArray(body) ||
        Object.keys(body).some((k) => k !== "owner" && k !== "capture") ||
        (body.capture !== undefined && typeof body.capture !== "boolean")
      ) {
        send(res, 400, { ok: false, error: "body must contain owner and optional boolean capture" });
        return;
      }
      try {
        send(res, 200, { ok: true, ...(await setInputOwner(body.owner, { capture: body.capture === true })) });
      } catch (err) {
        const out = failure(err);
        send(res, out.status, { ok: false, error: out.error, ...(out.outcome_unknown ? { outcome_unknown: true } : {}), ...status() });
      }
      return;
    }
    if (req.method === "POST" && req.url === "/action") {
      let body;
      try {
        body = await readBody(req);
      } catch (err) {
        send(res, 400, { ok: false, error: String(err.message || err) });
        return;
      }
      const v = validateAction(body);
      if (!v.ok) {
        send(res, 400, { ok: false, error: v.error });
        return;
      }
      try {
        const out = await submit(async () => {
          if (inputOwner === "operator" && MUTATING_ACTIONS.has(v.action.action)) {
            throw new HttpError(409, "operator owns input; resume agent control first");
          }
          const budget = v.action.action === "wait" ? v.action.ms + actionTimeoutMs : actionTimeoutMs;
          const summary = await runInputWithTimeout(backend, v.action, budget);
          let shot;
          try {
            shot = await runCaptureWithTimeout(backend, EXEC_TIMEOUT_MS);
          } catch (err) {
            if (MUTATING_ACTIONS.has(v.action.action)) {
              throw new ActionOutcomeUnknownError(v.action.action, `input completed but capture failed: ${String(err?.message || err).slice(0, 200)}`);
            }
            throw err;
          }
          return { summary, shot };
        });
        send(res, 200, {
          ok: true,
          result: out.summary,
          width: out.shot.width,
          height: out.shot.height,
          mime: out.shot.mime,
          image_b64: out.shot.png.toString("base64"),
          ...status(),
        });
      } catch (err) {
        const out = failure(err);
        send(res, out.status, { ok: false, error: out.error, ...(out.outcome_unknown ? { outcome_unknown: true } : {}), ...status() });
      }
      return;
    }
    send(res, 404, { ok: false, error: "not found" });
  };
}

// Supervisor: Xvfb, window manager, browser, and optional loopback-only VNC.
// A VNC failure is isolated: the HTTP control server and display stay alive.
export function vncArgs({ display = DISPLAY, port = VNC_PORT, viewOnly = true } = {}) {
  return [
    "-display", display,
    "-rfbport", String(port),
    "-localhost",
    "-nopw",
    "-forever",
    "-shared",
    ...(viewOnly ? ["-viewonly"] : []),
  ];
}

// Chromium's profile lives on the guest root disk, which survives sprite
// stop/start (RAM does not; /tmp is wiped at boot). This is Chromium's own
// default for HOME=/home/desktop, made explicit so existing profiles carry
// over and nothing depends on the entrypoint's HOME.
export const CHROMIUM_PROFILE_DIR = process.env.PI_DESKTOP_PROFILE_DIR || "/home/desktop/.config/chromium";

// True when pid is a live Chromium process. A bare liveness check is not
// enough: after a sprite stop/start pids restart low, so a stale lock's pid
// can name Xvfb or node in the new boot.
export function isChromiumPid(pid) {
  try {
    process.kill(pid, 0);
  } catch (err) {
    if (err?.code !== "EPERM") return false;
  }
  try {
    const argv0 = readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0")[0];
    return /chrom/i.test(argv0.split("/").pop() || "");
  } catch {
    return false;
  }
}

// Pid of the Chromium that holds dir's SingletonLock, or null when the lock
// is absent, malformed, from another host, or names a process that is not a
// live Chromium. The lock is a symlink whose target is "<hostname>-<pid>".
export function profileLockOwner(dir = CHROMIUM_PROFILE_DIR, { isChromiumPid: isChromium = isChromiumPid } = {}) {
  let target;
  try {
    target = readlinkSync(join(dir, "SingletonLock"));
  } catch {
    return null;
  }
  const m = /^(.*)-(\d+)$/.exec(target);
  if (!m || m[1] !== hostname()) return null;
  const pid = Number(m[2]);
  return pid > 0 && isChromium(pid) ? pid : null;
}

// Ready the persistent profile before Chromium starts. A sprite stop kills
// Chromium uncleanly, which leaves Singleton* locks (the next launch would
// think another browser owns the profile) and marks the profile crashed
// (a "Restore pages?" bubble the agent cannot reliably see or dismiss).
// Clear both, and set "continue where you left off". Returns restore=true
// when Chromium has run in this profile before, i.e. there is a previous
// session worth reopening; a brand-new desktop gets restore=false.
//
// The locks are cleared only when stale. sprite-entrypoint restarts
// server.js if node dies, and Chromium is not detached, so it can outlive
// node. If a live Chromium still holds the lock, touch nothing (its locks and
// Preferences are in use) and return running=true: the supervisor adopts it
// by not launching a second browser on the same profile.
export function prepareProfile(dir = CHROMIUM_PROFILE_DIR, { isChromiumPid: isChromium = isChromiumPid } = {}) {
  const prefsDir = join(dir, "Default");
  const prefsPath = join(prefsDir, "Preferences");
  mkdirSync(prefsDir, { recursive: true });
  if (profileLockOwner(dir, { isChromiumPid: isChromium }) !== null) {
    return { restore: existsSync(prefsPath), running: true };
  }
  for (const f of ["SingletonLock", "SingletonSocket", "SingletonCookie"]) {
    try {
      rmSync(join(dir, f), { force: true });
    } catch {}
  }
  const restore = existsSync(prefsPath);
  let prefs = {};
  if (restore) {
    try {
      const parsed = JSON.parse(readFileSync(prefsPath, "utf8"));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) prefs = parsed;
      else return { restore };
    } catch {
      // Unreadable prefs: leave Chromium's file alone (it recovers itself);
      // --hide-crash-restore-bubble still suppresses the bubble.
      return { restore };
    }
  }
  const obj = (v) => (v && typeof v === "object" && !Array.isArray(v) ? v : {});
  prefs.profile = { ...obj(prefs.profile), exit_type: "Normal", exited_cleanly: true };
  prefs.session = { ...obj(prefs.session), restore_on_startup: 1 };
  const tmp = `${prefsPath}.${process.pid}.tmp`;
  try {
    writeFileSync(tmp, JSON.stringify(prefs));
    renameSync(tmp, prefsPath);
  } catch {
    try {
      rmSync(tmp, { force: true });
    } catch {}
  }
  return { restore };
}

// Guest Chromium flags. --disable-gpu is load-bearing: the guest has no GPU
// (Alpine chromium on Xvfb, no mesa/SwiftShader), so any page touching
// WebGL/compositing makes Chromium spin the CPU in software fallback and
// the desktop looks frozen. Matches etc/sprites/an existing browser desktop/entrypoint.sh.
// --disable-gpu-shader-disk-cache is load-bearing too: Alpine 3.24's musl
// writes with pwritev2, which Chromium 152's GPU seccomp policy traps, so
// the shader cache write kills the GPU process and then the browser
// (aports MR !108402). Keeps every sandbox on; drop once that patch ships.
// A restarted desktop reopens its previous tabs; passing a URL there would
// add a stray tab, so only a brand-new profile starts on about:blank.
export function chromiumArgs({ profileDir = CHROMIUM_PROFILE_DIR, restore = false } = {}) {
  return [
    `--user-data-dir=${profileDir}`,
    "--window-size=1280,800",
    "--window-position=0,0",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-default-apps",
    "--disable-dev-shm-usage",
    "--disable-gpu",
    "--disable-gpu-shader-disk-cache",
    "--disk-cache-size=104857600",
    "--hide-crash-restore-bubble",
    ...(process.env.PI_DESKTOP_NO_SANDBOX === "1" ? ["--no-sandbox"] : []),
    ...(restore ? ["--restore-last-session"] : ["about:blank"]),
  ];
}

export function supervise({
  spawnFn = spawn,
  display = DISPLAY,
  width = WIDTH,
  height = HEIGHT,
  profileDir = CHROMIUM_PROFILE_DIR,
  prepareProfileFn = prepareProfile,
  waitForSocketFn = null,
  sleepFn = null,
} = {}) {
  const procs = [];
  const num = display.startsWith(":") ? display.slice(1) : "99";
  let vncProc = null;
  let vncViewOnly = true;
  let stopping = false;
  let restartTimer = null;
  const start = (cmd, args) => {
    const p = spawnFn(cmd, args, { stdio: "ignore" });
    procs.push({ cmd, proc: p });
    return p;
  };
  const logVnc = (message) => console.error(`pi-desktop VNC: ${message}`);
  const startVnc = () => {
    if (stopping || vncProc) return;
    let p;
    try {
      p = spawnFn("x11vnc", vncArgs({ display, port: VNC_PORT, viewOnly: vncViewOnly }), { stdio: "ignore" });
    } catch (err) {
      logVnc(`failed to start: ${String(err?.message || err)}`);
      scheduleVncRestart();
      return;
    }
    vncProc = p;
    const done = (reason) => {
      if (vncProc !== p) return;
      vncProc = null;
      logVnc(`${reason}; reconnecting`);
      scheduleVncRestart();
    };
    if (typeof p.once === "function") {
      let handled = false;
      const finish = (reason) => {
        if (handled) return;
        handled = true;
        done(reason);
      };
      p.once("exit", (code, signal) => finish(`exited (${code ?? "?"}/${signal ?? "none"})`));
      p.once("error", (err) => finish(`failed: ${String(err?.message || err)}`));
    }
  };
  const scheduleVncRestart = () => {
    if (stopping || restartTimer !== null) return;
    restartTimer = setTimeout(() => {
      restartTimer = null;
      startVnc();
    }, 1000);
  };
  const stopVnc = async () => {
    if (restartTimer !== null) {
      clearTimeout(restartTimer);
      restartTimer = null;
    }
    const p = vncProc;
    if (!p) return;
    // Null the reference only after verified termination: if the old x11vnc
    // cannot be reaped it may still hold :5900, and a replacement must not
    // spawn into a bind race. Callers (mode switch) throw before restarting.
    await terminateProcess(p, "VNC");
    if (vncProc === p) vncProc = null;
  };
  const waitForSocket = async () => {
    const sock = `/tmp/.X11-unix/X${num}`;
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      if (existsSync(sock)) return;
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error(`X socket ${sock} never appeared`);
  };
  const sleep = sleepFn || ((ms) => new Promise((r) => setTimeout(r, ms)));
  async function up() {
    start("Xvfb", [display, "-screen", "0", `${width}x${height}x24`, "-ac"]);
    await (waitForSocketFn || waitForSocket)();
    start("openbox", []);
    await sleep(500);
    let restore = false;
    let running = false;
    try {
      ({ restore, running = false } = prepareProfileFn(profileDir));
    } catch (err) {
      // Never block the desktop on profile housekeeping; start fresh instead.
      console.error(`pi-desktop profile: ${String(err?.message || err)}`);
    }
    if (running) {
      // A Chromium from before a server.js restart still owns the profile.
      // It is not our child, so down() cannot signal it; a sprite stop ends
      // it with the VM. Leave it be rather than open the profile twice.
      console.error("pi-desktop profile: chromium already running on this profile; not launching another");
    } else {
      start("chromium", chromiumArgs({ profileDir, restore }));
    }
    startVnc();
  }
  async function setVncViewOnly(viewOnly) {
    await stopVnc();
    vncViewOnly = Boolean(viewOnly);
    if (!stopping) startVnc();
  }
  async function down() {
    stopping = true;
    try {
      await stopVnc();
    } catch (err) {
      logVnc(`stop failed during shutdown: ${String(err?.message || err)}`);
    }
    for (const { proc } of [...procs].reverse()) {
      try {
        proc.kill("SIGTERM");
      } catch {}
    }
    await sleep(2000);
    for (const { proc } of procs) {
      try {
        if (proc.exitCode === null) proc.kill("SIGKILL");
      } catch {}
    }
    procs.length = 0;
  }
  function vncStatus() {
    return { state: vncProc ? "running" : "down", port: VNC_PORT, loopback: true, view_only: vncViewOnly };
  }
  return { up, down, setVncViewOnly, vncStatus };
}

async function main() {
  const token = process.env.PI_DESKTOP_TOKEN;
  if (!token) {
    console.error("PI_DESKTOP_TOKEN is required; refusing to start unauthenticated");
    process.exit(1);
  }
  const backend = realBackend();
  const supervisor = process.env.PI_DESKTOP_SUPERVISE === "0" ? null : supervise();
  const handler = buildHandler({
    token,
    backend,
    control: supervisor ? { status: supervisor.vncStatus, setViewOnly: supervisor.setVncViewOnly } : {},
  });
  const server = http.createServer(handler);
  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    server.close();
    if (supervisor) await supervisor.down().catch(() => {});
    process.exit(0);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  server.listen(PORT, HOST, () => {
    console.log(`pi-desktop listening on ${HOST}:${PORT} display ${DISPLAY} ${WIDTH}x${HEIGHT}`);
    if (supervisor) supervisor.up().catch((err) => console.error(`pi-desktop supervisor: ${err.message || err}`));
  });
}

const invoked = process.argv[1] ? import.meta.url === pathToFileURL(process.argv[1]).href : false;
if (invoked) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
