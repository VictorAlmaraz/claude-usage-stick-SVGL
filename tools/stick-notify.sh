#!/bin/bash
#
# Ponte hooks do Claude Code -> Claude Usage Stick (POST /session).
#
# Instalacao:
#   cp tools/stick-notify.sh ~/.claude/stick-notify.sh
#   chmod +x ~/.claude/stick-notify.sh
#   export CLAUDE_STICK_HOST=<ip-do-device>     # ver README
# e registre os 4 hooks em ~/.claude/settings.json (ver README).
#
# Uso: stick-notify.sh <working|waiting|done|gone>   (payload do hook via stdin)
#
# REGRA INEGOCIAVEL: o monitor nunca pode travar o que ele monitora. Hooks sao
# sincronos e bloqueiam o Claude Code, entao aqui tudo e curto e silencioso:
#   --connect-timeout 1 / -m 2  -> teto de 2s
#   &                           -> curl em background, nao espera resposta
#   exit 0 incondicional        -> device desligado nunca vira erro na sessao
#   circuit breaker             -> apos uma falha, 60s de custo zero
#
# Descoberta automatica: funciona em casa e no escritorio sem editar nada.
#
# Nao dá para passar "claude-stick.local" direto ao curl: o getaddrinfo do
# macOS leva ~2.8s para resolver .local (tenta DNS unicast antes de cair no
# mDNS), o que estoura o timeout curto que os hooks exigem. Ja o ping resolve
# o MESMO nome em ~80ms, porque fala direto com o mDNSResponder.
#
# Entao: resolve com ping, guarda o IP em cache e usa o cache no caminho
# rapido. Ao trocar de rede o IP em cache falha, o cache e invalidado e a
# descoberta roda de novo — tudo dentro do bloco em background.
# Quando o mDNS nao serve — rede corporativa que poe o device noutra VLAN, com
# o multicast barrado entre elas — escreva o IP em ~/.claude/stick-host. Ele
# vale mais que o cache e sobrevive a invalidacao, entao o device continua
# alcancavel mesmo sem descoberta possivel. Apague o arquivo ao voltar para uma
# rede onde o mDNS funciona.
MDNS_NAME="${CLAUDE_STICK_NAME:-claude-stick.local}"
PINNED="$HOME/.claude/stick-host"
CACHE="/tmp/.stick-ip"
BREAKER="/tmp/.stick-down"
# Janela curta de proposito: o curl ja e background com --connect-timeout 1,
# entao uma tentativa falha custa quase nada. Uma janela longa (5 min) deixaria
# a tela mentindo depois de qualquer piscada de rede ou reboot do device.
BREAKER_SEC=60

STATUS="$1"
case "$STATUS" in
  working|waiting|done|gone) ;;
  *) exit 0 ;;
esac

resolve_stick() {   # imprime o IP, ou nada se o device nao esta nesta rede
  ping -c 1 -t 1 -W 1000 "$MDNS_NAME" 2>/dev/null \
    | sed -n '1s/.*(\([0-9][0-9.]*\)).*/\1/p'
}

# breaker aberto? sai na hora, sem nem ler o stdin
if [ -f "$BREAKER" ]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$BREAKER" 2>/dev/null || echo 0) ))
  [ "$AGE" -lt "$BREAKER_SEC" ] && exit 0
  rm -f "$BREAKER"
fi

# Um unico python3 monta o corpo ja escapado (json.dumps), o que tambem evita
# quebrar com cwd contendo espacos. Subagentes sao ignorados: eles compartilham
# o session_id do pai, entao um Stop de subagente marcaria a sua sessao como
# concluida enquanto o Claude ainda esta trabalhando.
# "ts" e o instante em que ESTE hook disparou, e vai primeiro no payload (o
# parser do device pega a primeira ocorrencia da chave). Os curls sao
# assincronos: o PostToolUse final e o Stop saem com milissegundos de
# diferenca e podem chegar trocados. O device usa o ts para descartar o que
# chegar fora de ordem — sem isso a sessao fica azul depois de terminar.
BODY=$(python3 -c '
import json, os, sys, time, unicodedata

def ascii_only(s, n):
    # as fontes montserrat do LVGL sao ASCII: "Sessoes" renderiza, "Sessões" nao
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return s.encode("ascii", "ignore").decode().strip()[:n]

def session_title(path):
    # O titulo (o mesmo da barra lateral) e reescrito no transcript a cada
    # prompt, entao esta sempre perto do fim. Le so a cauda: este script roda
    # a cada PostToolUse, ~100x por turno, e o arquivo passa de 1 MB.
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 131072))
            tail = f.read().decode("utf-8", "ignore").splitlines()
    except Exception:
        return ""
    custom = ai = ""
    for line in tail:                      # varre p/ frente: fica com o ultimo
        if "-title\"" not in line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue                       # 1a linha da cauda costuma vir cortada
        custom = o.get("customTitle") or custom
        ai     = o.get("aiTitle") or ai
    return custom or ai                    # titulo definido por voce ganha do automatico

d = json.load(sys.stdin)
if d.get("agent_id"):
    sys.exit(1)
sid = (d.get("session_id") or "")[:8]
if not sid:
    sys.exit(1)
print(json.dumps({
    "ts": time.time_ns(),
    "id": sid,
    "project": ascii_only(os.path.basename((d.get("cwd") or "").rstrip("/")), 23) or "?",
    "title": ascii_only(session_title(d.get("transcript_path") or ""), 47),
    "status": sys.argv[1],
    "host": sys.argv[2],
}))' "$STATUS" "$(hostname -s)" 2>/dev/null) || exit 0

[ -n "$BODY" ] || exit 0

# Daqui p/ baixo tudo roda em background: resolucao de nome e rede nunca
# entram no caminho sincrono do hook.
{
  post() {
    [ -n "$1" ] && curl -s --connect-timeout 1 -m 2 -X POST "http://$1/session" \
      -H 'Content-Type: application/json' -d "$BODY"
  }

  # Tres candidatos, do mais barato ao mais caro. Nenhum e mandatorio: um
  # endereco so vale enquanto responde, entao a falha de um sempre cai para o
  # proximo, e a troca de rede se resolve no PRIMEIRO evento.
  CAND_CACHE=$(cat "$CACHE" 2>/dev/null)
  CAND_PIN="${CLAUDE_STICK_HOST:-$(cat "$PINNED" 2>/dev/null)}"

  # 1) caminho rapido: o ultimo IP que funcionou
  if [ -n "$CAND_CACHE" ] && post "$CAND_CACHE"; then
    exit 0
  fi

  # 2) IP fixado — para rede que poe o device noutra VLAN e barra o multicast
  if [ -n "$CAND_PIN" ] && [ "$CAND_PIN" != "$CAND_CACHE" ] && post "$CAND_PIN"; then
    echo "$CAND_PIN" > "$CACHE"
    exit 0
  fi

  # 3) descoberta por mDNS. Roda MESMO com IP fixado: um pin esquecido ao voltar
  # para uma rede onde o mDNS funciona cegaria o bridge para sempre.
  FOUND=$(resolve_stick)
  if [ -n "$FOUND" ] && [ "$FOUND" != "$CAND_CACHE" ] && [ "$FOUND" != "$CAND_PIN" ] && post "$FOUND"; then
    echo "$FOUND" > "$CACHE"
    exit 0
  fi

  rm -f "$CACHE"
  touch "$BREAKER"
} >/dev/null 2>&1 &

exit 0
