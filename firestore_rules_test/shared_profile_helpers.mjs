// Payload builders for shared_profiles/{uid} (docs/82 §4.1, §4.4). Not a test file.
// The shapes mirror the example of docs/82 §4.1; they are the ORACLE of the rules tests until the
// Dart serializer exists (Fatia 1: SharedProfilePayloads + fixtures/shared_profile_payloads.json).
import { Timestamp, doc, serverTimestamp } from 'firebase/firestore';

export const HOUR = 60 * 60 * 1000;
export const st = () => serverTimestamp();
export const past = (ms) => Timestamp.fromMillis(Date.now() - ms);
export const future = (ms) => Timestamp.fromMillis(Date.now() + ms);

export const spRef = (d, uid) => doc(d, 'shared_profiles', uid);

export const RANK = ['watchedMovies', 'watchedEpisodes', 'watchedSeries', 'completedSeries', 'minutes'];

export const total = (o = {}) => ({
  favorites: 54, movies: 20, series: 34, watchedMovies: 12, watchedEpisodes: 300,
  watchedSeries: 10, completedSeries: 3, minutes: 20000, estimated: 5, unknown: 2, ...o,
});
export const period = (key, o = {}) => ({
  key, watchedMovies: 1, watchedEpisodes: 12, watchedSeries: 2, completedSeries: 0,
  minutes: 600, estimated: 0, unknown: 0, ...o,
});
export const stats = (o = {}) => ({
  total: total(),
  year: period('2026'),
  month: period('2026-10'),
  undatedMovies: 2,
  undatedEpisodes: 260,
  datedFrom: Timestamp.fromDate(new Date('2026-10-11T22:10:00Z')),
  memberSince: Timestamp.fromDate(new Date('2025-03-02T10:00:00Z')),
  ...o,
});

// One derived activity item (docs/82 §4.4: the rules only check `at >= actSince`).
export const act = (at, o = {}) => ({
  type: 'watched_episodes', id: 1399, mediaType: 'tv', title: 'Serie X', poster: '/abc.jpg',
  at, count: 4, season: 2, episode: 4, ...o,
});
export const acts = (n, at) => Array.from({ length: n }, (_, i) => act(at, { id: 1000 + i }));

export const recItem = (i) => ({
  id: 5000 + i, mediaType: i % 2 ? 'tv' : 'movie', title: `Recomendado ${i} ${'x'.repeat(40)}`, poster: `/p${i}.jpg`,
});
export const recs = (n, count = n) => ({ count, items: Array.from({ length: n }, (_, i) => recItem(i)) });

// Create payloads (what the toggle transaction `set`s). `updatedAt`/`actSince` = server time.
export const createStats = (o = {}) => ({
  v: 1, calc: 1, updatedAt: st(), tz: -180, sharing: { stats: true }, stats: stats(), ...o,
});
export const createActivity = (o = {}) => ({
  v: 1, calc: 1, updatedAt: st(), tz: -180, sharing: { activity: true }, actSince: st(), activity: [], ...o,
});
export const createRecs = (o = {}) => ({
  v: 1, calc: 1, updatedAt: st(), tz: -180, sharing: { recs: true }, recs: recs(3), ...o,
});
// Heaviest legal document: every section, 10 activities, 50 recommended items.
export const createAll = (o = {}) => ({
  v: 1, calc: 1, updatedAt: st(), tz: -180,
  sharing: { stats: true, activity: true, recs: true },
  actSince: st(), stats: stats(), activity: acts(10, future(HOUR)), recs: recs(50, 120), ...o,
});

// A document as it already exists on the server (seeded with rules disabled).
export const stored = (o = {}) => ({
  v: 1, calc: 1, updatedAt: past(24 * HOUR), tz: -180,
  sharing: { stats: true, activity: true, recs: true },
  actSince: past(48 * HOUR), stats: stats(), activity: acts(3, past(HOUR)), recs: recs(3), ...o,
});
