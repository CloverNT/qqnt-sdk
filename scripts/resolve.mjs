#!/usr/bin/env node
// ---------------------------------------------------------------------------
// resolve.mjs - MANUAL mode.
//
// QQ's download config is geo-gated (it only serves the latest build to China
// IPs; overseas/CI runners get a stale snapshot whose files are already pruned),
// and the download URLs carry an unguessable per-build hash. So a US CI runner
// cannot auto-discover the latest. Instead the maintainer drives each build:
//
//   version : the QQ version this build is for (e.g. 9.9.31-49738). Used for the
//             release tag `qq-<version>` and what CMake consumers request.
//   win_url : an official QQ Windows installer link (any arch) — both x64 and
//             arm64 are derived from it by swapping the arch token.
//   linux_url: an official QQ Linux .deb link (any arch) — amd64 + arm64 derived.
//
// The links are copied straight from QQ's download page (https://im.qq.com), so
// this is still "direct from QQ" — no third-party version list. Each derived URL
// is HEAD-checked against QQ's CDN so a typo or a pruned link is caught early.
//
// Env: VERSION (required), WIN_URL and/or LINUX_URL (>=1), FORCE.
// ---------------------------------------------------------------------------

import { appendFileSync } from "node:fs";

const env = (k, d = "") => (process.env[k] ?? d).trim();
const VERSION = env("VERSION");
const WIN_URL = env("WIN_URL");
const LINUX_URL = env("LINUX_URL");
const FORCE = env("FORCE").toLowerCase() === "true";

function fail(msg) {
  console.error(`::error::resolve: ${msg}`);
  process.exit(1);
}
if (!VERSION) fail('VERSION is required, e.g. "9.9.31-49738".');
if (!WIN_URL && !LINUX_URL) fail("provide win_url and/or linux_url (an official QQ download link).");

// Arch token in the QQ filename, e.g. QQ_9.9.31_260528_x64_01.exe /
// QQ_3.2.29_260528_amd64_01.deb. Swapping it derives the sibling-arch URL.
const WIN_RE = /_(x64|x86|arm64)_01\.(exe)\b/i;
const LIN_RE = /_(amd64|arm64|x86_64|aarch64|loongarch64|mips64el)_01\.(deb|rpm|AppImage)\b/i;
const swap = (url, re, token) => url.replace(re, (_m, _a, ext) => `_${token}_01.${ext}`);

const isQQ = (u) => /^https:\/\/([a-z0-9.-]+\.)?(qq\.com|gtimg\.cn)\//i.test(u);
for (const [k, u] of [["win_url", WIN_URL], ["linux_url", LINUX_URL]])
  if (u && !isQQ(u)) console.error(`::warning::resolve: ${k} is not a qq.com/gtimg.cn link: ${u}`);

// Candidate (folder-arch-token -> download URL) pairs derived from each input.
const winCand = [];
if (WIN_URL) {
  if (WIN_RE.test(WIN_URL)) { winCand.push(["x64", swap(WIN_URL, WIN_RE, "x64")], ["arm64", swap(WIN_URL, WIN_RE, "arm64")]); }
  else winCand.push(["x64", WIN_URL]); // unknown arch token: take as-is (x64)
}
const linCand = [];
if (LINUX_URL) {
  if (LIN_RE.test(LINUX_URL)) { linCand.push(["x64", swap(LINUX_URL, LIN_RE, "amd64")], ["arm64", swap(LINUX_URL, LIN_RE, "arm64")]); }
  else linCand.push(["x64", LINUX_URL]);
}

// HEAD each URL against QQ's CDN. 403/404/410 => pruned/typo (drop); else keep.
async function live(url) {
  try {
    const r = await fetch(url, {
      method: "HEAD", redirect: "follow",
      headers: { "User-Agent": "Mozilla/5.0 qq-lib-autogen" },
      signal: AbortSignal.timeout(30000),
    });
    return ![403, 404, 410].includes(r.status);
  } catch {
    return true; // transient: don't drop; the build job's download will settle it
  }
}
async function validate(cands, label) {
  const keep = [];
  for (const [arch, url] of cands) {
    const ok = await live(url);
    console.log(`::notice::resolve: ${ok ? "live" : "DEAD"} ${label}-${arch} -> ${url}`);
    if (ok) keep.push({ arch, url });
  }
  return keep;
}

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

// --- resolve ---------------------------------------------------------------

const winM = await validate(winCand, "win");
const linM = await validate(linCand, "linux");
if (!winM.length && !linM.length) fail("none of the provided URLs are live on QQ's CDN — check the links.");
if (WIN_URL && !winM.length) console.error("::warning::resolve: win_url not live — skipping Windows.");
if (LINUX_URL && !linM.length) console.error("::warning::resolve: linux_url not live — skipping Linux.");

const out = {
  version: VERSION,
  tag: `qq-${VERSION}`,
  win_matrix: JSON.stringify(winM),
  linux_matrix: JSON.stringify(linM),
  force: String(FORCE),
};

// Skip when the release already has a .zip for every requested arch slot.
const wantSlots = [...winM.map((e) => `windows-${e.arch}`), ...linM.map((e) => `linux-${e.arch}`)];
const present = await releaseAssets(out.tag);
const presentZips = [...present].filter((a) => a.endsWith(".zip"));
out.existing = presentZips.join(",");
out.skip = String(!FORCE && wantSlots.length > 0 && wantSlots.every((s) => presentZips.some((a) => a.endsWith(`-${s}.zip`))));

const gh = process.env.GITHUB_OUTPUT;
if (gh) appendFileSync(gh, Object.entries(out).map(([k, v]) => `${k}=${String(v).replace(/\r?\n/g, " ")}`).join("\n") + "\n");

console.log("=== resolve (manual) ===");
for (const [k, v] of Object.entries(out)) console.log(`${k}: ${v}`);
