## RISCO ACEITO
Gate sobreposto: QA / validação manual (R1 e S1 do re-review, docs/11-re-review-login-perfil.md)
Motivo do bloqueio: exclusão de conta e isolamento da fila offline entre contas nunca foram exercitados contra o Firebase real (só fakes e Emulator de regras).
Justificativa de negócio: Manager decidiu publicar já (2026-10-02).
Mitigação: regras de segurança testadas no Emulator (isolamento por uid); código de exclusão idempotente e retomável; política de privacidade publicada com contato.
Prazo para correção: executar o roteiro manual de docs/11 (R1 e S1) logo após o deploy, antes de divulgar o app a outras pessoas.
Aprovado por: Manager (Celso Fabri Jr) — 2026-10-02

Dívidas registradas (sem dono/data): testes de integração das classes Firebase, App Check, alerta de cota, limpeza de dados sem dono, Sign in with Apple, N1/N5/N7 do re-review.
