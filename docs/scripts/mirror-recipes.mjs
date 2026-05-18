#!/usr/bin/env node
/**
 * Mirror recipes from the fixtures package into the docs site so Starlight
 * renders them as in-site pages.
 *
 * Why: recipes are authored once in `foundry-agent-fixtures/.apm/skills/...`
 * (single source of truth). The docs site renders them at /recipes/<slug>/.
 * Running this script before `astro build` keeps the mirror fresh.
 *
 * What it does:
 *  - Reads recipes from: ../foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/
 *  - Writes them to:     ./src/content/docs/recipes/
 *  - Preserves filenames (01-greenfield-quickstart.md → 01-greenfield-quickstart.md).
 *  - The recipes/README.md becomes recipes/index.md.
 *  - Adds Starlight-required frontmatter (`title`, `description`) by reading
 *    the source frontmatter or extracting the first H1.
 *  - Rewrites a few relative paths that don't resolve in the docs site:
 *      ../../../../foundry-agent-skillpack/.apm/skills/foundry-<X>/...
 *        → https://github.com/.../blob/main/foundry-agent-skillpack/.apm/skills/foundry-<X>/...
 *
 * Idempotent — re-runs overwrite the target directory.
 */

import { readdir, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');
const SRC_DIR = join(
  REPO_ROOT,
  'foundry-agent-fixtures',
  '.apm',
  'skills',
  'foundry-agent-fixtures',
  'recipes'
);
const DST_DIR = join(__dirname, '..', 'src', 'content', 'docs', 'recipes');
const GITHUB_BASE =
  'https://github.com/sathik11/foundry-agent-skillpack/blob/main';

if (!existsSync(SRC_DIR)) {
  console.error(`[mirror-recipes] source directory not found: ${SRC_DIR}`);
  process.exit(1);
}

// Wipe + recreate destination so deletions in source propagate.
if (existsSync(DST_DIR)) {
  await rm(DST_DIR, { recursive: true, force: true });
}
await mkdir(DST_DIR, { recursive: true });

const files = (await readdir(SRC_DIR)).filter((f) => f.endsWith('.md'));

let mirrored = 0;
for (const file of files) {
  const srcPath = join(SRC_DIR, file);
  const dstName = file === 'README.md' ? 'index.md' : file;
  const dstPath = join(DST_DIR, dstName);

  let content = await readFile(srcPath, 'utf8');

  // 1. Ensure Starlight frontmatter. Starlight's default docsSchema rejects
  //    unknown keys (validity_date, audience, surfaces, prerequisites, etc.),
  //    so we STRIP the source frontmatter and rebuild a clean Starlight one:
  //    `title` from the first H1 (or filename), and `description` from any
  //    `description:` line we find. Anything else from source frontmatter
  //    we capture into the body as a callout (so the recipe's metadata
  //    stays visible to humans).
  const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---\n/);
  const firstH1 = content.match(/^#\s+(.+)$/m);
  const title = firstH1 ? firstH1[1].trim() : basename(file, '.md');

  let sourceFm = {};
  let body = content;
  if (frontmatterMatch) {
    body = content.slice(frontmatterMatch[0].length);
    // Tiny parser — just key:value lines + bullet lists; we render them, not parse them strictly.
    const fmLines = frontmatterMatch[1].split('\n');
    let currentKey = null;
    for (const line of fmLines) {
      const kv = line.match(/^([a-z_]+):\s*(.*)$/);
      if (kv) {
        currentKey = kv[1];
        sourceFm[currentKey] = kv[2].trim();
      } else if (currentKey && /^\s+-\s/.test(line)) {
        sourceFm[currentKey] = (sourceFm[currentKey] || '') + (sourceFm[currentKey] ? ', ' : '') + line.replace(/^\s+-\s/, '');
      }
    }
  }

  // Build clean Starlight frontmatter — only title + optional description.
  const description = sourceFm.description || '';
  const cleanFm =
    `---\n` +
    `title: ${JSON.stringify(title)}\n` +
    (description ? `description: ${JSON.stringify(description)}\n` : '') +
    `---\n`;

  // Render source frontmatter (validity_date, audience, etc.) as a small
  // metadata block at the top of the body so humans still see it on the page.
  const meta = [];
  if (sourceFm.validity_date) meta.push(`**Validity:** ${sourceFm.validity_date}`);
  if (sourceFm.audience)      meta.push(`**Audience:** ${sourceFm.audience}`);
  if (sourceFm.duration)      meta.push(`**Duration:** ${sourceFm.duration}`);
  if (sourceFm.surfaces)      meta.push(`**Surfaces:** ${sourceFm.surfaces}`);
  if (sourceFm.prerequisites) meta.push(`**Prerequisites:** ${sourceFm.prerequisites}`);

  const metaBlock = meta.length
    ? `\n> ${meta.join('  \n> ')}\n\n`
    : '\n';

  content = cleanFm + metaBlock + body;

  // 2. Rewrite the repeated `../../../../foundry-agent-skillpack/...` style
  //    relative paths to absolute GitHub URLs. The recipes were authored
  //    relative to the fixtures package directory tree; in the docs site
  //    those relative paths don't resolve.
  content = content.replace(
    /\(\.\.\/\.\.\/\.\.\/\.\.\/foundry-agent-skillpack\//g,
    `(${GITHUB_BASE}/foundry-agent-skillpack/`
  );
  content = content.replace(
    /\(\.\.\/\.\.\/\.\.\/\.\.\/\.\.\/foundry-agent-skillpack\//g,
    `(${GITHUB_BASE}/foundry-agent-skillpack/`
  );

  // 3. Recipes link to each other by raw filename (e.g. `02-brownfield-onboarding.md`)
  //    inside the fixtures package. In the docs site, sibling pages live at
  //    /recipes/02-brownfield-onboarding/. Rewrite those inter-recipe links.
  content = content.replace(
    /\(([0-9]{2}-[a-z-]+)\.md(\#[^)]*)?\)/g,
    (_, slug, anchor) => `(/recipes/${slug}/${anchor ?? ''})`
  );

  await writeFile(dstPath, content, 'utf8');
  mirrored += 1;
}

console.log(`[mirror-recipes] mirrored ${mirrored} files → ${DST_DIR}`);
