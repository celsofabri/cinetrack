// Rules-call budget (docs/51 §budget): exists/get/getAfter limits and the REAL cost of
// isFriend / isBlocked. Probe collections are injected into a COPY of the real rules text
// (the shipped firestore.rules has no probes). Emulator only: production may differ.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, query, serverTimestamp, setDoc, where,
} from 'firebase/firestore';
import {
  RULES_URL, U, acceptBatch, commit, makeTools, newEnv, requestRef,
} from './social_helpers.mjs';

const MARKER = '    // Everything not allowed above is denied';
const base = readFileSync(RULES_URL, 'utf8');
assert.ok(base.includes(MARKER), 'rules marker not found');

const P = (name) => `/databases/$(database)/documents/probe_t/${name}`;
const chain = (n, prefix) =>
  Array.from({ length: n }, (_, i) => `exists(${P(`${prefix}${i}`)})`).join(' && ');
const lit = (prefix, n, fn) =>
  Array.from({ length: n }, (_, i) => fn(`'${prefix}${i}'`)).join(' && ');

const probes = `
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
  it('the accept batch (the heaviest single operation) passes alone', async () => {
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    await t.seedRequest(ana, bruno);
    await assertSucceeds(acceptBatch(t.db(bruno), bruno, ana));
  });
});

