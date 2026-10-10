// Adversarial shapes against the optimized type checks in shared_profiles (QA round 2, docs/84).
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { Timestamp, deleteField, getDoc, setDoc, updateDoc } from 'firebase/firestore';
import { U, makeTools, newEnv } from './social_helpers.mjs';
import { createRecs, createStats, period, recs, spRef, st, stats, stored, total } from './shared_profile_helpers.mjs';
const { ana } = U;
let env; let t;
before(async () => { env = await newEnv(); t = makeTools(env); });
after(async () => env?.cleanup());
beforeEach(async () => env.clearFirestore());
const bad = async (data) => {
  await t.seedSocial(ana);
  await assertFails(setDoc(spRef(t.db(ana), ana), data));
  await t.seed(async (d) => assert.equal((await getDoc(spRef(d, ana))).exists(), false));
};
const noKey = (p) => { const x = { ...p }; delete x.key; return x; };
describe('shared_profiles: wrong-type edge cases (optimized checks)', () => {
  it('A1 slice without key (year / month) denied', async () => {
    await bad(createStats({ stats: stats({ year: noKey(period('2026')) }) }));
    await bad(createStats({ stats: stats({ month: noKey(period('2026-10')) }) }));
  });
  it('A2 stats {} and stats with only total denied', async () => {
    await bad(createStats({ stats: {} }));
    await bad(createStats({ stats: { total: total() } }));
  });
  it('A3 recs shape edge cases denied', async () => {
    for (const r of [{}, { count: 1 }, { items: [] }, { count: 0, items: [], x: 1 }, { count: null, items: [] },
      { count: 0, items: null }, { count: 0, items: '' }, { count: 0, items: {} }, '', [], null]) {
      await bad(createRecs({ recs: r }));
    }
  });
  it('A4 update edge cases on stored doc denied', async () => {
    await t.seedDoc(['shared_profiles', ana], stored());
    await t.seedSocial(ana);
    const d = t.db(ana);
    for (const u of [
      { 'stats.year.key': deleteField() }, { 'stats.month.key': 202610 }, { 'stats.month.key': ['2026-10'] },
      { 'stats.total': [] }, { 'stats.year': null }, { activity: null }, { recs: null },
      { 'recs.items': deleteField() }, { 'recs.count': deleteField() }, { 'recs.items': {} },
      { 'stats.year.key': '2026', 'stats.month.key': '2027-01' }, { stats: {} },
    ]) {
      await assertFails(updateDoc(spRef(d, ana), { ...u, updatedAt: st() }));
    }
    const after = (await getDoc(spRef(d, ana))).data();
    assert.equal(after.stats.year.key, '2026');
    assert.equal(after.recs.items.length, 3);
  });
  it('A5 positive control: valid recalculation still accepted', async () => {
    await t.seedDoc(['shared_profiles', ana], stored());
    await assertSucceeds(updateDoc(spRef(t.db(ana), ana), { stats: stats({ total: total({ minutes: 1 }) }), recs: recs(0), updatedAt: st() }));
  });
});
