// sha256 gate of firestore.rules (docs/91 §13/§14.1, docs/93 B11). The ranking (Fase 3) changes NO
// rule: the file in the repository must be byte-identical to the rules live in production.
// Deliberately in its own file and NEVER in a mutations.mjs suite list (SP/RK/SUITES): every mutant
// changes the sha, so this gate inside a mutant suite would "kill" all of them without proving
// anything. Reads ../firestore.rules directly (ignores RULES_PATH). No emulator needed.
// When a future phase publishes new rules, update PRODUCTION_SHA here and in
// .github/workflows/deploy-pages.yml in the same change, after the CLI deploy.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { it } from 'node:test';

const PRODUCTION_SHA = '6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612';

it('firestore.rules sha256 equals the rules published in production', () => {
  const bytes = readFileSync(new URL('../firestore.rules', import.meta.url));
  const sha = createHash('sha256').update(bytes).digest('hex');
  assert.equal(sha, PRODUCTION_SHA, 'firestore.rules differs from production: Fase 3 must not change rules');
});
