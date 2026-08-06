#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$PROJECT_ROOT/.test-fixtures"
mkdir -p "$FIXTURES"
"$SCRIPT_DIR/prepare_local_toolchain.sh" >/dev/null

say -v 'Mónica' -o "$FIXTURES/spanish-known.aiff" \
    'Hoy estudiaremos el método de Newton Raphson para resolver ecuaciones no lineales. Después veremos el método de bisección.'
afconvert "$FIXTURES/spanish-known.aiff" "$FIXTURES/spanish-known.wav" -f WAVE -d LEI16@16000

say -v 'Grandpa (Español (México))' -r 175 -o "$FIXTURES/speaker-one-a.aiff" \
    'Primero definimos la ecuación diferencial, establecemos las condiciones iniciales y elegimos un tamaño de paso. El método de Runge Kutta aproxima la solución mediante cuatro pendientes. Cada pendiente aporta información sobre la evolución de la función en el intervalo.'
say -v 'Mónica' -r 195 -o "$FIXTURES/speaker-two-a.aiff" \
    'Profesor, quisiera entender cómo influye el tamaño del paso en el error numérico. Si reducimos el paso, ¿siempre obtenemos una mejor aproximación, o puede aparecer un problema de redondeo cuando hacemos demasiadas operaciones?'
say -v 'Grandpa (Español (México))' -r 175 -o "$FIXTURES/speaker-one-b.aiff" \
    'Es una buena pregunta. Al reducir el paso suele disminuir el error de truncamiento, pero aumenta la cantidad de cálculos. En aritmética finita, los errores de redondeo pueden acumularse. Por eso buscamos un equilibrio y verificamos la convergencia con diferentes pasos.'
say -v 'Mónica' -r 195 -o "$FIXTURES/speaker-two-b.aiff" \
    'Entonces podríamos resolver el mismo ejercicio tres veces y comparar las respuestas. También podríamos representar la diferencia en una gráfica. Así sabríamos si la solución se estabiliza y si el costo adicional realmente mejora el resultado.'
for clip in speaker-one-a speaker-two-a speaker-one-b speaker-two-b; do
    afconvert "$FIXTURES/$clip.aiff" "$FIXTURES/$clip.wav" -f WAVE -d LEI16@16000
done
xcrun swift -resource-dir "$PROJECT_ROOT/.toolchain/usr/lib/swift" \
    "$SCRIPT_DIR/concatenate_audio.swift" \
    "$FIXTURES/speaker-one-a.wav" "$FIXTURES/speaker-two-a.wav" \
    "$FIXTURES/speaker-one-b.wav" "$FIXTURES/speaker-two-b.wav" \
    "$FIXTURES/two-speakers.wav"

echo "Fixtures sintéticos creados en $FIXTURES"
