import 'shared_profile_models.dart';

/// Literal texts of the single "Aparecer na busca" switch (docs/95 §7,
/// Fatia S). Tests pin them 1:1 against the document.
class SharingTexts {
  const SharingTexts._();

  // T-I: the switch (Perfil -> Amizades).
  static const switchTitle = 'Aparecer na busca';
  static const switchSubtitle =
      'Ligado: quem digitar seu identificador exato encontra você, e seus amigos mútuos veem '
      'suas estatísticas, atividades recentes e recomendados. Desligado: só quem você aceitar ou '
      'convidar vira seu amigo, e seus amigos veem só seu cartão (apelido e foto).';
  static const switchSemantics = 'Aparecer na busca e compartilhar com amigos';
  static const review = 'Falta você confirmar o que seus amigos veem.';
  static const reviewButton = 'Revisar';
  static String legacy(Set<SharedSection> sections) =>
      'Você ainda compartilha: ${sectionList(sections)}.';

  /// "Estatísticas, Atividades recentes e Recomendados" (fixed order).
  static String sectionList(Set<SharedSection> sections) {
    final names = [
      for (final s in SharedSection.values)
        if (sections.contains(s)) sectionName(s),
    ];
    if (names.length <= 1) return names.join();
    return '${names.sublist(0, names.length - 1).join(', ')} e ${names.last}';
  }

  static String sectionName(SharedSection s) => switch (s) {
    SharedSection.stats => 'Estatísticas',
    SharedSection.activity => 'Atividades recentes',
    SharedSection.recs => 'Recomendados',
  };

  // T-C: the consent dialog (switch and activation form).
  static const consentTitle = 'Aparecer na busca e compartilhar com amigos?';
  static const consentBody =
      'Quem digitar seu identificador exato vai encontrar seu cartão (apelido e foto). E seus '
      'amigos mútuos vão ver, no seu perfil e no Ranking:';
  static const consentItems = [
    'Estatísticas: seus números (favoritos, filmes e episódios assistidos, séries assistidas e '
        'concluídas e tempo assistido), os totais deste mês e deste ano e desde quando você está '
        'no CineTrack.',
    'Atividades recentes: até 10 das suas atividades mais recentes (títulos que você favoritou, '
        'filmes e episódios que marcou como assistidos e séries que concluiu), só a partir de agora.',
    'Recomendados: os títulos que você marcou com Recomendo (até 50, na ordem da sua aba) e '
        'quantos são.',
  ];
  static const consentClosing =
      'Recomendações nunca aparecem como atividade e seu e-mail nunca é mostrado. Você pode '
      'desligar quando quiser: desligar tira você da busca e apaga na hora o que seus amigos viam.';
  static const previewTitle = 'Como seus amigos veem';
  static const cancel = 'Cancelar';
  static const notNow = 'Agora não';
  static const turnOn = 'Ligar';
  static const calculating = 'Calculando…';

  // T-D: confirmation when turning off.
  static const offTitle = 'Desligar "Aparecer na busca"?';
  static const offBody =
      'Você sai da busca e seus amigos passam a ver só seu cartão (apelido e foto). O que eles '
      'viam (estatísticas, atividades recentes e recomendados) é apagado agora; se você ligar de '
      'novo, as atividades recomeçam do zero. Seus amigos continuam seus amigos e seus dados no '
      'CineTrack não mudam.';
  static const turnOff = 'Desligar';

  // T-A: the one-time notice (E2).
  static const noticeTitle = 'Novidade: seus amigos veem mais de você';
  static const noticeBody =
      'Agora "Aparecer na busca" também mostra aos seus amigos mútuos, no seu perfil e no '
      'Ranking, suas estatísticas, suas atividades recentes (só a partir de agora) e seus '
      'recomendados. Nada disso é compartilhado antes de você tocar em OK.';
  static String noticeAlready(Set<SharedSection> sections) =>
      'Hoje você já compartilha: ${sectionList(sections)}.';
  static const noticeClosing =
      'Se preferir, desligue: você sai da busca e seus amigos veem só seu cartão.';
  static const noticeClosingAlready =
      'Se preferir, desligue: você sai da busca e seus amigos veem só seu cartão, e o que você '
      'já compartilha é apagado.';
  static const ok = 'OK';

  // T-B: the legacy notice (E3, Manager decision on ❓1).
  static const legacyTitle = 'Mudou a forma de compartilhar com amigos';
  static String legacyBody(Set<SharedSection> sections) =>
      'Agora o que seus amigos veem fica ligado junto com "Aparecer na busca". Hoje você não '
      'aparece na busca, mas compartilha: ${sectionList(sections)}. Escolha como prefere continuar.';
  static const legacyStop = 'Parar de compartilhar';
  static const legacyAll = 'Aparecer na busca e compartilhar tudo';

  // T-F: the activation form.
  static const formSubtitle =
      'Quem digitar seu identificador exato vê seu apelido e foto, e seus amigos mútuos veem '
      'suas estatísticas, atividades recentes e recomendados. Você confirma no próximo passo.';
  static const formFailed =
      'Amizades ativadas, mas não foi possível ligar "Aparecer na busca". Tente de novo no Perfil.';

  // T-V: "O que seus amigos veem" (E0 is the existing kSharingAllOff).
  static const viewOn =
      'Seus amigos mútuos veem suas estatísticas, atividades recentes e recomendados.';

  // T-Convite.
  static const invite =
      'Funciona mesmo com "Aparecer na busca" desligado (aí seus amigos veem só seu cartão). '
      'Você pode revogar quando quiser.';

  // T-R: the ranking banner (docs/90 RF-E10).
  static const rankingOff =
      'Você não aparece no ranking dos seus amigos porque "Aparecer na busca" está desligado.';
  static const rankingOffButton = 'Ir para o Perfil';
  static const rankingReview =
      'Você não aparece no ranking dos seus amigos porque ainda não confirmou o que eles veem.';
  static const rankingReviewButton = 'Revisar';

  /// The banner of the ranking when I do not share statistics (D9): the
  /// "falta confirmar" variant (E2) opens notice A; every other one leads to
  /// the Profile.
  static ({String text, String button, bool review}) rankingBanner({required bool review}) => review
      ? (text: rankingReview, button: rankingReviewButton, review: true)
      : (text: rankingOff, button: rankingOffButton, review: false);
}
