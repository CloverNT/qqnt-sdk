#!/usr/bin/env node
// Takes an explicit QQ download link per platform/arch (no derivation),
// HEAD-checks each, and reports whether the release can be skipped.
// Env: VERSION (required, auto-detected by the workflow), WIN_X64_URL,
// WIN_ARM64_URL, LINUX_X64_URL, LINUX_ARM64_URL (>=1 required), FORCE.
import { appendFileSync } from "node:fs";

const env = (k, d = "") => (process.env[k] ?? d).trim();
const VERSION = env("VERSION");
const WIN_X64_URL = env("WIN_X64_URL");
const WIN_ARM64_URL = env("WIN_ARM64_URL");
const LINUX_X64_URL = env("LINUX_X64_URL");
const LINUX_ARM64_URL = env("LINUX_ARM64_URL");
const FORCE = env("FORCE").toLowerCase() === "true";

function fail(msg) {
  console.error(`::error::resolve: ${msg}`);
  process.exit(1);
}
if (!VERSION) fail('VERSION is required, e.g. "9.9.31-49738".');
const entries = [
  ["win", "x64", WIN_X64_URL],
  ["win", "arm64", WIN_ARM64_URL],
  ["linux", "x64", LINUX_X64_URL],
  ["linux", "arm64", LINUX_ARM64_URL],
];
if (!entries.some(([, , u]) => u))
  fail("provide at least one of win_x64_url, win_arm64_url, linux_x64_url, linux_arm64_url.");

const isQQ = (u) => /^https:\/\/([a-z0-9.-]+\.)?(qq\.com|gtimg\.cn)\//i.test(u);
for (const [platform, arch, u] of entries)
  if (u && !isQQ(u)) console.error(`::warning::resolve: ${platform}_${arch}_url is not a qq.com/gtimg.cn link: ${u}`);

// 403/404/410 => pruned/typo (drop); else keep.
async function live(url) {
  try {
    const r = await fetch(url, {
      method: "HEAD", redirect: "follow",
      headers: { "User-Agent": "Mozilla/5.0 qq-lib-autogen" },
      signal: AbortSignal.timeout(30000),
    });
    return ![403, 404, 410].includes(r.status);
  } catch {
    return true;
  }
}

const winM = [];
const linM = [];
for (const [platform, arch, url] of entries) {
  if (!url) continue;
  const ok = await live(url);
  console.log(`::notice::resolve: ${ok ? "live" : "DEAD"} ${platform}-${arch} -> ${url}`);
  if (ok) (platform === "win" ? winM : linM).push({ arch, url });
  else console.error(`::warning::resolve: ${platform}_${arch}_url not live — skipping ${platform}-${arch}.`);
}
if (!winM.length && !linM.length) fail("none of the provided URLs are live on QQ's CDN — check the links.");

async function releaseAssets(tag) {
  const repo = process.env.GITHUB_REPOSITORY;
  if (!repo) return new Set();
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  try {
    const r = await fetch(`https://api.github.com/repos/${repo}/releases/tags/${tag}`, {
      headers: {
        "User-Agent": "qq-lib-autogen", Accept: "application/vnd.github+json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      signal: AbortSignal.timeout(30000),
    });
    if (!r.ok) return new Set();
    return new Set(((await r.json()).assets || []).map((a) => a.name));
  } catch { return new Set(); }
}

const out = {
  version: VERSION,
  tag: `qq-${VERSION}`,
  win_matrix: JSON.stringify(winM),
  linux_matrix: JSON.stringify(linM),
  force: String(FORCE),
};

const wantSlots = [...winM.map((e) => `windows-${e.arch}`), ...linM.map((e) => `linux-${e.arch}`)];
const present = await releaseAssets(out.tag);
const presentZips = [...present].filter((a) => a.endsWith(".zip"));
out.existing = presentZips.join(",");
out.skip = String(!FORCE && wantSlots.length > 0 && wantSlots.every((s) => presentZips.some((a) => a.endsWith(`-${s}.zip`))));

const gh = process.env.GITHUB_OUTPUT;
if (gh) appendFileSync(gh, Object.entries(out).map(([k, v]) => `${k}=${String(v).replace(/\r?\n/g, " ")}`).join("\n") + "\n");

console.log("=== resolve (manual) ===");
for (const [k, v] of Object.entries(out)) console.log(`${k}: ${v}`);
