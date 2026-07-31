# claude-context-guard

> **El [README en inglés](README.md) es el documento canónico.** Esta traducción se mantiene
> por conveniencia y puede quedar atrasada; ante cualquier discrepancia, manda el inglés.

Baja el techo de contexto de cada conversación de Claude Code de **~784.000 a ~440.000
tokens** en modelos de contexto 1M — de forma independiente por sesión, auditable y
totalmente reversible. Sin clics, sin `tmux send-keys`, sin proceso supervisor externo.

La pieza central es **una sola clave de settings**. Todo lo demás es un contrato de
preservación y evidencia.

**¿Para qué molestarse?** Con `autoCompactWindow` sin definir, Claude Code deja que una
conversación con modelo 1M crezca hasta ~784K tokens antes de compactar automáticamente. Cada
turno cerca de ese techo arrastra el contexto completo consigo — más lento y muchísimo más
caro. Limitar la compactación a ~440K reduce aproximadamente a la mitad el contexto que paga
cada turno, y el contrato de preservación evita que el resumen pierda las decisiones que
importan.

Nació y fue validado en el plugin de Claude Code dentro de **TRAE IDE** (macOS); funciona con
cualquier host que comparta `~/.claude/` (CLI, extensión de VS Code).

## Estado

`v0.0.1` — temprano, pero medido en producción por su autor:

- 12 compactaciones automáticas ocurrieron entre **435.080 y 440.004 tokens** (objetivo 440K,
  desviación máxima 1,1%) a lo largo de 7 sesiones independientes.
- Contrato de preservación aplicado en 18/19 resúmenes (`contract_markers: 2` en el log).
- Los resúmenes se mantuvieron entre 13 y 24 KB sin importar el tamaño del transcript (de 3,8
  MB a 42 MB).
- Los handoffs deterministas cubrieron 87 sesiones, incluidas sesiones interrumpidas a mitad
  de camino.

Los comentarios y los issues son muy bienvenidos — ese es justamente el motivo de publicar
esto tan temprano.

## Requisitos

- Claude Code ≥ 2.1.x (el binario incluido en la extensión de TRAE/VS Code cuenta).
- `jq` (macOS lo trae; en Linux, `apt install jq`).
- macOS se prueba a diario; Linux pasa la suite de tests en CI pero no se ha usado en serio.

## Instalación

```sh
git clone https://github.com/pablojacobi/claude-context-guard ~/.claude/context-guard
~/.claude/context-guard/install.sh
```

`install.sh` respalda `~/.claude/settings.json` en `~/.claude/backups/`, hace merge con `jq`
sobre el objeto existente (nunca lo reescribe), verifica que no se haya perdido ninguna clave
y aborta ante cualquier discrepancia. También copia la skill `velador` a `~/.claude/skills/`.

**Los hooks y el umbral se leen al iniciar una sesión.** Las conversaciones ya abiertas
conservan la configuración anterior: abre una nueva.

Verificar:

```sh
~/.claude/context-guard/tests/run-tests.sh        # 49 aserciones, sandbox descartable
~/.claude/context-guard/tests/threshold-math.sh   # canario de la fórmula
~/.claude/context-guard/bin/cg-status.sh          # auditoría de solo lectura
```

Desinstalar (deja los settings exactamente como estaban):

```sh
~/.claude/context-guard/uninstall.sh              # o --restore para el respaldo textual
```

## Cómo funciona

### Capa 0 — el umbral (hace el 90% del trabajo)

`autoCompactWindow: 473000` en `~/.claude/settings.json`. La fórmula del binario promete
`min(eff × 0.8, eff − 13000)`, pero lo que **medimos** en producción (2026-07-30, dos
sesiones: 534.878 y 536.796 con window=570000) es que solo manda el término reactivo:

```
punto de disparo real ≈ autoCompactWindow − 20.000 − 13.000
```

Con `473000` en un modelo 1M → **dispara en ~440.000**. Si la fracción remota volviera alguna
vez a 0,2, el punto baja a 362.400: la calibración falla hacia el lado agresivo, nunca hacia
el laxo.

`min()` acota según el modelo, así que la misma clave funciona en un modelo de 200K (dispara
en 144.000) sin configuración por modelo.

### Capa 1 — el contrato de preservación

`contract.md` se emite por **stdout del hook `PreCompact`**, y el binario lo usa como
instrucciones de compactación para el resumidor.

Vive aquí y no en `CLAUDE.md` por razones de costo: un `~/.claude/CLAUDE.md` global se carga
en el system prompt de *cada* sesión y cobra tokens en cada turno — exactamente lo que estamos
tratando de reducir. El stdout de un hook cuesta **cero hasta que ocurre una compactación**.

El contrato *se suma* a la plantilla incorporada del resumidor en lugar de competir con ella
(se probó un reemplazo desde cero y perdió 0/7 contra la estructura incorporada). Agrega las
secciones `Decisions and Rationale` y `Repo State`, exige el criterio de éxito verificable y
los errores actuales literales, y lleva una lista explícita de descarte: las decisiones
sobreviven, los logs no.

Si se detecta un estado de git delicado (`MERGE_HEAD`, `REBASE_HEAD`, `CHERRY_PICK_HEAD`,
`index.lock`, un rebase en curso), se antepone un bloque `CRITICAL GIT STATE` con la rama, el
paso exacto y la siguiente acción.

**Por qué no veta la compactación:** compactar solo reescribe la memoria conversacional entre
turnos — no puede interrumpir una herramienta en ejecución ni una operación de git.
Postergarla no protegería el rebase; solo dejaría que la sesión siga escalando. El riesgo real
es *perder la nota* sobre ese estado, así que se detecta y se inyecta, no se bloquea.

### Capa 2 — evidencia

Una línea JSON por evento en `logs/YYYY-MM.jsonl`, con `session_id`, `cwd`, rama, worktree,
disparador, conteo de tokens y un contador por sesión. Sin transcripts, sin secretos.

Aislamiento: un `printf` de una línea de menos de 4KB a un fd `O_APPEND` es atómico, y el
contador vive en un archivo por sesión, así que las conversaciones en paralelo nunca se
entrelazan ni se perturban entre sí.

`post-compact.sh` además revisa el resumen mismo (el payload de `PostCompact` lo incluye)
buscando las secciones marcadoras del contrato — así el log distingue entre "ocurrió una
compactación" y "el contrato se aplicó de verdad".

### Capa 3 — handoffs siempre activos, y el velador

El hook `Stop` reescribe `night/handoff-<session_id>.md` en cada turno de **cada** sesión — no
hay un modo que activar. Pedirle al modelo que "escriba un handoff cuando termine" falla
exactamente en el caso que importa: cuando se traba o lo cortan a las 4 de la mañana. Como
subproducto del hook, "siempre hay un handoff" es cierto por construcción.

Los estancamientos se detectan de forma determinista: N turnos en los que ningún HEAD se
movió, el conjunto de archivos sucios no cambió **y** ningún archivo bajo el cwd fue
modificado (la señal del sistema de archivos existe porque la detección basada solo en git una
vez marcó como estancada una sesión que legítimamente estaba investigando sin commitear).

**Corridas autónomas (velador — experimental, aún sin validar en una corrida real):** dile a
la conversación "leave it running until it's done" (o en español: "déjalo corriendo"). La
skill `velador` hace que el modelo destile su propio objetivo, criterio de éxito y presupuesto
de turnos opcional en `night/request.md`; el hook lo reclama para esa sesión y desde entonces
reinyecta el objetivo al final de cada turno, forzando la continuación hasta que el modelo
borre el marcador (criterio cumplido o bloqueo genuino), se agote el presupuesto o corte el
detector de estancamiento. **Sin tope de turnos por defecto** (las corridas reales pueden
durar legítimamente un día); un número en tu frase se convierte en un tope duro. La cuenta es
visible en cada reinyección y en el handoff. `/goal` + `bin/cg-goal.sh` siguen existiendo como
alternativa con un juez externo (`templates/night-run.md`).

## Operación

| Qué | Cómo |
|---|---|
| Auditar | `bin/cg-status.sh` |
| Apagar todo en 1s | `touch ~/.claude/context-guard/disabled` |
| Volver a encenderlo | `rm ~/.claude/context-guard/disabled` |
| Cambiar el umbral | `./install.sh --window 400000` |
| Handoffs por sesión | siempre activos; retención de 14 días |
| Ajustar el límite de estancamiento | `echo 8 > stall-limit` (por defecto 6) |
| Actualizar | `git pull && ./install.sh --repair` |
| Desinstalar | `./uninstall.sh` (o `--restore` para el respaldo textual) |
| Borrar también los logs | `./uninstall.sh --purge` |

Los logs rotan mensualmente. Para conservar 3 meses:

```sh
find ~/.claude/context-guard/logs -name '*.jsonl' -mtime +90 -delete
```

## Advertencias honestas — léelas antes de confiar en esto

1. **`autoCompactWindow` no está en la documentación pública de Anthropic.** Es una clave
   válida de `settings.json` (verificada en el binario, expuesta en `/config` en pasos de
   100K), pero puede cambiar entre versiones sin aviso. `tests/threshold-math.sh` es el
   canario.
2. **El punto de disparo depende de la configuración remota** (gates del lado del servidor):
   ya se movió una vez (la fracción 0,2 del binario frente al ~0 realmente servido). Se
   detecta comparando el `context_tokens` registrado contra el valor esperado; `cg-status.sh`
   avisa ante desviaciones >5%.
3. **Que el stdout de `PreCompact` se convierta en instrucciones del resumidor no está
   documentado.** Si deja de funcionar en silencio, el contrato se pierde. Mitigación siempre
   activa: `post-compact.sh` cuenta los marcadores del contrato en el resumen real; un
   `contract_markers: 0` sostenido significa que el mecanismo murió. Alternativa documentada:
   mover el contrato a `~/.claude/CLAUDE.md`, al costo de tokens en cada turno.
4. **La configuración de la sesión está congelada por proceso, no para siempre**: retomar una
   conversación (o reiniciar el IDE) vuelve a leer los settings; una sesión que ya pasó el
   nuevo umbral compacta de inmediato al retomarse. Espera un dato fuera de rango en la serie
   de desviación cuando eso ocurra.
5. **Otro hook `PreCompact` que imprima en stdout contaminaría el contrato**, porque el binario
   concatena el stdout de todos los hooks. `install.sh` preserva deliberadamente los hooks
   ajenos; si agregas uno en ese evento, mantén su stdout vacío.
6. **Ningún hook puede detener una sesión que insiste en continuar.** `Stop` solo puede forzar
   lo contrario. Los límites duros viven en el corte por presupuesto/estancamiento y en tu
   lista `deny` de permisos.
7. **El handoff es determinista, no omnisciente.** Captura el estado de git y del progreso, no
   el razonamiento del modelo. Si una sesión muere sin haber commiteado nada, dirá "no
   verifiable progress" — que es la verdad útil, no una reconstrucción inventada.
8. **El progreso se mide por actividad de git y de archivos bajo el cwd.** Una sesión que solo
   lee igual cuenta como estancada; sube `stall-limit` si eso te molesta.
9. **El velador es experimental.** Todas las demás capas tienen mediciones reales de
   producción detrás; el velador tiene un ciclo completo de suite de tests pero ninguna
   corrida nocturna real todavía.
10. **La compactación no devuelve los tokens ya gastados.** Baja el techo: el ahorro viene de
    no ir navegando en 780K, no de un reembolso.

## Después de una semana, revisa

- El `context_tokens` registrado frente a 440.000: desviación >5% ⇒ la fracción remota se movió
  ⇒ ajusta `autoCompactWindow` proporcionalmente (`cg-status.sh` lo calcula).
- Más de 3-4 compactaciones por día en una sola tarea ⇒ la ventana es demasiado chica para tu
  flujo de trabajo ⇒ súbela.
- Lee los primeros 2-3 turnos posteriores a una compactación: si la sesión vuelve a leer
  archivos que no necesitaba o vuelve a preguntar algo ya decidido, hay un campo de
  `contract.md` que necesita refuerzo.
- `STALLED` durante exploración legítima ⇒ sube `stall-limit`.

## Archivos

```
install.sh · uninstall.sh · README.md · README.es.md · contract.md · CHANGELOG.md · LICENSE
bin/lib.sh              helpers; todo falla en abierto
bin/pre-compact.sh      contrato vía stdout + log         (stdout = SOLO el contrato)
bin/post-compact.sh     tokens antes/después/ahorrados + chequeo del contrato
bin/stop-progress.sh    handoff determinista + estancamiento + loop del velador (siempre activo)
bin/cg-status.sh        auditoría de solo lectura
bin/cg-goal.sh          goal estándar apuntado al plan más nuevo -> portapapeles
skills/velador/         corridas autónomas por frase natural (se instala en ~/.claude/skills)
templates/night-run.md  la alternativa a /goal
tests/run-tests.sh      49 aserciones sobre eventos simulados, sandbox descartable
tests/threshold-math.sh canario de la fórmula
logs/ state/ night/     runtime, chmod 700, ignorados por git
disabled                ausente por defecto; touch -> todo pasa a no-op
capture                 modo de captura de payloads crudos (./install.sh --capture)
stall-limit             turnos sin progreso antes de STALLED (por defecto 6)
```

## Hoja de ruta

- Primera validación en vivo del velador (gate de la v0.1).
- Validación en más hosts: se espera que el CLI plano y la extensión de VS Code funcionen
  (mismo `~/.claude/`), los reportes son bienvenidos.
- Pruebas de campo en Linux (CI en verde hoy, sin probar en uso diario).

## Licencia

MIT.