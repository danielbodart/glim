#!/usr/bin/env -S mise exec -- bun
import { $ } from "bun";
import { existsSync } from "fs";

process.env.FORCE_COLOR = "1";

const TARBALL = "glim-linux-x86_64.tar.gz";
const STAGING = "dist/staging";

// ─── Version ────────────────────────────────────────────────────────────────

/** 0.<commits>.<build>: the build number on CI, a timestamp anywhere else. */
async function version(): Promise<string> {
    const branch = process.env.GITHUB_REF_NAME
        || (await $`git rev-parse --abbrev-ref HEAD`.quiet().nothrow()).text().trim();
    const buildNumber = process.env.GITHUB_RUN_NUMBER
        || new Date().toISOString().replace(/[-:T]/g, "").split(".")[0];
    const revisions = (await $`git rev-list --count ${branch}`.quiet().nothrow()).text().trim() || "0";
    return `0.${revisions}.${buildNumber}`;
}

// ─── Commands ──────────────────────────────────────────────────────────────

/** Static, for any x86_64 Linux: baseline CPU, no libc. */
export async function build() {
    const ver = await version();
    console.log(`Building v${ver}...`);
    await $`zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux -Dcpu=baseline -Dversion=${ver}`;
}

/** Under a private bus when dbus-run-session is there, for the D-Bus
 *  client's test: it is handed that bus's address and never sees the session
 *  this was run from. Without one, that test is skipped. */
export async function test() {
    const { exitCode } = await $`which dbus-run-session`.quiet().nothrow();
    if (exitCode === 0) {
        await $`dbus-run-session -- sh -c 'GLIM_TEST_BUS="$DBUS_SESSION_BUS_ADDRESS" exec zig build test --summary all'`;
    } else {
        await $`zig build test --summary all`;
    }
}

export async function lint() {
    await $`shellcheck dist/install.sh`;
}

export async function clean() {
    await $`rm -rf zig-out .zig-cache ${STAGING} ${TARBALL} ${TARBALL}.sha256`;
    console.log("Cleaned.");
}

/** Default: what a change has to get through before it is pushed. */
export async function dev() {
    await lint();
    await test();
    await build();
}

/** The release tarball: the binary and everything install.sh puts in place. */
export async function dist() {
    if (!existsSync("zig-out/bin/glim")) await build();
    await $`rm -rf ${STAGING} && mkdir -p ${STAGING}`;
    await $`cp zig-out/bin/glim dist/install.sh dist/glim.service dist/glim-follow.service dist/glim.conf ${STAGING}/`;
    await $`tar -czf ${TARBALL} -C ${STAGING} .`;
    await $`sha256sum ${TARBALL} > ${TARBALL}.sha256`;
    console.log(`Tarball: ${TARBALL} (v${await version()})`);
}

export async function ci() {
    await lint();
    await test();
    await build();
    await dist();
    if (process.env.GH_TOKEN) {
        const ver = await version();
        const notes = (await $`git log -1 --format=%B`.quiet()).text().trim();
        console.log(`Creating release v${ver}...`);
        await $`gh release create v${ver} ${TARBALL} ${TARBALL}.sha256 dist/install.sh --title v${ver} --notes ${notes}`;
    }
}

/** The flake: the package builds from source and its tests pass, and the
 *  NixOS module wires glim up (checked in a NixOS VM). */
export async function nix() {
    const { exitCode } = await $`which nix`.quiet().nothrow();
    if (exitCode !== 0) {
        console.log("nix: skipped (nix not installed)");
        return;
    }
    await $`nix flake check --print-build-logs`;
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function printVersion() {
    console.log(await version());
}

const commands: Record<string, Function> = {
    dev, build, test, lint, clean, dist, ci, nix, version: printVersion,
};

const command = process.argv[2] || "dev";
const fn = commands[command];
if (!fn) {
    console.error(`Unknown command: ${command}`);
    console.error(`Available: ${Object.keys(commands).join(", ")}`);
    process.exit(1);
}
try {
    await fn(...process.argv.slice(3));
} catch (e: any) {
    console.error(`Command failed: ${command}`);
    console.error(e.message || e);
    process.exit(1);
}
