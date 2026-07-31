#include <Arduino.h>
#include <string.h>
#include "sessions.h"

static Session g_sess[MAX_SESSIONS];

// Prioridade na tela: quem precisa de voce vem primeiro. Tambem define quem e
// sacrificado quando a lista lota (o de maior rank sai antes).
static uint8_t sess_rank(SessStatus s) {
    switch (s) {
        case S_WAITING: return 0;
        case S_WORKING: return 1;
        case S_DONE:    return 2;
        default:        return 3;   // S_STALE
    }
}

void sessionsInit() { memset(g_sess, 0, sizeof(g_sess)); }

static int find_by_id(const char *id) {
    for (int i = 0; i < MAX_SESSIONS; i++)
        if (g_sess[i].used && !strcmp(g_sess[i].id, id)) return i;
    return -1;
}

// Slot livre; se lotou, descarta o card menos util (stale, depois done, ...) e
// so entao o mais antigo dentro do mesmo status. Descartar por updatedAt puro,
// como seria o obvio, pode matar justamente um "waiting" — o unico card que o
// dispositivo existe para mostrar.
static int alloc_slot() {
    for (int i = 0; i < MAX_SESSIONS; i++)
        if (!g_sess[i].used) return i;

    int worst = 0;
    for (int i = 1; i < MAX_SESSIONS; i++) {
        uint8_t ri = sess_rank(g_sess[i].status), rw = sess_rank(g_sess[worst].status);
        if (ri > rw || (ri == rw && g_sess[i].updatedAt < g_sess[worst].updatedAt)) worst = i;
    }
    return worst;
}

bool sessionUpsert(const char *id, const char *project, const char *title,
                   const char *host, SessStatus st, uint64_t seq) {
    if (!id || !id[0]) return false;

    bool changed = false;
    int i = find_by_id(id);
    // evento fora de ordem (curl em background nao garante ordem de chegada)
    if (i >= 0 && seq && g_sess[i].seq && seq < g_sess[i].seq) return false;
    if (i < 0) {
        i = alloc_slot();
        memset(&g_sess[i], 0, sizeof(Session));
        g_sess[i].used = true;
        strlcpy(g_sess[i].id, id, sizeof(g_sess[i].id));
        changed = true;
    }
    if (project && project[0] && strcmp(g_sess[i].project, project)) {
        strlcpy(g_sess[i].project, project, sizeof(g_sess[i].project));
        changed = true;
    }
    // o titulo e reescrito pelo Claude Code conforme a conversa evolui
    if (title && title[0] && strcmp(g_sess[i].title, title)) {
        strlcpy(g_sess[i].title, title, sizeof(g_sess[i].title));
        changed = true;
    }
    if (host && host[0] && strcmp(g_sess[i].host, host)) {
        strlcpy(g_sess[i].host, host, sizeof(g_sess[i].host));
        changed = true;
    }
    if (g_sess[i].status != st) { g_sess[i].status = st; changed = true; }
    g_sess[i].updatedAt = millis();
    if (seq) g_sess[i].seq = seq;
    return changed;
}

bool sessionRemove(const char *id) {
    if (!id || !id[0]) return false;
    int i = find_by_id(id);
    if (i < 0) return false;
    memset(&g_sess[i], 0, sizeof(Session));
    return true;
}

bool sessionsSweep() {
    uint32_t now = millis();
    bool changed = false;
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (!g_sess[i].used || g_sess[i].status == S_STALE) continue;
        // aritmetica unsigned: sobrevive ao rollover de millis()
        if (now - g_sess[i].updatedAt >= SESSION_STALE_MS) {
            g_sess[i].status = S_STALE;
            changed = true;
        }
    }
    return changed;
}

uint8_t sessionsSnapshot(Session *out, uint8_t max) {
    if (!out || !max) return 0;
    uint8_t n = 0;
    for (int i = 0; i < MAX_SESSIONS && n < max; i++)
        if (g_sess[i].used) out[n++] = g_sess[i];

    // insertion sort: no maximo 6 itens, nao vale nada mais elaborado
    for (uint8_t i = 1; i < n; i++) {
        Session key = out[i];
        int j = i - 1;
        while (j >= 0) {
            uint8_t rk = sess_rank(key.status), rj = sess_rank(out[j].status);
            bool after = (rj < rk) || (rj == rk && out[j].updatedAt >= key.updatedAt);
            if (after) break;
            out[j + 1] = out[j];
            j--;
        }
        out[j + 1] = key;
    }
    return n;
}
