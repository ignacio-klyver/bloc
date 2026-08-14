# Bloc

Notas rápidas para macOS, en un panel flotante estilo Spotlight. Apretás un atajo desde cualquier app, escribís, y el panel desaparece. Sin ventanas, sin Dock, sin fricción.

<!-- screenshot pendiente: docs/screenshot.png -->

## Por qué

La mayoría de las apps de notas te piden abrir una app, elegir dónde va la nota y decidir un título. Bloc apuesta a lo contrario: capturar en dos segundos y seguir con lo que estabas haciendo. Las notas se ordenan solas por día.

## Cómo funciona

- **Un atajo global** (⌥⌘B por defecto, configurable) abre el panel sobre lo que estés haciendo. Un campo único sirve para escribir una nota nueva o para buscar entre las viejas.
- **Una lista por día.** Cada día es una pestaña. Las notas se pueden tildar como hechas, destacar para que suban al tope, editar o borrar (con deshacer).
- **Tus notas son archivos.** Cada día vive en un markdown plano (`2026-08-14.md`) dentro de `~/Documents/Bloc`. Sin base de datos, sin formato propietario, sin cuenta. Podés leerlos, editarlos o sincronizarlos con lo que quieras.
- **Vive en la barra de estado.** Sin ícono en el Dock ni ventana principal. El contador del ícono muestra cuántas notas quedan pendientes.
- **Una nota puede volver a buscarte por Slack.** Escribís `@mañana 9:30` al final y esa nota te llega como mensaje directo a esa hora. Opcional, se conecta una vez: ver [Recordatorios en Slack](#recordatorios-en-slack).

## Instalación

Con [Homebrew](https://brew.sh):

```sh
brew install ignacio-klyver/tap/bloc
```

La fórmula compila Bloc en tu máquina (por eso no hace falta que la app esté firmada por Apple) y al final te indica cómo copiarla a `/Applications`.

Requisitos: macOS 14 o posterior, y Xcode o Command Line Tools con Swift 6 (`xcode-select --install`).

### Desde el código

```sh
git clone https://github.com/ignacio-klyver/bloc.git
cd bloc
./build.sh
cp -r Bloc.app /Applications/
```

## Recordatorios en Slack

Opcional. Una nota puede volver a buscarte como mensaje directo de Slack a la hora que le pidas.

Escribís la nota y le agregás al final cuándo querés que te llegue:

```
avisarle a Marina lo del contrato @mañana 9:30
```

La fila de abajo te muestra la nota ya sin el `@…` y, debajo, **Slack · mañana 09:30**. Esa línea es la confirmación: si no aparece, la nota se guarda como texto y no sale nada. Enter la guarda y la agenda.

También podés apretar **⌘⏎**, que abre una fila con cuatro tiempos habituales y un campo para escribir el mismo texto, por si no te acordás de la sintaxis. Con clic derecho sobre una nota vieja podés agendarla, reprogramarla o cancelar el recordatorio.

**Qué entiende el `@`:** `@hoy 18:00`, `@mañana 9:30`, `@lunes` (a las 9 si no ponés hora), `@vie 15:30`, `@pasado mañana 11`, `@14/8 10:00`, `@2026-09-01 7:15`, `@18:00` (hoy, o mañana si ya pasó), `@en 2h`, `@en 30 min`, `@en 3 días`. Acepta `a las`, `pm`/`am` y `hs`, y no le importan mayúsculas ni acentos.

Si lo que sigue al `@` no se entiende **entero**, no se toca nada: `mandale el doc a juan@empresa.com` y `hablar con @juan` se guardan tal cual.

### Setup

Una sola vez, y se hace en dos minutos. El agendado lo hace Slack, no Bloc: la nota se le entrega a Slack junto con su hora, y sale aunque tengas la Mac apagada.

**1. Creá la Slack app.** En [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest** → elegí tu workspace → pegá el contenido de [`docs/slack-app-manifest.yml`](docs/slack-app-manifest.yml) (ya trae los permisos) → **Next** → **Create**.

**2. Instalala.** En **Install App** → **Install to Workspace** → **Allow**. Copiá el **Bot User OAuth Token**, el que empieza con `xoxb-`.

**3. Conectala.** Poné un alias, porque la ruta al binario es larga:

```sh
alias bloc="/Applications/Bloc.app/Contents/MacOS/Bloc"   # sumalo a tu ~/.zshrc

bloc --slack-connect xoxb-tu-token --to vos@empresa.com
bloc --slack-test
```

Si `--slack-test` te llega como DM de "Bloc", ya está andando. Probá una nota real con `@en 2 min`.

### Comandos

| Comando | Qué hace |
|---|---|
| `bloc --slack-connect <token> [--to <destino>]` | Conecta el workspace y guarda el token |
| `bloc --slack-status` | A dónde está apuntando |
| `bloc --slack-test` | Manda un DM de prueba |
| `bloc --slack-pending` | Qué hay agendado esperando en Slack |
| `bloc --slack-off` | Borra el token de tu máquina |

`--to` acepta un mail, un member ID (`U…`), un ID de conversación (`C…`) o `#un-canal`. Sin `--to`, un token de usuario (`xoxp-…`) se resuelve solo a tu propio DM.

### Si algo falla

| Lo que ves | Qué pasó |
|---|---|
| *Request to Install* en vez de instalar | Tu workspace pide aprobación de admin. No hay forma de saltearlo. |
| `al token le faltan permisos` | La app se creó sin el manifiesto. Agregá los scopes en **OAuth & Permissions** y **reinstalá** la app: los permisos nuevos no aplican hasta reinstalar. |
| `no encontré a esa persona en el workspace` | El mail de `--to` no es el de tu cuenta de Slack. Probá con tu member ID (perfil → **⋮** → *Copy member ID*). |
| `el token no sirve o fue revocado` | Copiaste el *App-Level Token* o el *Signing Secret* en vez del **Bot User OAuth Token** (`xoxb-…`). |
| La nota dice **sin agendar** | Se guardó pero no llegó a Slack. Se reintenta solo la próxima vez que abras el panel. |

### Límites y privacidad

Slack no agenda más allá de **120 días**. Una hora que ya pasó no se agenda, y el panel te lo dice antes de guardar.

El token queda en `~/Library/Application Support/Bloc/slack.json` con permisos `0600` (solo lo lee tu usuario), igual que hacen `gh` y `aws`. Está en texto plano: si te preocupa, revocalo desde api.slack.com o corré `--slack-off`. No va al Keychain porque Bloc se firma ad-hoc, así que cada recompilación cambiaría su identidad y macOS te pediría permiso de nuevo cada vez.

Si preferís no darle los permisos de `users:read`, sacalos del manifiesto y pasale tu member ID en vez del mail.

## Datos

Las notas se guardan en `~/Documents/Bloc`, un archivo markdown por día. No hay telemetría, ni cuentas, ni sync propio.

Bloc sale a internet en un solo caso: cuando conectás Slack y agendás una nota, esa nota viaja a la API de Slack. Nada más se transmite nunca, y sin conectar Slack la app no abre un socket en su vida.

Una nota agendada se anota en el mismo archivo, debajo de su línea:

```markdown
- [ ] avisarle a Marina lo del contrato
      ↳ slack 2026-08-15 09:30 · Q1298393284
```

## Licencia

[MIT](LICENSE)
