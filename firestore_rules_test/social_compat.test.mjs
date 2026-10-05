// Compatibility (docs/51): (1) NEW rules x documents written by the OLD app (legacy fixtures),
// (2) NEW app x OLD rules (fixtures/firestore.rules.v1 and v2): social operations are denied
// (the app shows "Amizades ainda nao estao disponiveis"), legacy operations keep working.
// The existing suites (firestore.rules.test.mjs, recommended.test.mjs) run unchanged against the
// new rules with `npm test`.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  Timestamp, collection, deleteDoc, doc, getDoc, getDocs, setDoc, updateDoc,
} from 'firebase/firestore';
import {
  CODE, RULES_URL, U, acceptBatch, activate, cardData, commit, friendshipData, friendshipRef,
  inviteData, makeTools, newEnv, requestData, requestRef, socialData, st,
} from './social_helpers.mjs';

const V1 = new URL('./fixtures/firestore.rules.v1', import.meta.url);
const V2 = new URL('./fixtures/firestore.rules.v2', import.meta.url);
const { ana, bruno, caio } = U;

const legacyUser = { displayName: 'Ana' }; // no schemaVersion, no updatedAt (oldest app)
const legacyFav = (id, extra = {}) => ({
  id, mediaType: 'movie', title: `Filme ${id}`, addedAt: Timestamp.fromDate(new Date('2025-01-01T00:00:00Z')), ...extra,
});

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
      });
    }
  });
}

suite('NEW rules x documents/operations of the old app', RULES_URL, true);
suite('OLD rules v2 (main before social) x new app', V2, false);
suite('OLD rules v1 (before "recommended") x new app', V1, false);
