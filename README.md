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

## Datos

Las notas se guardan en `~/Documents/Bloc`, un archivo markdown por día. Bloc nunca sale a internet: no hay telemetría, ni cuentas, ni sync propio.

## Licencia

[MIT](LICENSE)
