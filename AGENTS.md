# AGENTS.md

## Controlli runtime Denial

- Nel processo embedded `deniald` non usare `dart:io` `Process.run` o
  `Process.start`: la gestione dei processi non e' affidabile in questo runtime
  e puo' essere intercettata o fallire durante il teardown del compositor.
- Non implementare controlli frequenti o sensibili alla latenza (audio,
  luminosita', input, power mode) lanciando utility CLI. Usare una connessione
  nativa persistente tramite il platform bridge esistente, oppure un IPC
  dedicato gia' gestito da un servizio.

## Comandi di sviluppo PC

- Tutti i comandi `tools/denial-pc` devono essere eseguiti fuori dal
  sandbox (`require_escalated`). La toolchain Flutter eLinux e le relative
  cache sono vendorizzate nella radice `denial`; i comandi di sessione
  interagiscono inoltre con DRM, libseat e la sessione grafica in esecuzione.
