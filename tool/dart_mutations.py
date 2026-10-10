"""Dart mutation check of the friendships closing slice (docs/73) and of Phase 2, Fatia 1 (docs/85).

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
 # --- Phase 2, Fatia 1 (docs/83 §4 "Dart"; docs/85) ---
 ('G1 validator: favorites ceiling removed (violations)','lib/shared_profile/shared_profile_validator.dart',
  "if (t.favorites > kMaxSharedFavorites) out.add('total.favorites');","if (false) out.add('total.favorites');",
  ['test/shared_profile_validator_test.dart']),
 ('G2 validator: favorites ceiling removed (clamp)','lib/shared_profile/shared_profile_validator.dart',
  "final movies = t.movies.clamp(0, kMaxSharedFavorites);\n    final series = t.series.clamp(0, kMaxSharedFavorites - movies);","final movies = t.movies;\n    final series = t.series;",
  ['test/shared_profile_validator_test.dart']),
 ('G3 validator: date margin removed (violations)','lib/shared_profile/shared_profile_validator.dart',
  "    final limit = now.toUtc().add(kSharedDateMargin);\n    bool late(","    final limit = DateTime.utc(9999);\n    bool late(",
  ['test/shared_profile_validator_test.dart']),
 ('G4 validator: date margin removed (clamp)','lib/shared_profile/shared_profile_validator.dart',
  "    final limit = now.toUtc().add(kSharedDateMargin);\n    DateTime? capDate","    final limit = DateTime.utc(9999);\n    DateTime? capDate",
  ['test/shared_profile_validator_test.dart','test/shared_profile_builder_test.dart']),
 ('G5 validator: list item outside the schema accepted (mediaType)','lib/shared_profile/shared_profile_validator.dart',
  "    if (mediaType != 'movie' && mediaType != 'tv') 'mediaType',","",
  ['test/shared_profile_validator_test.dart']),
 ('G6 validator: watched episodes ceiling removed','lib/shared_profile/shared_profile_validator.dart',
  "if (t.watchedEpisodes > kMaxSharedWatchedEpisodes) out.add('total.watchedEpisodes');","",
  ['test/shared_profile_validator_test.dart']),
 ('G7 period in UTC (owner zone ignored)','lib/shared_profile/period_key.dart',
  "final local = instant.toUtc().add(Duration(minutes: tzMinutes));","final local = instant.toUtc();",
  ['test/period_key_test.dart','test/shared_profile_builder_test.dart']),
 ('G8 unknown activity type throws in the reader','lib/shared_profile/shared_profile_models.dart',
  "if (type == null || id is! int || title is! String || at is! DateTime) return null;","if (type == null) throw StateError('unknown type');\n    if (id is! int || title is! String || at is! DateTime) return null;",
  ['test/activity_deriver_test.dart']),
 ('G9 "Recomendações" without the opt-in','lib/shared_profile/shared_profile_builder.dart',
  "recs: sections.contains(SharedSection.recs) ? recs(docs) : null,","recs: recs(docs),",
  ['test/shared_profile_builder_test.dart']),
 ('G10 activities calculated with "Atividades" off','lib/shared_profile/shared_profile_builder.dart',
  "activity: sections.contains(SharedSection.activity)","activity: true",
  ['test/shared_profile_builder_test.dart']),
 ('G11 activities before the consent are published','lib/shared_profile/activity_deriver.dart',
  "events.removeWhere((e) => e.at.isBefore(since));","",
  ['test/activity_deriver_test.dart']),
 ('G12 mark dates sent before the rules are confirmed','lib/data/firestore_favorites_data_source.dart',
  "    dates: datesEnabled\n        ? EpisodeDates.plan(","    dates: true\n        ? EpisodeDates.plan(",
  ['test/episode_dates_test.dart']),
 ('G13 orphan dates never cleaned','lib/services/episode_dates.dart',
  "delete.addAll(orphans.take(kMaxOrphanDeletesPerWrite));","",
  ['test/episode_dates_test.dart']),
 ('G14 Desfazer makes the history younger (dates not restored)','lib/repositories/favorites_repository.dart',
  "      restoreDates: undo.restoreDates,\n","",
  ['test/episode_dates_test.dart']),
 ('G15 account deletion: shared profile deleted only AFTER the sweeps','lib/account/account_deleter.dart',
  "    await _deleteSharedProfile();\n    await _social.wipeForAccountDeletion();","    await _social.wipeForAccountDeletion();",
  ['test/shared_profile_data_test.dart','test/account_deleter_test.dart','test/social_repository_test.dart']),
 ('G16 account deletion: no delete after closing social','lib/account/account_deleter.dart',
  "    await _social.wipeForAccountDeletion();\n    await _deleteSharedProfile();","    await _social.wipeForAccountDeletion();",
  ['test/shared_profile_data_test.dart','test/account_deleter_test.dart']),
 ('G17 deactivation: shared profile not deleted before the sweeps','lib/repositories/social_repository.dart',
  "  Future<void> deactivate() async {\n    await _shared.deleteOwn();\n","  Future<void> deactivate() async {\n",
  ['test/shared_profile_data_test.dart']),
 ('G18 deactivation: second delete outside "cleanup pending"','lib/repositories/social_repository.dart',
  "    try {\n      await _shared.deleteOwn();\n      await sweepAll();","    await _shared.deleteOwn();\n    try {\n      await sweepAll();",
  ['test/shared_profile_data_test.dart']),
 ('G19 export omits the shared profile','lib/export/data_exporter.dart',
  "builder.sharedProfile = await source.readSharedProfile(fromServer: fromServer);","await source.readSharedProfile(fromServer: fromServer);",
  ['test/shared_profile_data_test.dart']),
 ('G20 rules probe never remembered (reads every session)','lib/data/shared_rules_gate.dart',
  "        await _storeReady();","        await Future<void>.value();",
  ['test/shared_profile_data_test.dart']),
 ('G21 deleteOwn under old rules fails the deletion','lib/data/firestore_shared_profile_data_source.dart',
  "      if (e.kind == SocialFailureKind.denied) return;\n      rethrow;","      rethrow;",
  ['test/shared_profile_data_test.dart']),
 ('G22 completion ignores the injected clock','lib/services/progress_calculator.dart',
  "final at = now ?? DateTime.now();","final at = DateTime.now();",
  ['test/period_key_test.dart','test/shared_profile_builder_test.dart']),
 ('G23 several instants in one write (a date per episode)','lib/services/episode_dates.dart',
  "        final at = restore == null ? instant : restore[k];","        final at = restore == null ? instant.add(Duration(milliseconds: set.length)) : restore[k];",
  ['test/episode_dates_test.dart']),
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
