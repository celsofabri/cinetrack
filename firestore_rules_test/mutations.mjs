// Mutation check (docs/51): removes ONE critical check from a copy of firestore.rules and
// proves that at least one test fails. Run: npm run test:mutations (starts the emulator).
// Never touches ../firestore.rules: mutated copies live in the OS temp dir.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const rules = readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8');

// Suites that kill the Phase 2 mutations (SP*).
const SP = ['shared_profile.test.mjs', 'favorites_epsat.test.mjs', 'social_compat.test.mjs', 'rules_budget.test.mjs'];

const MUTATIONS = [
  ['M1 friendship without the other side\'s request (no consent)',
    [["let req = get(requestPath(other, me)).data;", "let req = {'fromName': (d.members[0] == other ? d.aName : d.bName), 'fromPhoto': d.get(d.members[0] == other ? 'aPhoto' : 'bPhoto', null)};"]]],
  ['M2 accept does not consume the request',
    [["        && !existsAfter(requestPath(other, me))\n", "\n"]]],
  ['M3 request ignores blocks', [["        && !isBlockedEither(d.from, d.to)\n", "\n"]]],
  ['M4 block does not require removing the friendship', [["        && !existsAfter(friendshipPath(uid, blocked))\n", "\n"]]],
  ['M5 handle change without the 30-day interval',
    [["                 && resource.data.handleChangedAt + duration.value(30, 'd') <= request.time\n", "\n"]]],
  ['M6 handle card without the pointer (1 handle per user / uniqueness link)',
    [["        && request.resource.data.createdAt == request.time\n        && getAfter(socialPath(request.auth.uid)).data.handle == h;", "        && request.resource.data.createdAt == request.time;"]]],
  ['M7 expired invite still readable', [["            || (resource.data.expiresAt > request.time\n                && !isBlockedEither(resource.data.uid, request.auth.uid)));\n      allow list: if false;", "            || (!isBlockedEither(resource.data.uid, request.auth.uid)));\n      allow list: if false;"]]],
  ['M8 a member edits the other member\'s half',
    [["request.auth.uid == resource.data.members[0] ? ['aName', 'aPhoto'] : ['bName', 'bPhoto']", "['aName', 'aPhoto', 'bName', 'bPhoto']"]]],
  ['M9 hidden card readable by anyone', [["            || (resource.data.discoverable == true\n                && !isBlockedEither", "            || (true\n                && !isBlockedEither"]]],
  ['M10 favorites opened to friends',
    [["        allow read, delete: if isOwner(uid);\n        allow create: if isOwner(uid) && validFavorite(key);", "        allow read: if isOwner(uid) || isFriend(uid, request.auth.uid);\n        allow delete: if isOwner(uid);\n        allow create: if isOwner(uid) && validFavorite(key);"]]],
  ['M11 third party deletes someone else\'s request',
    [["            : request.auth.uid in [resource.data.from, resource.data.to]);\n    }\n\n    // --- friendships", "            : true);\n    }\n\n    // --- friendships"]]],
  ['M12 invite without the pointer (unbounded invites per user)',
    [["        && request.resource.data.createdAt == request.time\n        && getAfter(socialPath(request.auth.uid)).data.get('inviteCode', null) == code;\n      allow update", "        && request.resource.data.createdAt == request.time;\n      allow update"]]],
  ['M13 uid with "_" accepted (ambiguous composite ids)',
    [["return u is string && u.matches('^[^_/]{1,128}$');", "return u is string && u.matches('^.{1,128}$');"]]],
  ['M14 block create does not require removing pending requests',
    [["        && !existsAfter(requestPath(uid, blocked))\n        && !existsAfter(requestPath(blocked, uid));", ";"]]],
  ['M15 any sign-in provider accepted (anonymous/password can squat)',
    [["return request.auth != null && request.auth.token.firebase.sign_in_provider == 'google.com';", "return request.auth != null;"]]],
  ['M16 friend request creation without the Google check',
    [["allow create: if isGoogle() && validRequest(key);", "allow create: if request.auth != null && validRequest(key);"]]],
  ['M17 invite creation without the Google check',
    [["      allow create: if isGoogle() && validInviteCode(code)\n", "      allow create: if request.auth != null && validInviteCode(code)\n"]]],
  ['M18 reserved handle list shortened ("staff" allowed)', [["'staff', ", ""]]],
  ['M19 photo host loosened to any googleusercontent subdomain',
    [["^https://lh[0-9]+[.]googleusercontent[.]com/.*$", "^https://[A-Za-z0-9-]+[.]googleusercontent[.]com/.*$"]]],
  ['M20 names accept control/zero-width/bidi characters', [["&& !s.matches('(?s).*[", "&& !s.matches('(?s)NEVERMATCH_.*["]]],
  ['M21 photo regex without the start anchor (prefix before lh accepted)',
    [["'^https://lh[0-9]+[.]googleusercontent[.]com/.*$'", "'^.*https://lh[0-9]+[.]googleusercontent[.]com/.*$'"]]],
  ['M22 reserved list: "admin" allowed', [["'admin', ", ""]]],
  // Slice 3 (docs/62): killed by the replay of the Dart payloads (dart_payloads.test.mjs).
  ['M23 accept (or crossed request) leaves MY pending request behind',
    [["        && !existsAfter(requestPath(other, me))\n        && !existsAfter(requestPath(me, other));", "        && !existsAfter(requestPath(other, me));"]], true],
  ['M24 a third party removes a friendship',
    [["            : request.auth.uid in resource.data.members);\n    }\n\n    // --- users", "            : true);\n    }\n\n    // --- users"]], true],
  ['M25 the other person\'s half of a friendship can be forged',
    [["        && (otherIsA ? d.aName : d.bName) == req.fromName\n", "\n"]], true],
  ['M26 the sender confirms their own request (accept without the other side\'s request)',
    [["let req = get(requestPath(other, me)).data;", "let req = get(requestPath(me, other)).data;"]], true],
  // Slice 4 (docs/65): block / unblock; killed by the replay of the Dart payloads.
  ['M27 the blocked person can read the block (any signed-in user reads blocks)',
    [["      allow read: if isOwner(uid);\n      allow create: if isOwner(uid)\n        && request.resource.data.keys().hasOnly(['blockedName'", "      allow read: if request.auth != null;\n      allow create: if isOwner(uid)\n        && request.resource.data.keys().hasOnly(['blockedName'"]], true],
  ['M28 block create does not require removing the RECEIVED request',
    [["        && !existsAfter(requestPath(uid, blocked))\n        && !existsAfter(requestPath(blocked, uid));", "        && !existsAfter(requestPath(uid, blocked));"]], true],
  ['M29 block create does not require removing the SENT request',
    [["        && !existsAfter(requestPath(uid, blocked))\n        && !existsAfter(requestPath(blocked, uid));", "        && !existsAfter(requestPath(blocked, uid));"]], true],
  ['M30 somebody else deletes (unblocks) my block',
    [["      allow update: if false;\n      allow delete: if isOwner(uid);\n    }\n\n    // --- social", "      allow update: if false;\n      allow delete: if request.auth != null;\n    }\n\n    // --- social"]], true],
  ['M31 self-block accepted',
    [["        && validUid(blocked) && blocked != uid\n", "        && validUid(blocked)\n"]], true],
  ['M32 blocking twice (an update of the block) accepted',
    [["      allow update: if false;\n      allow delete: if isOwner(uid);\n    }\n\n    // --- social", "      allow update: if isOwner(uid);\n      allow delete: if isOwner(uid);\n    }\n\n    // --- social"]], true],
  ['M33 block name not validated (zero-width / 41 chars accepted)',
    [["        && (!('blockedName' in request.resource.data) || validName(request.resource.data.blockedName))\n", "\n"]], true],
  // Slice 5 (docs/68): invite link; killed by social.test.mjs and/or the replay of the payloads.
  ['M34 invite expiry capped at 30 days removed (an invite that never expires)',
    [["        && d.expiresAt > request.time\n        && d.expiresAt <= request.time + duration.value(30, 'd');", "        && d.expiresAt > request.time;"]], true],
  ['M35 the invite of somebody who blocked me (or whom I blocked) is readable',
    [["            || (resource.data.expiresAt > request.time\n                && !isBlockedEither(resource.data.uid, request.auth.uid)));\n      allow list: if false;", "            || (resource.data.expiresAt > request.time));\n      allow list: if false;"]], true],
  ['M36 revoking (deleting) an invite does not require moving the pointer',
    [["      allow delete: if request.auth != null && isOwner(resource.data.uid)\n        && (!existsAfter(socialPath(request.auth.uid))\n            || getAfter(socialPath(request.auth.uid)).data.get('inviteCode', null) != code);", "      allow delete: if request.auth != null && isOwner(resource.data.uid);"]], true],
  ['M37 the pointer can move to another invite without deleting the old one (2 active invites)',
    [["            && (o == null || !existsAfter(invitePath(o))));", "            );"]], true],
  ['M38 the invite format allows a short code (8 characters)',
    [["c.matches('^[A-Za-z0-9]{22,40}$')", "c.matches('^[A-Za-z0-9]{8,40}$')"]], true],
  // Fechamento (docs/73): request bound to the sender's @handle; hidden users keep using friendships.
  ['M39 request not bound to the sender\'s handle (any fromHandle accepted: impersonation)',
    [["        && get(socialPath(d.from)).data.handle == d.fromHandle\n", "        && exists(socialPath(d.from))\n"]], true],
  ['M40 the sender must be visible in the search ("Aparecer na busca" off cannot send)',
    [["        && get(socialPath(d.from)).data.handle == d.fromHandle\n", "        && get(socialPath(d.from)).data.handle == d.fromHandle\n        && get(handlePath(d.fromHandle)).data.discoverable == true\n"]], true],
  // Phase 2, Fatia 0 (docs/84): shared_profiles/{uid} and favorites.epsAt. Third element = suites
  // to run (SP); killed by shared_profile / favorites_epsat / social_compat / rules_budget.
  ['SP1 friend read without isFriend (any Google user reads every shared profile)',
    [["allow get: if isOwner(uid) || (isGoogle() && isFriend(uid, request.auth.uid));", "allow get: if isOwner(uid) || (isGoogle());"]], SP],
  ['SP2 friend read without the Google check',
    [["allow get: if isOwner(uid) || (isGoogle() && isFriend(uid, request.auth.uid));", "allow get: if isOwner(uid) || (request.auth != null && isFriend(uid, request.auth.uid));"]], SP],
  ['SP3 list (enumeration) opened to signed-in users',
    [["      allow list: if false;\n      // Primeiro interruptor", "      allow list: if request.auth != null;\n      // Primeiro interruptor"]], SP],
  ['SP4 friend read pays an extra exists(social) (2 rules calls per profile open)',
    [["allow get: if isOwner(uid) || (isGoogle() && isFriend(uid, request.auth.uid));", "allow get: if isOwner(uid) || (isGoogle() && isFriend(uid, request.auth.uid) && exists(socialPath(uid)));"]], SP],
  ['SP5 create without the Google check',
    [["      allow create: if isGoogle() && isOwner(uid) && validUid(uid)\n", "      allow create: if isOwner(uid) && validUid(uid)\n"]], SP],
  ['SP6 create without isOwner (a friend creates the owner\'s profile)',
    [["      allow create: if isGoogle() && isOwner(uid) && validUid(uid)\n", "      allow create: if isGoogle() && validUid(uid)\n"]], SP],
  ['SP7 create without validUid',
    [["      allow create: if isGoogle() && isOwner(uid) && validUid(uid)\n", "      allow create: if isGoogle() && isOwner(uid)\n"]], SP],
  ['SP8 create without social/{uid} (friendships off can publish)',
    [["        && sharedSectionsOk(request.resource.data, request.resource.data.keys())\n        && exists(socialPath(uid));", "        && sharedSectionsOk(request.resource.data, request.resource.data.keys());"]], SP],
  ['SP9 create without validShared',
    [["        && validShared(request.resource.data)\n        && sharedSectionsOk(request.resource.data, request.resource.data.keys())", "        && sharedSectionsOk(request.resource.data, request.resource.data.keys())"]], SP],
  ['SP10 create without sharedSectionsOk',
    [["        && sharedSectionsOk(request.resource.data, request.resource.data.keys())\n", "\n"]], SP],
  ['SP11 update without isOwner',
    [["      allow update: if isOwner(uid)\n        && validShared(request.resource.data)\n", "      allow update: if request.auth != null\n        && validShared(request.resource.data)\n"]], SP],
  ['SP12 update without validShared',
    [["      allow update: if isOwner(uid)\n        && validShared(request.resource.data)\n", "      allow update: if isOwner(uid)\n"]], SP],
  ['SP13 update does not revalidate changed sections',
    [["sharedSectionsOk(request.resource.data, request.resource.data.diff(resource.data).affectedKeys())", "true"]], SP],
  ['SP14 consent change without social/{uid}',
    [["            || (isGoogle() && exists(socialPath(uid))));", "            || (isGoogle()));"]], SP],
  ['SP15 consent change without the Google check',
    [["            || (isGoogle() && exists(socialPath(uid))));", "            || (exists(socialPath(uid))));"]], SP],
  ['SP16 changing actSince is not treated as a consent change',
    [["hasAny(['sharing', 'actSince'])", "hasAny(['sharing'])"]], SP],
  ['SP17 recalculation pays an exists(social) (and fails without social)',
    [["        && (!request.resource.data.diff(resource.data).affectedKeys().hasAny(['sharing', 'actSince'])\n", "        && exists(socialPath(uid)) && (!request.resource.data.diff(resource.data).affectedKeys().hasAny(['sharing', 'actSince'])\n"]], SP],
  ['SP18 anyone signed in deletes a shared profile',
    [["      allow delete: if isOwner(uid);\n    }\n\n    // Everything", "      allow delete: if request.auth != null;\n    }\n\n    // Everything"]], SP],
  ['SP19 document keys not closed (hasOnly removed)',
    [["      return d.keys().hasOnly(['v', 'calc', 'updatedAt', 'tz', 'sharing', 'actSince', 'stats', 'activity', 'recs'])\n        && d.keys().hasAll", "      return d.keys().hasAll"]], SP],
  ['SP20 v not pinned to 1', [["        && d.v == 1 && d.calc is int", "        && d.calc is int"]], SP],
  ['SP21 calc not an int', [["&& d.calc is int && d.calc >= 1", "&& d.calc >= 1"]], SP],
  ['SP22 calc >= 1 removed', [["&& d.calc is int && d.calc >= 1", "&& d.calc is int"]], SP],
  ['SP23 updatedAt from the client accepted', [["        && d.updatedAt == request.time\n        && d.tz", "        && d.updatedAt is timestamp\n        && d.tz"]], SP],
  ['SP24 tz not an int', [["&& d.tz is int && d.tz >= -840", "&& d.tz >= -840"]], SP],
  ['SP25 tz lower bound removed', [["&& d.tz >= -840 && d.tz <= 840", "&& d.tz <= 840"]], SP],
  ['SP26 tz upper bound removed', [["&& d.tz >= -840 && d.tz <= 840", "&& d.tz >= -840"]], SP],
  ['SP27 empty sharing accepted', [["&& s is map && s.size() >= 1 && s.keys()", "&& s is map && s.keys()"]], SP],
  ['SP28 unknown sharing keys accepted', [[" && s.keys().hasOnly(['stats', 'activity', 'recs'])\n", "\n"]], SP],
  ['SP29 sharing values other than true accepted', [["        && s.values().hasOnly([true])\n", "\n"]], SP],
  ['SP30 stats section without stats consent', [["        && ('stats' in d) == ('stats' in s)\n", "\n"]], SP],
  ['SP31 activity section without activity consent', [["        && ('activity' in d) == ('activity' in s)\n", "\n"]], SP],
  ['SP32 recs section without recs consent', [["        && ('recs' in d) == ('recs' in s)\n", "\n"]], SP],
  ['SP33 actSince decoupled from the activity consent', [["        && ('actSince' in d) == ('activity' in s);", ";"]], SP],
  ['SP34 stats keys not closed', [["      return s is map\n        && s.keys().hasOnly(['total', 'month', 'year', 'undatedMovies', 'undatedEpisodes', 'datedFrom', 'memberSince'])\n", "      return s is map\n"]], SP],
  ['SP35 stats.total keys not closed', [["        && s.total.keys().hasOnly(['favorites', 'movies', 'series', 'watchedMovies', 'watchedEpisodes',\n                                   'watchedSeries', 'completedSeries', 'minutes', 'estimated', 'unknown'])\n", "\n"]], SP],
  ['SP36 stats.month keys not closed', [["        && s.month.keys().hasOnly(['key', 'watchedMovies', 'watchedEpisodes', 'watchedSeries',\n                                   'completedSeries', 'minutes', 'estimated', 'unknown'])\n", "\n"]], SP],
  ['SP37 stats.year keys not closed', [["        && s.year.keys().hasOnly(['key', 'watchedMovies', 'watchedEpisodes', 'watchedSeries',\n                                  'completedSeries', 'minutes', 'estimated', 'unknown'])\n", "\n"]], SP],
  ...['watchedMovies', 'watchedEpisodes', 'watchedSeries', 'completedSeries', 'minutes'].map((m, i) =>
    [`SP${38 + i} ranking metric ${m} may be negative/missing`, [[`p.${m} >= 0`, 'true']], SP]),
  ...['total', 'month', 'year'].map((sl, i) =>
    [`SP${43 + i} ranking metrics of stats.${sl} not checked`, [[`rankOk(s.${sl})`, 'true']], SP]),
  // SP46 (year.key format removed) is EQUIVALENT and was dropped after surviving the 2026-10-10 run:
  // month.key must match ^20YY-MM and month.key.split('-')[0] == year.key, which already forces
  // year.key = '20YY'. The year regex stays in the rules as defense in depth (docs/84).
  ['SP47 month.key format not checked', [["&& s.month.key is string && s.month.key.matches('^20[0-9]{2}-(0[1-9]|1[0-2])$')", "&& s.month.key is string"]], SP],
  ['SP48 month.key accepts month 00/13', [["(0[1-9]|1[0-2])", "[0-9]{2}"]], SP],
  ['SP49 month.key year differs from year.key', [["        && s.month.key.split('-')[0] == s.year.key;", ";"]], SP],
  ['SP50 more than 10 activities', [["      return l is list && l.size() <= 10\n", "      return l is list\n"]], SP],
  ...Array.from({ length: 10 }, (_, i) =>
    [`SP${51 + i} activity #${i} may predate actSince`, [[`(l.size() <= ${i} || l[${i}].at >= since)`, 'true']], SP]),
  ['SP61 activities not revalidated when actSince changes',
    [["((!('activity' in ch) && !('actSince' in ch)) || !('activity' in d)", "(!('activity' in ch) || !('activity' in d)"]], SP],
  ['SP62 recs keys not closed', [["      return r is map && r.keys().hasOnly(['count', 'items']) && r.keys().hasAll", "      return r is map && r.keys().hasAll"]], SP],
  ['SP63 recs.items not a list', [["        && r.items is list && r.items.size() <= 50", "        && r.items.size() <= 50"]], SP],
  ['SP64 more than 50 recommended items', [["        && r.items is list && r.items.size() <= 50", "        && r.items is list"]], SP],
  ['SP65 recs.count not an int', [["        && r.count is int && r.count >= r.items.size()", "        && r.count >= r.items.size()"]], SP],
  ['SP66 recs.count below the number of items', [["&& r.count >= r.items.size() && r.count <= 100000", "&& r.count <= 100000"]], SP],
  ['SP67 recs.count without cap', [["&& r.count >= r.items.size() && r.count <= 100000", "&& r.count >= r.items.size()"]], SP],
  ['SP68 changed stats not validated', [["validStats(d.stats))", "true)"]], SP],
  ['SP69 changed activity not validated', [["validActivities(d.activity, d.actSince))", "true)"]], SP],
  ['SP70 changed recs not validated', [["validRecs(d.recs))", "true)"]], SP],
  ['SP71 actSince from the client accepted', [["|| d.actSince == request.time);", "|| d.actSince is timestamp);"]], SP],
  ['SP72 favorites: epsAt not allowed (new app payload denied)', [["'recommended', 'epsAt'])", "'recommended'])"]], SP],
  ['SP73 favorites: epsAt not a map accepted', [["(d.epsAt is map && d.epsAt.size() <= 5000)", "(d.epsAt.size() <= 5000)"]], SP],
  ['SP74 favorites: epsAt without the 5000 cap', [["(d.epsAt is map && d.epsAt.size() <= 5000)", "(d.epsAt is map)"]], SP],
  ['SP75 favorites opened to friends of a shared profile',
    [["        allow read, delete: if isOwner(uid);\n        allow create: if isOwner(uid) && validFavorite(key);", "        allow read: if isOwner(uid) || (isGoogle() && isFriend(uid, request.auth.uid));\n        allow delete: if isOwner(uid);\n        allow create: if isOwner(uid) && validFavorite(key);"]], SP],
];

// Mutations of the PAYLOADS (the Dart side) instead of the rules: a deliberately broken copy of the
// fixture is replayed against the REAL rules; the replay must fail (the golden Dart test pins the
// real fixture, so the same change in Dart fails there first).
const FIXTURE_MUTATIONS = [
  ['F1 block payload forgets to delete the friendship',
    (fx) => dropOp(fx, 'friendships/')],
  ['F2 block payload forgets to delete the request I sent',
    (fx) => dropOp(fx, 'friend_requests/uid-ana_uid-bruno')],
  ['F3 block payload forgets to delete the request I received',
    (fx) => dropOp(fx, 'friend_requests/uid-bruno_uid-ana')],
  ['F4 block payload writes the block on the OTHER person\'s uid',
    (fx) => {
      for (const n of ['blockUser', 'blockUser_with_photo', 'blockUser_bare']) {
        fx.scenarios[n].write.ops[0].path = 'users/uid-bruno/blocks/uid-ana';
      }
    }],
  // Slice 5 (docs/68): invite link and refresh of halves.
  ['F5 invite payload uses a SHORT code (21 characters)',
    (fx) => {
      for (const n of ['createInvite', 'createInvite_with_photo', 'createInvite_replaces']) {
        const w = fx.scenarios[n].write;
        const short = fx.scenarios[n].input.code.slice(0, 21);
        for (const op of w.ops) {
          if (op.op === 'set' && op.path.startsWith('invites/')) op.path = `invites/${short}`;
          if (op.data?.inviteCode) op.data.inviteCode = short;
        }
      }
    }],
  ['F6 invite payload expires in 31 days (over the 30-day cap)',
    (fx) => {
      for (const n of ['createInvite', 'createInvite_with_photo', 'createInvite_replaces']) {
        for (const op of fx.scenarios[n].write.ops) {
          if (op.data?.expiresAt) op.data.expiresAt = `${fx.clientTimePlusPrefix}${31 * 24 * 3600 * 1000}`;
        }
      }
    }],
  ['F7 revoke deletes the invite but does not move the pointer',
    (fx) => {
      const w = fx.scenarios.revokeInvite.write;
      w.ops = w.ops.filter((o) => o.op !== 'update');
    }],
  ['F8 refresh writes the OTHER person\'s half of the friendship',
    (fx) => {
      for (const n of ['refreshHalves', 'refreshHalves_photo_removed']) {
        for (const op of fx.scenarios[n].write.ops) {
          op.data = Object.fromEntries(
            Object.entries(op.data).map(([k, v]) => [k.startsWith('a') ? `b${k.slice(1)}` : `a${k.slice(1)}`, v]),
          );
        }
      }
    }],
  ['F9 replacing an invite forgets to delete the old one',
    (fx) => {
      const w = fx.scenarios.createInvite_replaces.write;
      w.ops = w.ops.filter((o) => o.op !== 'delete');
    }],
  ['F10 invite document written with a foreign uid',
    (fx) => {
      fx.scenarios.createInvite.write.ops.find((o) => o.op === 'set').data.uid = 'uid-bruno';
    }],
  // Fechamento (docs/73): the request payload without the sender's handle, or with someone else's.
  ['F11 request payload without fromHandle',
    (fx) => {
      for (const n of ['sendRequest', 'sendRequest_with_photos']) delete fx.scenarios[n].write.ops[0].data.fromHandle;
    }],
  ['F12 request payload carries the recipient\'s handle instead of the sender\'s',
    (fx) => {
      for (const n of ['sendRequest', 'sendRequest_with_photos']) fx.scenarios[n].write.ops[0].data.fromHandle = 'bruno';
    }],
];
function dropOp(fx, prefix) {
  for (const n of ['blockUser', 'blockUser_with_photo', 'blockUser_bare']) {
    const w = fx.scenarios[n].write;
    w.ops = w.ops.filter((o, i) => i === 0 || !o.path.startsWith(prefix));
  }
}

const dir = mkdtempSync(join(tmpdir(), 'cinetrack-mut-'));
const SUITES = ['social.test.mjs', 'social_compat.test.mjs', 'dart_payloads.test.mjs', ...SP.filter((f) => f !== 'social_compat.test.mjs')];
const notOk = (stdout) => [...stdout.matchAll(/^\s*not ok \d+ - (.+)$/gm)].map((m) => m[1]);
const okCount = (stdout) => [...stdout.matchAll(/^\s*ok \d+ - /gm)].length;

// Baseline (docs/71 G9): the UNMUTATED rules and fixture must pass with the exact same runner,
// otherwise any non-zero exit (emulator down, port taken, crash) would look like a killed mutation.
{
  const file = join(dir, 'baseline.rules');
  writeFileSync(file, rules);
  const r = spawnSync('node', ['--test', '--test-concurrency=1', '--test-reporter=tap', ...SUITES], {
    env: { ...process.env, RULES_PATH: file },
    encoding: 'utf8',
  });
  const failed = notOk(r.stdout);
  if (r.status !== 0 || failed.length > 0 || okCount(r.stdout) === 0) {
    console.error(`BASELINE FAILED (exit ${r.status}, ${failed.length} not ok): fix the suite or the emulator first.`);
    console.error(failed.slice(0, 5).join('\n') || r.stderr.slice(0, 2000));
    process.exit(2);
  }
  console.log(`BASELINE  unmutated rules + fixture: ${okCount(r.stdout)} ok, 0 not ok`);
}

let survived = 0;
let errored = 0;
// KILLED needs at least one failing test; a non-zero exit WITHOUT "not ok" is an infrastructure
// error, never a kill.
const judge = (name, r) => {
  const failed = notOk(r.stdout);
  if (failed.length > 0) {
    const leaf = failed.filter((n) => !/^(handles|busca|troca|pedidos|pedido amarrado|quem esta|amizade|bloqueio|exclusao|convite|isFriend|revogacao|rules do not|NEW rules|OLD rules|Dart payloads|shared_profiles|favorites|Phase 2|documented limits|real operations|F2-F5)/.test(n));
    console.log(`KILLED    ${name}  (${leaf.length || failed.length} failing tests, e.g. "${leaf[0] ?? failed[0]}")`);
  } else if (r.status === 0) {
    survived++;
    console.log(`SURVIVED  ${name}`);
  } else {
    errored++;
    console.log(`ERROR     ${name}  (exit ${r.status} without any failing test: not counted as killed)`);
  }
};
for (const [name, edits, replay] of MUTATIONS) {
  if (process.env.ONLY && !name.startsWith(`${process.env.ONLY} `)) continue;
  let text = rules;
  for (const [from, to] of edits) {
    if (Array.isArray(replay) && text.split(from).length !== 2) {
      console.error(`MUTATION AMBIGUOUS (must match exactly once): ${name}`);
      process.exit(2);
    }
    if (!text.includes(from)) {
      console.error(`MUTATION NOT APPLICABLE (rules text changed?): ${name}`);
      process.exit(2);
    }
    text = text.replace(from, () => to);
  }
  const file = join(dir, `${name.split(' ')[0]}.rules`);
  writeFileSync(file, text);
  const r = spawnSync(
    'node',
    ['--test', '--test-concurrency=1', '--test-reporter=tap',
      ...(Array.isArray(replay) ? replay : ['social.test.mjs', 'social_compat.test.mjs', ...(replay ? ['dart_payloads.test.mjs'] : [])])],
    { env: { ...process.env, RULES_PATH: file }, encoding: 'utf8' },
  );
  judge(name, r);
}
const fixture = JSON.parse(readFileSync(new URL('./fixtures/social_payloads.json', import.meta.url), 'utf8'));
for (const [name, mutate] of FIXTURE_MUTATIONS) {
  if (process.env.ONLY && !name.startsWith(`${process.env.ONLY} `)) continue;
  const copy = JSON.parse(JSON.stringify(fixture));
  mutate(copy);
  const file = join(dir, `${name.split(' ')[0]}.json`);
  writeFileSync(file, JSON.stringify(copy));
  const r = spawnSync('node', ['--test', '--test-concurrency=1', '--test-reporter=tap', 'dart_payloads.test.mjs'], {
    env: { ...process.env, FIXTURE_PATH: file },
    encoding: 'utf8',
  });
  judge(name, r);
}
const TOTAL = MUTATIONS.length + FIXTURE_MUTATIONS.length;
if (errored > 0) console.log(`\n${errored} mutation run(s) ERRORED (infrastructure): rerun.`);
console.log(survived === 0 && errored === 0
  ? `\nAll ${TOTAL} mutations were killed.`
  : `\n${survived} mutation(s) SURVIVED, ${errored} errored.`);
process.exit(survived === 0 && errored === 0 ? 0 : 1);
