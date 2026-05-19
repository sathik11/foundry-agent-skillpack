#!/usr/bin/env node
/**
 * Drift check between the skillpack sources and the docs site.
 *
 * Why this exists: the docs site is a CURATED SUBSET of the skillpack content,
 * not a mirror. Skills, prompts, and TECHNICAL_DEBT entries are paraphrased
 * into the docs site by hand. This script catches the most common drift case:
 *
 *   "A skill / prompt / TD entry exists in the skillpack but isn't named in the
 *    matching docs page."
 *
 *   ...and the reverse:
 *
 *   "The docs page names something that doesn't exist in the skillpack anymore."
 *
 * Strategy: set-difference, not content-equality. We don't try to detect when
 * a skill's body has changed — that's noisy. We detect new/renamed/removed
 * artifacts. This is the highest-value, lowest-false-positive check.
 *
 * Output: markdown report on stdout. ALWAYS exits 0 (non-blocking — surfaces
 * drift to humans via PR summary; never fails the build).
 *
 * Usage:
 *   node docs/scripts/check-drift.mjs                # report to stdout
 *   node docs/scripts/check-drift.mjs > drift.md     # capture
 *
 * In CI: redirect to $GITHUB_STEP_SUMMARY so it renders on the workflow page.
 *
 * Tracked: TD-17 Phase 1.
 */

import { readdir, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');

const SKILLPACK = join(REPO_ROOT, 'foundry-agent-skillpack');
const DOCS_DIR = join(REPO_ROOT, 'docs', 'src', 'content', 'docs');

// ── Helpers ─────────────────────────────────────────────────────────────

async function listSkills() {
  const skillsDir = join(SKILLPACK, '.apm', 'skills');
  if (!existsSync(skillsDir)) return [];
  const entries = await readdir(skillsDir, { withFileTypes: true });
  return entries
    .filter((e) => e.isDirectory() && existsSync(join(skillsDir, e.name, 'SKILL.md')))
    .map((e) => e.name)
    .sort();
}

async function listPrompts() {
  const promptsDir = join(SKILLPACK, '.apm', 'prompts');
  if (!existsSync(promptsDir)) return [];
  const entries = await readdir(promptsDir);
  return entries
    .filter((f) => f.endsWith('.prompt.md'))
    .map((f) => basename(f, '.prompt.md'))
    .sort();
}

async function listTdEntries() {
  const file = join(SKILLPACK, 'TECHNICAL_DEBT.md');
  if (!existsSync(file)) return [];
  const content = await readFile(file, 'utf8');
  // Match both open and closed entries:
  //   open:   "## TD-N — <title>"
  //   closed: "## ~~TD-N — <title>~~ **(CLOSED in vX.Y.Z)**"
  // The optional `~~` prefix lets the regex catch strike-through (closed) headings.
  return [...content.matchAll(/^##\s+(?:~~)?(TD-\d+)\b/gm)]
    .map((m) => m[1])
    .sort((a, b) => parseInt(a.split('-')[1], 10) - parseInt(b.split('-')[1], 10));
}

function mentioned(content, needle) {
  // Case-sensitive substring match. We avoid regex on raw names because
  // skill / prompt names contain hyphens and would need escaping; substring
  // is robust enough for our table-row mention check.
  return content.includes(needle);
}

function setDiff(sourceItems, docsContent) {
  const inSourceNotDocs = sourceItems.filter((s) => !mentioned(docsContent, s));
  return { inSourceNotDocs };
}

function reverseSetDiff(docsContent, sourceItems, namePattern) {
  // Find names mentioned in the docs page that LOOK like skill/prompt names
  // but aren't in the source set. Heuristic — namePattern is a regex of what
  // a mention looks like (e.g. /\bfoundry-[a-z-]+\b/g).
  const mentions = new Set([...docsContent.matchAll(namePattern)].map((m) => m[0]));
  // Filter out known false positives:
  // - the source items themselves (those are valid)
  // - skill names that include sub-doc fragments (foundry-deploy/scaffold.md)
  // We just check "is this mention not in our source set?" — if a name is
  // in the docs and not on disk, report it.
  const sourceSet = new Set(sourceItems);
  return [...mentions].filter((m) => !sourceSet.has(m));
}

// ── Checks ──────────────────────────────────────────────────────────────

async function checkSkills() {
  const sourceItems = await listSkills();
  const docsPage = join(DOCS_DIR, 'skills.md');
  if (!existsSync(docsPage)) {
    return { name: 'Skills', error: `Missing docs page: ${docsPage}` };
  }
  const docsContent = await readFile(docsPage, 'utf8');
  const { inSourceNotDocs } = setDiff(sourceItems, docsContent);
  const reverseDrift = reverseSetDiff(
    docsContent,
    sourceItems,
    /\bfoundry-[a-z][a-z-]*[a-z]\b/g,
  );
  return {
    name: 'Skills',
    sourceCount: sourceItems.length,
    docsPage,
    inSourceNotDocs,
    reverseDrift: reverseDrift.filter(
      (m) =>
        // Allow common false positives: cross-references to sub-doc / script paths.
        // The reverse-drift heuristic matches any `foundry-*` name; many sub-docs
        // and knowledge-source kinds use that prefix (e.g. `foundry-iq`,
        // `foundry-deploy/scaffold.md`). We allowlist non-skill `foundry-*` names
        // here. When a real skill is removed, the test will still fire.
        m !== 'foundry-agent-engineering' && // historical name
        m !== 'foundry-agent-skillpack' && // the package itself
        m !== 'foundry-agent-playbook' && // sibling package
        m !== 'foundry-iq' && // knowledge source kind, lives under foundry-knowledge/
        m !== 'foundry-engineer', // agent persona file (foundry-engineer.agent.md)
    ),
  };
}

async function checkPrompts() {
  const sourceItems = await listPrompts();
  const docsPage = join(DOCS_DIR, 'reference', 'prompts.md');
  if (!existsSync(docsPage)) {
    return { name: 'Prompts', error: `Missing docs page: ${docsPage}` };
  }
  const docsContent = await readFile(docsPage, 'utf8');
  // Mention format on the docs page: /<prompt-name> (with leading slash)
  const inSourceNotDocs = sourceItems.filter((s) => !mentioned(docsContent, `/${s}`));
  return {
    name: 'Prompts',
    sourceCount: sourceItems.length,
    docsPage,
    inSourceNotDocs,
  };
}

async function checkTdEntries() {
  const sourceItems = await listTdEntries();
  const docsPage = join(DOCS_DIR, 'technical-debt.md');
  if (!existsSync(docsPage)) {
    return { name: 'TD entries', error: `Missing docs page: ${docsPage}` };
  }
  const docsContent = await readFile(docsPage, 'utf8');
  const inSourceNotDocs = sourceItems.filter((s) => !mentioned(docsContent, s));
  // Reverse: TD-N mentioned in docs but not in source
  const docsMentions = new Set(
    [...docsContent.matchAll(/\bTD-(\d+)\b/g)].map((m) => `TD-${m[1]}`),
  );
  const sourceSet = new Set(sourceItems);
  const reverseDrift = [...docsMentions].filter((m) => !sourceSet.has(m));
  return {
    name: 'TD entries',
    sourceCount: sourceItems.length,
    docsPage,
    inSourceNotDocs,
    reverseDrift,
  };
}

// ── Report ──────────────────────────────────────────────────────────────

function emitReport(checks) {
  const lines = [];
  lines.push('# 📋 Docs drift check');
  lines.push('');
  lines.push(
    `_Compares skillpack sources against the docs site. **Non-blocking** — surfaces drift to humans. Tracked under TD-17._`,
  );
  lines.push('');

  let totalIssues = 0;

  for (const check of checks) {
    lines.push(`## ${check.name}`);
    lines.push('');
    if (check.error) {
      lines.push(`❌ ${check.error}`);
      lines.push('');
      totalIssues += 1;
      continue;
    }
    lines.push(`- Source items on disk: **${check.sourceCount}**`);
    lines.push(`- Docs page: \`${relative(check.docsPage)}\``);
    lines.push('');

    if (check.inSourceNotDocs?.length) {
      totalIssues += check.inSourceNotDocs.length;
      lines.push(`### Missing from docs (${check.inSourceNotDocs.length})`);
      lines.push('');
      for (const item of check.inSourceNotDocs) {
        lines.push(`- ⚠ \`${item}\` exists in the skillpack but isn't mentioned on the docs page`);
      }
      lines.push('');
    } else {
      lines.push('✅ All source items are mentioned on the docs page.');
      lines.push('');
    }

    if (check.reverseDrift?.length) {
      totalIssues += check.reverseDrift.length;
      lines.push(`### Possibly stale on docs (${check.reverseDrift.length})`);
      lines.push('');
      lines.push(
        '_Heuristic — these names appear on the docs page but don\'t match anything in the skillpack today. Could be a rename or removal that wasn\'t reflected on the docs page, or a false positive (e.g., a name fragment we picked up accidentally)._',
      );
      lines.push('');
      for (const item of check.reverseDrift) {
        lines.push(`- ⚠ \`${item}\` mentioned on docs page but not in the skillpack`);
      }
      lines.push('');
    }
  }

  lines.push('---');
  lines.push('');
  if (totalIssues === 0) {
    lines.push('## ✅ Summary: no drift detected');
  } else {
    lines.push(`## ⚠ Summary: ${totalIssues} potential drift issue(s)`);
    lines.push('');
    lines.push('**Next step:** update the named docs page(s) to add / remove / rename the items above. The docs site is a curated subset of the skillpack sources — see TD-17 for the full mirror plan (post-1.0).');
  }
  lines.push('');

  return lines.join('\n');
}

function relative(absolute) {
  return absolute.replace(REPO_ROOT + '/', '');
}

// ── Main ────────────────────────────────────────────────────────────────

const checks = await Promise.all([checkSkills(), checkPrompts(), checkTdEntries()]);
process.stdout.write(emitReport(checks));
// Always exit 0 — non-blocking by design.
process.exit(0);
