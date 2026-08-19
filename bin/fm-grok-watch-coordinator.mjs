#!/usr/bin/env node

// Grok monitor-owned watcher coordinator.
//
// Run this exact executable through Grok's persistent `monitor` tool.
// It owns one fm-watch-arm.sh child at a time, buffers an actionable close,
// verifies a singleton successor, then emits exactly one JSON wake line for
// Grok. The monitor stays live across watcher cycles, so the model never has to
// remember a routine re-arm step and no shell fire-and-forget process is used.

import { spawn, spawnSync } from "node:child_process";
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(process.env.FM_ROOT_OVERRIDE || resolve(scriptDir, ".."));
const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${home}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${home}/config`;
const armScript = `${root}/bin/fm-watch-arm.sh`;
const wakeLib = `${root}/bin/fm-wake-lib.sh`;
const ownerRecord = `${state}/.grok-watch-coordinator`;
const ownerLock = `${state}/.grok-watch-coordinator.lock`;

function positiveInteger(name, fallback) {
  const value = Number.parseInt(process.env[name] || "", 10);
  return Number.isInteger(value) && value > 0 ? value : fallback;
}

const readinessTimeoutMs = positiveInteger(
  "FM_WATCH_ARM_READY_TIMEOUT_MS",
  positiveInteger("FM_ARM_CONFIRM_TIMEOUT", process.platform === "win32" ? 30 : 10) * 1000 + 1000,
);
const retireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 2000);
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);

mkdirSync(state, { recursive: true });

function runBash(script, args = []) {
  return spawnSync("bash", ["-c", script, "_", ...args], {
    cwd: root,
    env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: root },
    encoding: "utf8",
  });
}

function pidIdentity(pid) {
  const result = runBash('. "$1"; fm_pid_identity "$2"', [wakeLib, String(pid)]);
  return result.status === 0 ? result.stdout.trim() : "";
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function readRecord(path) {
  try {
    return Object.fromEntries(
      readFileSync(path, "utf8")
        .split(/\r?\n/)
        .filter((line) => line.includes("="))
        .map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]),
    );
  } catch {
    return {};
  }
}

function recordIsLive(record) {
  const pid = Number.parseInt(record.pid || "", 10);
  return record.home === home && pidAlive(pid) && record.identity && pidIdentity(pid) === record.identity;
}

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

async function acquireOwnerLock() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      mkdirSync(ownerLock, { mode: 0o700 });
      writeFileSync(`${ownerLock}/pid`, `${process.pid}\n`, { mode: 0o600 });
      writeFileSync(`${ownerLock}/identity`, `${pidIdentity(process.pid)}\n`, { mode: 0o600 });
      return;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
    let lock = {};
    try {
      lock = {
        pid: readFileSync(`${ownerLock}/pid`, "utf8").trim(),
        identity: readFileSync(`${ownerLock}/identity`, "utf8").trim(),
        home,
      };
    } catch {
      // The winning coordinator may still be publishing the short lock record.
    }
    let stale = !recordIsLive(lock);
    try {
      stale = stale && Date.now() - statSync(ownerLock).mtimeMs >= 2000;
    } catch {
      stale = false;
    }
    if (stale) {
      const quarantine = `${ownerLock}.stale.${process.pid}.${Date.now()}`;
      try {
        renameSync(ownerLock, quarantine);
        rmSync(quarantine, { recursive: true, force: true });
      } catch {
        // A competing coordinator resolved it first.
      }
    }
    await sleep(20);
  }
  throw new Error("coordinator owner state could not be serialized");
}

function releaseOwnerLock() {
  rmSync(ownerLock, { recursive: true, force: true });
}

async function claimCoordinator() {
  await acquireOwnerLock();
  try {
    const existing = readRecord(ownerRecord);
    if (recordIsLive(existing)) return { claimed: false, pid: Number(existing.pid) };
    const identity = pidIdentity(process.pid);
    if (!identity) throw new Error("coordinator process identity could not be established");
    const temporary = `${ownerRecord}.tmp.${process.pid}`;
    const fd = openSync(temporary, "w", 0o600);
    writeFileSync(fd, `pid=${process.pid}\nidentity=${identity}\nhome=${home}\n`);
    closeSync(fd);
    renameSync(temporary, ownerRecord);
    return { claimed: true, pid: process.pid };
  } finally {
    releaseOwnerLock();
  }
}

async function releaseCoordinator() {
  let locked = false;
  try {
    await acquireOwnerLock();
    locked = true;
    const current = readRecord(ownerRecord);
    if (Number(current.pid) === process.pid && current.identity === pidIdentity(process.pid) && current.home === home) {
      rmSync(ownerRecord, { force: true });
    }
  } finally {
    if (locked) releaseOwnerLock();
  }
}

async function sessionOwnsLock() {
  let lockPid;
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return false;
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
  let pid = String(process.pid);
  for (let depth = 0; depth < 12; depth += 1) {
    if (pid === lockPid) return true;
    const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
    if (result.status !== 0) return false;
    pid = result.stdout.trim();
    if (!pid || pid === "1") return false;
  }
  return false;
}

function shouldArm() {
  if (existsSync(`${state}/.afk`)) return false;
  if (existsSync(`${config}/x-mode.env`)) return true;
  try {
    return runBash('find "$1" -maxdepth 1 -type f -name "*.meta" -print -quit | grep -q .', [state]).status === 0;
  } catch {
    return false;
  }
}

function recoveryGeneration() {
  const result = runBash(
    '. "$1"; fm_recovery_marker_snapshot "$2" || exit 1; case "$FM_RECOVERY_MARKER_TOKEN" in pending:downtime:*|pending:handling:*) printf "%s" "${FM_RECOVERY_MARKER_TOKEN##*:}" ;; *) exit 1 ;; esac',
    [wakeLib, `${state}/.watcher-down`],
  );
  return result.status === 0 ? result.stdout.trim() : "";
}

function classifyClose(stdout, stderr, code, signal) {
  const lines = `${stdout}\n${stderr}`.split(/\r?\n/);
  const reason = lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line));
  if (reason) return { kind: "actionable", message: reason };
  const failed = lines.find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) return { kind: "failure", message: `watcher: FAILED - Grok coordinator arm ended from ${signal}` };
  if (code && code !== 0) return { kind: "failure", message: `watcher: FAILED - fm-watch-arm.sh exited ${code}` };
  return { kind: "failure", message: "watcher: FAILED - Grok coordinator arm ended without an actionable reason" };
}

function spawnArm(predecessorArmPid = "", restart = false) {
  const env = {
    ...process.env,
    FM_HOME: home,
    FM_STATE_OVERRIDE: state,
    FM_ROOT_OVERRIDE: root,
    FM_CONFIG_OVERRIDE: config,
    FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    FM_WATCH_HANDLING_OWNER_RECORD: ownerRecord,
  };
  const command = 'config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec "$FM_ROOT_OVERRIDE/bin/fm-watch-arm.sh" "$@"';
  const args = ["-lc", command, "fm-grok-watch-coordinator"];
  if (restart) args.push("--restart");
  const child = spawn("bash", args, { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  let ready = null;
  let settleReady;
  const readiness = new Promise((resolveReady) => {
    settleReady = (value) => {
      if (ready !== null) return;
      ready = value;
      resolveReady(value);
    };
  });
  let settleClosed;
  const closed = new Promise((resolveClosed) => {
    settleClosed = resolveClosed;
  });
  const observe = () => {
    const combined = `${stdout}\n${stderr}`;
    const match = combined.match(/^watcher: (started|attached) pid=([0-9]+).*$/m);
    if (match) {
      const generationMatch = combined.match(/ recovery-generation=([A-Za-z0-9._-]+)$/m);
      settleReady({ status: "ready", arm: child, watcherPid: match[2], generation: generationMatch?.[1] || "" });
      return;
    }
    if (/^(signal:|stale:|check:|heartbeat($|:))/m.test(combined)) settleReady({ status: "wake", arm: child });
    if (/^watcher: FAILED/m.test(combined)) settleReady({ status: "failed", arm: child });
    if (/^watcher: owner verified .*\(duplicate returned\)/m.test(combined)) settleReady({ status: "duplicate", arm: child });
  };
  child.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    observe();
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
    observe();
  });
  child.on("error", (error) => {
    stderr += `\n${error.message}`;
    settleReady({ status: "failed", arm: child });
    settleClosed({ stdout, stderr, code: 1, signal: null });
  });
  child.on("close", (code, signal) => {
    settleReady({ status: "closed", arm: child });
    settleClosed({ stdout, stderr, code, signal });
  });
  return { child, readiness, closed };
}

async function waitForReadiness(arm) {
  return Promise.race([
    arm.readiness,
    sleep(readinessTimeoutMs).then(() => ({ status: "timeout", arm: arm.child })),
  ]);
}

async function retireArm(arm) {
  if (!arm || !pidAlive(arm.child.pid)) return true;
  arm.child.kill("SIGTERM");
  arm.child.kill("SIGCONT");
  const result = await Promise.race([arm.closed.then(() => true), sleep(retireTimeoutMs).then(() => false)]);
  return result;
}

function retryDelay(attempt) {
  return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
}

async function restoreAfterClose(predecessorArmPid) {
  let failure = "";
  for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
    if (!(await sessionOwnsLock())) {
      return { arm: null, failure: "watcher: FAILED - Grok coordinator cannot restore continuity because this session no longer owns the lock" };
    }
    const arm = spawnArm(String(predecessorArmPid), true);
    const readiness = await waitForReadiness(arm);
    if (readiness.status === "ready") {
      const generation = readiness.generation || recoveryGeneration();
      if (generation) return { arm, readiness: { ...readiness, generation }, failure: "" };
      failure = "watcher: FAILED - Grok coordinator could not bind the ready successor to a recovery generation";
    } else {
      failure = `watcher: FAILED - Grok coordinator could not verify a ready successor watcher (${readiness.status})`;
    }
    if (!(await retireArm(arm))) {
      return {
        arm,
        readiness: null,
        failure: `${failure}; unready successor arm did not exit within ${retireTimeoutMs}ms; no overlapping retry was started`,
      };
    }
    if (attempt === retryLimit) break;
    await sleep(retryDelay(attempt + 1));
  }
  return { arm: null, readiness: null, failure: `${failure}; continuity restoration exhausted ${retryLimit} retries` };
}

function emit(prefix, payload) {
  process.stdout.write(`${prefix} ${JSON.stringify(payload)}\n`);
}

let currentArm = null;
let shuttingDown = false;

async function stopCurrentArm() {
  if (!currentArm) return;
  let watcherPid = 0;
  try {
    watcherPid = Number.parseInt(readFileSync(`${state}/.watch.lock/pid`, "utf8").trim(), 10);
  } catch {
    watcherPid = 0;
  }
  if (pidAlive(watcherPid)) {
    try { process.kill(watcherPid, "SIGTERM"); } catch {}
    try { process.kill(watcherPid, "SIGCONT"); } catch {}
  }
  if (pidAlive(currentArm.child.pid)) {
    currentArm.child.kill("SIGTERM");
    currentArm.child.kill("SIGCONT");
    if (!(await Promise.race([currentArm.closed.then(() => true), sleep(retireTimeoutMs).then(() => false)]))) {
      currentArm.child.kill("SIGKILL");
    }
  }
}

async function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  try { await stopCurrentArm(); } catch {}
  try { await releaseCoordinator(); } catch {}
  process.exit(code);
}

process.on("SIGTERM", () => { void shutdown(143); });
process.on("SIGINT", () => { void shutdown(130); });
process.on("SIGHUP", () => { void shutdown(129); });

async function main() {
  const claim = await claimCoordinator();
  if (!claim.claimed) {
    emit("FIRSTMATE_GROK_COORDINATOR_DUPLICATE", { owner_pid: claim.pid });
    return;
  }
  if (!(await sessionOwnsLock())) throw new Error("current Grok session does not own the Firstmate session lock");
  if (!shouldArm()) throw new Error("this home does not currently need watcher supervision");

  currentArm = spawnArm();
  const initial = await waitForReadiness(currentArm);
  if (initial.status !== "ready") throw new Error(`initial watcher did not become ready (${initial.status})`);
  emit("FIRSTMATE_GROK_WATCH_READY", {
    coordinator_pid: process.pid,
    arm_pid: currentArm.child.pid,
    watcher_pid: Number(initial.watcherPid),
  });

  while (!shuttingDown && currentArm) {
    const closed = await currentArm.closed;
    const classification = classifyClose(closed.stdout, closed.stderr, closed.code, closed.signal);
    const predecessorArmPid = currentArm.child.pid;
    const restoration = await restoreAfterClose(predecessorArmPid);
    currentArm = restoration.arm;
    if (classification.kind === "actionable") {
      emit("FIRSTMATE_GROK_WAKE", {
        reason: classification.message,
        successor_arm_pid: restoration.arm?.child.pid || null,
        successor_watcher_pid: restoration.readiness ? Number(restoration.readiness.watcherPid) : null,
        recovery_generation: restoration.readiness?.generation || null,
        continuity_failure: restoration.failure || null,
      });
    } else if (restoration.failure) {
      emit("FIRSTMATE_GROK_FAILURE", {
        reason: classification.message,
        continuity_failure: restoration.failure,
      });
    }
    if (!currentArm) break;
  }
}

let exitCode = 0;
try {
  await main();
} catch (error) {
  exitCode = 1;
  emit("FIRSTMATE_GROK_FAILURE", { reason: `watcher: FAILED - ${error.message}` });
}
await shutdown(exitCode);
