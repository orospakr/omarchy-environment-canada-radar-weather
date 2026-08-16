#!/bin/bash
# Regenerate darkmap.frag.qsb from darkmap.frag (needs qt6-shadertools).
cd "$(dirname "$0")" && /usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o darkmap.frag.qsb darkmap.frag
