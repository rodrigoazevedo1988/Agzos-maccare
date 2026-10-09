#!/bin/sh
# Confere as invariantes de entitlements e Info.plist descritas em
# Resources/MacCare.entitlements e docs/BUILD.md §5.1.
#
# Uso:
#   scripts/check-entitlements.sh                 # confere os arquivos do repositório
#   scripts/check-entitlements.sh MacCare.app     # confere também o binário assinado
#
# Invariantes:
#   - o arquivo de entitlements é um plist válido;
#   - a ÚNICA chave é com.apple.security.get-task-allow, com valor false;
#     (sem app-sandbox, sem cs.* de relaxamento, sem câmera/microfone,
#      sem rede, sem automação de Apple Events);
#   - o Info.plist não declara câmera nem microfone;
#   - num .app assinado, get-task-allow é false ou ausente.
set -eu
cd "$(dirname "$0")/.."

ENTITLEMENTS=Resources/MacCare.entitlements
INFO=Resources/Info.plist
fail() { echo "ERRO: $*" >&2; exit 1; }

plutil -lint "$ENTITLEMENTS" >/dev/null || fail "$ENTITLEMENTS não é um plist válido"
plutil -lint "$INFO" >/dev/null || fail "$INFO não é um plist válido"

# plutil -extract trata "." como separador de caminho; as chaves aqui têm
# pontos, então a leitura usa plistlib.
/usr/bin/python3 - "$ENTITLEMENTS" "$INFO" <<'PY' || exit 1
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    ent = plistlib.load(f)
with open(sys.argv[2], "rb") as f:
    info = plistlib.load(f)
errors = []
if set(ent) != {"com.apple.security.get-task-allow"}:
    errors.append("entitlements devem conter apenas com.apple.security.get-task-allow; encontrado: %s" % sorted(ent))
if ent.get("com.apple.security.get-task-allow") is not False:
    errors.append("get-task-allow precisa ser false no arquivo")
for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription"):
    if key in info:
        errors.append("Info.plist declara %s, mas o app não usa câmera nem microfone" % key)
for e in errors:
    print("ERRO: " + e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY

if [ $# -ge 1 ]; then
    APP=$1
    signed=$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)
    case "$signed" in
        *get-task-allow*"<true/>"*) fail "$APP foi assinado com get-task-allow = true" ;;
    esac
    for forbidden in app-sandbox device.camera device.audio-input network.client network.server automation.apple-events cs.disable-library-validation cs.allow-jit cs.allow-unsigned-executable-memory cs.allow-dyld-environment-variables; do
        case "$signed" in
            *"com.apple.security.$forbidden"*) fail "$APP foi assinado com com.apple.security.$forbidden" ;;
        esac
    done
    echo "OK: entitlements do binário $APP"
fi
echo "OK: invariantes de entitlements e Info.plist"
