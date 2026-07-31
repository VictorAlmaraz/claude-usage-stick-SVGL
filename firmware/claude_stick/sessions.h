#pragma once
#include <stdint.h>

// Sessoes do Claude Code em andamento na maquina do usuario.
//
// A API da Anthropic nao expoe sessao (os headers unified-* so falam de quota),
// entao o estado chega por push: os hooks do Claude Code disparam
// tools/stick-notify.sh, que faz POST /session neste device.
//
// Estado efemero por definicao — depois de um reboot nada aqui e valido, logo
// NAO vai para LittleFS. Array estatico, sem heap e sem String, igual ao resto
// do firmware.
#define MAX_SESSIONS      6
#define SESSION_STALE_MS  (10UL * 60UL * 1000UL)

enum SessStatus : uint8_t { S_WORKING = 0, S_WAITING, S_DONE, S_STALE };

struct Session {
    char       id[12];       // 8 primeiros chars do session_id
    char       project[24];  // basename do cwd
    char       title[48];    // titulo da sessao (o mesmo da barra lateral); "" = sem titulo
    char       host[24];     // hostname curto (16 nao cabe um "Nome-MacBook-Pro-2")
    SessStatus status;
    uint32_t   updatedAt;    // millis() do ultimo evento recebido
    uint64_t   seq;          // time.time_ns() do hook que gerou o evento
    bool       used;
};

void sessionsInit();

// As tres funcoes abaixo retornam true quando a lista mudou de forma VISIVEL
// (entrou/saiu sessao ou trocou de status). Só nesse caso a UI precisa
// reconstruir os cards — um heartbeat que so renova updatedAt retorna false e
// e absorvido pelo tick de 1s, sem rebuild.
//
// `seq` e o instante em que o HOOK disparou (ns). Os hooks sao assincronos e
// mandam curl em background, entao dois eventos a milissegundos um do outro
// (o PostToolUse final e o Stop) podem chegar trocados. Sem isso, um "working"
// atrasado sobrescreve o "done" e a sessao fica azul depois de terminar.
// Evento com seq menor que o ja registrado e descartado.
bool sessionUpsert(const char *id, const char *project, const char *title,
                   const char *host, SessStatus st, uint64_t seq);
bool sessionRemove(const char *id);
bool sessionsSweep();        // marca S_STALE quem passou de SESSION_STALE_MS

// Copia ordenada por acionabilidade (waiting > working > done > stale,
// desempate por updatedAt desc). Retorna quantas sessoes foram copiadas.
uint8_t sessionsSnapshot(Session *out, uint8_t max);
