#!/usr/bin/env node

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const docsRoot = join(repositoryRoot, "docs");
const validationPath = join(docsRoot, "VALIDATION.md");
const issues = [];

const expectedDocuments = [
  "ARCHITECTURE.md", "DEVELOPMENT.md", "README.md", "ROADMAP.md",
  "SAFETY.md", "SQLITE_SCHEMA.md", "USER_GUIDE.md", "VALIDATION.md"
];
const actualDocuments = readdirSync(docsRoot, { recursive: true })
  .filter(name => name.endsWith(".md")).sort();
if (JSON.stringify(actualDocuments) !== JSON.stringify(expectedDocuments)) {
  issues.push("keep the reader-facing documentation in the eight agreed core documents");
}

if (existsSync(join(docsRoot, "experiement")) || existsSync(join(docsRoot, "experiment"))) {
  issues.push("experiment documentation must remain consolidated in docs/VALIDATION.md");
}
const validation = existsSync(validationPath) ? readFileSync(validationPath, "utf8") : "";
for (const heading of ["## 目前結論", "## 已交付版本", "## 驗證到哪裡", "## 保留的限制與設計決策", "## 歷史追溯（需要時才查）"]) {
  if (!validation.includes(heading)) issues.push("missing validation section: " + heading);
}
if (/^\| (?:GR-\d{2}|`(?:LIVE|PKG)-)/m.test(validation)) {
  issues.push("keep experiment IDs and per-attempt matrices out of the validation summary");
}

// Validate the maintained reader-facing documents, not historical material in Git.
function checkDocuments(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const file = join(directory, entry.name);
    if (entry.isDirectory()) { checkDocuments(file); continue; }
    if (!entry.name.endsWith(".md")) continue;
    checkDocument(file);
  }
}
function checkDocument(file) {
  const content = readFileSync(file, "utf8");
  // Validate local file destinations, ignoring fenced examples and URL links.
  const prose = content.replace(/^```[^\n]*\n[\s\S]*?^```\s*$/gm, "");
  for (const match of prose.matchAll(/\]\(([^)]+)\)/g)) {
    const destination = match[1].trim().replace(/^<|>$/g, "");
    if (/^(?:[a-z][a-z0-9+.-]*:|#)/i.test(destination)) continue;
    const path = destination.split("#")[0];
    if (path && !existsSync(resolve(dirname(file), decodeURIComponent(path)))) {
      issues.push("broken local link in " + relative(repositoryRoot, file) + ": " + destination);
    }
  }
  if (/\]\([^)]*(?:experiement|experiment)\//.test(content)) {
    issues.push("retired experiment navigation: " + relative(repositoryRoot, file));
  }
  if (/\]\([^)]*fixtures\/ghost-contracts\//.test(content)) {
    issues.push("test fixture linked as reader documentation: " + relative(repositoryRoot, file));
  }
  if (/\]\([^)]*(?:\.\/|\.\.\/)capabilities\//.test(content)) {
    issues.push("retired capability-card navigation: " + relative(repositoryRoot, file));
  }
}
checkDocuments(docsRoot);
for (const name of ["README.md", "README.zh-TW.md"]) checkDocument(join(repositoryRoot, name));

if (issues.length) {
  console.error("Documentation verification failed:\n" + issues.map(issue => "- " + issue).join("\n"));
  process.exit(1);
}
console.log("Documentation verification passed: " + actualDocuments.length + " core documents, local links checked.");
