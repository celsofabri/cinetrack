import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/social/social_models.dart';
import 'package:cinetrack/social/social_validation.dart';

String _c(int code) => String.fromCharCode(code);

void main() {
  group('Handle', () {
    test('normalizes: trim, one leading @, lower case', () {
      expect(Handle.normalize('  @Ana_9 '), 'ana_9');
      expect(Handle.normalize('@@ana'), '@ana');
    });

    test('accepts the valid format and rejects the rest with pt-BR messages', () {
      for (final ok in ['abc', 'ana_9', 'a_b', '0' * 20]) {
        expect(Handle.errorFor(ok), isNull, reason: ok);
      }
      for (final bad in ['', 'ab', 'a b', '_ana', 'ana_', 'a' * 21, 'ação', 'ana-9', 'ana.9']) {
        expect(Handle.errorFor(bad), isNotNull, reason: bad);
      }
      expect(Handle.errorFor('Ab'), contains('pelo menos'));
      expect(Handle.errorFor('_ana'), contains('_'));
      expect(Handle.parse('@Ana_9'), 'ana_9');
      expect(Handle.parse('admin'), isNull);
    });

    test('the 31 reserved handles are identical to firestore.rules', () {
      final rules = File('firestore.rules').readAsStringSync();
      final start = rules.indexOf('function validHandle');
      final block = rules.substring(start, rules.indexOf('function validInviteCode'));
      final list = RegExp(r"h in \[([^\]]*)\]").firstMatch(block)!.group(1)!;
      final fromRules = RegExp(r"'([a-z]+)'").allMatches(list).map((m) => m.group(1)!).toSet();
      expect(fromRules, hasLength(31));
      expect(kReservedHandles, fromRules);
      for (final r in kReservedHandles) {
        expect(Handle.errorFor(r), isNotNull, reason: r);
      }
      expect(Handle.errorFor('staff_1'), isNull);
    });
  });

  group('SocialNickname', () {
    test('trims, NFC-normalizes and removes invisible / bidi / tag characters', () {
      expect(SocialNickname.normalize('  Ana  '), 'Ana');
      // e + combining acute -> precomposed
      expect(SocialNickname.normalize('Jose${_c(0x301)}'), 'Jos${_c(0xE9)}');
      final dirty = 'A${_c(0x200B)}n${_c(0x202E)}a${_c(0xFEFF)}${_c(0x2066)}${_c(0xE0041)}';
      expect(SocialNickname.normalize(dirty), 'Ana');
    });

    test('NBSP, ideographic space and line breaks do not make an empty nickname valid', () {
      expect(SocialNickname.normalize('${_c(0xA0)}${_c(0x3000)} \n'), isNull);
      expect(SocialNickname.errorFor(_c(0xA0)), isNotNull);
      expect(SocialNickname.normalize('Ana${_c(0xA0)}Maria'), 'Ana Maria');
    });

    test('keeps emoji ZWJ sequences and accents', () {
      final family = '${_c(0x1F468)}${_c(0x200D)}${_c(0x1F469)}';
      expect(SocialNickname.normalize('José $family'), 'José $family');
    });

    test('limit counts UTF-16 units: 40 CJK / 20 emoji ok, one more is not', () {
      expect(SocialNickname.normalize('字' * 40), isNotNull);
      expect(SocialNickname.normalize('字' * 41), isNull);
      expect(SocialNickname.normalize('\u{1F3AC}' * 20), isNotNull);
      expect(SocialNickname.normalize('\u{1F3AC}' * 21), isNull);
      expect(SocialNickname.errorFor('x' * 41), contains('40'));
      expect(SocialNickname.errorFor('   '), contains('vazio'));
    });
  });

  group('SocialPhoto', () {
    test('only https lh<n>.googleusercontent.com up to 512 chars', () {
      const ok = 'https://lh3.googleusercontent.com/a/abc=s96-c';
      expect(SocialPhoto.sanitize(ok), ok);
      expect(SocialPhoto.sanitize('https://lh12.googleusercontent.com/x'), isNotNull);
      for (final bad in [
        null,
        '',
        'http://lh3.googleusercontent.com/x',
        'https://evil.com/?https://lh3.googleusercontent.com/x',
        'https://lh.googleusercontent.com/x',
        'https://lh3x.googleusercontent.com/x',
        'https://lh3.googleusercontent.com.evil.com/x',
        'https://lh3.googleusercontent.com/x\ny',
        'https://lh3.googleusercontent.com/${'a' * 520}',
      ]) {
        expect(SocialPhoto.sanitize(bad), isNull, reason: '$bad');
      }
      expect(SocialPhoto.sanitize('https://lh3.googleusercontent.com/${'a' * 400}'), isNotNull);
    });
  });

  group('models', () {
    test('profile parsing is tolerant of old / partial documents', () {
      expect(SocialProfile.fromRaw(null, null), isNull);
      expect(SocialProfile.fromRaw({}, null), isNull);
      final p = SocialProfile.fromRaw({'handle': 'ana'}, null)!;
      expect(p.cardMissing, isTrue);
      expect(p.nickname, '');
      expect(p.discoverable, isFalse);
      expect(p.canChangeHandle(DateTime.now()), isTrue);
    });

    test('30-day interval', () {
      final at = DateTime.utc(2026, 1, 1);
      final p = SocialProfile(handle: 'ana', handleChangedAt: at);
      expect(p.canChangeHandle(at.add(const Duration(days: 29))), isFalse);
      expect(p.canChangeHandle(at.add(const Duration(days: 30))), isTrue);
    });

    test('rule denials share one generic message; Firestore codes map', () {
      expect(SocialFailure.fromFirestoreCode('permission-denied').kind, SocialFailureKind.denied);
      expect(SocialFailure.fromFirestoreCode('unavailable').kind, SocialFailureKind.offline);
      expect(
        SocialFailure.fromFirestoreCode('resource-exhausted').message,
        'Muitas operações hoje. Tente de novo amanhã.',
      );
      expect(
        SocialFailure(SocialFailureKind.tooSoon, retryAt: DateTime(2026, 3, 5)).message,
        contains('05/03/2026'),
      );
    });
  });
}
