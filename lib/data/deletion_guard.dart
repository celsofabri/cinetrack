import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../account/account_deletion_failure.dart';

/// Server-confirmed operations give up after this (offline: the SDK would
/// otherwise keep them queued and never complete).
const deletionStepTimeout = Duration(seconds: 30);

/// Guard so a bug can never loop forever (400 * 500 = 200k documents).
const deletionMaxPages = 500;

/// Runs one round trip of the account deletion with a timeout and maps
/// provider errors to [AccountDeletionFailure] (Firebase types never leak).
///
/// [write] says whether [action] sends a write. A timed-out READ changed
/// nothing ([AccountDeletionFailureKind.offline]). A timed-out WRITE is
/// different: the Dart future is abandoned but the SDK keeps the mutation in
/// its persistent queue and sends it when the connection returns, so we can
/// NOT claim "nothing was deleted": it is
/// [AccountDeletionFailureKind.uncertain].
Future<T> guardDeletionStep<T>(
  Future<T> Function() action, {
  required bool write,
  Duration timeout = deletionStepTimeout,
}) async {
  try {
    return await action().timeout(timeout);
  } on AccountDeletionFailure {
    rethrow;
  } on TimeoutException {
    throw AccountDeletionFailure(
      write ? AccountDeletionFailureKind.uncertain : AccountDeletionFailureKind.offline,
      code: 'timeout',
    );
  } on FirebaseException catch (e) {
    debugPrint('Firestore delete step failed: ${e.code}');
    throw AccountDeletionFailure.fromFirestoreCode(e.code);
  }
}

/// Deletes a collection page by page until the SERVER says it is empty.
/// [readPage] must read from the server (a cached read could be stale or
/// empty); [deletePage] must delete exactly the documents it is given in
/// one batch (Firestore allows 500 per batch). Each round trip has its own
/// timeout, so a long deletion is not cut short as a whole.
Future<void> wipeInPages<D>({
  required Future<List<D>> Function() readPage,
  required Future<void> Function(List<D> page) deletePage,
  int maxPages = deletionMaxPages,
  Duration timeout = deletionStepTimeout,
}) async {
  for (var i = 0; i < maxPages; i++) {
    final page = await guardDeletionStep(readPage, write: false, timeout: timeout);
    if (page.isEmpty) return;
    await guardDeletionStep(() => deletePage(page), write: true, timeout: timeout);
  }
  throw const AccountDeletionFailure(AccountDeletionFailureKind.unknown, code: 'too-many-pages');
}
