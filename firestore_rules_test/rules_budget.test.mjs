// Rules-call budget (docs/51 §budget): exists/get/getAfter limits and the REAL cost of
// isFriend / isBlocked. Probe collections are injected into a COPY of the real rules text
// (the shipped firestore.rules has no probes). Emulator only: production may differ.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, query, serverTimestamp, setDoc, updateDoc, where,
} from 'firebase/firestore';
import {
  RULES_URL, U, acceptBatch, commit, makeTools, newEnv, requestRef,
} from './social_helpers.mjs';
import {
  HOUR, acts, createAll, createStats, past, recs, stats, stored, st, total,
} from './shared_profile_helpers.mjs';

const MARKER = '    // Everything not allowed above is denied';
const base = readFileSync(RULES_URL, 'utf8');
assert.ok(base.includes(MARKER), 'rules marker not found');

const P = (name) => `/databases/$(database)/documents/probe_t/${name}`;
const chain = (n, prefix) =>
  Array.from({ length: n }, (_, i) => `exists(${P(`${prefix}${i}`)})`).join(' && ');
const lit = (prefix, n, fn) =>
  Array.from({ length: n }, (_, i) => fn(`'${prefix}${i}'`)).join(' && ');

// Phase 2 (docs/82 §4.3/§4.5): the REAL allow-expressions of shared_profiles/{uid}, extracted from
// the rules text (so a mutation of the rules changes the probes too), plus N extra distinct exists()
// (call budget) or N extra comparisons (expression budget).
const SP = base.slice(base.indexOf('    match /shared_profiles/{uid} {'));
assert.ok(SP.length > 0, 'shared_profiles block not found');
const spExpr = (verb) => {
  const m = SP.match(new RegExp(`allow ${verb}: if ([\\s\\S]*?);\\n`));
  assert.ok(m, `allow ${verb} not found in shared_profiles`);
  return `(${m[1]})`;
};
// N extra comparisons, grouped 10 per function (a flat chain of 100+ does not compile).
const xGroups = (tag, n) => Array.from({ length: Math.ceil(n / 10) }, (_, g) =>
  `    function x${tag}${g}() { return ${Array.from({ length: Math.min(10, n - g * 10) }, (_, i) =>
    `request.resource.data.tz != ${2000 + g * 10 + i}`).join(' && ')}; }`).join('\n');
const xCall = (tag, n) => Array.from({ length: Math.ceil(n / 10) }, (_, g) => `x${tag}${g}()`).join(' && ');
// NFR (docs/82 §4.5, revised 2026-10-10): heaviest APP write <= 65% of the 1000-expression limit;
// heaviest LEGAL document <= 70%. Unit = 1 comparison grouped 10 per function; an empty request fits
// ~123 of them (CAPACITY, locked below). "Uses <= X%" is locked as "still fits (1 - X) * CAPACITY
// extra comparisons". Calibrated in the emulator after the round-2 optimization (docs/84):
//   create 3 sections/10 activities/50 recs: 43 free (~65%) | set over existing, all changing: 47 (~62%)
//   consent change + 3 sections all changing (heaviest app write): 44 (~64%) | recalc 3 changing: 47 (~62%)
const CAPACITY = 120; // an empty request must fit at least this many (measured 123)
const OVER_LIMIT = 140; // ... and this many must exceed the limit (the limit is real and counted)
const HEAD_APP = Math.ceil(0.35 * 123); // 44 -> heaviest app write <= 65%
const HEAD_WORST = Math.ceil(0.30 * 123); // 37 -> heaviest legal document <= 70%

const probes = `
    match /probe_sp_get9/{uid} { allow get: if ${spExpr('get')} && ${chain(9, 's')}; }
    match /probe_sp_get10/{uid} { allow get: if ${spExpr('get')} && ${chain(10, 's')}; }
    match /probe_sp_create9/{uid} { allow create: if ${spExpr('create')} && ${chain(9, 's')}; }
    match /probe_sp_create10/{uid} { allow create: if ${spExpr('create')} && ${chain(10, 's')}; }
    match /probe_sp_update9/{uid} { allow update: if ${spExpr('update')} && ${chain(9, 's')}; }
    match /probe_sp_update10/{uid} { allow update: if ${spExpr('update')} && ${chain(10, 's')}; }
    match /probe_sp_delete10/{uid} { allow delete: if ${spExpr('delete')} && ${chain(10, 's')}; }
${xGroups('w', HEAD_WORST)}
${xGroups('a', HEAD_APP)}
${xGroups('o', OVER_LIMIT)}
${xGroups('c', CAPACITY)}
    match /probe_sp_headw/{uid} { allow create: if ${spExpr('create')} && ${xCall('w', HEAD_WORST)}; }
    match /probe_sp_headws/{uid} { allow update: if ${spExpr('update')} && ${xCall('w', HEAD_WORST)}; }
    match /probe_sp_heada/{uid} { allow update: if ${spExpr('update')} && ${xCall('a', HEAD_APP)}; }
    match /probe_sp_over/{uid} { allow create: if ${xCall('o', OVER_LIMIT)}; }
    match /probe_sp_cap/{uid} { allow create: if ${xCall('c', CAPACITY)}; }
    match /probe_get10/{id} { allow get: if request.auth != null && ${chain(10, 'a')}; }
    match /probe_get11/{id} { allow get: if request.auth != null && ${chain(11, 'a')}; }
    match /probe_rep/{id} { allow get: if request.auth != null && ${Array.from({ length: 12 }, () => `exists(${P('a0')})`).join(' && ')}; }
    match /probe_wa/{id} { allow create: if request.auth != null && ${chain(7, 'wa')}; }
    match /probe_wb/{id} { allow create: if request.auth != null && ${chain(7, 'wb')}; }
    match /probe_wc/{id} { allow create: if request.auth != null && ${chain(7, 'wc')}; }
    match /probe_f10/{id} { allow get: if request.auth != null && ${lit('f', 10, (x) => `isFriend(${x}, request.auth.uid)`)}; }
    match /probe_f11/{id} { allow get: if request.auth != null && ${lit('f', 11, (x) => `isFriend(${x}, request.auth.uid)`)}; }
    match /probe_b10/{id} { allow get: if request.auth != null && ${lit('f', 10, (x) => `!isBlocked(${x}, request.auth.uid)`)}; }
    match /probe_b11/{id} { allow get: if request.auth != null && ${lit('f', 11, (x) => `!isBlocked(${x}, request.auth.uid)`)}; }
    match /probe_frep/{id} { allow get: if request.auth != null && ${Array.from({ length: 12 }, () => `isFriend('f0', request.auth.uid)`).join(' && ')}; }
    // F2/F4/F5-style probes (NOT shipped): author fixed in the document, decision = isFriend only.
    match /probe_docs/{id} {
      allow get, list: if request.auth != null
        && (resource.data.authorId == request.auth.uid || isFriend(resource.data.authorId, request.auth.uid));
    }
    match /probe_comments/{id} {
      allow get: if request.auth != null
        && (resource.data.authorId == request.auth.uid
            || (resource.data.visibility == 'friends' && isFriend(resource.data.authorId, request.auth.uid)));
    }
`;

let env;
let t;
before(async () => {
  env = await newEnv(base.replace(MARKER, probes + MARKER));
  t = makeTools(env);
});
after(async () => env?.cleanup());
beforeEach(async () => env.clearFirestore());

const { ana, bruno, caio, dora } = U;
const seedProbePaths = (prefix, n) =>
  t.seed(async (d) => {
    for (let i = 0; i < n; i++) await setDoc(doc(d, 'probe_t', `${prefix}${i}`), { x: 1 });
  });
const friends = (n) => Array.from({ length: n }, (_, i) => `f${i}`);
const seedFriends = async (me, n) => {
  for (const f of friends(n)) await t.seedFriendship(me, f);
};

describe('documented limits (emulator)', () => {
  it('get with 10 distinct exists() passes, 11 is denied', async () => {
    await seedProbePaths('a', 11);
    await t.seedDoc(['probe_get10', 'x'], { v: 1 });
    await t.seedDoc(['probe_get11', 'x'], { v: 1 });
    await assertSucceeds(getDoc(doc(t.db(ana), 'probe_get10', 'x')));
    await assertFails(getDoc(doc(t.db(ana), 'probe_get11', 'x')));
  });
  it('the same path repeated 12 times counts once', async () => {
    await seedProbePaths('a', 1);
    await t.seedDoc(['probe_rep', 'x'], { v: 1 });
    await assertSucceeds(getDoc(doc(t.db(ana), 'probe_rep', 'x')));
  });
  it('batch: 2 writes x 7 distinct calls (14) passes; 3 writes (21 > 20) is denied', async () => {
    await seedProbePaths('wa', 7);
    await seedProbePaths('wb', 7);
    await seedProbePaths('wc', 7);
    const d = t.db(ana);
    await assertSucceeds(
      commit(d, (b) => {
        b.set(doc(d, 'probe_wa', '1'), { v: 1 });
        b.set(doc(d, 'probe_wb', '1'), { v: 1 });
      }),
    );
    await assertFails(
      commit(d, (b) => {
        b.set(doc(d, 'probe_wa', '2'), { v: 1 });
        b.set(doc(d, 'probe_wb', '2'), { v: 1 });
        b.set(doc(d, 'probe_wc', '2'), { v: 1 });
      }),
    );
  });
});

describe('isFriend / isBlocked cost exactly 1 rules call each (real functions)', () => {
  it('10 distinct isFriend() in one get passes, 11 denied', async () => {
    await seedFriends(ana, 11);
    await t.seedDoc(['probe_f10', 'x'], { v: 1 });
    await t.seedDoc(['probe_f11', 'x'], { v: 1 });
    await assertSucceeds(getDoc(doc(t.db(ana), 'probe_f10', 'x')));
    await assertFails(getDoc(doc(t.db(ana), 'probe_f11', 'x')));
  });
  it('10 distinct isBlocked() in one get passes, 11 denied', async () => {
    await t.seedDoc(['probe_b10', 'x'], { v: 1 });
    await t.seedDoc(['probe_b11', 'x'], { v: 1 });
    await assertSucceeds(getDoc(doc(t.db(ana), 'probe_b10', 'x')));
    await assertFails(getDoc(doc(t.db(ana), 'probe_b11', 'x')));
  });
  it('isFriend repeated 12x on the same pair counts once', async () => {
    await seedFriends(ana, 1);
    await t.seedDoc(['probe_frep', 'x'], { v: 1 });
    await assertSucceeds(getDoc(doc(t.db(ana), 'probe_frep', 'x')));
  });
});

describe('F2-F5 shapes (probes only): visibility = isFriend, revocation, batches of authors', () => {
  it('friend reads the owner\'s doc; stranger, ex-friend, blocked and anonymous do not', async () => {
    await t.seedFriendship(ana, bruno);
    await t.seedDoc(['probe_docs', 'd1'], { authorId: ana, v: 1 });
    await assertSucceeds(getDoc(doc(t.db(bruno), 'probe_docs', 'd1')));
    await assertSucceeds(getDoc(doc(t.db(ana), 'probe_docs', 'd1')));
    await assertFails(getDoc(doc(t.db(caio), 'probe_docs', 'd1')));
    await assertFails(getDoc(doc(t.anon(), 'probe_docs', 'd1')));
    // revocation: unfriend -> denied right away
    await t.seed((d) => deleteDoc(doc(d, 'friendships', `${ana}_${bruno}`)));
    await assertFails(getDoc(doc(t.db(bruno), 'probe_docs', 'd1')));
  });
  it('block revokes: the block batch removes the pair, so the former friend loses access', async () => {
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    await t.seedFriendship(ana, bruno);
    await t.seedDoc(['probe_docs', 'd1'], { authorId: ana, v: 1 });
    const d = t.db(ana);
    await assertSucceeds(
      commit(d, (b) => {
        b.set(doc(d, 'users', ana, 'blocks', bruno), { createdAt: serverTimestamp() });
        b.delete(doc(d, 'friendships', `${ana}_${bruno}`));
        b.delete(requestRef(d, ana, bruno));
        b.delete(requestRef(d, bruno, ana));
      }),
    );
    await assertFails(getDoc(doc(t.db(bruno), 'probe_docs', 'd1')));
  });
  it('comment visibility: friends-only readable by friends; private only by the author', async () => {
    await t.seedFriendship(ana, bruno);
    await t.seedDoc(['probe_comments', 'c1'], { authorId: ana, visibility: 'friends' });
    await t.seedDoc(['probe_comments', 'c2'], { authorId: ana, visibility: 'private' });
    await assertSucceeds(getDoc(doc(t.db(bruno), 'probe_comments', 'c1')));
    await assertFails(getDoc(doc(t.db(bruno), 'probe_comments', 'c2')));
    await assertFails(getDoc(doc(t.db(caio), 'probe_comments', 'c1')));
    await assertSucceeds(getDoc(doc(t.db(ana), 'probe_comments', 'c2')));
  });
  it('query authorId == friend and authorId in [10 friends] pass; a stranger in the list denies the whole query', async () => {
    await seedFriends(ana, 10);
    for (const f of friends(10)) await t.seedDoc(['probe_docs', `d-${f}`], { authorId: f, v: 1 });
    await t.seedDoc(['probe_docs', 'd-x'], { authorId: dora, v: 1 });
    const col = collection(t.db(ana), 'probe_docs');
    await assertSucceeds(getDocs(query(col, where('authorId', '==', 'f0'))));
    const r = await assertSucceeds(getDocs(query(col, where('authorId', 'in', friends(10)))));
    assert.equal(r.size, 10);
    await assertFails(getDocs(query(col, where('authorId', 'in', [...friends(9), dora]))));
    await assertFails(getDocs(col)); // unconstrained list is never allowed
  });
  it('authorId in [N friends] for N = 11, 15, 20, 21, 30 (recorded; project rule is <= 10)', async () => {
    await seedFriends(ana, 30);
    const col = collection(t.db(ana), 'probe_docs');
    const out = {};
    for (const n of [11, 15, 20, 21, 30]) {
      try {
        await getDocs(query(col, where('authorId', 'in', friends(n))));
        out[n] = 'ok';
      } catch (e) {
        out[n] = e.code;
      }
    }
    console.log('authorId in [N friends] (emulator):', JSON.stringify(out));
    // The shipped design only batches <= 10, so only the documented figure is asserted.
    const ok10 = await getDocs(query(col, where('authorId', 'in', friends(10))));
    assert.equal(ok10.size, 0);
  });
});

describe('real operations stay inside the budget', () => {
  it('accepting N requests in ONE batch: recorded for N = 1, 3, 4, 6, 8 (client rule: 1 per batch)', async () => {
    const out = {};
    for (const n of [1, 3, 4, 6, 8]) {
      await env.clearFirestore();
      const others = Array.from({ length: n }, (_, i) => `u${i}`);
      await t.seedSocial(ana);
      for (const o of others) {
        await t.seedSocial(o);
        await t.seedRequest(o, ana);
      }
      const d = t.db(ana);
      out[n] = await commit(d, (b) => {
        for (const o of others) {
          const [x, y] = ana < o ? [ana, o] : [o, ana];
          b.set(doc(d, 'friendships', `${x}_${y}`), {
            members: [x, y], createdAt: serverTimestamp(), aName: `Nome ${x}`, bName: `Nome ${y}`,
          });
          b.delete(requestRef(d, o, ana));
          b.delete(requestRef(d, ana, o));
        }
      }).then(() => 'ok', (e) => e.code);
    }
    console.log('accept N in one batch (emulator):', JSON.stringify(out));
    assert.equal(out[1], 'ok');
  });
  it('send request with the handle binding (get social + exists social + 2 blocks + pair = 5 calls) passes, also as the crossed transaction', async () => {
    // docs/73: get(socialPath(from)) replaced exists(socialPath(from)): same path, same 1 call.
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    const d = t.db(ana);
    await assertSucceeds(setDoc(requestRef(d, ana, bruno), {
      from: ana, to: bruno, fromHandle: 'ana', fromName: 'Nome uid-ana', toName: 'Nome uid-bruno',
      createdAt: serverTimestamp(),
    }));
    // ... and the accept batch that consumes it still fits
    await assertSucceeds(acceptBatch(t.db(bruno), bruno, ana));
  });
  it('the accept batch (the heaviest single operation) passes alone', async () => {
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    await t.seedRequest(ana, bruno);
    await assertSucceeds(acceptBatch(t.db(bruno), bruno, ana));
  });
});

describe('Phase 2 shared_profiles: rules calls (real expressions + N distinct exists)', () => {
  const sp = (d, col, uid = ana) => doc(d, col, uid);
  it('friend read costs exactly 1 call (passes with +9, denied with +10); owner read costs 0', async () => {
    await seedProbePaths('s', 10);
    await t.seedFriendship(ana, bruno);
    for (const c of ['probe_sp_get9', 'probe_sp_get10']) await t.seedDoc([c, ana], stored());
    await assertSucceeds(getDoc(sp(t.db(bruno), 'probe_sp_get9')));
    await assertFails(getDoc(sp(t.db(bruno), 'probe_sp_get10')));
    await assertSucceeds(getDoc(sp(t.db(ana), 'probe_sp_get10')));
  });
  it('create (first toggle) costs exactly 1 call', async () => {
    await seedProbePaths('s', 10);
    await t.seedSocial(ana);
    await assertSucceeds(setDoc(sp(t.db(ana), 'probe_sp_create9'), createStats()));
    await assertFails(setDoc(sp(t.db(ana), 'probe_sp_create10'), createStats()));
  });
  it('recalculation costs 0 calls; a consent change costs exactly 1', async () => {
    await seedProbePaths('s', 10);
    await t.seedSocial(ana);
    const noRecs = () => { const s = stored(); delete s.sharing.recs; delete s.recs; return s; };
    await t.seedDoc(['probe_sp_update10', ana], noRecs());
    await t.seedDoc(['probe_sp_update9', ana], noRecs());
    const recalc = { stats: stats({ total: total({ minutes: 20777 }) }), activity: acts(10, past(HOUR)), updatedAt: st() };
    const consent = { 'sharing.recs': true, recs: recs(5), updatedAt: st() };
    await assertSucceeds(updateDoc(sp(t.db(ana), 'probe_sp_update10'), recalc));
    await assertFails(updateDoc(sp(t.db(ana), 'probe_sp_update10'), consent));
    await assertSucceeds(updateDoc(sp(t.db(ana), 'probe_sp_update9'), consent));
  });
  it('delete costs 0 calls', async () => {
    await seedProbePaths('s', 10);
    await t.seedDoc(['probe_sp_delete10', ana], stored());
    await assertSucceeds(deleteDoc(sp(t.db(ana), 'probe_sp_delete10')));
  });
});

describe('Phase 2 shared_profiles: headroom under the 1000-expression limit (docs/82 §4.5)', () => {
  const sp = (d, col) => doc(d, col, ana);
  // Every section CHANGES (stored values differ), so every validator is evaluated.
  const changed = () => ({
    stats: stats({ total: total({ minutes: 20777 }) }), activity: acts(10, past(HOUR / 2)), recs: recs(50, 121),
  });
  it(`sanity: an empty request fits ${CAPACITY} comparisons and ${OVER_LIMIT} exceed the limit`, async () => {
    await assertSucceeds(setDoc(sp(t.db(ana), 'probe_sp_cap'), { tz: 1 }));
    await assertFails(setDoc(sp(t.db(ana), 'probe_sp_over'), { tz: 1 }));
  });
  it(`heaviest legal document (create: 3 sections, 10 activities, 50 recs) <= 70%: + ${HEAD_WORST} comparisons fit`, async () => {
    await t.seedSocial(ana);
    await assertSucceeds(setDoc(sp(t.db(ana), 'probe_sp_headw'), createAll()));
  });
  it(`owner set over an existing document, all sections changing, <= 70%: + ${HEAD_WORST} comparisons fit`, async () => {
    const seed = stored();
    await t.seedDoc(['probe_sp_headws', ana], seed);
    await assertSucceeds(setDoc(sp(t.db(ana), 'probe_sp_headws'), { ...seed, ...changed(), updatedAt: st() }));
  });
  it(`heaviest app write (consent change + 3 sections all changing) <= 65%: + ${HEAD_APP} comparisons fit`, async () => {
    await t.seedSocial(ana);
    const s = stored();
    delete s.sharing.recs;
    delete s.recs;
    await t.seedDoc(['probe_sp_heada', ana], s);
    await assertSucceeds(updateDoc(sp(t.db(ana), 'probe_sp_heada'), {
      'sharing.recs': true, ...changed(), tz: -180, calc: 1, updatedAt: st(),
    }));
  });
  it(`recalculation of the 3 sections, all changing, <= 65%: + ${HEAD_APP} comparisons fit`, async () => {
    await t.seedDoc(['probe_sp_heada', ana], stored());
    await assertSucceeds(updateDoc(sp(t.db(ana), 'probe_sp_heada'), {
      ...changed(), tz: -120, calc: 1, updatedAt: st(),
    }));
  });
});
