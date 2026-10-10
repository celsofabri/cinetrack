// Rules tests for shared_profiles/{uid} (Fase 2, docs/82 §4.3/§4.4/§13, ADR-006).
// Oracle: the caps/schema table of docs/82 §4.4 (rows marked R). Emulator only.
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  Timestamp, collection, deleteDoc, deleteField, documentId, getDoc, getDocs, query, setDoc,
  updateDoc, where,
} from 'firebase/firestore';
import { U, commit, doc, friendshipRef, makeTools, newEnv, requestRef } from './social_helpers.mjs';
import {
  HOUR, RANK, act, acts, createActivity, createAll, createRecs, createStats, future, past, period,
  recs, spRef, st, stats, stored, total,
} from './shared_profile_helpers.mjs';

const { ana, bruno, caio } = U;
let env;
let t;
before(async () => {
  env = await newEnv();
  t = makeTools(env);
});
after(async () => env?.cleanup());
beforeEach(async () => env.clearFirestore());

const seedShared = (uid, data = stored()) => t.seedDoc(['shared_profiles', uid], data);
const spExists = (uid) => t.exists(['shared_profiles', uid]);
const anaDb = () => t.db(ana);
// Create as Ana (social active) and expect success / failure.
const okCreate = async (data) => {
  await t.seedSocial(ana);
  await assertSucceeds(setDoc(spRef(anaDb(), ana), data));
};
const badCreate = async (data) => {
  await t.seedSocial(ana);
  await assertFails(setDoc(spRef(anaDb(), ana), data));
  assert.equal(await spExists(ana), false, 'a denied create must not leave a document');
};
const blockBatch = (d, me, other) =>
  commit(d, (b) => {
    b.set(doc(d, 'users', me, 'blocks', other), { createdAt: st() });
    b.delete(friendshipRef(d, me, other));
    b.delete(requestRef(d, me, other));
    b.delete(requestRef(d, other, me));
  });

describe('shared_profiles: read matrix', () => {
  it('owner reads own document (existing and non-existing), even without social or Google', async () => {
    await assertSucceeds(getDoc(spRef(anaDb(), ana)));
    assert.equal((await getDoc(spRef(anaDb(), ana))).exists(), false);
    await seedShared(ana);
    assert.equal((await assertSucceeds(getDoc(spRef(anaDb(), ana)))).exists(), true);
    await assertSucceeds(getDoc(spRef(t.dbWith(ana, 'password'), ana)));
  });

  it('mutual friend reads; reading a non-existing document returns "does not exist"', async () => {
    await t.seedFriendship(ana, bruno);
    const r = await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    assert.equal(r.exists(), false);
    await seedShared(ana);
    const r2 = await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    assert.equal(r2.data().sharing.stats, true);
  });

  it('stranger is denied whether or not the document exists (no existence oracle)', async () => {
    await assertFails(getDoc(spRef(t.db(caio), ana)));
    await seedShared(ana);
    await assertFails(getDoc(spRef(t.db(caio), ana)));
  });

  it('immediate revocation: ex-friend (pair deleted by either side) is denied on the next read', async () => {
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    await seedShared(ana);
    await t.seedFriendship(ana, bruno);
    await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    await assertSucceeds(deleteDoc(friendshipRef(t.db(ana), ana, bruno)));
    await assertFails(getDoc(spRef(t.db(bruno), ana)));
    // the other side removing also revokes
    await t.seedFriendship(ana, bruno);
    await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    await assertSucceeds(deleteDoc(friendshipRef(t.db(bruno), ana, bruno)));
    await assertFails(getDoc(spRef(t.db(bruno), ana)));
  });

  it('blocked in both directions: the real block batch revokes reading for both sides', async () => {
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    await seedShared(ana);
    await seedShared(bruno);
    await t.seedFriendship(ana, bruno);
    await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    // owner blocks the friend
    await assertSucceeds(blockBatch(t.db(ana), ana, bruno));
    await assertFails(getDoc(spRef(t.db(bruno), ana)));
    await assertFails(getDoc(spRef(t.db(ana), bruno)));
    // friend blocks the owner
    await t.seed((d) => deleteDoc(doc(d, 'users', ana, 'blocks', bruno)));
    await t.seedFriendship(ana, bruno);
    await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    await assertSucceeds(blockBatch(t.db(bruno), bruno, ana));
    await assertFails(getDoc(spRef(t.db(bruno), ana)));
    await assertFails(getDoc(spRef(t.db(ana), bruno)));
  });

  it('a block without friendship never grants reading (blocked user is not a friend)', async () => {
    await seedShared(ana);
    await t.seedBlock(ana, bruno);
    await t.seedBlock(bruno, ana);
    await assertFails(getDoc(spRef(t.db(bruno), ana)));
  });

  it('anonymous is denied (existing and non-existing)', async () => {
    await assertFails(getDoc(spRef(t.anon(), ana)));
    await seedShared(ana);
    await assertFails(getDoc(spRef(t.anon(), ana)));
  });

  it('friend signed in with a non-Google provider (or without the claim) is denied', async () => {
    await seedShared(ana);
    await t.seedFriendship(ana, bruno);
    await assertFails(getDoc(spRef(t.dbWith(bruno, 'password'), ana)));
    await assertFails(getDoc(spRef(t.dbWith(bruno, 'anonymous'), ana)));
    await assertFails(getDoc(spRef(t.dbNoClaim(bruno), ana)));
    await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
  });

  it('list is denied to everyone (owner, friend, stranger), including by document id', async () => {
    await seedShared(ana);
    await t.seedFriendship(ana, bruno);
    for (const d of [t.db(ana), t.db(bruno), t.db(caio)]) {
      await assertFails(getDocs(collection(d, 'shared_profiles')));
      await assertFails(getDocs(query(collection(d, 'shared_profiles'), where(documentId(), '==', ana))));
    }
    await assertFails(getDocs(collection(t.anon(), 'shared_profiles')));
  });

  it('sharing a profile never opens favorites: friend still denied on users/{uid}/favorites', async () => {
    await seedShared(ana);
    await t.seedFriendship(ana, bruno);
    await t.seedDoc(['users', ana, 'favorites', '1-movie'], {
      id: 1, mediaType: 'movie', title: 'x', addedAt: past(HOUR),
    });
    await assertFails(getDoc(doc(t.db(bruno), 'users', ana, 'favorites', '1-movie')));
    await assertFails(getDocs(collection(t.db(bruno), 'users', ana, 'favorites')));
  });
});

describe('shared_profiles: only the owner writes', () => {
  it('friend, stranger and anonymous cannot create, update or delete the owner\'s document', async () => {
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    await t.seedFriendship(ana, bruno);
    for (const d of [t.db(bruno), t.db(caio), t.anon()]) {
      await assertFails(setDoc(spRef(d, ana), createStats()));
    }
    assert.equal(await spExists(ana), false);
    await seedShared(ana);
    for (const d of [t.db(bruno), t.db(caio), t.anon()]) {
      await assertFails(updateDoc(spRef(d, ana), { tz: 0, updatedAt: st() }));
      await assertFails(setDoc(spRef(d, ana), createStats()));
      await assertFails(deleteDoc(spRef(d, ana)));
    }
    assert.equal(await spExists(ana), true);
  });
});

describe('shared_profiles: create', () => {
  it('each single section and the heaviest document (3 sections, 10 activities, 50 recs) are accepted', async () => {
    for (const data of [createStats(), createActivity(), createRecs(), createAll()]) {
      await env.clearFirestore();
      await okCreate(data);
    }
  });

  it('without social/{uid} (friendships off) is denied', async () => {
    await assertFails(setDoc(spRef(anaDb(), ana), createStats()));
    assert.equal(await spExists(ana), false);
  });

  it('non-Google provider or missing claim is denied', async () => {
    await t.seedSocial(ana);
    await assertFails(setDoc(spRef(t.dbWith(ana, 'password'), ana), createStats()));
    await assertFails(setDoc(spRef(t.dbNoClaim(ana), ana), createStats()));
    assert.equal(await spExists(ana), false);
  });

  it('uid outside the social format ("_") is denied even with social present', async () => {
    const odd = 'uid_odd';
    await t.seedDoc(['social', odd], { handle: 'odd', handleChangedAt: past(HOUR) });
    await assertFails(setDoc(spRef(t.db(odd), odd), createStats()));
  });

  it('creating someone else\'s document is denied (even when both have social)', async () => {
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    await assertFails(setDoc(spRef(anaDb(), bruno), createStats()));
  });
});

describe('shared_profiles: document schema (docs/82 §4.4, rows R)', () => {
  it('extra top-level field is denied', async () => {
    await badCreate(createStats({ extra: 1 }));
    await badCreate(createStats({ favorites: [] }));
  });

  for (const k of ['v', 'calc', 'updatedAt', 'tz', 'sharing']) {
    it(`missing required "${k}" is denied`, async () => {
      const d = createStats();
      delete d[k];
      await badCreate(d);
    });
  }

  it('v must be exactly 1', async () => {
    for (const v of [0, 2, '1', 1.5, null, true]) await badCreate(createStats({ v }));
  });

  it('calc: int >= 1 (higher versions accepted for forward compat)', async () => {
    for (const calc of [0, -1, 1.5, '1', null]) await badCreate(createStats({ calc }));
    await okCreate(createStats({ calc: 7 }));
  });

  it('updatedAt must be the server time: client timestamp or other types denied', async () => {
    await badCreate(createStats({ updatedAt: Timestamp.now() }));
    await badCreate(createStats({ updatedAt: past(HOUR) }));
    await badCreate(createStats({ updatedAt: 'now' }));
  });

  it('tz: int in -840..840', async () => {
    for (const tz of [-841, 841, 1.5, '0', null]) await badCreate(createStats({ tz }));
    for (const tz of [-840, 840, 0]) {
      await env.clearFirestore();
      await okCreate(createStats({ tz }));
    }
  });

  it('sharing: non-empty map of `true` with keys stats/activity/recs only', async () => {
    await badCreate(createStats({ sharing: {} }));
    await badCreate(createStats({ sharing: { stats: false } }));
    await badCreate(createStats({ sharing: { stats: 'yes' } }));
    await badCreate(createStats({ sharing: { stats: 1 } }));
    await badCreate(createStats({ sharing: { stats: true, foo: true } }));
    await badCreate(createStats({ sharing: ['stats'] }));
    await badCreate(createStats({ sharing: 'stats' }));
  });

  it('{} sharing with no section at all is denied (document exists only with >= 1 section)', async () => {
    const d = createStats({ sharing: {} });
    delete d.stats;
    await badCreate(d);
  });

  it('section present <=> consent present (stats, activity, recs, actSince)', async () => {
    // section without consent
    await badCreate(createStats({ recs: recs(1) }));
    await badCreate(createStats({ activity: [], actSince: st() }));
    await badCreate(createRecs({ stats: stats() }));
    // consent without section
    const noStats = createStats();
    delete noStats.stats;
    await badCreate(noStats);
    await badCreate(createStats({ sharing: { stats: true, recs: true } }));
    const noAct = createActivity();
    delete noAct.activity;
    await badCreate(noAct);
    // actSince <=> activity consent
    const noSince = createActivity();
    delete noSince.actSince;
    await badCreate(noSince);
    await badCreate(createStats({ actSince: st() }));
  });

  it('actSince must be the server time when it is written', async () => {
    await badCreate(createActivity({ actSince: past(HOUR) }));
    await badCreate(createActivity({ actSince: Timestamp.now() }));
  });
});

describe('shared_profiles: stats section', () => {
  it('extra key in stats or in total/month/year is denied', async () => {
    await badCreate(createStats({ stats: stats({ recommendations: 3 }) }));
    await badCreate(createStats({ stats: stats({ total: total({ x: 1 }) }) }));
    await badCreate(createStats({ stats: stats({ month: period('2026-10', { favorites: 1 }) }) }));
    await badCreate(createStats({ stats: stats({ year: period('2026', { other: 0 }) }) }));
  });

  it('minimal stats (optional counters and dates absent) is accepted', async () => {
    const r = Object.fromEntries(RANK.map((k) => [k, 0]));
    await okCreate(createStats({ stats: { total: r, year: { key: '2026', ...r }, month: { key: '2026-01', ...r } } }));
  });

  for (const slice of ['total', 'year', 'month']) {
    it(`missing "${slice}" is denied`, async () => {
      const s = stats();
      delete s[slice];
      await badCreate(createStats({ stats: s }));
    });
    it(`${slice} not a map is denied`, async () => {
      await badCreate(createStats({ stats: stats({ [slice]: [1, 2] }) }));
    });
    for (const m of RANK) {
      it(`${slice}.${m}: negative, missing, text and null are denied`, async () => {
        const mk = (v) => {
          const s = stats();
          s[slice] = { ...s[slice], [m]: v };
          if (v === undefined) delete s[slice][m];
          return createStats({ stats: s });
        };
        for (const v of [-1, undefined, '5', null]) await badCreate(mk(v));
        await env.clearFirestore();
        await okCreate(mk(0));
      });
    }
  }

  it('year.key: "20YY" only', async () => {
    for (const key of ['1999', '20266', '2O26', '26', 2026, null]) {
      await badCreate(createStats({ stats: stats({ year: period(key), month: period(`${key}-10`) }) }));
    }
  });

  it('month.key: "20YY-MM" (01..12) with the same year as year.key', async () => {
    for (const key of ['2026-00', '2026-13', '2026-1', '2026/10', '2026-10-01', '202610', 202610]) {
      await badCreate(createStats({ stats: stats({ month: period(key) }) }));
    }
    await badCreate(createStats({ stats: stats({ month: period('2025-10') }) }));
    for (const key of ['2026-01', '2026-12']) {
      await env.clearFirestore();
      await okCreate(createStats({ stats: stats({ month: period(key) }) }));
    }
  });
});

describe('shared_profiles: activity section', () => {
  it('10 items accepted, 11 denied', async () => {
    await okCreate(createActivity({ activity: acts(10, future(HOUR)) }));
    await env.clearFirestore();
    await badCreate(createActivity({ activity: acts(11, future(HOUR)) }));
  });

  for (let i = 0; i < 10; i++) {
    it(`item #${i} with at < actSince is denied (nothing before consent)`, async () => {
      const l = acts(10, future(HOUR));
      l[i] = act(past(HOUR));
      await badCreate(createActivity({ activity: l }));
    });
  }

  it('not a list, item without `at` or with a non-timestamp `at` is denied', async () => {
    await badCreate(createActivity({ activity: { 0: act(future(HOUR)) } }));
    const noAt = act(future(HOUR));
    delete noAt.at;
    await badCreate(createActivity({ activity: [noAt] }));
    await badCreate(createActivity({ activity: [act('2099-01-01')] }));
    await badCreate(createActivity({ activity: ['x'] }));
  });

  it('update: at == actSince accepted, at < actSince denied (stored actSince)', async () => {
    const since = past(2 * HOUR);
    await seedShared(ana, stored({ actSince: since }));
    await assertSucceeds(updateDoc(spRef(anaDb(), ana), { activity: [act(since)], updatedAt: st() }));
    await assertFails(updateDoc(spRef(anaDb(), ana), {
      activity: [act(past(3 * HOUR))], updatedAt: st(),
    }));
    await assertFails(updateDoc(spRef(anaDb(), ana), {
      activity: [...acts(9, past(HOUR)), act(past(3 * HOUR))], updatedAt: st(),
    }));
  });
});

describe('shared_profiles: recs section', () => {
  it('0..50 items accepted, 51 denied', async () => {
    await okCreate(createRecs({ recs: recs(0) }));
    await env.clearFirestore();
    await okCreate(createRecs({ recs: recs(50, 51) }));
    await env.clearFirestore();
    await badCreate(createRecs({ recs: recs(51) }));
  });

  it('count: int, >= items, <= 100000', async () => {
    await badCreate(createRecs({ recs: recs(2, 1) }));
    await badCreate(createRecs({ recs: recs(2, 100001) }));
    await badCreate(createRecs({ recs: recs(2, 2.5) }));
    await badCreate(createRecs({ recs: recs(2, '2') }));
    await okCreate(createRecs({ recs: recs(2, 100000) }));
  });

  it('closed shape: extra key, missing count/items, items not a list are denied', async () => {
    await badCreate(createRecs({ recs: { ...recs(1), more: true } }));
    await badCreate(createRecs({ recs: { count: 1 } }));
    await badCreate(createRecs({ recs: { items: [] } }));
    await badCreate(createRecs({ recs: { count: 1, items: { a: 1 } } }));
    await badCreate(createRecs({ recs: [1] }));
  });
});

describe('shared_profiles: update (recalculation, consent, stale device)', () => {
  it('recalculation (sections only) is accepted without social and without Google (0 rules calls)', async () => {
    await seedShared(ana);
    await assertSucceeds(updateDoc(spRef(t.dbWith(ana, 'password'), ana), {
      stats: stats({ total: total({ minutes: 20100 }) }), tz: -120, calc: 1, updatedAt: st(),
    }));
    await assertSucceeds(updateDoc(spRef(anaDb(), ana), {
      activity: acts(10, past(HOUR)), recs: recs(50, 60), updatedAt: st(),
    }));
  });

  it('every update must stamp updatedAt with the server time', async () => {
    await seedShared(ana);
    await assertFails(updateDoc(spRef(anaDb(), ana), { tz: 0 }));
    await assertFails(updateDoc(spRef(anaDb(), ana), { tz: 0, updatedAt: Timestamp.now() }));
    await assertSucceeds(updateDoc(spRef(anaDb(), ana), { updatedAt: st() })); // 24 h pulse
  });

  it('changed sections are revalidated (invalid stats/activity/recs denied on update)', async () => {
    await seedShared(ana);
    const d = anaDb();
    await assertFails(updateDoc(spRef(d, ana), { 'stats.total.minutes': -1, updatedAt: st() }));
    await assertFails(updateDoc(spRef(d, ana), { 'stats.month.key': '2025-10', updatedAt: st() }));
    await assertFails(updateDoc(spRef(d, ana), { activity: acts(11, past(HOUR)), updatedAt: st() }));
    await assertFails(updateDoc(spRef(d, ana), { recs: recs(51), updatedAt: st() }));
    await assertFails(updateDoc(spRef(d, ana), { recs: recs(3, 2), updatedAt: st() }));
    await assertFails(updateDoc(spRef(d, ana), { v: 2, updatedAt: st() }));
    await assertFails(updateDoc(spRef(d, ana), { tz: 900, updatedAt: st() }));
    await assertFails(updateDoc(spRef(d, ana), { extra: 1, updatedAt: st() }));
  });

  it('unchanged sections are not revalidated (only changed ones cost expressions)', async () => {
    // A stored section that the current rules would refuse (e.g. written by a future schema the
    // reader ignores) does not block a recalculation of ANOTHER section.
    await seedShared(ana, stored({ stats: stats({ total: total({ minutes: -5 }) }) }));
    await assertSucceeds(updateDoc(spRef(anaDb(), ana), { recs: recs(4), updatedAt: st() }));
  });

  for (const [sec, value] of [['stats', stats()], ['activity', acts(1, past(HOUR))], ['recs', recs(2)]]) {
    it(`stale device cannot republish "${sec}" turned off on another device`, async () => {
      const s = stored();
      delete s.sharing[sec];
      delete s[sec];
      if (sec === 'activity') delete s.actSince;
      await seedShared(ana, s);
      await t.seedSocial(ana);
      await assertFails(updateDoc(spRef(anaDb(), ana), { [sec]: value, updatedAt: st() }));
      const after = (await getDoc(spRef(anaDb(), ana))).data();
      assert.equal(sec in after, false);
    });
  }

  it('changing consent (turn on recs) needs social + Google; same payload denied without them', async () => {
    const s = stored();
    delete s.sharing.recs;
    delete s.recs;
    await seedShared(ana, s);
    const turnOn = { 'sharing.recs': true, recs: recs(2), updatedAt: st() };
    await assertFails(updateDoc(spRef(anaDb(), ana), turnOn)); // no social
    await t.seedSocial(ana);
    await assertFails(updateDoc(spRef(t.dbWith(ana, 'password'), ana), turnOn));
    await assertSucceeds(updateDoc(spRef(anaDb(), ana), turnOn));
  });

  it('changing consent (turn off stats) needs social; removes the section with the consent', async () => {
    await seedShared(ana);
    const turnOff = { 'sharing.stats': deleteField(), stats: deleteField(), updatedAt: st() };
    await assertFails(updateDoc(spRef(anaDb(), ana), turnOff));
    await assertFails(updateDoc(spRef(anaDb(), ana), { 'sharing.stats': deleteField(), updatedAt: st() }));
    await t.seedSocial(ana);
    await assertFails(updateDoc(spRef(anaDb(), ana), { stats: deleteField(), updatedAt: st() }));
    await assertSucceeds(updateDoc(spRef(anaDb(), ana), turnOff));
  });

  it('turning activity off and on again: new actSince (server time) and empty list', async () => {
    await seedShared(ana);
    await t.seedSocial(ana);
    const d = anaDb();
    await assertSucceeds(updateDoc(spRef(d, ana), {
      'sharing.activity': deleteField(), activity: deleteField(), actSince: deleteField(), updatedAt: st(),
    }));
    await assertFails(updateDoc(spRef(d, ana), {
      'sharing.activity': true, activity: [], actSince: past(HOUR), updatedAt: st(),
    }));
    await assertSucceeds(updateDoc(spRef(d, ana), {
      'sharing.activity': true, activity: [], actSince: st(), updatedAt: st(),
    }));
  });

  it('a new actSince never keeps items from before it (activity revalidated when actSince changes)', async () => {
    await seedShared(ana); // 3 items 1 h ago, actSince 48 h ago
    await t.seedSocial(ana);
    await assertFails(updateDoc(spRef(anaDb(), ana), { actSince: st(), updatedAt: st() }));
    await assertSucceeds(updateDoc(spRef(anaDb(), ana), { actSince: st(), activity: [], updatedAt: st() }));
  });

  it('changing only actSince needs social (it is a consent change)', async () => {
    await seedShared(ana, stored({ activity: [] }));
    await assertFails(updateDoc(spRef(anaDb(), ana), { actSince: st(), updatedAt: st() }));
    await t.seedSocial(ana);
    await assertSucceeds(updateDoc(spRef(anaDb(), ana), { actSince: st(), updatedAt: st() }));
  });
});

describe('shared_profiles: delete', () => {
  it('owner deletes (with or without social, any provider; deleting a missing doc is ok)', async () => {
    await assertSucceeds(deleteDoc(spRef(anaDb(), ana)));
    await seedShared(ana);
    await assertSucceeds(deleteDoc(spRef(t.dbWith(ana, 'password'), ana)));
    assert.equal(await spExists(ana), false);
  });

  it('after the owner deletes, a friend reads "does not exist"', async () => {
    await seedShared(ana);
    await t.seedFriendship(ana, bruno);
    await assertSucceeds(deleteDoc(spRef(anaDb(), ana)));
    const r = await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    assert.equal(r.exists(), false);
  });
});
