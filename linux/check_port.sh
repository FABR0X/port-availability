#!/usr/bin/env bash
#
# check_port.sh - Verifica si un puerto TCP esta ABIERTO o CERRADO.
#
# Uso:
#   ./check_port.sh <PUERTO> [HOST] [-t SEGUNDOS]
#   ./check_port.sh -p <PUERTO> -H <HOST> -t <SEGUNDOS>
#
# Variables de entorno:
#   TARGET_HOST         Host destino (por defecto 127.0.0.1)
#   PORT_CHECK_TIMEOUT  Timeout de conexion en segundos (por defecto 3)
#
# Codigos de salida:
#   0 = puerto ABIERTO
#   1 = puerto CERRADO / filtrado (sin respuesta)
#   2 = error de uso o de argumentos

set -uo pipefail

SCRIPT_NAME="${0##*/}"
MIN_PORT=1
MAX_PORT=65535

HOST="${TARGET_HOST:-127.0.0.1}"
PORT=""
TIMEOUT_SECONDS="${PORT_CHECK_TIMEOUT:-3}"

# --- Salida -----------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
else
    C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""
fi

log()  { printf '%s\n' "$*"; }
info() { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
    cat <<EOF
${C_BOLD}Uso:${C_RESET}
  ${SCRIPT_NAME} <PUERTO> [HOST] [-t SEGUNDOS]
  ${SCRIPT_NAME} -p <PUERTO> [-H <HOST>] [-t <SEGUNDOS>] [-q]

${C_BOLD}Opciones:${C_RESET}
  -p, --port      Puerto TCP a verificar (${MIN_PORT}-${MAX_PORT}). Obligatorio.
  -H, --host      Host o direccion IP destino. Def.: TARGET_HOST o ${HOST}
  -t, --timeout   Segundos de espera de la conexion. Def.: ${TIMEOUT_SECONDS}
  -q, --quiet     Solo imprime el estado final (ABIERTO / CERRADO).
  -h, --help      Muestra esta ayuda.

${C_BOLD}Ejemplos:${C_RESET}
  ${SCRIPT_NAME} 80
  ${SCRIPT_NAME} 5432 127.0.0.1
  ${SCRIPT_NAME} -p 443 -H google.com -t 5
  TARGET_HOST=host.docker.internal ${SCRIPT_NAME} 3306

${C_BOLD}Codigos de salida:${C_RESET}
  0  Puerto ABIERTO
  1  Puerto CERRADO o filtrado
  2  Uso incorrecto
EOF
}

die_usage() {
    err "$1"
    log ""
    usage
    exit 2
}

# --- Validacion de argumentos ----------------------------------------------
valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge "$MIN_PORT" ] && [ "$1" -le "$MAX_PORT" ]
}

valid_timeout() {
    case "$1" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    [ "$1" -gt 0 ] 2>/dev/null
}

POSITIONAL=()
QUIET=0
HOST_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--port)    [ $# -ge 2 ] || die_usage "Falta el valor de $1";    PORT="$2";       shift 2 ;;
        -H|--host)   [ $# -ge 2 ] || die_usage "Falta el valor de $1";    HOST="$2"; HOST_SET=1; shift 2 ;;
        -t|--timeout)[ $# -ge 2 ] || die_usage "Falta el valor de $1"; TIMEOUT_SECONDS="$2"; shift 2 ;;
        -q|--quiet)  QUIET=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          die_usage "Opcion desconocida: $1" ;;
        *)           POSITIONAL+=("$1"); shift ;;
    esac
done

# Host y puerto tambien pueden ir como posicionales: ./check_port.sh PUERTO HOST
# Las opciones explicitas (-p / -H) tienen prioridad sobre los posicionales.
if [ "${#POSITIONAL[@]}" -ge 1 ] && [ -z "$PORT" ]; then
    PORT="${POSITIONAL[0]}"
fi
if [ "${#POSITIONAL[@]}" -ge 2 ] && [ "$HOST_SET" -eq 0 ]; then
    HOST="${POSITIONAL[1]}"
fi

[ -n "$PORT" ] || die_usage "El puerto es obligatorio."
valid_port "$PORT" || die_usage "Puerto invalido: '$PORT' (debe ser numerico entre ${MIN_PORT} y ${MAX_PORT})."
valid_timeout "$TIMEOUT_SECONDS" || die_usage "Timeout invalido: '$TIMEOUT_SECONDS' (debe ser un numero mayor que 0)."
[ -n "$HOST" ] || die_usage "El host no puede estar vacio."

# --- Comprobacion del puerto ------------------------------------------------
# Bash expone /dev/tcp: si la conexion TCP se establece, el puerto esta
# abierto. timeout acota la espera para no bloquearse con paquetes descartados.
probe_port() {
    timeout "$TIMEOUT_SECONDS" bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null
}

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

if [ "$QUIET" -eq 1 ]; then
    if probe_port; then printf 'ABIERTO\n'; exit 0; else printf 'CERRADO\n'; exit 1; fi
fi

log "${C_BOLD}=== Verificacion de puerto ===${C_RESET}"
info "Fecha/hora : ${TIMESTAMP}"
info "Host       : ${HOST}"
info "Puerto     : ${PORT}"
info "Timeout    : ${TIMEOUT_SECONDS}s"
info "Metodo     : conexion TCP (bash /dev/tcp)"
log ""

START_NS=$(date +%s%N)

if probe_port; then
    END_NS=$(date +%s%N)
    ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
    log "${C_GREEN}${C_BOLD}[ ABIERTO ]${C_RESET} El puerto ${C_BOLD}${PORT}${C_RESET} en ${C_BOLD}${HOST}${C_RESET} acepta conexiones TCP (${ELAPSED_MS} ms)."
    exit 0
else
    END_NS=$(date +%s%N)
    ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
    log "${C_RED}${C_BOLD}[ CERRADO ]${C_RESET} El puerto ${C_BOLD}${PORT}${C_RESET} en ${C_BOLD}${HOST}${C_RESET} no acepta conexiones: no responde o esta filtrado (${ELAPSED_MS} ms)."
    exit 1
fi
