// Mutation check (docs/51): removes ONE critical check from a copy of firestore.rules and
// proves that at least one test fails. Run: npm run test:mutations (starts the emulator).
// Never touches ../firestore.rules: mutated copies live in the OS temp dir.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const rules = readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8');

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
];

const dir = mkdtempSync(join(tmpdir(), 'cinetrack-mut-'));
let survived = 0;
for (const [name, edits, replay] of MUTATIONS) {
  if (process.env.ONLY && !name.startsWith(`${process.env.ONLY} `)) continue;
  let text = rules;
  for (const [from, to] of edits) {
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
    ['--test', '--test-concurrency=1', '--test-reporter=tap', 'social.test.mjs', 'social_compat.test.mjs', ...(replay ? ['dart_payloads.test.mjs'] : [])],
    { env: { ...process.env, RULES_PATH: file }, encoding: 'utf8' },
  );
  const failed = [...r.stdout.matchAll(/^\s*not ok \d+ - (.+)$/gm)].map((m) => m[1]).filter((n) => !/\(\d/.test(n) || true);
  const leaf = failed.filter((n) => !/^(handles|busca|troca|pedidos|amizade|bloqueio|exclusao|convite|isFriend|revogacao|rules do not|NEW rules|OLD rules)/.test(n));
  if (r.status === 0) {
    survived++;
    console.log(`SURVIVED  ${name}`);
  } else {
    console.log(`KILLED    ${name}  (${leaf.length} failing tests, e.g. "${leaf[0] ?? failed[0]}")`);
  }
}
console.log(survived === 0 ? `\nAll ${MUTATIONS.length} mutations were killed.` : `\n${survived} mutation(s) SURVIVED.`);
process.exit(survived === 0 ? 0 : 1);
