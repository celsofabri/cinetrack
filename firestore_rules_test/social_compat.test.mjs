// Compatibility (docs/51): (1) NEW rules x documents written by the OLD app (legacy fixtures),
// (2) NEW app x OLD rules (fixtures/firestore.rules.v1, v2 and v3): social operations are denied
// (v1/v2) and Phase 2 operations (shared_profiles, favorites.epsAt) are denied with no side effect
// (v1/v2/v3)
// (the app shows "Amizades ainda nao estao disponiveis"), legacy operations keep working.
// The existing suites (firestore.rules.test.mjs, recommended.test.mjs) run unchanged against the
// new rules with `npm test`.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  Timestamp, collection, deleteDoc, deleteField, doc, getDoc, getDocs, setDoc, updateDoc,
} from 'firebase/firestore';
import {
  CODE, RULES_URL, U, acceptBatch, activate, cardData, commit, friendshipData, friendshipRef,
  inviteData, makeTools, newEnv, requestData, requestRef, socialData, st,
} from './social_helpers.mjs';
import { createAll, createStats, spRef, stored as storedShared } from './shared_profile_helpers.mjs';

const V1 = new URL('./fixtures/firestore.rules.v1', import.meta.url);
const V2 = new URL('./fixtures/firestore.rules.v2', import.meta.url);
const V3 = new URL('./fixtures/firestore.rules.v3', import.meta.url); // production (main 9c57327)
const { ana, bruno, caio } = U;

const legacyUser = { displayName: 'Ana' }; // no schemaVersion, no updatedAt (oldest app)
const legacyFav = (id, extra = {}) => ({
  id, mediaType: 'movie', title: `Filme ${id}`, addedAt: Timestamp.fromDate(new Date('2025-01-01T00:00:00Z')), ...extra,
});

// NEW app (Phase 2) x rules without Phase 2: the rules probe (owner get of shared_profiles) is
// denied, toggles are denied, and a favorite update carrying epsAt is denied ATOMICALLY (the
// episode is NOT marked). That is why the app only sends epsAt after the probe (docs/82 §4.2).
async function phase2DeniedNoSideEffect(t, env) {
  const d = t.db(ana);
  await assertFails(getDoc(spRef(d, ana)));
  await assertFails(setDoc(spRef(d, ana), createStats()));
  await assertFails(setDoc(spRef(d, ana), createAll()));
  await t.seed(async (x) => assert.equal((await getDoc(doc(x, 'shared_profiles', ana))).exists(), false));
  await t.seedDoc(['users', ana, 'favorites', '2-tv'], { ...legacyFav(2), mediaType: 'tv', eps: {} });
  await assertFails(updateDoc(doc(d, 'users', ana, 'favorites', '2-tv'), {
    'eps.1_1': true, 'epsAt.1_1': Timestamp.now(), lastWatchedAt: st(), updatedAt: st(),
  }));
  await assertFails(setDoc(doc(d, 'users', ana, 'favorites', '3-tv'), {
    ...legacyFav(3), mediaType: 'tv', eps: {}, epsAt: {},
  }));
  const after = (await getDoc(doc(d, 'users', ana, 'favorites', '2-tv'))).data();
  assert.deepEqual(after.eps, {}, 'denied write must not mark the episode');
  assert.equal('epsAt' in after, false);
  assert.equal((await getDoc(doc(d, 'users', ana, 'favorites', '3-tv'))).exists(), false);
  // without epsAt (probe said "old rules") the same marking works
  await assertSucceeds(updateDoc(doc(d, 'users', ana, 'favorites', '2-tv'), {
    'eps.1_1': true, lastWatchedAt: st(), updatedAt: st(),
  }));
}

function suite(name, rulesUrl, social) {
  describe(name, () => {
    let env;
    let t;
    before(async () => {
      env = await newEnv(readFileSync(rulesUrl, 'utf8'));
      t = makeTools(env);
    });
    after(async () => env?.cleanup());
    beforeEach(async () => env.clearFirestore());

    it('legacy documents (no new fields) keep working for the owner', async () => {
      await t.seedDoc(['users', ana], legacyUser);
      await t.seedDoc(['users', ana, 'favorites', '1-movie'], legacyFav(1));
      await t.seedDoc(['users', ana, 'favorites', '2-tv'], {
        ...legacyFav(2), mediaType: 'tv', eps: { '1_1': true }, seasonSummaries: [], recommended: true,
      });
      const d = t.db(ana);
      await assertSucceeds(getDoc(doc(d, 'users', ana)));
      await assertSucceeds(getDocs(collection(d, 'users', ana, 'favorites')));
      await assertSucceeds(updateDoc(doc(d, 'users', ana), { displayName: 'Ana B', schemaVersion: 1, updatedAt: st() }));
      await assertSucceeds(setDoc(doc(d, 'users', ana, 'favorites', '1-movie'), legacyFav(1, { watchedMovie: true })));
      await assertSucceeds(setDoc(doc(d, 'users', ana, 'favorites', '3-movie'), legacyFav(3)));
      await assertSucceeds(deleteDoc(doc(d, 'users', ana, 'favorites', '3-movie')));
      await assertSucceeds(deleteDoc(doc(d, 'users', ana)));
    });

    it('nobody else reads legacy data: stranger, anonymous (and, under new rules, friend/blocked/inviter)', async () => {
      await t.seedDoc(['users', ana], legacyUser);
      await t.seedDoc(['users', ana, 'favorites', '1-movie'], legacyFav(1));
      await assertFails(getDoc(doc(t.db(caio), 'users', ana)));
      await assertFails(getDocs(collection(t.db(caio), 'users', ana, 'favorites')));
      await assertFails(getDoc(doc(t.anon(), 'users', ana, 'favorites', '1-movie')));
      if (social) {
        await t.seedSocial(ana, { inviteCode: CODE });
        await t.seedSocial(bruno);
        await t.seedFriendship(ana, bruno);
        await t.seedBlock(ana, caio);
        for (const u of [bruno, caio]) {
          const d = t.db(u);
          await assertFails(getDoc(doc(d, 'users', ana)));
          await assertFails(getDoc(doc(d, 'users', ana, 'favorites', '1-movie')));
          await assertFails(getDocs(collection(d, 'users', ana, 'favorites')));
          await assertFails(updateDoc(doc(d, 'users', ana, 'favorites', '1-movie'), { watchedMovie: true }));
          await assertFails(deleteDoc(doc(d, 'users', ana, 'favorites', '1-movie')));
          await assertFails(setDoc(doc(d, 'users', ana, 'favorites', '9-movie'), legacyFav(9)));
        }
        // the user document is closed to social fields (validProfile unchanged)
        await assertFails(setDoc(doc(t.db(ana), 'users', ana), { displayName: 'Ana', handle: 'x' }));
        await assertFails(setDoc(doc(t.db(ana), 'users', ana), { displayName: 'Ana', friends: [bruno] }));
        // no subcollection of users/{uid} other than favorites/blocks exists
        await assertFails(getDoc(doc(t.db(ana), 'users', ana, 'friends', bruno)));
        await assertFails(setDoc(doc(t.db(ana), 'users', ana, 'invites', 'x'), { a: 1 }));
      }
    });

    if (social) {
      it('social path works with legacy data present (activation does not touch users/*)', async () => {
        await t.seedDoc(['users', ana], legacyUser);
        await t.seedDoc(['users', ana, 'favorites', '1-movie'], legacyFav(1));
        await assertSucceeds(activate(t.db(ana), ana, 'ana_s'));
        assert.ok((await getDoc(doc(t.db(ana), 'users', ana, 'favorites', '1-movie'))).exists());
      });
    } else {
      it('NEW app x OLD rules: every social operation is denied; nothing is written', async () => {
        const d = t.db(ana);
        await assertFails(activate(d, ana, 'ana_s'));
        await assertFails(setDoc(doc(d, 'social', ana), socialData('ana_s')));
        await assertFails(setDoc(doc(d, 'handles', 'ana_s'), cardData(ana)));
        await assertFails(getDoc(doc(d, 'handles', 'ana_s')));
        await assertFails(setDoc(requestRef(d, ana, bruno), requestData(ana, bruno)));
        await assertFails(setDoc(friendshipRef(d, ana, bruno), friendshipData(ana, bruno)));
        await assertFails(acceptBatch(d, ana, bruno));
        await assertFails(setDoc(doc(d, 'users', ana, 'blocks', bruno), { createdAt: st() }));
        await assertFails(commit(d, (b) => {
          b.set(doc(d, 'invites', CODE), inviteData(ana));
          b.set(doc(d, 'social', ana), socialData('ana_s', { inviteCode: CODE }));
        }));
        await assertFails(getDoc(doc(d, 'invites', CODE)));
        assert.equal(await t.exists(['social', ana]), false);
        // ... and the legacy operations still work
        await assertSucceeds(setDoc(doc(d, 'users', ana), { displayName: 'Ana' }));
        await assertSucceeds(setDoc(doc(d, 'users', ana, 'favorites', '1-movie'), legacyFav(1)));
        await phase2DeniedNoSideEffect(t, env);
      });
    }
  });
}

suite('NEW rules x documents/operations of the old app', RULES_URL, true);
suite('OLD rules v2 (main before social) x new app', V2, false);
suite('OLD rules v1 (before "recommended") x new app', V1, false);

// Production rules (v3 = main 9c57327, Phase 1) x Phase 2 app: Phase 1 keeps working, Phase 2 is
// denied with no side effect. And NEW rules x documents/payloads written under v3 by the old app.
describe('OLD rules v3 (production, Phase 1) x Phase 2 app', () => {
  let env;
  let t;
  before(async () => {
    env = await newEnv(readFileSync(V3, 'utf8'));
    t = makeTools(env);
  });
  after(async () => env?.cleanup());
  beforeEach(async () => env.clearFirestore());

  it('Phase 1 social works; shared_profiles and epsAt are denied with no side effect', async () => {
    await assertSucceeds(activate(t.db(ana), ana, 'ana_s'));
    await t.seedSocial(bruno);
    await t.seedFriendship(ana, bruno);
    await t.seedDoc(['shared_profiles', ana], storedShared()); // even if a doc existed...
    await assertFails(getDoc(spRef(t.db(bruno), ana))); // ...no friend can read it under v3
    await env.clearFirestore();
    await t.seedSocial(ana);
    await phase2DeniedNoSideEffect(t, env);
  });
});

describe('NEW rules x data written by the production app (v3)', () => {
  let env;
  let t;
  before(async () => {
    env = await newEnv(readFileSync(RULES_URL, 'utf8'));
    t = makeTools(env);
  });
  after(async () => env?.cleanup());
  beforeEach(async () => env.clearFirestore());

  it('Phase 1 data + favorites without epsAt: every old-app operation still works; no shared doc appears', async () => {
    await t.seedSocial(ana);
    await t.seedSocial(bruno);
    await t.seedFriendship(ana, bruno);
    await t.seedDoc(['users', ana], legacyUser);
    await t.seedDoc(['users', ana, 'favorites', '2-tv'], {
      ...legacyFav(2), mediaType: 'tv', eps: { '1_1': true }, seasonSummaries: [], recommended: true,
    });
    const d = t.db(ana);
    await assertSucceeds(updateDoc(doc(d, 'users', ana, 'favorites', '2-tv'), {
      'eps.1_2': true, lastWatchedAt: st(), updatedAt: st(),
    }));
    await assertSucceeds(updateDoc(doc(d, 'users', ana, 'favorites', '2-tv'), {
      'eps.1_1': deleteField(), lastWatchedAt: st(), updatedAt: st(),
    }));
    await assertSucceeds(updateDoc(doc(d, 'users', ana, 'favorites', '2-tv'), { recommended: deleteField(), updatedAt: st() }));
    await assertSucceeds(deleteDoc(friendshipRef(d, ana, bruno)));
    // a friend never sees favorites; the shared profile does not exist until the owner opts in
    await t.seedFriendship(ana, bruno);
    await assertFails(getDocs(collection(t.db(bruno), 'users', ana, 'favorites')));
    const r = await assertSucceeds(getDoc(spRef(t.db(bruno), ana)));
    assert.equal(r.exists(), false);
  });
});
