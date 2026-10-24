// Rules tests for the friends ranking (Fase 3, docs/90 Fatia 0, docs/91 §4 + §14.1, docs/93 §4.1/B11,
// ADR-007). The ranking changes NO rule: these tests lock the access the client relies on.
//   - one `get` of shared_profiles/{friend} per friend, in a sliding window of 10 parallel reads;
//   - `list` (any query, including documentId in [...]) is denied;
//   - section present <=> consent present (`stats` only with sharing.stats);
//   - rankOk does NOT guarantee sane numbers (documentary: why the client reader is strict);
//   - the "has >= 1 friend" signal (D7): count() of friendships where members array-contains me.
// The sha256 gate lives in rules_sha.test.mjs on purpose (B11): never put it here, since this suite
// is run against every RK* mutant by mutations.mjs. Emulator only.
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, deleteField, documentId, getCountFromServer, getDoc, getDocs, limit, query,
  setDoc, updateDoc, where,
} from 'firebase/firestore';
import { U, commit, doc, friendshipRef, makeTools, newEnv, requestRef } from './social_helpers.mjs';
import {
  RANK, createActivity, createStats, period, spRef, st, stats, stored, total,
} from './shared_profile_helpers.mjs';

const { ana, bruno, caio, dora } = U;
const carla = 'uid-carla';
let env;
let t;
before(async () => {
  env = await newEnv();
  t = makeTools(env);
});
after(async () => env?.cleanup());
beforeEach(async () => env.clearFirestore());

const WINDOW = 10; // docs/91 §10.3: at most 10 reads in flight, the 11th starts when one finishes
const friendUid = (i) => `uid-f${String(i).padStart(2, '0')}`;
const seedShared = (uid, data = stored()) => t.seedDoc(['shared_profiles', uid], data);
const spExists = (uid) => t.exists(['shared_profiles', uid]);
const blockBatch = (d, me, other) =>
  commit(d, (b) => {
    b.set(doc(d, 'users', me, 'blocks', other), { createdAt: st() });
    b.delete(friendshipRef(d, me, other));
    b.delete(requestRef(d, me, other));
    b.delete(requestRef(d, other, me));
  });

// Sliding window (not steps of 10): `tasks` are thunks; returns the settled results in input order
// and the observed peak of reads in flight.
async function slidingWindow(tasks, size = WINDOW) {
  const out = new Array(tasks.length);
  let next = 0;
  let inFlight = 0;
  let peak = 0;
  const worker = async () => {
    while (next < tasks.length) {
      const i = next++;
      inFlight++;
      peak = Math.max(peak, inFlight);
      try {
        out[i] = { ok: true, value: await tasks[i]() };
      } catch (e) {
        out[i] = { ok: false, code: e?.code };
      } finally {
        inFlight--;
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(size, tasks.length) }, worker));
  return { out, peak };
}

// The D7 signal exactly as docs/91 §8.1 describes it.
const friendsCount = (d, uid) =>
  getCountFromServer(query(collection(d, 'friendships'), where('members', 'array-contains', uid), limit(300)));

describe('ranking: get of each friend snapshot (docs/91 §4.1/§4.2)', () => {
  it('owner reads own document (existing or not), even without Google', async () => {
    assert.equal((await assertSucceeds(getDoc(spRef(t.db(ana), ana)))).exists(), false);
    await seedShared(ana);
    assert.equal((await assertSucceeds(getDoc(spRef(t.db(ana), ana)))).exists(), true);
    await assertSucceeds(getDoc(spRef(t.dbWith(ana, 'password'), ana)));
  });

  it('12 mutual Google friends: all read by get in a sliding window of 10 parallel reads', async () => {
    const friends = Array.from({ length: 12 }, (_, i) => friendUid(i));
    for (const f of friends) {
      await t.seedFriendship(ana, f);
      await seedShared(f, stored({ calc: 1 + friends.indexOf(f) }));
    }
    const d = t.db(ana);
    const { out, peak } = await slidingWindow(friends.map((f) => () => getDoc(spRef(d, f))));
    assert.equal(peak, WINDOW, 'the window must reach exactly 10 reads in flight');
    out.forEach((r, i) => {
      assert.ok(r.ok, `friend ${friends[i]} must be readable (got ${r.code})`);
      assert.equal(r.value.exists(), true);
      assert.equal(r.value.data().calc, 1 + i);
      assert.ok(r.value.data().stats, 'stats section shared');
    });
  });

  it('each get is decided alone: a stranger in the middle is denied, the friends around it are read', async () => {
    const uids = [friendUid(0), friendUid(1), caio, friendUid(2)];
    for (const u of uids) await seedShared(u);
    for (const u of uids.filter((x) => x !== caio)) await t.seedFriendship(ana, u);
    const d = t.db(ana);
    const { out } = await slidingWindow(uids.map((u) => () => getDoc(spRef(d, u))));
    assert.deepEqual(out.map((r) => r.ok), [true, true, false, true]);
    assert.equal(out[2].code, 'permission-denied');
  });

  it('a friend without a snapshot: get allowed, document does not exist ("não participa")', async () => {
    await t.seedFriendship(ana, bruno);
    const r = await assertSucceeds(getDoc(spRef(t.db(ana), bruno)));
    assert.equal(r.exists(), false);
  });

  it('non-friend is denied whether or not the document exists (no existence oracle)', async () => {
    await assertFails(getDoc(spRef(t.db(ana), caio)));
    await seedShared(caio);
    await assertFails(getDoc(spRef(t.db(ana), caio)));
  });

  it('ex-friend: pair deleted by either side is denied on the next read (both directions); re-friended reads again', async () => {
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    await seedShared(ana);
    await seedShared(bruno);
    await t.seedFriendship(ana, bruno);
    await assertSucceeds(getDoc(spRef(t.db(ana), bruno)));
    await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    // Ana removes Bruno
    await assertSucceeds(deleteDoc(friendshipRef(t.db(ana), ana, bruno)));
    await assertFails(getDoc(spRef(t.db(ana), bruno)));
    await assertFails(getDoc(spRef(t.db(bruno), ana)));
    // pair re-created (friends again) => readable again
    await t.seedFriendship(ana, bruno);
    await assertSucceeds(getDoc(spRef(t.db(ana), bruno)));
    await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    // Bruno removes Ana
    await assertSucceeds(deleteDoc(friendshipRef(t.db(bruno), ana, bruno)));
    await assertFails(getDoc(spRef(t.db(ana), bruno)));
    await assertFails(getDoc(spRef(t.db(bruno), ana)));
  });

  it('blocked in both directions (real block batch): Ana->Dora and Bruno->Ana, both sides denied', async () => {
    for (const u of [ana, bruno, dora]) {
      await t.seedSocial(u);
      await seedShared(u);
    }
    await t.seedFriendship(ana, dora);
    await t.seedFriendship(ana, bruno);
    await assertSucceeds(getDoc(spRef(t.db(ana), dora)));
    await assertSucceeds(getDoc(spRef(t.db(ana), bruno)));
    await assertSucceeds(blockBatch(t.db(ana), ana, dora));
    await assertFails(getDoc(spRef(t.db(ana), dora)));
    await assertFails(getDoc(spRef(t.db(dora), ana)));
    await assertSucceeds(blockBatch(t.db(bruno), bruno, ana));
    await assertFails(getDoc(spRef(t.db(ana), bruno)));
    await assertFails(getDoc(spRef(t.db(bruno), ana)));
  });

  it('a block left with the pair absent never grants reading (both directions seeded)', async () => {
    await seedShared(dora);
    await t.seedBlock(ana, dora);
    await t.seedBlock(dora, ana);
    await assertFails(getDoc(spRef(t.db(ana), dora)));
    await assertFails(getDoc(spRef(t.db(dora), ana)));
  });

  // One `it` per non-Google identity (clearer RK4/RK5 diagnosis). Each also checks a friend WITHOUT a
  // snapshot (no existence oracle for non-Google) and that the same friend with Google reads.
  const nonGoogle = [
    ['anonymous (signed out)', () => t.anon()],
    ['password provider', () => t.dbWith(ana, 'password')],
    ['anonymous provider', () => t.dbWith(ana, 'anonymous')],
    ['no sign_in_provider claim', () => t.dbNoClaim(ana)],
  ];
  for (const [label, dbOf] of nonGoogle) {
    it(`friend signed in as ${label} is denied (with and without a snapshot); Google reads`, async () => {
      await seedShared(bruno);
      await t.seedFriendship(ana, bruno);
      await t.seedFriendship(ana, caio);
      await assertFails(getDoc(spRef(dbOf(), bruno)));
      await assertFails(getDoc(spRef(dbOf(), caio)));
      await assertSucceeds(getDoc(spRef(t.db(ana), bruno)));
    });
  }

  it('account in deletion with the pair still present: get allowed, document does not exist; then denied', async () => {
    await t.seedSocial(carla);
    await t.seedDoc(['users', carla], { displayName: 'Carla', schemaVersion: 1 });
    await seedShared(carla);
    await t.seedFriendship(ana, carla);
    await assertSucceeds(getDoc(spRef(t.db(ana), carla)));
    // AccountDeleter order (lib/account/account_deleter.dart): mark deleting, delete the snapshot,
    // then the social sweep (pairs). Done with Carla's own credentials, as the app does.
    const c = t.db(carla);
    await assertSucceeds(setDoc(doc(c, 'users', carla), { deleting: true }, { merge: true }));
    await assertSucceeds(deleteDoc(spRef(c, carla)));
    assert.equal(await spExists(carla), false);
    const r = await assertSucceeds(getDoc(spRef(t.db(ana), carla)));
    assert.equal(r.exists(), false, 'pair still present => "não participa", never an error');
    // the sweep removes the pair => denied ("denied" path of the ranking)
    await assertSucceeds(deleteDoc(friendshipRef(c, ana, carla)));
    await assertFails(getDoc(spRef(t.db(ana), carla)));
  });

  it('a friend never writes the other person\'s snapshot (set, update, delete)', async () => {
    await t.seedSocial(bruno);
    await seedShared(ana);
    await t.seedFriendship(ana, bruno);
    const b = t.db(bruno);
    await assertFails(setDoc(spRef(b, ana), createStats()));
    await assertFails(updateDoc(spRef(b, ana), { calc: 2, updatedAt: st() }));
    await assertFails(deleteDoc(spRef(b, ana)));
    assert.equal(await spExists(ana), true);
  });
});

describe('ranking: queries on shared_profiles are denied (no list, docs/91 §4.2)', () => {
  const three = [friendUid(0), friendUid(1), friendUid(2)];
  const ten = Array.from({ length: 10 }, (_, i) => friendUid(i));
  beforeEach(async () => {
    for (const f of ten) {
      await t.seedFriendship(ana, f);
      await seedShared(f);
    }
    await seedShared(caio);
    await seedShared(ana);
  });

  it('getDocs(collection) is denied (owner, friend, anonymous)', async () => {
    await assertFails(getDocs(collection(t.db(ana), 'shared_profiles')));
    await assertFails(getDocs(collection(t.db(friendUid(0)), 'shared_profiles')));
    await assertFails(getDocs(collection(t.anon(), 'shared_profiles')));
  });

  it('documentId in [3 friends] is denied', async () => {
    await assertFails(getDocs(query(collection(t.db(ana), 'shared_profiles'), where(documentId(), 'in', three))));
  });

  it('documentId in [10 friends] is denied', async () => {
    await assertFails(getDocs(query(collection(t.db(ana), 'shared_profiles'), where(documentId(), 'in', ten))));
  });

  it('documentId in [friend, non-friend] (mixed) is denied', async () => {
    await assertFails(getDocs(query(collection(t.db(ana), 'shared_profiles'), where(documentId(), 'in', [friendUid(0), caio]))));
  });

  it('documentId == one friend and filters on the content are denied', async () => {
    const col = collection(t.db(ana), 'shared_profiles');
    await assertFails(getDocs(query(col, where(documentId(), '==', friendUid(0)))));
    await assertFails(getDocs(query(col, where('sharing.stats', '==', true))));
    await assertFails(getDocs(query(col, where('stats.total.minutes', '>=', 0), limit(50))));
  });
});

describe('ranking: section present <=> consent present (stats, docs/91 §4.2)', () => {
  beforeEach(async () => {
    await t.seedSocial(ana);
    await t.seedFriendship(ana, bruno);
  });
  const anaRef = () => spRef(t.db(ana), ana);

  it('create with stats but sharing without stats is denied', async () => {
    await assertFails(setDoc(anaRef(), createActivity({ stats: stats() })));
    assert.equal(await spExists(ana), false);
  });

  it('create with sharing.stats but without the stats section is denied', async () => {
    const d = createStats();
    delete d.stats;
    await assertFails(setDoc(anaRef(), d));
    assert.equal(await spExists(ana), false);
  });

  it('update adding stats without sharing.stats is denied', async () => {
    const noStats = stored({ sharing: { activity: true, recs: true } });
    delete noStats.stats;
    await seedShared(ana, noStats);
    await assertFails(updateDoc(anaRef(), { stats: stats(), calc: 2, updatedAt: st() }));
  });

  it('update removing sharing.stats while keeping stats is denied; removing both is allowed', async () => {
    await seedShared(ana);
    await assertFails(updateDoc(anaRef(), { 'sharing.stats': deleteField(), updatedAt: st() }));
    await assertSucceeds(updateDoc(anaRef(), { 'sharing.stats': deleteField(), stats: deleteField(), updatedAt: st() }));
    const r = await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    assert.equal('stats' in r.data(), false, 'the friend reads the document without stats');
    assert.equal('stats' in r.data().sharing, false);
  });

  it('a friend reading a snapshot without stats gets the document without the field', async () => {
    await assertSucceeds(setDoc(anaRef(), createActivity()));
    const r = await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    assert.equal(r.exists(), true);
    assert.equal(r.data().stats, undefined);
    assert.deepEqual(r.data().sharing, { activity: true });
  });
});

// Documentary (docs/91 §4.3, ADR-007 option D rejected): the rules only check `>= 0` per metric.
// If one of the "accepted" rows starts failing, the rules were hardened: revisit RankingReading
// (it may be relaxed) and the expression budget, and update docs/91 §4.3.
describe('ranking: current rankOk behavior (why the client reader is strict)', () => {
  beforeEach(async () => {
    await t.seedSocial(ana);
    await t.seedFriendship(ana, bruno);
  });
  const withTotal = (o) => createStats({ stats: stats({ total: total(o) }) });
  const tryCreate = async (data, ok) => {
    await env.clearFirestore();
    await t.seedSocial(ana);
    const p = setDoc(spRef(t.db(ana), ana), data);
    await (ok ? assertSucceeds(p) : assertFails(p));
  };

  for (const [label, v] of [['Infinity', Infinity], ['1e300', 1e300], ['1.5', 1.5]]) {
    it(`total.minutes = ${label} is ACCEPTED by the rules`, async () => {
      await tryCreate(withTotal({ minutes: v }), true);
    });
  }

  it('every ranking metric accepts a non-integer (1.5) in total, month and year', async () => {
    for (const m of RANK) {
      await tryCreate(withTotal({ [m]: 1.5 }), true);
      await tryCreate(createStats({ stats: stats({ month: period('2026-10', { [m]: 1.5 }) }) }), true);
      await tryCreate(createStats({ stats: stats({ year: period('2026', { [m]: 1.5 }) }) }), true);
    }
  });

  it('month > total (incoherent: 999999 movies this month, 1 in total) is ACCEPTED', async () => {
    await tryCreate(createStats({
      stats: stats({ total: total({ watchedMovies: 1 }), month: period('2026-10', { watchedMovies: 999999 }) }),
    }), true);
  });

  for (const [label, v] of [['NaN', NaN], ['-Infinity', -Infinity], ['-1', -1], ['"10"', '10'], ['null', null]]) {
    it(`total.minutes = ${label} is denied`, async () => {
      await tryCreate(withTotal({ minutes: v }), false);
    });
  }

  it('the friend reads Infinity back as Infinity (the reader must discard it)', async () => {
    await tryCreate(withTotal({ minutes: Infinity }), true);
    await t.seedFriendship(ana, bruno);
    const r = await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    assert.equal(r.data().stats.total.minutes, Infinity);
  });
});

describe('ranking: the ">= 1 friend" signal (D7: count of friendships)', () => {
  beforeEach(async () => {
    await t.seedFriendship(ana, bruno);
    await t.seedFriendship(ana, caio);
    await t.seedFriendship(caio, dora); // not Ana's
  });

  it('count() of friendships where members array-contains me, limit 300, is allowed to the member', async () => {
    const r = await assertSucceeds(friendsCount(t.db(ana), ana));
    assert.equal(r.data().count, 2);
    const z = await assertSucceeds(friendsCount(t.db(carla), carla));
    assert.equal(z.data().count, 0, 'nobody: allowed, 0');
  });

  it('the same query with another person\'s uid is denied (no counting someone else\'s friends)', async () => {
    await assertFails(friendsCount(t.db(ana), dora));
    await assertFails(friendsCount(t.db(carla), ana));
  });

  it('anonymous is denied', async () => {
    await assertFails(friendsCount(t.anon(), ana));
  });
});
