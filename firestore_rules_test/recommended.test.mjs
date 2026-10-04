// Security Rules tests for the `recommended` field ("Minhas recomendações",
// docs/36 R.3, cases T1 to T14). Same emulator as the main suite:
//   cd firestore_rules_test && npm install && npm test
// Two rule sets are exercised: the current `firestore.rules` and the previous
// version kept in fixtures/firestore.rules.v1 (what production runs until the
// Manager publishes the new rules). T14 is the existing suite
// (firestore.rules.test.mjs), which must stay green without edits.
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  Timestamp,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
  updateDoc,
  writeBatch,
} from 'firebase/firestore';

const RULES_NEW = new URL('../firestore.rules', import.meta.url);
const RULES_V1 = new URL('./fixtures/firestore.rules.v1', import.meta.url);

const T0 = Timestamp.fromDate(new Date('2026-01-01T00:00:00Z'));
const LATER = Timestamp.fromDate(new Date('2026-06-01T00:00:00Z'));

const validFavorite = (overrides = {}) => ({
  id: 42,
  mediaType: 'tv',
  title: 'A Show',
  posterPath: null,
  overview: 'o',
  addedAt: T0,
  lastWatchedAt: null,
  watchedMovie: false,
  seasonSummaries: [{ seasonNumber: 1, name: 'S1', episodeCount: 3 }],
  eps: {},
  ...overrides,
});

function suite(name, rulesUrl, v1) {
  describe(name, () => {
    let env;
    before(async () => {
      env = await initializeTestEnvironment({
        projectId: 'demo-cinetrack',
        firestore: { rules: readFileSync(rulesUrl, 'utf8') },
      });
    });
    after(async () => env?.cleanup());
    beforeEach(async () => env.clearFirestore());

    const ana = () => env.authenticatedContext('uid-ana').firestore();
    const bruno = () => env.authenticatedContext('uid-bruno').firestore();
    const anon = () => env.unauthenticatedContext().firestore();
    const fav = (db, uid, key) => doc(db, 'users', uid, 'favorites', key);
    const seed = (uid, key, data) =>
      env.withSecurityRulesDisabled((ctx) => setDoc(fav(ctx.firestore(), uid, key), data));
    // `new` = accepted by the new rules; v1 = accepted only when [okOnV1].
    const check = (okOnV1) => (v1 && !okOnV1 ? assertFails : assertSucceeds);

    it('T1 create without recommended (exact shape of today\'s add) is accepted', async () => {
      await assertSucceeds(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({
        updatedAt: serverTimestamp(),
      })));
    });

    it('T2 create with recommended:true (add and recommend)', async () => {
      await check(false)(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({
        recommended: true,
        updatedAt: serverTimestamp(),
      })));
    });

    it('T3 legacy doc: progress updates by field path are accepted', async () => {
      await seed('uid-ana', '42-tv', validFavorite());
      const ref = fav(ana(), 'uid-ana', '42-tv');
      await assertSucceeds(updateDoc(ref, {
        'eps.1_1': true,
        lastWatchedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }));
      await assertSucceeds(updateDoc(ref, { watchedMovie: true, updatedAt: serverTimestamp() }));
      await assertSucceeds(updateDoc(ref, { 'eps.1_1': deleteField(), updatedAt: serverTimestamp() }));
      await assertSucceeds(updateDoc(ref, {
        seasonSummaries: [{ seasonNumber: 1, name: 'S1', episodeCount: 4 }],
        updatedAt: serverTimestamp(),
      }));
    });

    it('T4 update({recommended:true, updatedAt})', async () => {
      await seed('uid-ana', '42-tv', validFavorite({ eps: { '1_1': true } }));
      await check(false)(updateDoc(fav(ana(), 'uid-ana', '42-tv'), {
        recommended: true,
        updatedAt: serverTimestamp(),
      }));
    });

    it('T5 update({recommended: deleteField()}) is accepted (also by v1)', async () => {
      await seed('uid-ana', '42-tv', validFavorite());
      await assertSucceeds(updateDoc(fav(ana(), 'uid-ana', '42-tv'), {
        recommended: deleteField(),
        updatedAt: serverTimestamp(),
      }));
    });

    it('T6 recommended:false is tolerated by the new rules (bool), refused by v1', async () => {
      await seed('uid-ana', '42-tv', validFavorite());
      await check(false)(updateDoc(fav(ana(), 'uid-ana', '42-tv'), { recommended: false }));
    });

    it('T7 recommended with a non-bool value is refused', async () => {
      await seed('uid-ana', '42-tv', validFavorite());
      for (const bad of ['sim', 1, null, {}, []]) {
        await assertFails(updateDoc(fav(ana(), 'uid-ana', '42-tv'), { recommended: bad }));
        await assertFails(setDoc(fav(ana(), 'uid-ana', '43-tv'), validFavorite({ id: 43, recommended: bad })));
      }
    });

    it('T8 unknown field names are refused', async () => {
      await seed('uid-ana', '42-tv', validFavorite());
      for (const f of ['recomended', 'loved', 'shared', 'public']) {
        await assertFails(updateDoc(fav(ana(), 'uid-ana', '42-tv'), { [f]: true }));
        await assertFails(setDoc(fav(ana(), 'uid-ana', '43-tv'), validFavorite({ id: 43, [f]: true })));
      }
    });

    it('T9 doc with recommended:true: progress update (v1 refuses: rules must never go back)', async () => {
      await seed('uid-ana', '42-tv', validFavorite({ recommended: true }));
      await check(false)(updateDoc(fav(ana(), 'uid-ana', '42-tv'), {
        'eps.1_1': true,
        lastWatchedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }));
    });

    it('T9b doc with recommended:true: un-recommending still works under v1 (contingency)', async () => {
      await seed('uid-ana', '42-tv', validFavorite({ recommended: true }));
      // v1 validates the resulting doc, which has no `recommended` any more.
      await assertSucceeds(updateDoc(fav(ana(), 'uid-ana', '42-tv'), {
        recommended: deleteField(),
      }));
    });

    it('T10 clobber: full set without recommended and a newer addedAt is refused', async () => {
      await seed('uid-ana', '42-tv', validFavorite({ recommended: true, eps: { '1_1': true } }));
      await assertFails(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({
        addedAt: LATER,
        updatedAt: serverTimestamp(),
      })));
    });

    it('T11 residual (documented): same full set with addedAt <= existing overwrites', async () => {
      await seed('uid-ana', '42-tv', validFavorite({ recommended: true, eps: { '1_1': true } }));
      // Under v1 the existing doc is out of its schema only for update's resulting
      // data, which has no `recommended`: accepted as well.
      await assertSucceeds(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite()));
    });

    it('T12 privacy: other users and anonymous cannot read or write recommended', async () => {
      await seed('uid-ana', '42-tv', validFavorite({ recommended: true }));
      const key = '42-tv';
      for (const db of [bruno(), anon()]) {
        await assertFails(getDoc(fav(db, 'uid-ana', key)));
        await assertFails(getDocs(collection(db, 'users', 'uid-ana', 'favorites')));
        await assertFails(updateDoc(fav(db, 'uid-ana', key), { recommended: true }));
        await assertFails(updateDoc(fav(db, 'uid-ana', key), { recommended: deleteField() }));
        await assertFails(setDoc(fav(db, 'uid-ana', '43-tv'), validFavorite({ id: 43, recommended: true })));
        await assertFails(deleteDoc(fav(db, 'uid-ana', key)));
      }
    });

    it('T13 owner deletes a recommended doc; account deletion batch of 400 works', async () => {
      await seed('uid-ana', '42-tv', validFavorite({ recommended: true }));
      await assertSucceeds(deleteDoc(fav(ana(), 'uid-ana', '42-tv')));

      await env.withSecurityRulesDisabled(async (ctx) => {
        const batch = writeBatch(ctx.firestore());
        for (let i = 1; i <= 400; i++) {
          batch.set(fav(ctx.firestore(), 'uid-ana', `${i}-movie`), validFavorite({
            id: i,
            mediaType: 'movie',
            ...(i % 2 === 0 ? { recommended: true } : {}),
          }));
        }
        await batch.commit();
      });
      const db = ana();
      const batch = writeBatch(db);
      for (let i = 1; i <= 400; i++) batch.delete(fav(db, 'uid-ana', `${i}-movie`));
      await assertSucceeds(batch.commit());
    });
  });
}

suite('new rules (firestore.rules)', RULES_NEW, false);
suite('previous rules v1 (fixtures/firestore.rules.v1: app new x rules old)', RULES_V1, true);
