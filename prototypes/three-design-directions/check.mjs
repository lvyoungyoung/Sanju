import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.dirname(fileURLToPath(import.meta.url));
const files = ['index.html', '01-gallery/index.html', '02-journal/index.html', '03-studio/index.html'];
let checks = 0;
for (const relative of files) {
  const filename = path.join(root, relative);
  const html = await readFile(filename, 'utf8');
  assert.match(html, /<meta\s+name=["']viewport["']/i, `${relative}: missing mobile viewport`);
  assert.match(html, /<html\s+lang=["']zh/i, `${relative}: missing language`);
  checks += 2;
  for (const [index, match] of [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)].entries()) {
    new vm.Script(match[1], { filename: `${relative}:script-${index}` });
    checks++;
  }
  for (const match of html.matchAll(/(?:src|href)=["']([^"']+)["']/g)) {
    const ref = match[1];
    if (/^(?:[a-z]+:|#|\/\/|\$\{)/i.test(ref) || ref.includes('${')) continue;
    const local = path.resolve(path.dirname(filename), ref.split(/[?#]/)[0]);
    assert.ok(local.startsWith(`${root}${path.sep}`), `${relative}: asset escapes prototype directory`);
    await access(local);
    checks++;
  }
  assert.doesNotMatch(html, /\b(?:fetch\s*\(|XMLHttpRequest|WebSocket\s*\(|supabase\.co|api-staging\.sanju\.cc)/, `${relative}: unexpected backend access`);
  assert.match(html, /sanju:navigate/, `${relative}: missing comparison navigation`);
  checks += 2;
  console.log(`PASS ${relative}`);
}
console.log(`${checks} static prototype checks passed. Browser interaction and visual checks are separate.`);
