# Fase 2B.1 — Identidad estable y reconciliación de startup

Fecha: 2026-08-25
Alcance: identidad lógica de aplicación, encarnación de proceso y
reconciliación de root/helpers/renderers antes de iniciar captura. No incluye
rebind durante una grabación activa, captura global, master/RF64, ASR, VAD ni
cambios de persistencia.

## Estado

**PHASE 2B.1 COMPLETE / PARTIAL**

La implementación separa la identidad lógica de una aplicación de su PID
efímero. El PID queda como diagnóstico de la encarnación observada; no se usa
como la identidad seleccionada ni se persiste como tal. La reconciliación de
startup pertenece al intento dueño y tiene deadline monotónico, cancelación
propagada al trabajo detached y publicación protegida contra intentos
obsoletos. Las filas del picker mantienen un ID de encarnación separado de la
identidad lógica seleccionable.

## Modelo macOS

`ApplicationIdentity` usa el bundle identifier como señal fuerte y bundle URL /
ejecutable canónico como refuerzo. El fallback sin bundle identifier es
explícitamente débil: puede conservar la misma encarnación observada, pero no
puede reasignarse a un PID de reemplazo por nombre visible.
`MacApplicationProcessSnapshot` representa una observación efímera.

La reconciliación realiza, fuera de MainActor:

1. resolver la identidad seleccionada contra los candidatos actuales;
2. rechazar una selección ambigua y no escoger por display name;
3. enumerar root y procesos bajo el bundle, filtrando PIDs ya muertos;
4. esperar y refrescar mientras CoreAudio publica procesos/helpers;
5. conservar sólo PIDs con traducción CoreAudio válida.

Antes de crear el tap se repite la traducción y se valida el round-trip con
`kAudioProcessPropertyPID`. Si no queda ningún objetivo válido,
`CATapDescription` no se crea y la captura termina con un error recuperable
explícito.

## Modelo Windows

`WindowsApplicationIdentity` prefiere ruta ejecutable y package identity cuando
está disponible; nombre de proceso solo es débil y no permite auto-rebind. El
root se revalida inmediatamente antes de
`WithProcessLoopback(...).BuildAsync()`. Si el PID incumbente sigue teniendo la
identidad seleccionada, conserva precedencia aunque existan hermanos con la
misma identidad fuerte; sólo cuando falta o no coincide se aplican las reglas
de cero candidatos (`missing`), una coincidencia (`resolved`) o varias
(`ambiguous`). Una identidad débil nunca auto-reenlaza. No existe una API de
rebind para un recorder activo.

## Resultados estructurados y seguridad de intentos

Ambas rutas modelan `resolved`, `missing`, `ambiguous` y
`unsupportedWeakIdentity`, con identidad seleccionada, PID previo/resuelto,
conteo/candidatos, topología y objetivos traducidos como evidencia técnica.
No se agregan títulos de ventanas ni audio a ese diagnóstico. Un intento stale
no puede publicar una topología resuelta, seleccionar un root ni iniciar el
tap/loopback de otro intento.

## Tests deterministas

macOS: `sameIdentitySamePidResolves`,
`sameIdentityReplacementPidResolvesDuringStartup`,
`helperAppearsAfterInitialEnumerationIsIncluded`, `deadPidIsRemovedFromTopology`,
`unrelatedSameDisplayNameIsNotSelected`, `multipleStrongMatchesAreAmbiguous`,
`missingApplicationIsMissing`, `staleAttemptCannotPublishResolvedTopology`,
`parentTaskCancellationStopsStartupReconciliation`,
`applicationRowsSeparateLogicalIdentityFromIncarnationID`,
`translatedAudioTargetIsValidatedBeforeTapHandoff` y
`noValidAudioObjectsDoesNotCreateTap` pasan en el focused Swift.

Windows: `sameIdentitySameRootResolves`,
`incumbentRootWinsWhenSiblingProcessesShareStrongIdentity`,
`expiredRootWithUniqueStrongReplacementResolves`,
`expiredRootWithMultipleStrongReplacementsIsAmbiguous`,
`incumbentPidWithDifferentIdentityIsNotAccepted`,
`sameNameDifferentExecutableDoesNotMatch`, `weakIdentityDoesNotAutoRebind`,
`staleAttemptCannotPublishReplacement`,
`staleAttemptCannotReachProcessLoopbackBuildBoundary` y
`resolvedPidIsRevalidatedBeforeBuildAsync` quedan escritos para MSTest.

## Gates físicos

No se ejecutó un fixture físico nuevo. El gate CATap físico macOS de Fase 1C
permanece **PASS**; micrófono macOS permanece **SKIPPED — TCC** y Windows
físico/runtime permanece **SKIPPED — PHYSICAL WINDOWS / dotnet unavailable**.
La ejecución de tests Windows no es una afirmación de runtime en este host.
