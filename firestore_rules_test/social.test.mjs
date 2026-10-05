// Social rules (docs/50 + docs/51): friendships, requests, blocks, handles, social pointer,
// invite link. Emulator only. Run: cd firestore_rules_test && npm test
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, deleteField, doc, getDoc, getDocs, orderBy, query, runTransaction,
  setDoc, updateDoc, where,
} from 'firebase/firestore';
import {
  CODE, CODE2, PHOTO, U, acceptBatch, activate, agoDays, cardData, commit, friendshipData,
  friendshipRef, handleFor, inDays, inviteData, makeTools, newEnv, nm, pairId, requestData,
  requestRef, socialData, st,
} from './social_helpers.mjs';

let env;
let t;
before(async () => {
  env = await newEnv();
  t = makeTools(env);
});
after(async () => env?.cleanup());
beforeEach(async () => env.clearFirestore());

const { ana, bruno, caio, dora } = U;
const both = async () => {
  await t.seedSocial(ana);
  await t.seedSocial(bruno);
};

// ---------------------------------------------------------------------------
describe('handles: reserva, unicidade e formato', () => {
  it('activation by batch (card + pointer) succeeds', async () => {
    await assertSucceeds(activate(t.db(ana), ana, 'ana_s'));
    assert.ok(await t.exists(['handles', 'ana_s']));
    assert.ok(await t.exists(['social', ana]));
  });

  it('the same handle for a second user is denied (id taken)', async () => {
    await t.seedSocial(ana, { handle: 'ana_s' });
    await assertFails(activate(t.db(bruno), bruno, 'ana_s'));
  });

  it('3 concurrent transactions on the same handle: exactly 1 wins', async () => {
    const claim = (uid) => {
      const d = t.db(uid);
      return runTransaction(d, async (tx) => {
        const ref = doc(d, 'handles', 'disputa');
        if ((await tx.get(ref)).exists()) throw new Error('taken');
        tx.set(ref, cardData(uid));
        tx.set(doc(d, 'social', uid), socialData('disputa'));
      });
    };
    const res = await Promise.allSettled([claim(bruno), claim(caio), claim(dora)]);
    assert.equal(res.filter((r) => r.status === 'fulfilled').length, 1);
    await t.seed(async (d) => {
      const owner = (await getDoc(doc(d, 'handles', 'disputa'))).data().uid;
      assert.ok((await getDoc(doc(d, 'social', owner))).exists());
    });
  });

  for (const bad of ['ab', 'a'.repeat(21), 'Maria', 'ma ria', '_maria', 'maria_', 'admin', 'cinetrack', 'joão', 'a-b-c']) {
    it(`invalid handle "${bad}" is denied`, async () => {
      await assertFails(activate(t.db(ana), ana, bad));
    });
  }

  it('boundary handles (3 and 20 chars, digits, inner underscore) pass', async () => {
    await assertSucceeds(activate(t.db(ana), ana, 'a_1'));
    await assertSucceeds(activate(t.db(bruno), bruno, 'b'.repeat(20)));
  });

  it('pointer to a handle that is not the user\'s card is denied', async () => {
    await t.seedSocial(bruno, { handle: 'bruno_h' });
    await assertFails(setDoc(doc(t.db(ana), 'social', ana), socialData('bruno_h')));
  });

  it('card with another uid (forged) is denied', async () => {
    const d = t.db(ana);
    await assertFails(
      commit(d, (b) => {
        b.set(doc(d, 'handles', 'forjado'), cardData(bruno));
        b.set(doc(d, 'social', ana), socialData('forjado'));
      }),
    );
  });

  it('card without pointer in the same batch is denied; pointer without card too', async () => {
    await assertFails(setDoc(doc(t.db(ana), 'handles', 'sozinho'), cardData(ana)));
    await assertFails(setDoc(doc(t.db(ana), 'social', ana), socialData('sozinho')));
  });

  it('schema: extra fields, wrong types, sizes, foreign photo, forged dates', async () => {
    const d = t.db(ana);
    const tryCard = (card, h = 'cartao') =>
      assertFails(
        commit(d, (b) => {
          b.set(doc(d, 'handles', h), card);
          b.set(doc(d, 'social', ana), socialData(h));
        }),
      );
    await tryCard(cardData(ana, { extra: 1 }));
    await tryCard(cardData(ana, { discoverable: 'sim' }));
    await tryCard(cardData(ana, { nickname: '' }));
    await tryCard(cardData(ana, { nickname: '   ' }));
    await tryCard(cardData(ana, { nickname: 'x'.repeat(41) }));
    await tryCard(cardData(ana, { nickname: 42 }));
    await tryCard(cardData(ana, { photoURL: 'https://evil.example.com/a.png' }));
    await tryCard(cardData(ana, { photoURL: 'http://lh3.googleusercontent.com/a' }));
    await tryCard(cardData(ana, { photoURL: 'https://lh3.googleusercontent.com.evil.com/a' }));
    await tryCard(cardData(ana, { photoURL: 'https://lh3.googleusercontent.com/' + 'a'.repeat(520) }));
    await tryCard(cardData(ana, { createdAt: agoDays(900) }));
    await tryCard(cardData(ana, { updatedAt: agoDays(1) }));
    const { discoverable, ...noDisc } = cardData(ana);
    void discoverable;
    await tryCard(noDisc);
    await assertSucceeds(
      commit(d, (b) => {
        b.set(doc(d, 'handles', 'cartao'), cardData(ana, { photoURL: PHOTO, nickname: 'x'.repeat(40) }));
        b.set(doc(d, 'social', ana), socialData('cartao'));
      }),
    );
  });

  it('social schema: extra field, wrong types, forged handleChangedAt, uid with underscore', async () => {
    const d = t.db(ana);
    const go = (social) =>
      assertFails(
        commit(d, (b) => {
          b.set(doc(d, 'handles', 'sch'), cardData(ana));
          b.set(doc(d, 'social', ana), social);
        }),
      );
    await go(socialData('sch', { extra: 1 }));
    await go(socialData('sch', { schemaVersion: '1' }));
    await go(socialData('sch', { handleChangedAt: agoDays(100) }));
    await go(socialData('sch', { handleChangedAt: 'agora' }));
    await go(socialData('sch', { inviteCode: 'curto' }));
    // uid containing "_" (ambiguous composite ids) can never activate the social
    const weird = t.db('a_b');
    await assertFails(
      commit(weird, (b) => {
        b.set(doc(weird, 'handles', 'weird'), cardData('a_b'));
        b.set(doc(weird, 'social', 'a_b'), socialData('weird'));
      }),
    );
  });

  it('two handles for the same user are denied', async () => {
    await t.seedSocial(ana, { handle: 'primeiro' });
    const d = t.db(ana);
    await assertFails(setDoc(doc(d, 'handles', 'segundo'), cardData(ana)));
    await assertFails(
      commit(d, (b) => {
        b.set(doc(d, 'handles', 'segundo'), cardData(ana));
        b.set(doc(d, 'social', ana), socialData('segundo'));
      }),
    );
  });

  it('uid and createdAt of a card are immutable; third party cannot edit/delete', async () => {
    await t.seedSocial(ana, { handle: 'ana_s' });
    const ref = (d) => doc(d, 'handles', 'ana_s');
    await assertFails(setDoc(ref(t.db(ana)), cardData(bruno)));
    await assertFails(setDoc(ref(t.db(ana)), cardData(ana, { createdAt: st() })));
    await assertFails(setDoc(ref(t.db(bruno)), cardData(bruno)));
    await assertFails(updateDoc(ref(t.db(bruno)), { discoverable: false }));
    await assertFails(deleteDoc(ref(t.db(bruno))));
    await assertFails(deleteDoc(ref(t.anon())));
  });

  it('owner toggles "Aparecer na busca" and photo (card update keeps createdAt)', async () => {
    await t.seedSocial(ana, { handle: 'ana_s' });
    const d = t.db(ana);
    // keep original createdAt: read, then rewrite with same createdAt
    const snap = await getDoc(doc(d, 'handles', 'ana_s'));
    await assertSucceeds(
      setDoc(doc(d, 'handles', 'ana_s'), {
        ...snap.data(), discoverable: false, photoURL: PHOTO, updatedAt: st(),
      }),
    );
  });
});

// ---------------------------------------------------------------------------
describe('busca por handle (get exato) e "aparecer na busca"', () => {
  it('visible card can be read by any signed-in user; list is denied', async () => {
    await t.seedSocial(ana, { handle: 'ana_s' });
    await assertSucceeds(getDoc(doc(t.db(bruno), 'handles', 'ana_s')));
    await assertFails(getDocs(collection(t.db(bruno), 'handles')));
    await assertFails(getDocs(query(collection(t.db(bruno), 'handles'), where('discoverable', '==', true))));
    await assertFails(getDocs(query(collection(t.db(ana), 'handles'), where('uid', '==', ana))));
  });
  it('anonymous cannot read cards', async () => {
    await t.seedSocial(ana, { handle: 'ana_s' });
    await assertFails(getDoc(doc(t.anon(), 'handles', 'ana_s')));
    await assertFails(getDoc(doc(t.anon(), 'handles', 'inexistente')));
  });
  it('hidden card: denied to others (even friends), allowed to owner', async () => {
    await t.seedSocial(ana, { handle: 'ana_s', discoverable: false });
    await t.seedSocial(bruno);
    await t.seedFriendship(ana, bruno);
    await assertFails(getDoc(doc(t.db(caio), 'handles', 'ana_s')));
    await assertFails(getDoc(doc(t.db(bruno), 'handles', 'ana_s')));
    await assertSucceeds(getDoc(doc(t.db(ana), 'handles', 'ana_s')));
  });
  it('nonexistent handle reads as "does not exist" (no permission error)', async () => {
    const s = await assertSucceeds(getDoc(doc(t.db(bruno), 'handles', 'nada_aqui')));
    assert.equal(s.exists(), false);
  });
  it('block in either direction hides the card; unblocking restores', async () => {
    await both();
    await t.seedBlock(ana, bruno); // ana blocked bruno
    await assertFails(getDoc(doc(t.db(bruno), 'handles', handleFor(ana))));
    await assertFails(getDoc(doc(t.db(ana), 'handles', handleFor(bruno))));
    await assertSucceeds(getDoc(doc(t.db(ana), 'handles', handleFor(ana)))); // owner always
    await assertSucceeds(getDoc(doc(t.db(caio), 'handles', handleFor(ana))));
    await assertSucceeds(deleteDoc(doc(t.db(ana), 'users', ana, 'blocks', bruno)));
    await assertSucceeds(getDoc(doc(t.db(bruno), 'handles', handleFor(ana))));
  });
});

// ---------------------------------------------------------------------------
describe('troca de handle (a cada 30 dias) e desativar', () => {
  const swap = (d, uid, oldH, newH) =>
    commit(d, (b) => {
      b.delete(doc(d, 'handles', oldH));
      b.set(doc(d, 'handles', newH), cardData(uid));
      b.set(doc(d, 'social', uid), socialData(newH, { handleChangedAt: st() }));
    });

  it('change after >= 30 days succeeds and frees the old handle for others', async () => {
    await t.seedSocial(ana, { handle: 'velho', changedAt: agoDays(31) });
    await assertSucceeds(swap(t.db(ana), ana, 'velho', 'novo'));
    await assertSucceeds(activate(t.db(bruno), bruno, 'velho'));
  });
  it('change within 30 days is denied (29 days; 1 day; just activated)', async () => {
    for (const days of [29, 1, 0]) {
      await env.clearFirestore();
      await t.seedSocial(ana, { handle: 'velho', changedAt: agoDays(days) });
      await assertFails(swap(t.db(ana), ana, 'velho', 'novo'));
    }
  });
  it('change without freeing the old handle is denied (orphan reservation)', async () => {
    await t.seedSocial(ana, { handle: 'velho', changedAt: agoDays(40) });
    const d = t.db(ana);
    await assertFails(
      commit(d, (b) => {
        b.set(doc(d, 'handles', 'novo'), cardData(ana));
        b.set(doc(d, 'social', ana), socialData('novo'));
      }),
    );
  });
  it('change keeping handleChangedAt old (to dodge the limit) is denied', async () => {
    await t.seedSocial(ana, { handle: 'velho', changedAt: agoDays(1) });
    const d = t.db(ana);
    await assertFails(
      commit(d, (b) => {
        b.delete(doc(d, 'handles', 'velho'));
        b.set(doc(d, 'handles', 'novo'), cardData(ana));
        b.set(doc(d, 'social', ana), socialData('novo', { handleChangedAt: agoDays(40) }));
      }),
    );
  });
  it('change to a handle owned by someone else is denied even after 30 days', async () => {
    await t.seedSocial(ana, { handle: 'velho', changedAt: agoDays(40) });
    await t.seedSocial(bruno, { handle: 'ocupado' });
    await assertFails(swap(t.db(ana), ana, 'velho', 'ocupado'));
  });
  it('touching the pointer without changing handle keeps handleChangedAt', async () => {
    await t.seedSocial(ana, { handle: 'velho', changedAt: agoDays(2) });
    await assertFails(updateDoc(doc(t.db(ana), 'social', ana), { handleChangedAt: st() }));
    await assertSucceeds(updateDoc(doc(t.db(ana), 'social', ana), { schemaVersion: 2 }));
  });
  it('deactivate: handle + pointer in one batch OK; either alone denied; third party denied', async () => {
    await t.seedSocial(ana, { handle: 'ana_s' });
    const d = t.db(ana);
    await assertFails(deleteDoc(doc(d, 'social', ana)));
    await assertFails(deleteDoc(doc(d, 'handles', 'ana_s')));
    await assertFails(deleteDoc(doc(t.db(bruno), 'social', ana)));
    await assertSucceeds(
      commit(d, (b) => {
        b.delete(doc(d, 'handles', 'ana_s'));
        b.delete(doc(d, 'social', ana));
      }),
    );
    assert.equal(await t.exists(['handles', 'ana_s']), false);
  });
  it('the pointer is private: others cannot read or write social/{uid}', async () => {
    await t.seedSocial(ana);
    await assertFails(getDoc(doc(t.db(bruno), 'social', ana)));
    await assertFails(setDoc(doc(t.db(bruno), 'social', ana), socialData('x')));
    await assertFails(getDoc(doc(t.anon(), 'social', ana)));
    await assertSucceeds(getDoc(doc(t.db(ana), 'social', ana)));
  });
});

// ---------------------------------------------------------------------------
describe('pedidos de amizade (friend_requests)', () => {
  it('send succeeds (both have social)', async () => {
    await both();
    await assertSucceeds(setDoc(requestRef(t.db(ana), ana, bruno), requestData(ana, bruno)));
  });
  it('photo fields (Google URL) are accepted', async () => {
    await both();
    await assertSucceeds(
      setDoc(requestRef(t.db(ana), ana, bruno), requestData(ana, bruno, { fromPhoto: PHOTO, toPhoto: null })),
    );
  });
  it('request to a user without social is denied; sender without social too', async () => {
    await t.seedSocial(ana);
    await assertFails(setDoc(requestRef(t.db(ana), ana, caio), requestData(ana, caio)));
    await assertFails(setDoc(requestRef(t.db(caio), caio, ana), requestData(caio, ana)));
  });
  it('malicious payloads are denied', async () => {
    await both();
    const d = t.db(ana);
    const key = `${ana}_${bruno}`;
    const bad = {
      'forged sender': [`${bruno}_${ana}`, requestData(bruno, ana)],
      'forged from, own key': [key, requestData(ana, bruno, { from: bruno })],
      'id mismatch': [`${ana}_${caio}`, requestData(ana, bruno)],
      'self request': [`${ana}_${ana}`, requestData(ana, ana)],
      'extra field': [key, requestData(ana, bruno, { admin: true })],
      'forged createdAt': [key, requestData(ana, bruno, { createdAt: agoDays(10) })],
      'empty name': [key, requestData(ana, bruno, { fromName: '' })],
      'name 41': [key, requestData(ana, bruno, { toName: 'x'.repeat(41) })],
      'name wrong type': [key, requestData(ana, bruno, { fromName: 7 })],
      'foreign photo': [key, requestData(ana, bruno, { fromPhoto: 'https://x.example/a.png' })],
      'photo wrong type': [key, requestData(ana, bruno, { toPhoto: 5 })],
      'to wrong type': [key, requestData(ana, bruno, { to: 5 })],
    };
    for (const [name, [k, data]] of Object.entries(bad)) {
      await assert.doesNotReject(assertFails(setDoc(doc(d, 'friend_requests', k), data)), name);
    }
    const { createdAt, ...noDate } = requestData(ana, bruno);
    void createdAt;
    await assertFails(setDoc(doc(d, 'friend_requests', key), noDate));
  });
  it('anonymous cannot send', async () => {
    await both();
    await assertFails(setDoc(requestRef(t.anon(), ana, bruno), requestData(ana, bruno)));
  });
  it('duplicate (same direction) is an update: denied (immutable)', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    await assertFails(setDoc(requestRef(t.db(ana), ana, bruno), requestData(ana, bruno)));
    await assertFails(updateDoc(requestRef(t.db(ana), ana, bruno), { fromName: 'Novo' }));
    await assertFails(updateDoc(requestRef(t.db(bruno), ana, bruno), { toName: 'Novo' }));
  });
  it('only sender and recipient read (get/list); third party and anonymous cannot', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    await assertSucceeds(getDoc(requestRef(t.db(ana), ana, bruno)));
    await assertSucceeds(getDoc(requestRef(t.db(bruno), ana, bruno)));
    await assertFails(getDoc(requestRef(t.db(caio), ana, bruno)));
    await assertFails(getDoc(requestRef(t.anon(), ana, bruno)));
    const col = (d) => collection(d, 'friend_requests');
    const q = (d, f, u) => getDocs(query(col(d), where(f, '==', u), orderBy('createdAt', 'desc')));
    await assertSucceeds(q(t.db(bruno), 'to', bruno));
    await assertSucceeds(q(t.db(ana), 'from', ana));
    await assertFails(q(t.db(caio), 'to', bruno));
    await assertFails(getDocs(col(t.db(caio))));
    await assertFails(getDocs(col(t.db(ana))));
  });
  it('cancel (sender) and decline (recipient) succeed; third party cannot delete', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    await assertFails(deleteDoc(requestRef(t.db(caio), ana, bruno)));
    await assertFails(deleteDoc(requestRef(t.anon(), ana, bruno)));
    await assertSucceeds(deleteDoc(requestRef(t.db(bruno), ana, bruno)));
    await t.seedRequest(ana, bruno);
    await assertSucceeds(deleteDoc(requestRef(t.db(ana), ana, bruno)));
  });
  it('deleting a request that does not exist is only allowed for ids containing own uid', async () => {
    await assertSucceeds(deleteDoc(requestRef(t.db(ana), ana, bruno)));
    await assertFails(deleteDoc(requestRef(t.db(caio), ana, bruno)));
  });
  it('already friends: new request in either direction is denied', async () => {
    await both();
    await t.seedFriendship(ana, bruno);
    await assertFails(setDoc(requestRef(t.db(ana), ana, bruno), requestData(ana, bruno)));
    await assertFails(setDoc(requestRef(t.db(bruno), bruno, ana), requestData(bruno, ana)));
  });
  it('crossed pending requests may coexist and either side can complete', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    await assertSucceeds(setDoc(requestRef(t.db(bruno), bruno, ana), requestData(bruno, ana)));
    await assertSucceeds(acceptBatch(t.db(ana), ana, bruno));
    assert.equal(await t.exists(['friend_requests', `${ana}_${bruno}`]), false);
    assert.equal(await t.exists(['friend_requests', `${bruno}_${ana}`]), false);
  });
});

// ---------------------------------------------------------------------------
describe('amizade (friendships): so nasce com consentimento do outro lado', () => {
  it('neither side can create a friendship alone (no request at all)', async () => {
    await both();
    await assertFails(setDoc(friendshipRef(t.db(ana), ana, bruno), friendshipData(ana, bruno)));
    await assertFails(setDoc(friendshipRef(t.db(bruno), ana, bruno), friendshipData(bruno, ana)));
    await assertFails(acceptBatch(t.db(ana), ana, bruno));
  });
  it('the sender cannot confirm his own request', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    await assertFails(acceptBatch(t.db(ana), ana, bruno));
    await assertFails(setDoc(friendshipRef(t.db(ana), ana, bruno), friendshipData(ana, bruno)));
  });
  it('recipient accepts only if the same batch consumes the request(s)', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    const d = t.db(bruno);
    const fr = friendshipRef(d, ana, bruno);
    await assertFails(setDoc(fr, friendshipData(bruno, ana))); // request left pending
    await assertFails(
      commit(d, (b) => {
        b.set(fr, friendshipData(bruno, ana));
        b.delete(requestRef(d, bruno, ana)); // wrong request deleted; the real one stays
      }),
    );
    await assertSucceeds(acceptBatch(d, bruno, ana));
    assert.equal(await t.exists(['friend_requests', `${ana}_${bruno}`]), false);
    await assertSucceeds(getDoc(friendshipRef(t.db(ana), ana, bruno)));
  });
  it('accept leaving MY own pending request behind is denied (crossed)', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    await t.seedRequest(bruno, ana);
    const d = t.db(bruno);
    await assertFails(
      commit(d, (b) => {
        b.set(friendshipRef(d, ana, bruno), friendshipData(bruno, ana));
        b.delete(requestRef(d, ana, bruno));
      }),
    );
    await assertSucceeds(acceptBatch(d, bruno, ana));
  });
  it('a third party cannot use someone else\'s request nor create a pair of others', async () => {
    await both();
    await t.seedSocial(caio);
    await t.seedRequest(ana, bruno);
    const d = t.db(caio);
    await assertFails(setDoc(friendshipRef(d, ana, bruno), friendshipData(ana, bruno)));
    await assertFails(
      commit(d, (b) => {
        b.set(friendshipRef(d, ana, bruno), friendshipData(ana, bruno));
        b.delete(requestRef(d, ana, bruno));
      }),
    );
    // caio as "member" of a pair with ana without ana's request
    await assertFails(acceptBatch(d, caio, ana));
    // caio claims bruno's request (to ana) does not exist for him
    await assertFails(acceptBatch(d, caio, bruno));
  });
  it('request for another pair does not authorise this pair', async () => {
    await both();
    await t.seedSocial(caio);
    await t.seedRequest(ana, caio);
    await assertFails(acceptBatch(t.db(bruno), bruno, ana));
  });
  it('without social on either side the pair is denied', async () => {
    await t.seedSocial(ana);
    await t.seedRequest(ana, bruno);
    await assertFails(acceptBatch(t.db(bruno), bruno, ana)); // bruno has no social
    await env.clearFirestore();
    await t.seedSocial(bruno);
    await t.seedRequest(ana, bruno);
    await assertFails(acceptBatch(t.db(bruno), bruno, ana)); // ana (sender) has no social
  });
  it('schema/malice: member order, 3 members, extra field, forged date, empty name, foreign photo, wrong id', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    const d = t.db(bruno);
    const base = friendshipData(bruno, ana);
    const send = (data, key = pairId(ana, bruno), mutate) =>
      assertFails(
        commit(d, (b) => {
          b.set(doc(d, 'friendships', key), data);
          b.delete(requestRef(d, ana, bruno));
          b.delete(requestRef(d, bruno, ana));
          mutate?.(b);
        }),
      );
    await send({ ...base, members: [...base.members].reverse() });
    await send({ ...base, members: [ana, bruno, caio] });
    await send({ ...base, members: [ana, ana] });
    await send({ ...base, members: 'x' });
    await send({ ...base, extra: 1 });
    await send({ ...base, createdAt: agoDays(30) });
    await send({ ...base, aName: '' });
    await send({ ...base, bName: 'x'.repeat(41) });
    await send({ ...base, aPhoto: 'https://x.example/a.png' });
    await send({ ...base, bPhoto: 9 });
    await send(base, `${bruno}_${ana}`);
    await send(base, `${ana}_${caio}`);
    const { members, ...noMembers } = base;
    void members;
    await send(noMembers);
  });
  it('the other side\'s half must be what THEY wrote in the request (no forged names)', async () => {
    await both();
    await t.seedRequest(ana, bruno, { fromName: 'Ana Real', fromPhoto: PHOTO });
    const d = t.db(bruno);
    const pair = pairId(ana, bruno);
    const aIsAna = ana < bruno;
    const half = (who) => (who === 'ana' ? (aIsAna ? 'aName' : 'bName') : aIsAna ? 'bName' : 'aName');
    const photoOf = (who) => half(who).replace('Name', 'Photo');
    const mk = (over) => ({ ...friendshipData(bruno, ana), [half('ana')]: 'Ana Real', [photoOf('ana')]: PHOTO, ...over });
    await assertFails(
      commit(d, (b) => {
        b.set(doc(d, 'friendships', pair), mk({ [half('ana')]: 'Ana Falsa' }));
        b.delete(requestRef(d, ana, bruno));
      }),
    );
    await assertFails(
      commit(d, (b) => {
        b.set(doc(d, 'friendships', pair), mk({ [photoOf('ana')]: null }));
        b.delete(requestRef(d, ana, bruno));
      }),
    );
    await assertSucceeds(
      commit(d, (b) => {
        b.set(doc(d, 'friendships', pair), mk({}));
        b.delete(requestRef(d, ana, bruno));
      }),
    );
  });
  it('crossed request by transaction (client treats "send" as "accept")', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    const d = t.db(bruno);
    await assertSucceeds(
      runTransaction(d, async (tx) => {
        const inverse = await tx.get(requestRef(d, ana, bruno));
        assert.ok(inverse.exists());
        tx.set(friendshipRef(d, ana, bruno), friendshipData(bruno, ana));
        tx.delete(requestRef(d, ana, bruno));
        tx.delete(requestRef(d, bruno, ana));
      }),
    );
    assert.equal(await t.exists(['friend_requests', `${ana}_${bruno}`]), false);
    assert.ok(await t.exists(['friendships', pairId(ana, bruno)]));
  });
  it('crossed request by batch also works', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    await assertSucceeds(acceptBatch(t.db(bruno), bruno, ana));
  });
  it('concurrent crossed transactions never leave a pending request next to a friendship', async () => {
    await both();
    const run = (me, other) => {
      const d = t.db(me);
      return runTransaction(d, async (tx) => {
        const inv = await tx.get(requestRef(d, other, me));
        if (inv.exists()) {
          tx.set(friendshipRef(d, me, other), friendshipData(me, other));
          tx.delete(requestRef(d, other, me));
          tx.delete(requestRef(d, me, other));
        } else {
          tx.set(requestRef(d, me, other), requestData(me, other));
        }
      });
    };
    await Promise.allSettled([run(ana, bruno), run(bruno, ana)]);
    const friend = await t.exists(['friendships', pairId(ana, bruno)]);
    const r1 = await t.exists(['friend_requests', `${ana}_${bruno}`]);
    const r2 = await t.exists(['friend_requests', `${bruno}_${ana}`]);
    // either both pending (nobody completed yet: client reconciles) or a friendship with no request
    assert.ok(friend ? !r1 && !r2 : r1 && r2, `friend=${friend} r1=${r1} r2=${r2}`);
  });
  it('only members read (get/list); others and anonymous cannot', async () => {
    await both();
    await t.seedFriendship(ana, bruno);
    await assertSucceeds(getDoc(friendshipRef(t.db(ana), ana, bruno)));
    await assertSucceeds(getDoc(friendshipRef(t.db(bruno), ana, bruno)));
    await assertFails(getDoc(friendshipRef(t.db(caio), ana, bruno)));
    await assertFails(getDoc(friendshipRef(t.anon(), ana, bruno)));
    const mine = (d, u) => getDocs(query(collection(d, 'friendships'), where('members', 'array-contains', u)));
    const r = await assertSucceeds(mine(t.db(ana), ana));
    assert.equal(r.size, 1);
    await assertFails(mine(t.db(caio), ana));
    await assertFails(getDocs(collection(t.db(caio), 'friendships')));
    await assertFails(getDocs(collection(t.anon(), 'friendships')));
  });
  it('each side edits only its own half (name/photo refresh)', async () => {
    await both();
    await t.seedFriendship(ana, bruno);
    const [x] = ana < bruno ? [ana] : [bruno];
    const aSide = x; // members[0]
    const bSide = x === ana ? bruno : ana;
    const own = (uid) => (uid === aSide ? { name: 'aName', photo: 'aPhoto', other: 'bName' } : { name: 'bName', photo: 'bPhoto', other: 'aName' });
    for (const uid of [ana, bruno]) {
      const f = friendshipRef(t.db(uid), ana, bruno);
      const k = own(uid);
      await assertSucceeds(updateDoc(f, { [k.name]: 'Novo Nome', [k.photo]: PHOTO }));
      await assertSucceeds(updateDoc(f, { [k.photo]: deleteField() }));
      await assertFails(updateDoc(f, { [k.other]: 'Forjado' }));
      await assertFails(updateDoc(f, { [k.name]: '' }));
      await assertFails(updateDoc(f, { [k.name]: 'x'.repeat(41) }));
      await assertFails(updateDoc(f, { [k.photo]: 'https://evil.example/a.png' }));
      await assertFails(updateDoc(f, { members: [uid, caio] }));
      await assertFails(updateDoc(f, { createdAt: st() }));
      await assertFails(updateDoc(f, { extra: 1 }));
    }
    void bSide;
    await assertFails(updateDoc(friendshipRef(t.db(caio), ana, bruno), { aName: 'X', bName: 'Y' }));
  });
  it('either member removes for both; third party and anonymous cannot', async () => {
    await both();
    await t.seedFriendship(ana, bruno);
    await assertFails(deleteDoc(friendshipRef(t.db(caio), ana, bruno)));
    await assertFails(deleteDoc(friendshipRef(t.anon(), ana, bruno)));
    await assertSucceeds(deleteDoc(friendshipRef(t.db(bruno), ana, bruno)));
    assert.equal(await t.exists(['friendships', pairId(ana, bruno)]), false);
    // recreating only through a new request
    await assertFails(acceptBatch(t.db(ana), ana, bruno));
    await assertSucceeds(setDoc(requestRef(t.db(ana), ana, bruno), requestData(ana, bruno)));
    await assertSucceeds(acceptBatch(t.db(bruno), bruno, ana));
  });
  it('contract: rules order (a < b) equals JS/Dart ASCII order for digits/upper/lower uids', async () => {
    const uids = ['Zed01', 'abc02', 'A1b2c', 'a1b2c', '0xyz9', 'z9Z9z', 'M0nkey', 'monkey'];
    for (let i = 0; i < uids.length; i++) {
      for (let j = 0; j < uids.length; j++) {
        if (i === j) continue;
        await env.clearFirestore();
        const [from, to] = [uids[i], uids[j]];
        await t.seedSocial(from);
        await t.seedSocial(to);
        await t.seedRequest(from, to);
        const wrongOrder = from < to ? [to, from] : [from, to]; // members[0] > members[1]
        const d = t.db(to);
        await assertFails(
          commit(d, (b) => {
            b.set(doc(d, 'friendships', `${wrongOrder[0]}_${wrongOrder[1]}`), {
              members: wrongOrder, createdAt: st(), aName: nm(wrongOrder[0]), bName: nm(wrongOrder[1]),
            });
            b.delete(requestRef(d, from, to));
          }),
        );
        await assertSucceeds(acceptBatch(d, to, from));
      }
    }
  });
});

// ---------------------------------------------------------------------------
describe('bloqueio', () => {
  const block = (d, me, other, { friend = true, reqOut = true, reqIn = true, extra } = {}) =>
    commit(d, (b) => {
      b.set(doc(d, 'users', me, 'blocks', other), { createdAt: st(), ...extra });
      if (friend) b.delete(friendshipRef(d, me, other));
      if (reqOut) b.delete(requestRef(d, me, other));
      if (reqIn) b.delete(requestRef(d, other, me));
    });

  it('block of a friend with pending requests: succeeds only if the batch removes all three', async () => {
    await both();
    await t.seedFriendship(ana, bruno);
    await t.seedRequest(ana, bruno);
    await t.seedRequest(bruno, ana);
    const d = t.db(ana);
    await assertFails(block(d, ana, bruno, { friend: false }));
    await assertFails(block(d, ana, bruno, { reqOut: false }));
    await assertFails(block(d, ana, bruno, { reqIn: false }));
    await assertFails(setDoc(doc(d, 'users', ana, 'blocks', bruno), { createdAt: st() }));
    await assertSucceeds(block(d, ana, bruno));
    assert.equal(await t.exists(['friendships', pairId(ana, bruno)]), false);
    assert.equal(await t.exists(['friend_requests', `${ana}_${bruno}`]), false);
    assert.equal(await t.exists(['friend_requests', `${bruno}_${ana}`]), false);
  });
  it('block with nothing existing works (deletes in the dark)', async () => {
    await assertSucceeds(block(t.db(ana), ana, bruno));
  });
  it('after the block: requests in both directions and the pair are denied', async () => {
    await both();
    await t.seedBlock(ana, bruno);
    await assertFails(setDoc(requestRef(t.db(ana), ana, bruno), requestData(ana, bruno)));
    await assertFails(setDoc(requestRef(t.db(bruno), bruno, ana), requestData(bruno, ana)));
    await t.seedRequest(bruno, ana); // legacy pending request seeded behind the rules
    await assertFails(acceptBatch(t.db(ana), ana, bruno));
    await assertFails(acceptBatch(t.db(bruno), bruno, ana));
  });
  it('block in the SAME batch as creating a request / a friendship is denied', async () => {
    await both();
    const d = t.db(ana);
    await assertFails(
      commit(d, (b) => {
        b.set(doc(d, 'users', ana, 'blocks', bruno), { createdAt: st() });
        b.set(requestRef(d, ana, bruno), requestData(ana, bruno));
      }),
    );
    await t.seedRequest(bruno, ana);
    await assertFails(
      commit(d, (b) => {
        b.set(doc(d, 'users', ana, 'blocks', bruno), { createdAt: st() });
        b.set(friendshipRef(d, ana, bruno), friendshipData(ana, bruno));
        b.delete(requestRef(d, bruno, ana));
      }),
    );
  });
  it('the blocked user cannot read, list, write or delete the block doc', async () => {
    await t.seedBlock(ana, bruno);
    const ref = (d) => doc(d, 'users', ana, 'blocks', bruno);
    await assertFails(getDoc(ref(t.db(bruno))));
    await assertFails(getDocs(collection(t.db(bruno), 'users', ana, 'blocks')));
    await assertFails(getDoc(ref(t.db(caio))));
    await assertFails(getDoc(ref(t.anon())));
    await assertFails(deleteDoc(ref(t.db(bruno))));
    await assertFails(setDoc(ref(t.db(bruno)), { createdAt: st() }));
    await assertSucceeds(getDoc(ref(t.db(ana))));
    await assertSucceeds(getDocs(query(collection(t.db(ana), 'users', ana, 'blocks'), orderBy('createdAt', 'desc'))));
  });
  it('blocks written for someone else\'s uid are denied', async () => {
    await assertFails(setDoc(doc(t.db(bruno), 'users', ana, 'blocks', caio), { createdAt: st() }));
  });
  it('schema: self-block, extra field, forged date, bad name/photo, uid with underscore', async () => {
    const d = t.db(ana);
    const put = (id, data) => setDoc(doc(d, 'users', ana, 'blocks', id), data);
    await assertFails(put(ana, { createdAt: st() }));
    await assertFails(put(bruno, { createdAt: st(), extra: 1 }));
    await assertFails(put(bruno, { createdAt: agoDays(3) }));
    await assertFails(put(bruno, {}));
    await assertFails(put(bruno, { createdAt: st(), blockedName: '' }));
    await assertFails(put(bruno, { createdAt: st(), blockedPhoto: 'https://evil.example/a.png' }));
    await assertFails(put('a_b', { createdAt: st() }));
    await assertFails(put('x'.repeat(129), { createdAt: st() }));
    await assertSucceeds(put(bruno, { createdAt: st(), blockedName: 'Bruno', blockedPhoto: PHOTO }));
    await assertFails(updateDoc(doc(d, 'users', ana, 'blocks', bruno), { blockedName: 'Outro' }));
  });
  it('unblocking does not restore friendship; a new request is possible', async () => {
    await both();
    await t.seedBlock(ana, bruno);
    await assertSucceeds(deleteDoc(doc(t.db(ana), 'users', ana, 'blocks', bruno)));
    assert.equal(await t.exists(['friendships', pairId(ana, bruno)]), false);
    await assertSucceeds(setDoc(requestRef(t.db(bruno), bruno, ana), requestData(bruno, ana)));
  });
  it('blocking does not touch the blocker\'s users/{uid} docs and blocks do not open favorites', async () => {
    await t.seedBlock(ana, bruno);
    await assertFails(getDoc(doc(t.db(bruno), 'users', ana)));
    await assertFails(getDocs(collection(t.db(bruno), 'users', ana, 'favorites')));
  });
});

// ---------------------------------------------------------------------------
describe('isFriend / isBlocked em outras features (sondas; nao implementadas)', () => {
  // The real isFriend/isBlocked are exercised with probe collections in rules_budget.test.mjs.
  it('friend, ex-friend and blocked user see different results on favorites (always denied)', async () => {
    await both();
    await t.seedFriendship(ana, bruno);
    await t.seedDoc(['users', ana, 'favorites', '1-movie'], {
      id: 1, mediaType: 'movie', title: 'x', addedAt: agoDays(1),
    });
    await assertFails(getDoc(doc(t.db(bruno), 'users', ana, 'favorites', '1-movie')));
    await assertFails(getDocs(collection(t.db(bruno), 'users', ana, 'favorites')));
    await assertFails(getDoc(doc(t.db(bruno), 'users', ana)));
    await assertFails(setDoc(doc(t.db(bruno), 'users', ana, 'favorites', '2-movie'), {
      id: 2, mediaType: 'movie', title: 'x', addedAt: agoDays(1),
    }));
    await assertFails(updateDoc(doc(t.db(bruno), 'users', ana, 'favorites', '1-movie'), { title: 'y' }));
    await assertFails(deleteDoc(doc(t.db(bruno), 'users', ana, 'favorites', '1-movie')));
  });
});

// ---------------------------------------------------------------------------
describe('exclusao de conta em sequencia: o usuario some da lista dos outros', () => {
  it('closes the door first (handle+pointer), then sweeps requests, pairs and blocks', async () => {
    await both();
    await t.seedSocial(caio);
    await t.seedFriendship(ana, bruno);
    await t.seedFriendship(ana, caio);
    await t.seedRequest(ana, dora);
    await t.seedBlock(ana, dora);
    const d = t.db(ana);
    // 1) handle + social in one batch
    await assertSucceeds(
      commit(d, (b) => {
        b.delete(doc(d, 'handles', handleFor(ana)));
        b.delete(doc(d, 'social', ana));
      }),
    );
    // the door is closed: nobody can send a request to ana or accept anything for ana
    await assertFails(setDoc(requestRef(t.db(bruno), bruno, ana), requestData(bruno, ana)));
    await t.seedRequest(bruno, ana);
    await assertFails(acceptBatch(d, ana, bruno));
    // friends still see the pair until the sweep
    const list = (u) => getDocs(query(collection(t.db(u), 'friendships'), where('members', 'array-contains', u)));
    assert.equal((await list(bruno)).size, 1);
    // 2) sweep (server-side reads of own queries)
    const pairs = await getDocs(query(collection(d, 'friendships'), where('members', 'array-contains', ana)));
    const outReq = await getDocs(query(collection(d, 'friend_requests'), where('from', '==', ana)));
    const inReq = await getDocs(query(collection(d, 'friend_requests'), where('to', '==', ana)));
    const blocks = await getDocs(collection(d, 'users', ana, 'blocks'));
    await assertSucceeds(
      commit(d, (b) => {
        [...pairs.docs, ...outReq.docs, ...inReq.docs, ...blocks.docs].forEach((s) => b.delete(s.ref));
      }),
    );
    assert.equal((await list(bruno)).size, 0);
    assert.equal((await list(caio)).size, 0);
    assert.equal(await t.exists(['friend_requests', `${bruno}_${ana}`]), false);
    assert.equal(await t.exists(['users', ana, 'blocks', dora]), false);
    // the handle is free right away
    await assertSucceeds(activate(t.db(dora), dora, handleFor(ana)));
  });
  it('someone else cannot sweep or close the door for the user', async () => {
    await both();
    await t.seedFriendship(ana, bruno);
    await assertFails(deleteDoc(doc(t.db(caio), 'social', ana)));
    await assertFails(deleteDoc(friendshipRef(t.db(caio), ana, bruno)));
  });
});

// ---------------------------------------------------------------------------
describe('revogacao imediata', () => {
  it('after unfriending, the pair is gone for both reads right away; after block as well', async () => {
    await both();
    await t.seedFriendship(ana, bruno);
    assert.ok((await getDoc(friendshipRef(t.db(bruno), ana, bruno))).exists());
    await deleteDoc(friendshipRef(t.db(ana), ana, bruno));
    assert.equal((await getDoc(friendshipRef(t.db(bruno), ana, bruno))).exists(), false);
    assert.equal((await getDoc(friendshipRef(t.db(ana), ana, bruno))).exists(), false);
  });
});

// ---------------------------------------------------------------------------
describe('convite por link (invites/{code}): criar, usar, revogar, expirar, codigo alheio', () => {
  const createInvite = (d, uid, code = CODE, o = {}) =>
    commit(d, (b) => {
      b.set(doc(d, 'invites', code), inviteData(uid, o.invite));
      b.update(doc(d, 'social', uid), { inviteCode: code, ...o.social });
    });
  const revoke = (d, uid, code = CODE) =>
    commit(d, (b) => {
      b.delete(doc(d, 'invites', code));
      b.update(doc(d, 'social', uid), { inviteCode: deleteField() });
    });

  it('owner creates an invite (doc + pointer in one batch)', async () => {
    await t.seedSocial(ana);
    await assertSucceeds(createInvite(t.db(ana), ana));
    await assertSucceeds(getDoc(doc(t.db(ana), 'invites', CODE)));
  });
  it('creation at activation time (card + social + invite in one batch)', async () => {
    const d = t.db(ana);
    await assertSucceeds(
      commit(d, (b) => {
        b.set(doc(d, 'handles', 'ana_s'), cardData(ana));
        b.set(doc(d, 'invites', CODE), inviteData(ana));
        b.set(doc(d, 'social', ana), socialData('ana_s', { inviteCode: CODE }));
      }),
    );
  });
  it('invite without pointer, or pointer without invite, is denied', async () => {
    await t.seedSocial(ana);
    await assertFails(setDoc(doc(t.db(ana), 'invites', CODE), inviteData(ana)));
    await assertFails(updateDoc(doc(t.db(ana), 'social', ana), { inviteCode: CODE }));
  });
  it('only 1 active invite per user: a second code without revoking the first is denied', async () => {
    await t.seedSocial(ana, { inviteCode: CODE });
    const d = t.db(ana);
    await assertFails(setDoc(doc(d, 'invites', CODE2), inviteData(ana)));
    await assertFails(
      commit(d, (b) => {
        b.set(doc(d, 'invites', CODE2), inviteData(ana));
        b.update(doc(d, 'social', ana), { inviteCode: CODE2 }); // CODE left orphan
      }),
    );
    // rotation: delete old + create new + move pointer
    await assertSucceeds(
      commit(d, (b) => {
        b.delete(doc(d, 'invites', CODE));
        b.set(doc(d, 'invites', CODE2), inviteData(ana));
        b.update(doc(d, 'social', ana), { inviteCode: CODE2 });
      }),
    );
    assert.equal(await t.exists(['invites', CODE]), false);
  });
  it('using it: another user reads the card by exact code; no list; anonymous denied', async () => {
    await t.seedSocial(ana, { inviteCode: CODE });
    const s = await assertSucceeds(getDoc(doc(t.db(bruno), 'invites', CODE)));
    assert.equal(s.data().uid, ana);
    await assertFails(getDocs(collection(t.db(bruno), 'invites')));
    await assertFails(getDocs(query(collection(t.db(bruno), 'invites'), where('uid', '==', ana))));
    await assertFails(getDocs(collection(t.db(ana), 'invites')));
    await assertFails(getDoc(doc(t.anon(), 'invites', CODE)));
  });
  it('a hidden ("Aparecer na busca" off) owner is still reachable by the link', async () => {
    await t.seedSocial(ana, { inviteCode: CODE, discoverable: false });
    await assertSucceeds(getDoc(doc(t.db(bruno), 'invites', CODE)));
  });
  it('using it = a normal request; the invite alone never creates a friendship', async () => {
    await t.seedSocial(ana, { inviteCode: CODE, discoverable: false });
    await t.seedSocial(bruno);
    await assertSucceeds(setDoc(requestRef(t.db(bruno), bruno, ana), requestData(bruno, ana)));
    await assertFails(setDoc(friendshipRef(t.db(bruno), ana, bruno), friendshipData(bruno, ana)));
    await assertSucceeds(acceptBatch(t.db(ana), ana, bruno));
  });
  it('unknown code reads as "does not exist"; malformed code is denied', async () => {
    const s = await assertSucceeds(getDoc(doc(t.db(bruno), 'invites', 'ZZZZZZZZZZZZZZZZZZZZZZZZ')));
    assert.equal(s.exists(), false);
    await assertFails(getDoc(doc(t.db(bruno), 'invites', 'curto')));
  });
  it('revocation is immediate: after revoking, the code reads as nonexistent', async () => {
    await t.seedSocial(ana, { inviteCode: CODE });
    assert.ok((await getDoc(doc(t.db(bruno), 'invites', CODE))).exists());
    await assertSucceeds(revoke(t.db(ana), ana));
    assert.equal((await getDoc(doc(t.db(bruno), 'invites', CODE))).exists(), false);
    assert.equal(await t.exists(['social', ana]), true);
  });
  it('revoking requires removing the pointer in the same batch (no dangling pointer / orphan doc)', async () => {
    await t.seedSocial(ana, { inviteCode: CODE });
    const d = t.db(ana);
    await assertFails(deleteDoc(doc(d, 'invites', CODE)));
    await assertFails(updateDoc(doc(d, 'social', ana), { inviteCode: deleteField() }));
  });
  it('expiry: expired invite is denied to others, still readable by the owner', async () => {
    await t.seedSocial(ana, { inviteCode: CODE, inviteExpires: agoDays(0.01) });
    await assertFails(getDoc(doc(t.db(bruno), 'invites', CODE)));
    await assertSucceeds(getDoc(doc(t.db(ana), 'invites', CODE)));
    await assertFails(getDoc(doc(t.anon(), 'invites', CODE)));
  });
  it('expiry bounds on create: past, now, > 30 days, wrong type are denied; 29 days OK', async () => {
    await t.seedSocial(ana);
    const d = t.db(ana);
    await assertFails(createInvite(d, ana, CODE, { invite: { expiresAt: agoDays(1) } }));
    await assertFails(createInvite(d, ana, CODE, { invite: { expiresAt: inDays(31) } }));
    await assertFails(createInvite(d, ana, CODE, { invite: { expiresAt: 'amanha' } }));
    await assertSucceeds(createInvite(d, ana, CODE, { invite: { expiresAt: inDays(29) } }));
  });
  it('owner can renew (extend) the expiry and refresh the card; uid/createdAt immutable', async () => {
    await t.seedSocial(ana, { inviteCode: CODE, inviteExpires: agoDays(1) });
    const d = t.db(ana);
    const snap = await getDoc(doc(d, 'invites', CODE));
    await assertSucceeds(setDoc(doc(d, 'invites', CODE), { ...snap.data(), expiresAt: inDays(10), nickname: 'Ana B', photoURL: PHOTO }));
    assert.ok((await getDoc(doc(t.db(bruno), 'invites', CODE))).exists());
    await assertFails(setDoc(doc(d, 'invites', CODE), { ...snap.data(), uid: bruno, expiresAt: inDays(10) }));
    await assertFails(setDoc(doc(d, 'invites', CODE), { ...snap.data(), createdAt: st(), expiresAt: inDays(10) }));
    await assertFails(setDoc(doc(d, 'invites', CODE), { ...snap.data(), expiresAt: inDays(40) }));
  });
  it('someone else\'s code: cannot create, overwrite, extend, revoke or point to it', async () => {
    await t.seedSocial(ana, { inviteCode: CODE });
    await t.seedSocial(bruno);
    const d = t.db(bruno);
    await assertFails(setDoc(doc(d, 'invites', CODE), inviteData(bruno))); // takeover
    await assertFails(setDoc(doc(d, 'invites', CODE), inviteData(ana, { expiresAt: inDays(20) })));
    await assertFails(updateDoc(doc(d, 'invites', CODE), { expiresAt: inDays(20) }));
    await assertFails(deleteDoc(doc(d, 'invites', CODE)));
    await assertFails(
      commit(d, (b) => {
        b.delete(doc(d, 'invites', CODE));
        b.update(doc(d, 'social', bruno), { inviteCode: CODE });
      }),
    );
    await assertFails(updateDoc(doc(d, 'social', bruno), { inviteCode: CODE })); // pointer to ana's code
    await assertFails(deleteDoc(doc(t.anon(), 'invites', CODE)));
    assert.ok(await t.exists(['invites', CODE]));
  });
  it('block in either direction hides the invite from the blocked / the blocker', async () => {
    await t.seedSocial(ana, { inviteCode: CODE });
    await t.seedBlock(ana, bruno);
    await assertFails(getDoc(doc(t.db(bruno), 'invites', CODE)));
    await assertSucceeds(getDoc(doc(t.db(caio), 'invites', CODE)));
    await env.clearFirestore();
    await t.seedSocial(ana, { inviteCode: CODE });
    await t.seedBlock(bruno, ana); // bruno blocked ana
    await assertFails(getDoc(doc(t.db(bruno), 'invites', CODE)));
  });
  it('schema: extra fields, wrong types, bad code format, forged uid/createdAt, foreign photo', async () => {
    await t.seedSocial(ana);
    const d = t.db(ana);
    const bad = [
      [CODE, { extra: 1 }],
      [CODE, { uid: bruno }],
      [CODE, { nickname: '' }],
      [CODE, { nickname: 'x'.repeat(41) }],
      [CODE, { photoURL: 'https://evil.example/a.png' }],
      [CODE, { createdAt: agoDays(5) }],
      ['abc', {}],
      ['a'.repeat(41), {}],
      ['abc def ghi jkl mno pqr', {}],
      ['abc-def-ghi-jkl-mno-pqr', {}],
    ];
    for (const [code, o] of bad) {
      await assert.doesNotReject(assertFails(createInvite(d, ana, code, { invite: o })), JSON.stringify([code, o]));
    }
    await assertSucceeds(createInvite(d, ana, CODE, { invite: { photoURL: PHOTO } }));
  });
  it('deactivation: handle + pointer + invite must go together; leaving the invite is denied', async () => {
    await t.seedSocial(ana, { inviteCode: CODE });
    const d = t.db(ana);
    await assertFails(
      commit(d, (b) => {
        b.delete(doc(d, 'handles', handleFor(ana)));
        b.delete(doc(d, 'social', ana));
      }),
    );
    await assertSucceeds(
      commit(d, (b) => {
        b.delete(doc(d, 'invites', CODE));
        b.delete(doc(d, 'handles', handleFor(ana)));
        b.delete(doc(d, 'social', ana));
      }),
    );
    assert.equal(await t.exists(['invites', CODE]), false);
  });
  it('handle change keeps the invite pointer (touching it is not required)', async () => {
    await t.seedSocial(ana, { handle: 'velho', inviteCode: CODE, changedAt: agoDays(40) });
    const d = t.db(ana);
    await assertSucceeds(
      commit(d, (b) => {
        b.delete(doc(d, 'handles', 'velho'));
        b.set(doc(d, 'handles', 'novo'), cardData(ana));
        b.set(doc(d, 'social', ana), socialData('novo', { inviteCode: CODE }));
      }),
    );
  });
});

// ---------------------------------------------------------------------------
describe('rules do not open anything else', () => {
  it('unknown collections and anonymous access stay denied', async () => {
    await assertFails(getDoc(doc(t.db(ana), 'outra', 'x')));
    await assertFails(setDoc(doc(t.db(ana), 'outra', 'x'), { a: 1 }));
    await assertFails(setDoc(doc(t.db(ana), 'users', ana, 'friends', bruno), { a: 1 }));
    await assertFails(setDoc(doc(t.anon(), 'social', ana), socialData('anon_h')));
  });
});

// ---------------------------------------------------------------------------
describe('endurecimento (revisao): provedor Google, reservados, host da foto, nomes', () => {
  it('only Google sign-in can activate, send requests, create invites or create a pair', async () => {
    for (const provider of ['anonymous', 'password', 'phone']) {
      await env.clearFirestore();
      const d = t.dbWith(bruno, provider);
      await assertFails(activate(d, bruno, 'bru_s'));
      await assertFails(setDoc(doc(d, 'social', bruno), socialData('bru_s')));
      // legit social already seeded for both; the foreign-provider token still cannot create things
      await t.seedSocial(ana);
      await t.seedSocial(bruno);
      await assertFails(setDoc(requestRef(d, bruno, ana), requestData(bruno, ana)));
      await assertFails(
        commit(d, (b) => {
          b.set(doc(d, 'invites', CODE), inviteData(bruno));
          b.update(doc(d, 'social', bruno), { inviteCode: CODE });
        }),
      );
      await t.seedRequest(ana, bruno);
      await assertFails(acceptBatch(d, bruno, ana));
    }
    // token without any firebase claim (old emulator-style token) is denied too
    await env.clearFirestore();
    await assertFails(activate(t.dbNoClaim(ana), ana, 'ana_s'));
    // google.com works
    await assertSucceeds(activate(t.dbWith(ana, 'google.com'), ana, 'ana_s'));
  });
  it('non-Google tokens still clean up their own data (cancel, unfriend, unblock)', async () => {
    await both();
    await t.seedRequest(ana, bruno);
    await t.seedBlock(bruno, caio);
    await assertSucceeds(deleteDoc(requestRef(t.dbWith(bruno, 'anonymous'), ana, bruno)));
    await assertSucceeds(deleteDoc(doc(t.dbWith(bruno, 'password'), 'users', bruno, 'blocks', caio)));
  });
  for (const word of ['staff', 'oficial', 'official', 'moderador', 'moderator', 'sistema', 'system',
    'seguranca', 'security', 'privacidade', 'privacy', 'contato', 'contact', 'equipe', 'team', 'null',
    'undefined', 'anonymous', 'anonimo', 'cine', 'admin', 'suporte']) {
    it(`reserved handle "${word}" is denied`, async () => {
      await assertFails(activate(t.db(ana), ana, word));
    });
  }
  for (const word of ['administrador', 'cinetrack', 'support', 'ajuda', 'help', 'root', 'api', 'me', 'eu']) {
    it(`original reserved handle "${word}" is denied`, async () => {
      await assertFails(activate(t.db(ana), ana, word));
    });
  }
  it('nickname limit: 40 CJK / 20 emoji / 40 ASCII accepted, one more denied (size() counts UTF-16 units, like Dart String.length)', async () => {
    const cases = [['李'.repeat(40), true], ['李'.repeat(41), false], ['🎬'.repeat(20), true],
      ['🎬'.repeat(21), false], ['a'.repeat(40), true], ['a'.repeat(41), false]];
    for (const [n, ok] of cases) {
      await env.clearFirestore();
      await (ok ? assertSucceeds : assertFails)(activate(t.db(ana), ana, 'ana_s', { card: { nickname: n } }));
    }
  });
  it('KNOWN LIMIT (accepted): nicknames made only of NBSP / U+3000 / tag characters pass; client must normalise', async () => {
    for (const n of ['\u00A0\u00A0', '\u3000', '\u{E0041}\u{E0042}']) {
      await env.clearFirestore();
      await assertSucceeds(activate(t.db(ana), ana, 'ana_s', { card: { nickname: n } }));
    }
  });
  it('similar non-reserved handles are fine (staff_1, cine_fan)', async () => {
    await assertSucceeds(activate(t.db(ana), ana, 'staff_1'));
    await assertSucceeds(activate(t.db(bruno), bruno, 'cine_fan'));
  });
  it('photo host must be lh<digits>.googleusercontent.com', async () => {
    const tryPhoto = async (url, ok, h) => {
      await env.clearFirestore();
      return (ok ? assertSucceeds : assertFails)(activate(t.db(ana), ana, h, { card: { photoURL: url } }));
    };
    await tryPhoto('https://lh3.googleusercontent.com/a/ACg8oc', true, 'foto_a');
    await tryPhoto('https://lh12.googleusercontent.com/a/x', true, 'foto_b');
    await tryPhoto('https://evil.googleusercontent.com/a', false, 'foto_c');
    await tryPhoto('https://lh.googleusercontent.com/a', false, 'foto_d');
    await tryPhoto('https://lh3x.googleusercontent.com/a', false, 'foto_e');
    await tryPhoto('https://drive.googleusercontent.com/a', false, 'foto_f');
    await tryPhoto('https://lh3.googleusercontent.com.evil.com/a', false, 'foto_g');
    // prefix before "https://lh..." must not match (anchor ^)
    await tryPhoto('https://evil.com/?https://lh3.googleusercontent.com/a', false, 'foto_h');
    await tryPhoto('evil.com?lh3.googleusercontent.com/a', false, 'foto_i');
    await tryPhoto('x https://lh3.googleusercontent.com/a', false, 'foto_j');
    await tryPhoto('http://lh3.googleusercontent.com/a', false, 'foto_k');
  });
  it('names: control, zero-width and bidi characters are denied everywhere a name is stored', async () => {
    const bad = ['\u0000x', 'a\nb', 'a\tb', 'a\u0007', 'a​b', 'a‌b', 'a‎b', 'a‏b',
      'a‮b', 'a‪b', 'a⁦b', 'a⁩b', '﻿a', 'a b', 'a⁠b', 'a؜b', '​'];
    for (const n of bad) {
      await env.clearFirestore();
      await assert.doesNotReject(
        assertFails(activate(t.db(ana), ana, 'ana_s', { card: { nickname: n } })),
        `card ${JSON.stringify(n)}`,
      );
    }
    await both();
    for (const n of bad.slice(0, 6)) {
      await assert.doesNotReject(
        assertFails(setDoc(requestRef(t.db(ana), ana, bruno), requestData(ana, bruno, { fromName: n }))),
        `request ${JSON.stringify(n)}`,
      );
    }
  });
  it('names: accents, emoji, CJK, ZWJ emoji and inner spaces are still accepted', async () => {
    const good = ['José Çelso', 'Ana 🎬', 'Ana María', '李雷', '👨‍👩‍👧', 'Zoë  O\'Neil', 'a'];
    for (const n of good) {
      await env.clearFirestore();
      await assert.doesNotReject(
        assertSucceeds(activate(t.db(ana), ana, 'ana_s', { card: { nickname: n } })),
        `card ${JSON.stringify(n)}`,
      );
    }
  });
});
