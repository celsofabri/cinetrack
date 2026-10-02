// Security Rules tests. They need the Firestore Emulator (see README):
//   cd firestore_rules_test && npm install && npm test
// `npm test` starts the emulator, runs these tests and stops it. They never
// touch a real Firebase project (project id "demo-cinetrack" is emulator-only).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { deleteDoc, deleteField, serverTimestamp, doc, getDoc, getDocs, collection, setDoc, updateDoc, writeBatch, Timestamp, query, limit } from 'firebase/firestore';

const RULES = new URL('../firestore.rules', import.meta.url);
let env;

const validFavorite = (overrides = {}) => ({
  id: 42,
  mediaType: 'tv',
  title: 'A Show',
  posterPath: null,
  overview: 'o',
  addedAt: Timestamp.fromDate(new Date('2026-01-01T00:00:00Z')),
  lastWatchedAt: null,
  watchedMovie: false,
  seasonSummaries: [{ seasonNumber: 1, name: 'S1', episodeCount: 3 }],
  eps: {},
  ...overrides,
});

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-cinetrack',
    firestore: { rules: readFileSync(RULES, 'utf8') },
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

describe('isolation between users', () => {
  it('owner can create and read own favorite', async () => {
    await assertSucceeds(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite()));
    await assertSucceeds(getDoc(fav(ana(), 'uid-ana', '42-tv')));
  });

  it('user B cannot read or write user A data', async () => {
    await seed('uid-ana', '42-tv', validFavorite());
    await assertFails(getDoc(fav(bruno(), 'uid-ana', '42-tv')));
    await assertFails(getDocs(collection(bruno(), 'users', 'uid-ana', 'favorites')));
    await assertFails(setDoc(fav(bruno(), 'uid-ana', '43-tv'), validFavorite({ id: 43 })));
    await assertFails(updateDoc(fav(bruno(), 'uid-ana', '42-tv'), { watchedMovie: true }));
    await assertFails(updateDoc(fav(bruno(), 'uid-ana', '42-tv'), { 'eps.1_1': true }));
  });

  it('user B cannot delete user A favorite', async () => {
    await seed('uid-ana', '42-tv', validFavorite());
    const { deleteDoc } = await import('firebase/firestore');
    await assertFails(deleteDoc(fav(bruno(), 'uid-ana', '42-tv')));
  });

  it('unauthenticated requests are denied', async () => {
    await seed('uid-ana', '42-tv', validFavorite());
    await assertFails(getDoc(fav(anon(), 'uid-ana', '42-tv')));
    await assertFails(setDoc(fav(anon(), 'uid-ana', '43-tv'), validFavorite({ id: 43 })));
  });

  it('anything outside users/{uid} is denied', async () => {
    await assertFails(setDoc(doc(ana(), 'other', 'x'), { a: 1 }));
    await assertFails(setDoc(doc(ana(), 'users', 'uid-ana', 'secrets', 'x'), { a: 1 }));
  });
});

describe('favorite schema validation', () => {
  it('rejects invalid keys', async () => {
    await assertFails(setDoc(fav(ana(), 'uid-ana', 'abc'), validFavorite()));
    await assertFails(setDoc(fav(ana(), 'uid-ana', '42-person'), validFavorite()));
  });

  it('rejects id/mediaType that do not match the key', async () => {
    await assertFails(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({ id: 99 })));
    await assertFails(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({ mediaType: 'movie' })));
  });

  it('rejects unknown (extra) fields', async () => {
    await assertFails(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({ email: 'x@example.test' })));
  });

  it('rejects missing required fields and wrong types', async () => {
    const { title, ...noTitle } = validFavorite();
    await assertFails(setDoc(fav(ana(), 'uid-ana', '42-tv'), noTitle));
    await assertFails(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({ addedAt: 'yesterday' })));
    await assertFails(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({ watchedMovie: 'yes' })));
  });

  it('rejects oversized title', async () => {
    await assertFails(setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({ title: 'x'.repeat(301) })));
  });
});

describe('favorite schema validation: eps, seasonSummaries, updatedAt, sizes', () => {
  const bigEps = (n) => Object.fromEntries(Array.from({ length: n }, (_, i) => [`1_${i}`, true]));
  const create = (overrides) => setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite(overrides));

  it('eps: accepts up to 5000 entries, rejects more or a non-map', async () => {
    await assertSucceeds(create({ eps: bigEps(5000) }));
    await assertFails(create({ eps: bigEps(5001) }));
    await assertFails(create({ eps: [true] }));
    await assertFails(create({ eps: 'x' }));
  });

  it('seasonSummaries: accepts up to 100 items, rejects more or a non-list', async () => {
    const list = (n) => Array.from({ length: n }, (_, i) => ({ seasonNumber: i, name: 'S', episodeCount: 1 }));
    await assertSucceeds(create({ seasonSummaries: list(100) }));
    await assertFails(create({ seasonSummaries: list(101) }));
    await assertFails(create({ seasonSummaries: { a: 1 } }));
  });

  it('updatedAt must be a timestamp (create and update)', async () => {
    await assertFails(create({ updatedAt: 'now' }));
    await assertFails(create({ updatedAt: 123 }));
    await assertSucceeds(create({ updatedAt: serverTimestamp() }));
    await assertFails(updateDoc(fav(ana(), 'uid-ana', '42-tv'), { updatedAt: 'now' }));
    await assertSucceeds(updateDoc(fav(ana(), 'uid-ana', '42-tv'), { updatedAt: serverTimestamp() }));
  });

  it('lastWatchedAt must be null or a timestamp', async () => {
    await assertFails(create({ lastWatchedAt: 'yesterday' }));
    await assertSucceeds(create({ lastWatchedAt: serverTimestamp() }));
  });

  it('rejects oversized overview and posterPath', async () => {
    await assertFails(create({ overview: 'x'.repeat(4001) }));
    await assertFails(create({ posterPath: '/' + 'x'.repeat(200) }));
  });

  it('update that makes eps oversized is rejected', async () => {
    await seed('uid-ana', '42-tv', validFavorite({ eps: bigEps(5000) }));
    await assertFails(updateDoc(fav(ana(), 'uid-ana', '42-tv'), { 'eps.9_9': true }));
  });
});

describe('progress updates (merge by field)', () => {
  it('marks and unmarks an episode by field path', async () => {
    await seed('uid-ana', '42-tv', validFavorite());
    await assertSucceeds(updateDoc(fav(ana(), 'uid-ana', '42-tv'), { 'eps.1_2': true }));
    await assertSucceeds(updateDoc(fav(ana(), 'uid-ana', '42-tv'), { 'eps.1_2': deleteField() }));
  });

  it('accepts the exact write shapes the app sends (server timestamps)', async () => {
    await assertSucceeds(
      setDoc(fav(ana(), 'uid-ana', '42-tv'), validFavorite({ updatedAt: serverTimestamp() })),
    );
    await assertSucceeds(
      updateDoc(fav(ana(), 'uid-ana', '42-tv'), {
        'eps.1_1': true,
        'eps.1_2': deleteField(),
        lastWatchedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      updateDoc(fav(ana(), 'uid-ana', '42-tv'), {
        seasonSummaries: [{ seasonNumber: 1, name: 'S1', episodeCount: 3 }],
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('allows marking watched movie', async () => {
    await seed('uid-ana', '1-movie', validFavorite({ id: 1, mediaType: 'movie', seasonSummaries: [] }));
    await assertSucceeds(updateDoc(fav(ana(), 'uid-ana', '1-movie'), { watchedMovie: true }));
  });

  it('addedAt can decrease but never advance', async () => {
    await seed('uid-ana', '42-tv', validFavorite());
    await assertSucceeds(
      updateDoc(fav(ana(), 'uid-ana', '42-tv'), { addedAt: Timestamp.fromDate(new Date('2025-01-01T00:00:00Z')) }),
    );
    await assertFails(
      updateDoc(fav(ana(), 'uid-ana', '42-tv'), { addedAt: Timestamp.fromDate(new Date('2030-01-01T00:00:00Z')) }),
    );
  });
});

describe('profile document', () => {
  it('owner can write a valid nickname, not an empty or oversized one', async () => {
    const ref = doc(ana(), 'users', 'uid-ana');
    await assertSucceeds(setDoc(ref, { displayName: 'Ana', schemaVersion: 1 }));
    await assertFails(setDoc(ref, { displayName: '   ' }));
    await assertFails(setDoc(ref, { displayName: 'x'.repeat(41) }));
    await assertFails(setDoc(ref, { displayName: 'Ana', email: 'x@example.test' }));
  });

  it('update with an extra field or a non-timestamp updatedAt is rejected', async () => {
    const ref = doc(ana(), 'users', 'uid-ana');
    await assertSucceeds(setDoc(ref, { displayName: 'Ana' }));
    await assertFails(updateDoc(ref, { email: 'x@example.test' }));
    await assertFails(updateDoc(ref, { updatedAt: 'now' }));
    await assertSucceeds(updateDoc(ref, { updatedAt: serverTimestamp() }));
  });

  it('owner can delete own profile; others cannot', async () => {
    const { deleteDoc } = await import('firebase/firestore');
    await env.withSecurityRulesDisabled((ctx) =>
      setDoc(doc(ctx.firestore(), 'users', 'uid-ana'), { displayName: 'Ana' }));
    await assertFails(deleteDoc(doc(bruno(), 'users', 'uid-ana')));
    await assertSucceeds(deleteDoc(doc(ana(), 'users', 'uid-ana')));
  });
});

// Reads with rules disabled (the callback's return value is not propagated by the helper).
const admin = async (fn) => {
  let out;
  await env.withSecurityRulesDisabled(async (ctx) => {
    out = await fn(ctx.firestore());
  });
  return out;
};

describe('nickname (displayName) as the app writes it', () => {
  const profile = (db) => doc(db, 'users', 'uid-ana');
  const write = (db, displayName) =>
    setDoc(
      profile(db),
      { displayName, schemaVersion: 1, updatedAt: serverTimestamp() },
      { merge: true },
    );

  it('accepts 1 and 40 characters', async () => {
    await assertSucceeds(write(ana(), 'A'));
    await assertSucceeds(write(ana(), 'x'.repeat(40)));
  });

  it('rejects 41 characters, blank values and non-strings', async () => {
    await assertFails(write(ana(), 'x'.repeat(41)));
    await assertFails(write(ana(), ''));
    await assertFails(write(ana(), '   '));
    await assertFails(write(ana(), 123));
    await assertFails(write(ana(), null));
  });

  it('can be removed again (back to the Google name) without breaking the document', async () => {
    await assertSucceeds(write(ana(), 'Ana'));
    await assertSucceeds(
      setDoc(profile(ana()), { displayName: deleteField(), schemaVersion: 1, updatedAt: serverTimestamp() }, { merge: true }),
    );
    const snap = await admin((db) => getDoc(profile(db)));
    assert.equal(snap.exists(), true);
    assert.equal(snap.data().displayName, undefined);
  });

  it('another user cannot set or read it; anonymous cannot either', async () => {
    await assertFails(write(bruno(), 'Hacker'));
    await assertFails(write(anon(), 'Hacker'));
    await assertSucceeds(write(ana(), 'Ana'));
    await assertFails(getDoc(profile(bruno())));
  });

  it('does not allow stuffing other personal data into the profile', async () => {
    await assertFails(
      setDoc(profile(ana()), { displayName: 'Ana', email: 'a@example.test' }, { merge: true }),
    );
    await assertFails(
      setDoc(profile(ana()), { displayName: 'Ana', photoURL: 'http://x' }, { merge: true }),
    );
  });
});

describe('account deletion sequence (what deleteAccount() does, in order)', () => {
  const profile = (db) => doc(db, 'users', 'uid-ana');
  const seedMany = async (n) =>
    env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await setDoc(profile(db), { displayName: 'Ana', schemaVersion: 1 });
      for (let i = 1; i <= n; i++) {
        await setDoc(fav(db, 'uid-ana', `${i}-movie`), validFavorite({ id: i, mediaType: 'movie', seasonSummaries: [] }));
      }
    });

  it('marker -> batch deletes -> profile delete all succeed for the owner', async () => {
    await seedMany(5);
    const db = ana();
    // 1. marker (exact shape the app sends)
    await assertSucceeds(
      setDoc(profile(db), { deleting: true, schemaVersion: 1, updatedAt: serverTimestamp() }, { merge: true }),
    );
    // 2. delete favorites in a batch (the app pages 400 at a time)
    const snap = await getDocs(collection(db, 'users', 'uid-ana', 'favorites'));
    assert.equal(snap.size, 5);
    const batch = writeBatch(db);
    snap.docs.forEach((d) => batch.delete(d.ref));
    await assertSucceeds(batch.commit());
    // 3. profile document
    await assertSucceeds(deleteDoc(profile(db)));

    const left = await admin((adb) => getDocs(collection(adb, 'users', 'uid-ana', 'favorites')));
    assert.equal(left.size, 0);
    const prof = await admin((adb) => getDoc(profile(adb)));
    assert.equal(prof.exists(), false);
  });

  it('a full 400-document page can be deleted in one batch', async () => {
    await seedMany(400);
    const db = ana();
    const snap = await getDocs(collection(db, 'users', 'uid-ana', 'favorites'));
    assert.equal(snap.size, 400);
    const batch = writeBatch(db);
    snap.docs.forEach((d) => batch.delete(d.ref));
    await assertSucceeds(batch.commit());
  });

  it('950 favorites: the paging loop of the app (limit 400, batch, repeat until empty) wipes everything', async () => {
    await seedMany(950);
    const db = ana();
    const pages = [];
    for (let guard = 0; guard < 500; guard++) {
      const snap = await getDocs(query(collection(db, 'users', 'uid-ana', 'favorites'), limit(400)));
      if (snap.empty) break;
      const batch = writeBatch(db);
      snap.docs.forEach((d) => batch.delete(d.ref));
      await assertSucceeds(batch.commit());
      pages.push(snap.size);
    }
    assert.deepEqual(pages, [400, 400, 150]);
    const left = await admin((adb) => getDocs(collection(adb, 'users', 'uid-ana', 'favorites')));
    assert.equal(left.size, 0);
  });

  it('the marker can be written again after the profile was deleted (resume after a failed User.delete)', async () => {
    await seedMany(1);
    await assertSucceeds(deleteDoc(profile(ana())));
    await assertSucceeds(
      setDoc(profile(ana()), { deleting: true, schemaVersion: 1, updatedAt: serverTimestamp() }, { merge: true }),
    );
  });

  it('marker must be a boolean', async () => {
    await assertFails(setDoc(profile(ana()), { deleting: 'yes' }, { merge: true }));
  });

  it('nobody else can mark or delete the account data of another user', async () => {
    await seedMany(2);
    const other = bruno();
    await assertFails(setDoc(profile(other), { deleting: true }, { merge: true }));
    await assertFails(deleteDoc(profile(other)));
    await assertFails(deleteDoc(fav(other, 'uid-ana', '1-movie')));
    const batch = writeBatch(other);
    batch.delete(fav(other, 'uid-ana', '2-movie'));
    await assertFails(batch.commit());
    await assertFails(deleteDoc(profile(anon())));
  });

  it('after deletion the same uid starts from scratch (new user semantics)', async () => {
    await seedMany(1);
    await assertSucceeds(deleteDoc(fav(ana(), 'uid-ana', '1-movie')));
    await assertSucceeds(deleteDoc(profile(ana())));
    await assertSucceeds(setDoc(fav(ana(), 'uid-ana', '9-movie'), validFavorite({ id: 9, mediaType: 'movie', seasonSummaries: [] })));
  });
});
