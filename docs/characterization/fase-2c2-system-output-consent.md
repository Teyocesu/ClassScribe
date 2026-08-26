# Caracterización Fase 2C.2 — UX de audio del equipo y consentimiento explícito

Fecha: 2026-08-25

Baseline de implementación: `d70795b2ed74bfd5b812ba1d1782c3545c0d547e`

Estado: **FIXED / PARTIAL**. La UX y el control-plane de consentimiento quedaron
implementados en macOS y Windows; el correctivo de ownership del modal macOS y la
revisión local macOS pasaron. La suite/runtime Windows queda **SKIPPED —
dotnet/csc unavailable**. Esto no marca la Fase 2C.2 como APPROVED, no marca la
Fase 2 completa ni convierte los gates físicos o de runtime en PASS.

## UX de fuente online

`CaptureMode` conserva únicamente `online` e `inPerson`. La fuente online es
una dimensión separada, con dos opciones estructuradas:

- `Una aplicación`: conserva el selector de aplicaciones y el comportamiento
  existente.
- `Audio del equipo`: oculta/deshabilita el selector de aplicación y muestra
  `Captura todo el audio que sale por tu equipo.`

La elección está visible en el target activo macOS
(`app/MeetingTranscriber/ClassScribeSources/ContentView.swift`) y en Windows
(`app/ClassScribe.Windows/src/ClassScribe.Windows/MainWindow.xaml`). Windows
usa `AudioSourceOption.SystemOutput` sólo como representación interna del scope;
no enumera una pseudo-aplicación.

## Modal de privacidad

Cada nuevo intento `systemOutput` presenta, antes de crear la sesión durable o
iniciar el recorder, el siguiente contenido:

```text
Título: Capturar audio del equipo

ClassScribe capturará todo el audio que salga por el dispositivo de salida del equipo. Esto puede incluir otras aplicaciones, notificaciones y sonidos del sistema.

El audio se procesa y guarda localmente en tu dispositivo.

¿Quieres continuar?

Confirmar: Capturar audio del equipo
Cancelar: Cancelar
```

No hay checkbox, opción de recordar, consentimiento global ni persistencia del
consentimiento.

## Ownership de presentación del modal macOS

`ClassScribeModel.pendingSystemOutputConsent` es la única fuente de ownership
del request pendiente. `ContentView` presenta una copia separada mediante
`SystemOutputConsentPresentationState`; por eso el dismiss automático del
`Alert` sólo limpia el estado de presentación y no puede borrar el request de
dominio antes del confirm. Una invalidación legítima del pending sincroniza la
copia de presentación, y la desaparición de la ventana cancela el pending.

La acción afirmativa llama a `confirmSystemOutputConsent`, que verifica y
consume el request exacto y emite el capability antes del primer `await`.
Una segunda confirmación del mismo request, o una copia stale después de un
cambio de fuente/modo, no puede iniciar otra captura.

## Frontera de autorización

La única emisión productiva ocurre en la acción afirmativa del modal mediante
`issueAfterExplicitUserConsent` (expuesto por el control-plane de cada
plataforma). El capability es efímero, contiene nonce y queda ligado al
`SessionAttemptID` exacto; `WindowsAudioCapture.StartAsync` y
`CaptureController.start` lo validan en el boundary de captura.

Seleccionar `Audio del equipo`, pulsar el CTA, refrescar fuentes, abrir
historial o leer metadata con `captureScope: systemOutput` no emite
autorización. Cancelar, cambiar modo/fuente durante el pending, iniciar otra
acción, cerrar la ventana o fallar antes de iniciar invalida el intento y no
deja un capability reutilizable. No se crean `source.raw`, `source.wav` ni
metadata de grabación cuando se cancela el modal.

## Confirmación tardía y ownership

El pending-consent conserva un request explícito con el intento y la materia.
La confirmación se acepta sólo si sigue siendo el request actual y la selección
continúa en online/system-output. Un cambio de fuente o modo vuelve stale el
request; una confirmación posterior no puede arrancar la fuente anterior.

Después de confirmar, el scope y la configuración se capturan como snapshot
del intento. No existe transición automática entre aplicación y audio del
equipo ni hot-switch durante una grabación.

## CTA posterior a fallo

`Capturar audio del equipo` aparece sólo cuando el estado/cause estructurado
identifica un fallo relevante de la captura online de aplicación: fallo de
resolución, fuente sin audio, callbacks detenidos o fallo de fuente durante el
start. Los fallos de disco/metadata, ASR, diarización, exportación e historial
no lo recomiendan.

El CTA únicamente cambia la fuente elegida para el próximo intento a
`systemOutput`. No inicia captura, no emite autorización y el siguiente
`Start` vuelve a mostrar el modal. Si el fallo ocurre durante una grabación,
el owner sigue siendo `Stop`/finalización y el CTA no cambia el scope activo.

## Metadata y persistencia

Una captura confirmada del audio del equipo persiste:

```text
mode         = online
captureScope = systemOutput
source       = Audio del equipo
```

No se persisten consent, nonce ni capabilities. Se conservan las fronteras de
persistencia existentes: audio original, transcript ASR original y overlays de
correcciones humanas siguen siendo independientes de la proyección automática.
La apertura de historial restaura la elección visual de `systemOutput`, pero no
autoriza una captura nueva.

## Tests y evidencia local

macOS:

- `./scripts/pre-push.sh --with-tests` — **PASS**;
- build release del bundle macOS — **PASS**;
- suite ClassScribe — **237 tests passed**;
- tests focalizados de modelo/UI: selección sin aplicación, cancelación,
  capability por intento, metadata, ownership de presentación/dismissal,
  confirmación única, stale confirmation, segundo consentimiento y CTA sin
  fallback — **PASS** dentro de la suite.

Windows:

- tests del product/control path escritos en
  `app/ClassScribe.Windows/tests/ClassScribe.Windows.Tests` para selección,
  modal aceptado/denegado, autorización por intento, metadata, CTA y segundo
  consentimiento;
- static review de `MainWindow`, `MainViewModel` y `WindowsAudioCapture` —
  **PASS**;
- compile/runtime Windows — **SKIPPED — dotnet/csc unavailable**; no se
  instaló ningún SDK.

## Gates heredados y trabajo diferido

Siguen **PENDING/SKIPPED**, no PASS:

- Windows compile/runtime físico;
- Windows physical gate;
- macOS CATap global physical gate;
- TCC;
- hardware/device-change physical gates.

Master source-rate/stereo frente al derivado ASR 16 kHz mono, y el formato de
archivo largo RF64/W64 o segmentación, permanecen pendientes. La Fase 2C.2 no
afirma release readiness completo ni inicia la Fase 2D o una fase posterior.
