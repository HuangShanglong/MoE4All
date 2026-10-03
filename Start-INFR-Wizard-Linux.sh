#!/usr/bin/env bash
#
# Start-INFR-Wizard-Linux.sh — interactive launcher for `infr` on Linux.
#
# The Windows package ships a PowerShell wizard; this covers the same common
# workflow on Linux, and nothing more (no self-update, no rarely-used advanced
# options). The command is assembled in a Bash array and executed directly —
# there is no `eval` anywhere in this script.
#
#   ./Start-INFR-Wizard-Linux.sh                 # interactive
#   ./Start-INFR-Wizard-Linux.sh --dry-run       # print the command, do not launch
#
# Every option can also be given on the command line, in which case it is not
# asked for. With `--dry-run` the script never needs a TTY, so it is testable:
#
#   ./Start-INFR-Wizard-Linux.sh --dry-run --mode serve --model m.gguf \
#       --profile aggressive --addr 127.0.0.1:8080 --parallel 1
#
set -euo pipefail

PROG="${0##*/}"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/infr"
STATE_FILE="$STATE_DIR/wizard.conf"

# --------------------------------------------------------------- selection ---
MODE=""          # run | serve | bench
MODEL=""
PROFILE=""       # aggressive | conservative | manual
CTX=""
UBATCH=""
KV_K=""
KV_V=""
RAM=""
VRAM=""
MTP=""           # empty = off; otherwise the path to the MTP head
MTP_K="4"
ADDR=""
PARALLEL=""
MMPROJ=""
EMBEDDING=""
BENCH_P="512"
BENCH_N="128"
BENCH_D="0"

DRY_RUN=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
Start-INFR-Wizard-Linux.sh — interactive launcher for infr on Linux

Usage:
  ./Start-INFR-Wizard-Linux.sh [options]

Any option that is not given is asked for interactively. `--dry-run` prints the
final command and exits without launching, and works without a TTY.

Options:
  --dry-run                print the final command, do not launch
  --yes                    do not ask for confirmation before launching
  --mode <run|serve|bench> what to start
  --model <path>           main model (.gguf path, or org/repo[:quant])
  --profile <name>         aggressive | conservative | manual
  --ctx <tokens>           context window (e.g. 32768, 256k)
  --ubatch <n>             prefill micro-batch (alias: -u)
  --kv-k <dtype>           KV format for K (e.g. q8_0, q4_0, f16)
  --kv-v <dtype>           KV format for V
  --ram <size>             device.ram_budget (e.g. 16GiB)
  --vram <size>            device.vram_budget (e.g. 23GiB)
  --mtp <path>             enable MTP with this MTP head (default: off)
  --mtp-k <n>              MTP verification width (default: 4)
  --addr <host:port>       serve: listen address
  --parallel <n>           serve: parallel slots
  --mmproj <path>          serve: vision projector
  --embedding <path>       serve: embedding model
  --bench-p <n>            bench: prompt tokens (default: 512)
  --bench-n <n>            bench: generated tokens (default: 128)
  --bench-d <n>            bench: context depth (default: 0)
  -h, --help               this help
EOF
    exit 0
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

# ----------------------------------------------------------- CLI arguments ---
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)          DRY_RUN=1 ;;
        --yes|-y)           ASSUME_YES=1 ;;
        --mode)             MODE="${2-}"; shift ;;
        --model)            MODEL="${2-}"; shift ;;
        --profile)          PROFILE="${2-}"; shift ;;
        --ctx)              CTX="${2-}"; shift ;;
        --ubatch|-u)        UBATCH="${2-}"; shift ;;
        --kv-k)             KV_K="${2-}"; shift ;;
        --kv-v)             KV_V="${2-}"; shift ;;
        --ram)              RAM="${2-}"; shift ;;
        --vram)             VRAM="${2-}"; shift ;;
        --mtp)              MTP="${2-}"; shift ;;
        --no-mtp)           MTP="" ;;
        --mtp-k)            MTP_K="${2-}"; shift ;;
        --addr)             ADDR="${2-}"; shift ;;
        --parallel)         PARALLEL="${2-}"; shift ;;
        --mmproj)           MMPROJ="${2-}"; shift ;;
        --embedding)        EMBEDDING="${2-}"; shift ;;
        --bench-p)          BENCH_P="${2-}"; shift ;;
        --bench-n)          BENCH_N="${2-}"; shift ;;
        --bench-d)          BENCH_D="${2-}"; shift ;;
        -h|--help)          usage ;;
        *)                  die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ------------------------------------------------------------ saved values ---
# Reuse the previous selections for anything the caller did not specify.
if [ -f "$STATE_FILE" ]; then
    while IFS= read -r line; do
        case "$line" in
            *=*) : ;;
            *)   continue ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            MODE)      [ -z "$MODE" ]      && MODE=$value ;;
            MODEL)     [ -z "$MODEL" ]     && MODEL=$value ;;
            PROFILE)   [ -z "$PROFILE" ]   && PROFILE=$value ;;
            CTX)       [ -z "$CTX" ]       && CTX=$value ;;
            UBATCH)    [ -z "$UBATCH" ]    && UBATCH=$value ;;
            KV_K)      [ -z "$KV_K" ]      && KV_K=$value ;;
            KV_V)      [ -z "$KV_V" ]      && KV_V=$value ;;
            RAM)       [ -z "$RAM" ]       && RAM=$value ;;
            VRAM)      [ -z "$VRAM" ]      && VRAM=$value ;;
            ADDR)      [ -z "$ADDR" ]      && ADDR=$value ;;
            PARALLEL)  [ -z "$PARALLEL" ]  && PARALLEL=$value ;;
            MTP)       [ -z "$MTP" ]       && MTP=$value ;;
            MTP_K)     MTP_K=$value ;;
            MMPROJ)    [ -z "$MMPROJ" ]    && MMPROJ=$value ;;
            EMBEDDING) [ -z "$EMBEDDING" ] && EMBEDDING=$value ;;
        esac
    done < "$STATE_FILE"
fi

# ------------------------------------------------------------- locate infr ---
find_infr() {
    local candidate
    for candidate in ./target/release/infr ./infr "$(command -v infr || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}
INFR_BIN="$(find_infr || true)"
[ -n "$INFR_BIN" ] || die "infr not found. Build it first:
  cargo build --release --locked -p infr-cli"

# --------------------------------------------------------------- prompting ---
ask() { # ask <name> <prompt> <default>
    local name="$1" prompt="$2" default="${3-}" answer=""
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " answer || true
        [ -n "$answer" ] || answer="$default"
    else
        read -r -p "$prompt: " answer || true
    fi
    printf -v "$name" '%s' "$answer"
}

choose() { # choose <name> <prompt> <default-index> <option>...
    local name="$1" prompt="$2" default="$3"; shift 3
    local -a options=("$@")
    local i choice
    printf '%s\n' "$prompt"
    for i in "${!options[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"
    done
    read -r -p "Choice [$default]: " choice || true
    case "$choice" in
        ''|*[!0-9]*) choice="$default" ;;
    esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ] || choice="$default"
    printf -v "$name" '%s' "${options[$((choice - 1))]}"
}

scan_models() { # list nearby *.gguf, first shard first
    find . -maxdepth 2 -type f -name '*.gguf' 2>/dev/null | sort | head -20
}

# Prompt only when there is a terminal to answer on. With --dry-run and no TTY
# the flags (and the saved selections) fully determine the command, so it stays
# scriptable.
INTERACTIVE=0
if [ -t 0 ]; then INTERACTIVE=1; fi

if [ "$INTERACTIVE" -eq 1 ]; then
    printf '\n=== infr Linux wizard (%s) ===\n\n' "$INFR_BIN"

    if [ -z "$MODE" ]; then
        choose MODE 'Start what?' 2 'run (terminal chat)' 'serve (OpenAI-compatible API)' 'bench (benchmark)'
        MODE="${MODE%% *}"
    fi

    if [ -z "$MODEL" ]; then
        printf 'Models found nearby:\n'
        scan_models | sed 's/^/  /' || true
        ask MODEL 'Model path (.gguf, or org/repo[:quant])'
    fi
    [ -n "$MODEL" ] || die "a model is required"

    if [ -z "$PROFILE" ]; then
        choose PROFILE 'Resource profile?' 2 'aggressive' 'conservative' 'manual'
    fi

    case "$PROFILE" in
        manual)
            [ -n "$CTX" ]    || ask CTX    'Context window (e.g. 32768, 256k; blank = engine default)'
            [ -n "$UBATCH" ] || ask UBATCH 'Prefill micro-batch (blank = engine default)'
            [ -n "$KV_K" ]   || ask KV_K   'KV format for K (e.g. q8_0, q4_0, f16; blank = default)'
            [ -n "$KV_V" ]   || ask KV_V   'KV format for V (blank = default)'
            [ -n "$RAM" ]    || ask RAM    'device.ram_budget (e.g. 16GiB; blank = default)'
            [ -n "$VRAM" ]   || ask VRAM   'device.vram_budget (e.g. 23GiB; blank = default)'
            ;;
        *)
            [ -n "$KV_K" ] || KV_K="q8_0"
            [ -n "$KV_V" ] || KV_V="q8_0"
            ;;
    esac

    if [ -z "$MTP" ]; then
        local_mtp=""
        ask local_mtp 'MTP head path (blank = disabled)'
        MTP="$local_mtp"
    fi

    if [ "$MODE" = serve ]; then
        [ -n "$ADDR" ]     || ask ADDR     'Listen address' '127.0.0.1:8080'
        [ -n "$PARALLEL" ] || ask PARALLEL 'Parallel slots' '1'
        [ -z "$MMPROJ" ]   && ask MMPROJ 'Vision projector (mmproj, blank = none)'
        [ -z "$EMBEDDING" ] && ask EMBEDDING 'Embedding model (blank = none)'
    fi
fi

case "$MODE" in
    run|serve|bench) : ;;
    *) die "mode must be run, serve or bench (got '${MODE:-<empty>}')" ;;
esac

# ----------------------------------------------------------- build command ---
# Everything below only appends to an array. Nothing is ever passed through a
# shell parser, which is why `eval` is not needed.
cmd=("$INFR_BIN" "$MODE")
[ -n "$MODEL" ] && cmd+=("$MODEL")

case "$PROFILE" in
    aggressive|conservative)
        cmd+=(--set "device.auto_profile=$PROFILE")
        [ -n "$KV_K" ] && cmd+=(--set "kv.type_k=$KV_K")
        [ -n "$KV_V" ] && cmd+=(--set "kv.type_v=$KV_V")
        ;;
    manual)
        [ -n "$CTX" ]    && cmd+=(--ctx "$CTX")
        [ -n "$UBATCH" ] && cmd+=(-u "$UBATCH")
        [ -n "$RAM" ]    && cmd+=(--set "device.ram_budget=$RAM")
        [ -n "$VRAM" ]   && cmd+=(--set "device.vram_budget=$VRAM")
        [ -n "$KV_K" ]   && cmd+=(--set "kv.type_k=$KV_K")
        [ -n "$KV_V" ]   && cmd+=(--set "kv.type_v=$KV_V")
        ;;
esac

if [ -n "$MTP" ]; then
    cmd+=(--set spec.mtp=1 --set "spec.draft=$MTP" --set "spec.k=$MTP_K")
fi

if [ "$MODE" = serve ]; then
    [ -n "$ADDR" ]      && cmd+=(--addr "$ADDR")
    [ -n "$PARALLEL" ]  && cmd+=(-n "$PARALLEL")
    [ -n "$MMPROJ" ]    && cmd+=(--mmproj "$MMPROJ")
    [ -n "$EMBEDDING" ] && cmd+=(--embedding-model "$EMBEDDING")
fi

if [ "$MODE" = bench ]; then
    cmd+=(-p "$BENCH_P" -n "$BENCH_N" -d "$BENCH_D")
fi

print_cmd() {
    printf '\nCommand:\n  '
    printf '%q ' "${cmd[@]}"
    printf '\n\n'
}

print_cmd

if [ "$DRY_RUN" -eq 1 ]; then
    exit 0
fi

# ------------------------------------------------------------ remember it ----
mkdir -p "$STATE_DIR"
( umask 077; cat > "$STATE_FILE" <<EOF
MODE=$MODE
MODEL=$MODEL
PROFILE=$PROFILE
CTX=$CTX
UBATCH=$UBATCH
KV_K=$KV_K
KV_V=$KV_V
RAM=$RAM
VRAM=$VRAM
MTP=$MTP
MTP_K=$MTP_K
ADDR=$ADDR
PARALLEL=$PARALLEL
MMPROJ=$MMPROJ
EMBEDDING=$EMBEDDING
EOF
) || printf '%s: could not save selections to %s\n' "$PROG" "$STATE_FILE" >&2

if [ "$ASSUME_YES" -eq 0 ]; then
    answer=""
    read -r -p 'Launch? [Y/n]: ' answer || true
    case "$answer" in
        ''|Y|y|yes|YES) : ;;
        *) printf 'aborted.\n'; exit 0 ;;
    esac
fi

exec "${cmd[@]}"
