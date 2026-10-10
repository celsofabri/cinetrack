// validFavorite + `epsAt` (Fase 2, docs/82 §4.2/§13). Additive field: every payload the current
// production app sends (lib/data/firestore_favorites_data_source.dart) must keep working, on
// documents with and without `epsAt`; favorites stay owner-only. Emulator only.
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  Timestamp, collection, deleteDoc, deleteField, doc, getDoc, getDocs, setDoc, updateDoc,
} from 'firebase/firestore';
import { U, makeTools, newEnv } from './social_helpers.mjs';
import { HOUR, past, st } from './shared_profile_helpers.mjs';

const { ana, bruno, caio } = U;
let env;
let t;
before(async () => {
  env = await newEnv();
  t = makeTools(env);
});
after(async () => env?.cleanup());
beforeEach(async () => env.clearFirestore());

const KEY = '1399-tv';
const fav = (d, uid = ana, key = KEY) => doc(d, 'users', uid, 'favorites', key);
// Exactly what FirestoreFavoritesDataSource.add() sends today (FavoriteMapper.toMap + 3 fields).
const addPayload = (o = {}) => ({
  id: 1399, mediaType: 'tv', title: 'Serie X', posterPath: '/abc.jpg', overview: 'o',
  addedAt: Timestamp.fromDate(new Date('2026-01-01T00:00:00Z')),
  watchedMovie: false, seasonSummaries: [{ seasonNumber: 1, name: 'S1', episodeCount: 3 }],
  eps: {}, lastWatchedAt: null, updatedAt: st(), ...o,
});
const stored = (o = {}) => ({ ...addPayload(), updatedAt: past(HOUR), ...o });
const epsMap = (n, v) => Object.fromEntries(Array.from({ length: n }, (_, i) => [`1_${i + 1}`, v()]));
const at = () => Timestamp.fromDate(new Date('2026-10-12T21:30:00Z'));

// The 5 write shapes of the current app (main), applied to a document.
const oldAppWrites = async (d) => {
  await assertSucceeds(updateDoc(fav(d), { 'eps.1_1': true, 'eps.1_2': true, lastWatchedAt: st(), updatedAt: st() }));
  await assertSucceeds(updateDoc(fav(d), { 'eps.1_2': deleteField(), lastWatchedAt: st(), updatedAt: st() }));
  await assertSucceeds(updateDoc(fav(d), { watchedMovie: true, lastWatchedAt: st(), updatedAt: st() }));
  await assertSucceeds(updateDoc(fav(d), {
    seasonSummaries: [{ seasonNumber: 1, name: 'S1', episodeCount: 4 }], updatedAt: st(),
  }));
  await assertSucceeds(updateDoc(fav(d), { recommended: true, updatedAt: st() }));
  await assertSucceeds(updateDoc(fav(d), { recommended: deleteField(), updatedAt: st() }));
};

describe('favorites: payloads of the current app are unchanged (epsAt absent)', () => {
  it('add (set), every update shape, delete', async () => {
    const d = t.db(ana);
    await assertSucceeds(setDoc(fav(d), addPayload()));
    await oldAppWrites(d);
    await assertSucceeds(deleteDoc(fav(d)));
  });

  it('old app writing to a document that already has epsAt (written by the new app)', async () => {
    await t.seedDoc(['users', ana, 'favorites', KEY], stored({ eps: { '1_1': true }, epsAt: { '1_1': at() } }));
    const d = t.db(ana);
    await oldAppWrites(d);
    // old app unmarks eps.1_1 and leaves an orphan epsAt.1_1 (allowed; the new app ignores it)
    await assertSucceeds(updateDoc(fav(d), { 'eps.1_1': deleteField(), lastWatchedAt: st(), updatedAt: st() }));
    const data = (await getDoc(fav(d))).data();
    assert.equal('1_1' in data.eps, false);
    assert.equal('1_1' in data.epsAt, true);
    // the old app's add (set) replaces the document, dropping epsAt: still accepted
    await assertSucceeds(setDoc(fav(d), addPayload()));
    await assertSucceeds(deleteDoc(fav(d)));
  });
});

describe('favorites: epsAt (new field)', () => {
  it('setEpisodes with epsAt in the same update (mark, unmark, orphan cleanup) is accepted', async () => {
    await t.seedDoc(['users', ana, 'favorites', KEY], stored());
    const d = t.db(ana);
    await assertSucceeds(updateDoc(fav(d), {
      'eps.1_1': true, 'epsAt.1_1': at(), 'eps.1_3': true, 'epsAt.1_3': at(), lastWatchedAt: st(), updatedAt: st(),
    }));
    await assertSucceeds(updateDoc(fav(d), {
      'eps.1_3': deleteField(), 'epsAt.1_3': deleteField(), lastWatchedAt: st(), updatedAt: st(),
    }));
    await assertSucceeds(updateDoc(fav(d), { 'eps.1_2': true, 'epsAt.1_2': at(), 'epsAt.9_9': deleteField(), lastWatchedAt: st(), updatedAt: st() }));
    const data = (await getDoc(fav(d))).data();
    assert.deepEqual(Object.keys(data.epsAt).sort(), ['1_1', '1_2']);
  });

  it('absent, empty map and exactly 5000 entries are accepted (create and update)', async () => {
    const d = t.db(ana);
    await assertSucceeds(setDoc(fav(d), addPayload({ epsAt: {} })));
    await assertSucceeds(setDoc(fav(d, ana, '2-tv'), addPayload({ id: 2, eps: epsMap(5000, () => true), epsAt: epsMap(5000, at) })));
    await assertSucceeds(updateDoc(fav(d), { eps: epsMap(5000, () => true), epsAt: epsMap(5000, at), updatedAt: st() }));
  });

  it('5001 entries are denied (create, and an update that grows it past 5000)', async () => {
    const d = t.db(ana);
    await assertFails(setDoc(fav(d), addPayload({ epsAt: epsMap(5001, at) })));
    await t.seedDoc(['users', ana, 'favorites', KEY], stored({ epsAt: epsMap(5000, at) }));
    await assertFails(updateDoc(fav(d), { 'epsAt.9_9': at(), updatedAt: st() }));
    assert.equal(Object.keys((await getDoc(fav(d))).data().epsAt).length, 5000);
  });

  it('epsAt that is not a map is denied', async () => {
    const d = t.db(ana);
    for (const epsAt of [[at()], 'x', true, 1, at(), null]) {
      await assertFails(setDoc(fav(d), addPayload({ epsAt })));
    }
    await t.seedDoc(['users', ana, 'favorites', KEY], stored());
    await assertFails(updateDoc(fav(d), { epsAt: [at()], updatedAt: st() }));
    await assertFails(updateDoc(fav(d), { epsAt: null, updatedAt: st() }));
  });

  it('a similar but unknown field (epsAtX / eps_at) is still denied (hasOnly stays closed)', async () => {
    const d = t.db(ana);
    await assertFails(setDoc(fav(d), addPayload({ epsAtX: {} })));
    await assertFails(setDoc(fav(d), addPayload({ eps_at: {} })));
  });

  it('epsAt never opens favorites: friend, stranger, anonymous cannot read or write it', async () => {
    await t.seedFriendship(ana, bruno);
    await t.seedDoc(['users', ana, 'favorites', KEY], stored({ epsAt: { '1_1': at() } }));
    for (const d of [t.db(bruno), t.db(caio), t.anon()]) {
      await assertFails(getDoc(fav(d)));
      await assertFails(getDocs(collection(d, 'users', ana, 'favorites')));
      await assertFails(updateDoc(fav(d), { 'epsAt.1_2': at(), updatedAt: st() }));
      await assertFails(deleteDoc(fav(d)));
    }
  });
});
