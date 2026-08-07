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
#
# So que em rede de coworking o mDNS nao serve: o device fica noutra VLAN e o
# multicast e barrado entre elas. O trafego unicast atravessa normalmente — o
# que falta ali nao e alcance, e descoberta. Por isso o candidato principal
# nessa rede e o CABO USB: o device anuncia "[NET] ip=..." no serial e o script
# le de la. E o unico endereco que o DHCP nao consegue invalidar, e ainda vem
# com identidade de brinde — veio do device, nao de um nome que outro host da
# rede poderia ter respondido.
#
# Sobra ~/.claude/stick-host como escotilha, para o device na rede mas sem cabo
# nem mDNS (na tomada, noutra VLAN). Ele e MANUAL e apodrece sozinho quando o
# lease troca, entao e o ultimo recurso, nao o primeiro. Apague o arquivo ao
# voltar para uma rede onde o mDNS funciona.
MDNS_NAME="${CLAUDE_STICK_NAME:-claude-stick.local}"
PINNED="$HOME/.claude/stick-host"
CACHE="/tmp/.stick-ip"
BREAKER="/tmp/.stick-down"
SERIAL_LOCK="/tmp/.stick-serial.lock"
# O firmware anuncia a cada 5s; 7 da uma margem sem virar espera longa.
SERIAL_WAIT=7
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

# Descoberta pelo cabo: o device anuncia "[NET] ip=..." no serial a cada 5s.
# Vale mais que qualquer resolucao de nome — o IP vem do proprio device, e nao
# de um nome que outro host da rede poderia responder. E o unico candidato que
# nao apodrece: o DHCP pode trocar o lease a hora que quiser.
#
# So LE. Escrever exigiria abrir a porta para escrita, e o ROM USB-Serial-JTAG
# do S3 entra em download mode por DTR/RTS — um reset disparado por hook cairia
# na tela de PIN no meio da sessao.
#
# Sem stty de proposito: /dev/cu.* nao e exclusive-open no macOS e dois leitores
# DIVIDEM o stream de bytes, entao mexer nos ajustes da porta atrapalharia um
# `build.sh monitor` aberto. Pelo mesmo motivo a janela e curta e a falha cai
# para o proximo candidato em vez de insistir: com o monitor aberto as linhas
# podem simplesmente nunca chegar aqui.
read_net_marker() {   # escuta UMA porta ate o deadline; imprime o IP anunciado
  local line ip deadline
  exec 3<"$1" 2>/dev/null || return 1
  # O deadline e do laco inteiro: o `read -t` sozinho reiniciaria a contagem a
  # cada linha, e o device fala bastante ([API], [STATUS], [PROBE], [SESS]).
  deadline=$(( $(date +%s) + SERIAL_WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    IFS= read -r -t 2 line <&3 || continue
    case "$line" in
      *"[NET] ip="*)
        ip="${line##*\[NET\] ip=}"
        ip="${ip%%[!0-9.]*}"        # corta \r e qualquer sujeira da linha
        break
        ;;
    esac
  done
  exec 3<&-

  case "$ip" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) echo "$ip" ;;
    *) return 1 ;;
  esac
}

read_serial_ip() {
  local port ok=1

  # Lock por mkdir (o macOS nao tem flock): e atomico. Um lock preso ha mais de
  # 90s so pode ser sobra de um hook morto — a varredura toda cabe nisso.
  if ! mkdir "$SERIAL_LOCK" 2>/dev/null; then
    local age=$(( $(date +%s) - $(stat -f %m "$SERIAL_LOCK" 2>/dev/null || echo 0) ))
    [ "$age" -lt 90 ] && return 1
    rm -rf "$SERIAL_LOCK"
    mkdir "$SERIAL_LOCK" 2>/dev/null || return 1
  fi

  # Tenta cada porta, sem chutar qual e a do stick: a numeracao do usbmodem nao
  # e estavel (o build.sh assume 101, aqui enumerou 112201) e qualquer outra
  # placa na USB entraria na frente. O proprio marcador [NET] e o discriminador,
  # entao errar a porta so custa a janela de espera. Teto de 3 para a varredura
  # nao virar espera longa numa bancada cheia.
  for port in $(ls /dev/cu.usbmodem* 2>/dev/null | head -3); do
    if read_net_marker "$port"; then ok=0; break; fi
  done

  rm -rf "$SERIAL_LOCK"
  return $ok
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
  # Exige 2xx, e nao "o curl conseguiu falar". Sem isso QUALQUER resposta HTTP
  # conta como entrega: o 302 que a tela de token devolve no /session, ou o 404
  # de um host qualquer que herdou o lease do device — e o endereco errado vai
  # parar no cache, que e o candidato de MAIOR prioridade.
  post() {
    [ -n "$1" ] || return 1
    local code
    code=$(curl -s --connect-timeout 1 -m 2 -o /dev/null -w '%{http_code}' \
      -X POST "http://$1/session" \
      -H 'Content-Type: application/json' -d "$BODY") || return 1
    case "$code" in 2??) return 0 ;; *) return 1 ;; esac
  }

  # Quatro candidatos, do mais barato ao mais caro. Nenhum e mandatorio: um
  # endereco so vale enquanto responde, entao a falha de um sempre cai para o
  # proximo, e a troca de rede se resolve no PRIMEIRO evento.
  CAND_CACHE=$(cat "$CACHE" 2>/dev/null)
  CAND_PIN="${CLAUDE_STICK_HOST:-$(cat "$PINNED" 2>/dev/null)}"

  # 1) caminho rapido: o ultimo IP que funcionou
  if [ -n "$CAND_CACHE" ] && post "$CAND_CACHE"; then
    exit 0
  fi

  # 2) o cabo USB. Vem antes do pin e do mDNS porque e o unico candidato que o
  # DHCP nao consegue invalidar. Sem device na USB sai de graca, entao nao
  # atrapalha quem esta em casa com o mDNS funcionando.
  CAND_SER=$(read_serial_ip)
  if [ -n "$CAND_SER" ] && [ "$CAND_SER" != "$CAND_CACHE" ] && post "$CAND_SER"; then
    echo "$CAND_SER" > "$CACHE"
    exit 0
  fi

  # 3) IP fixado — escotilha de emergencia para quando o device esta na rede mas
  # nem o cabo nem o mDNS servem (na tomada, noutra VLAN, multicast barrado).
  if [ -n "$CAND_PIN" ] && [ "$CAND_PIN" != "$CAND_CACHE" ] && [ "$CAND_PIN" != "$CAND_SER" ] && post "$CAND_PIN"; then
    echo "$CAND_PIN" > "$CACHE"
    exit 0
  fi

  # 4) descoberta por mDNS. Roda MESMO com IP fixado: um pin esquecido ao voltar
  # para uma rede onde o mDNS funciona cegaria o bridge para sempre.
  FOUND=$(resolve_stick)
  if [ -n "$FOUND" ] && [ "$FOUND" != "$CAND_CACHE" ] && [ "$FOUND" != "$CAND_SER" ] && [ "$FOUND" != "$CAND_PIN" ] && post "$FOUND"; then
    echo "$FOUND" > "$CACHE"
    exit 0
  fi

  rm -f "$CACHE"
  touch "$BREAKER"
} >/dev/null 2>&1 &

exit 0
