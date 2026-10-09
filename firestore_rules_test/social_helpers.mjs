// Shared helpers for the social rules tests (docs/51). Not a test file.
import { readFileSync } from 'node:fs';
import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import {
  Timestamp,
  deleteDoc,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  writeBatch,
} from 'firebase/firestore';

// RULES_PATH lets the mutation harness (mutations.mjs) point the suite at a mutated copy.
export const RULES_URL = process.env.RULES_PATH
  ? new URL(`file://${process.env.RULES_PATH}`)
  : new URL('../firestore.rules', import.meta.url);

export const DAY = 24 * 60 * 60 * 1000;
export const ts = (ms) => Timestamp.fromMillis(ms);
export const agoDays = (n) => ts(Date.now() - n * DAY);
export const inDays = (n) => ts(Date.now() + n * DAY);
export const st = () => serverTimestamp();

export const U = {
  ana: 'uid-ana',
  bruno: 'uid-bruno',
  caio: 'uid-caio',
  dora: 'uid-dora',
};
export const nm = (uid) => `Nome ${uid}`;
export const PHOTO = 'https://lh3.googleusercontent.com/a/abc123';
export const CODE = 'AbCdEfGhIjKlMnOpQrStUv12'; // 24 chars, base62
export const CODE2 = 'ZyXwVuTsRqPoNmLkJiHgFe99';

export const pairId = (a, b) => (a < b ? `${a}_${b}` : `${b}_${a}`);
export const handleFor = (uid) => uid.replace('uid-', '');

export async function newEnv(rulesText) {
  return initializeTestEnvironment({
    projectId: 'demo-cinetrack',
    firestore: { rules: rulesText ?? readFileSync(RULES_URL, 'utf8') },
  });
}

export function makeTools(env) {
  const google = { firebase: { sign_in_provider: 'google.com' } };
  const db = (uid) => env.authenticatedContext(uid, google).firestore();
  const dbWith = (uid, provider) =>
    env.authenticatedContext(uid, { firebase: { sign_in_provider: provider } }).firestore();
  const dbNoClaim = (uid) => env.authenticatedContext(uid).firestore();
  const anon = () => env.unauthenticatedContext().firestore();
  const seed = (fn) =>
    env.withSecurityRulesDisabled(async (ctx) => {
      await fn(ctx.firestore());
    });

  const seedSocial = (uid, o = {}) =>
    seed(async (d) => {
      const handle = o.handle ?? handleFor(uid);
      const social = { handle, handleChangedAt: o.changedAt ?? agoDays(60), schemaVersion: 1 };
      if (o.inviteCode) social.inviteCode = o.inviteCode;
      await setDoc(doc(d, 'social', uid), social);
      const card = {
        uid,
        nickname: o.nickname ?? nm(uid),
        discoverable: o.discoverable ?? true,
        createdAt: agoDays(60),
        updatedAt: agoDays(60),
      };
      if (o.photo) card.photoURL = o.photo;
      await setDoc(doc(d, 'handles', handle), card);
      if (o.inviteCode) {
        await setDoc(doc(d, 'invites', o.inviteCode), {
          uid,
          nickname: card.nickname,
          createdAt: agoDays(1),
          expiresAt: o.inviteExpires ?? inDays(7),
        });
      }
    });
  const seedRequest = (from, to, o = {}) =>
    seed((d) =>
      setDoc(doc(d, 'friend_requests', `${from}_${to}`), {
        from,
        to,
        fromHandle: o.fromHandle ?? handleFor(from),
        fromName: o.fromName ?? nm(from),
        toName: o.toName ?? nm(to),
        createdAt: agoDays(1),
        ...(o.fromPhoto ? { fromPhoto: o.fromPhoto } : {}),
      }),
    );
  const seedFriendship = (a, b) =>
    seed((d) => {
      const [x, y] = a < b ? [a, b] : [b, a];
      return setDoc(doc(d, 'friendships', `${x}_${y}`), {
        members: [x, y],
        createdAt: agoDays(1),
        aName: nm(x),
        bName: nm(y),
      });
    });
  const seedBlock = (blocker, blocked) =>
    seed((d) => setDoc(doc(d, 'users', blocker, 'blocks', blocked), { createdAt: agoDays(1) }));
  const seedDoc = (path, data) => seed((d) => setDoc(doc(d, ...path), data));

  const exists = async (path) => {
    let r;
    await seed(async (d) => {
      r = (await getDoc(doc(d, ...path))).exists();
    });
    return r;
  };

  return { db, dbWith, dbNoClaim, anon, seed, seedSocial, seedRequest, seedFriendship, seedBlock, seedDoc, exists };
}

export const commit = (d, fn) => {
  const b = writeBatch(d);
  fn(b);
  return b.commit();
};

// --- valid payload builders (what the app will send) ---
// fromHandle = the sender's CURRENT handle (seedSocial uses handleFor(uid) by default).
export const requestData = (from, to, o = {}) => ({
  from,
  to,
  fromHandle: handleFor(from),
  fromName: nm(from),
  toName: nm(to),
  createdAt: st(),
  ...o,
});
export const requestRef = (d, from, to) => doc(d, 'friend_requests', `${from}_${to}`);

export const friendshipData = (me, other, o = {}) => {
  const [x, y] = me < other ? [me, other] : [other, me];
  return { members: [x, y], createdAt: st(), aName: nm(x), bName: nm(y), ...o };
};
export const friendshipRef = (d, a, b) => doc(d, 'friendships', pairId(a, b));

// Accept: create the pair (other's half comes from the request) and consume both requests.
export const acceptBatch = (d, me, other, over = {}) =>
  commit(d, (b) => {
    b.set(friendshipRef(d, me, other), friendshipData(me, other, over));
    b.delete(requestRef(d, other, me));
    b.delete(requestRef(d, me, other));
  });

export const cardData = (uid, o = {}) => ({
  uid,
  nickname: nm(uid),
  discoverable: true,
  createdAt: st(),
  updatedAt: st(),
  ...o,
});
export const socialData = (handle, o = {}) => ({
  handle,
  handleChangedAt: st(),
  schemaVersion: 1,
  ...o,
});
export const inviteData = (uid, o = {}) => ({
  uid,
  nickname: nm(uid),
  createdAt: st(),
  expiresAt: inDays(7),
  ...o,
});

// Activate (card + pointer) in one batch.
export const activate = (d, uid, handle = handleFor(uid), o = {}) =>
  commit(d, (b) => {
    b.set(doc(d, 'handles', handle), cardData(uid, o.card));
    b.set(doc(d, 'social', uid), socialData(handle, o.social));
  });

export { deleteDoc, doc, setDoc };
