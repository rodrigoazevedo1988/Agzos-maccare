#!/bin/sh
# Roda a suíte (Swift Testing) com `swift test`, com ou sem Xcode.
#
# Com apenas as Command Line Tools, o Testing.framework fica em
# CommandLineTools/Library/Developer/Frameworks, mas o SwiftPM não passa esse
# caminho ao compilador nem ao linker. Sem ele, o runner gerado pelo SwiftPM compila sem
# `import Testing` e `swift test` termina "verde" sem executar NENHUM teste.
# Este script acrescenta o caminho só quando as CLT são o diretório ativo.
#
# Uso: scripts/test.sh [argumentos do swift test], ex.:
#   scripts/test.sh --filter PathGuardTests
set -eu
CLT=/Library/Developer/CommandLineTools
FRAMEWORKS="$CLT/Library/Developer/Frameworks"
LIBRARIES="$CLT/Library/Developer/usr/lib"
DEVELOPER_DIR_ACTIVE="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"

case "$DEVELOPER_DIR_ACTIVE" in
    "$CLT"*)
        if [ -d "$FRAMEWORKS/Testing.framework" ]; then
            exec swift test \
                -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
                -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
                -Xlinker -rpath -Xlinker "$LIBRARIES" \
                "$@"
        fi
        ;;
esac
exec swift test "$@"
