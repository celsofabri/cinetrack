"""Dart mutation check of the friendships closing slice (docs/73).

Applies ONE mutation at a time to a COPY of the project, runs the tests that must catch it and
restores the file. A mutation is KILLED only when `flutter test` reports failing tests.

Usage (never on your working tree: files are edited in place while a mutation runs):
    rsync -a --exclude build --exclude node_modules --exclude .git ./ /tmp/cinetrack-mut/
    python3 tool/dart_mutations.py /tmp/cinetrack-mut [D4 D5 ...]
"""
import subprocess, sys, shutil, os
if len(sys.argv) < 2: sys.exit(__doc__)
root=sys.argv[1]
if os.path.isdir(os.path.join(root, ".git")) or os.path.isfile(os.path.join(root, ".git")):
    sys.exit("refusing to mutate a git checkout: run it on a copy (see the docstring)")
M=[
 ('D4 handle hidden by the rules reads as FREE','lib/data/firestore_social_data_source.dart',
  "throw const SocialFailure(SocialFailureKind.handleTaken, code: 'permission-denied');","return (exists: false, data: null);",
  ['test/firestore_social_data_source_test.dart']),
 ('D5 handle hidden by the rules becomes denied','lib/data/firestore_social_data_source.dart',
  "throw const SocialFailure(SocialFailureKind.handleTaken, code: 'permission-denied');","throw const SocialFailure(SocialFailureKind.denied, code: 'permission-denied');",
  ['test/firestore_social_data_source_test.dart']),
 ('D9 activate reads the handle before the own pointer','lib/data/firestore_social_data_source.dart',
  "      final social = await get(_socialPath);\n      final card = await _getHandle(get, draft.handle);","      final card = await _getHandle(get, draft.handle);\n      final social = await get(_socialPath);",
  ['test/firestore_social_data_source_test.dart']),
 ('D10 busy answers null (success)','lib/providers/social_providers.dart',
  "if (state.busy) return const SocialFailure(SocialFailureKind.busy);","if (state.busy) return null;",
  ['test/social_closing_test.dart']),
 ('D11 header nickname button not locked while busy','lib/screens/profile_screen.dart',
  "onPressed: socialBusy\n                        ? null","onPressed: false\n                        ? null",
  ['test/social_closing_test.dart']),
 ('D12 Google photo never synced','lib/providers/social_providers.dart',
  "    if (_photoChecked || generation != _generation) return;","    if (true) return;",
  ['test/social_closing_test.dart']),
 ('D13 photo sync ignores "photo off"','lib/providers/social_providers.dart',
  "    if (!profile.photoVisible || profile.cardMissing) return;","    if (profile.cardMissing) return;",
  ['test/social_closing_test.dart']),
 ('D14 photo sync without the once-per-session guard','lib/providers/social_providers.dart',
  "    _photoChecked = true;\n    if (google == profile.photoUrl) return;","    if (google == profile.photoUrl) return;",
  ['test/social_closing_test.dart']),
 ('D15 account deletion skips sweeps on ANY denial (G5)','lib/repositories/social_repository.dart',
  "if (e.kind == SocialFailureKind.denied && e.code == kSocialReadDeniedCode) return;","if (e.kind == SocialFailureKind.denied) return;",
  ['test/social_repository_test.dart','test/firestore_social_data_source_test.dart']),
 ('D16 export skips the lists without pointer (G6)','lib/export/data_exporter.dart',
  "  for (final kind in SocialExportKind.values) {\n    String? socialCursor;","  for (final kind in hasPointer ? SocialExportKind.values : const <SocialExportKind>[]) {\n    String? socialCursor;",
  ['test/social_export_test.dart']),
 ('D17 request sent without the CURRENT handle','lib/repositories/social_repository.dart',
  "fromHandle: me.handle,","fromHandle: 'x${me.handle}',",
  ['test/friends_screens_test.dart']),
 ('D18 received card hides the @handle','lib/screens/friends_screen.dart',
  "Text('@$handle', style: theme.textTheme.bodyMedium),","const SizedBox.shrink(),",
  ['test/friends_slice3_screens_test.dart']),
 ('E2 photo sync also runs from the device cache (docs/75 N3)','lib/providers/social_providers.dart',
  "if (generation == _generation && profile != null && !next.fromCache) {","if (generation == _generation && profile != null) {",
  ['test/social_closing_test.dart']),
 ('E4 photo taken from the top-level photoURL, not the Google provider (docs/74 R1)','lib/auth/app_user.dart',
  "    if (p.providerId == 'google.com') return usable(p.photoUrl);","    if (false) return usable(p.photoUrl);",
  ['test/app_user_mapping_test.dart']),
 ('E5 Google provider without a photo falls back to the stale top-level photo (docs/77 P1)','lib/auth/app_user.dart',
  "    if (p.providerId == 'google.com') return usable(p.photoUrl);","    if (p.providerId == 'google.com' && usable(p.photoUrl) != null) return usable(p.photoUrl);",
  ['test/app_user_mapping_test.dart','test/social_closing_test.dart']),
 ('D19 not-found text drifts from the contract','lib/social/social_models.dart',
  "const kSearchNotFoundMessage = 'Nenhum usuário encontrado com esse identificador.';","const kSearchNotFoundMessage = 'Não encontramos ninguém com esse apelido';",
  ['test/friends_screens_test.dart']),
]
only=sys.argv[2:]
bad=0
for name,f,a,b,tests in M:
    if only and name.split()[0] not in only: continue
    p=os.path.join(root,f); orig=open(p).read()
    assert orig.count(a)==1,(name,orig.count(a))
    open(p,'w').write(orig.replace(a,b))
    r=subprocess.run(['flutter','test',*tests],cwd=root,capture_output=True,text=True)
    open(p,'w').write(orig)
    killed = r.returncode!=0 and ('Some tests failed' in r.stdout)
    status='KILLED' if killed else ('SURVIVED' if r.returncode==0 else 'ERROR')
    print(status, name, flush=True)
    if status!='KILLED': bad+=1
    if status=='ERROR': print(r.stdout[-1500:])
print('All Dart mutations were killed.' if bad==0 else f'{bad} mutation(s) not killed.')
sys.exit(1 if bad else 0)
