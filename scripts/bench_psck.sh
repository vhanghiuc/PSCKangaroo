#!/bin/bash
# =============================================================================
# bench_psck.sh — Automated PSCKangaroo benchmark
#
# Tests combinations of V45_OCCUPANCY × V45_PNT_GROUP_CNT to find the
# configuration that maximizes GKey/s on the current hardware.
#
# Usage:
#   ./bench_psck.sh                        # default sweep
#   OCC_LIST="1 2" PNT_LIST="12 16 24 32" ./bench_psck.sh
#   RUN_SECONDS=120 ./bench_psck.sh        # longer measurement window
#
# Output:
#   bench_results/<timestamp>/
#     ├── results.csv                # parsed results
#     ├── compile_<occ>_<pnt>.log    # compile output (regs, spills)
#     ├── run_<occ>_<pnt>.log        # full PSCKangaroo output
#     └── summary.txt                # final ranked table
# =============================================================================

set -u  # error on undefined vars

# Forçar locale C para que printf use PONTO como decimal em vez de vírgula.
# Sem isso, em sistemas pt_BR/de_DE/etc o output do PSCKangaroo e do awk
# usa "2,70" em vez de "2.70" e o parser do CSV se confunde.
export LC_ALL=C
export LANG=C

# ----------------------------------------------------------------------------
# CONFIG (override via env vars)
# ----------------------------------------------------------------------------
PSCK_DIR="${PSCK_DIR:-$HOME/Desafios/rck/PSCKangaroo}"
OCC_LIST="${OCC_LIST:-1 2}"
PNT_LIST="${PNT_LIST:-12 16 24 32 48}"
RUN_SECONDS="${RUN_SECONDS:-90}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"   # discard speed samples before this point

# Comando para benchmark — ramlimit MÍNIMO porque só medimos velocidade do KernelA,
# não precisamos de tabela TAME grande (e ramlimit alto sem -loadwild causa OOM)
RUN_CMD=(
    ./psckangaroo
    -gpu 0
    -dp 16
    -range 134
    -pubkey 02145d2611c823a396ef6712ce0f712f09b9b4f3135e3e0aa3230fb9b6d08d1e16
    -start 4000000000000000000000000000000000
    -ramlimit 8              # mínimo viável; benchmark não precisa de tabela cheia
    -concurrent 1
    -wwbuffer 1              # também mínimo
    -checkpoint 999          # praticamente desabilita checkpoint durante o teste
)

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="$HOME/bench_results/$TIMESTAMP"
mkdir -p "$OUTDIR"
RESULTS_CSV="$OUTDIR/results.csv"
SUMMARY_TXT="$OUTDIR/summary.txt"

cd "$PSCK_DIR" || { echo "ERROR: cd $PSCK_DIR failed"; exit 1; }
[ -f Makefile ] || { echo "ERROR: Makefile not found in $PSCK_DIR"; exit 1; }

# Header CSV
echo "occupancy,pnt_group_cnt,registers,spill_bytes,compile_ok,gkey_s,samples,run_ok" > "$RESULTS_CSV"

# ----------------------------------------------------------------------------
# Header de tela
# ----------------------------------------------------------------------------
TOTAL_TESTS=$(($(echo "$OCC_LIST" | wc -w) * $(echo "$PNT_LIST" | wc -w)))
TEST_NUM=0
START_TS=$(date +%s)

cat <<EOF
================================================================================
PSCKangaroo Benchmark Sweep
================================================================================
Diretório:       $PSCK_DIR
Output:          $OUTDIR
OCC_LIST:        $OCC_LIST
PNT_LIST:        $PNT_LIST
Duração/teste:   ${RUN_SECONDS}s (descartando primeiros ${WARMUP_SECONDS}s)
Total testes:    $TOTAL_TESTS
Tempo estimado:  ~$((TOTAL_TESTS * (RUN_SECONDS + 30) / 60)) minutos
================================================================================

EOF

# ----------------------------------------------------------------------------
# Funções auxiliares
# ----------------------------------------------------------------------------
parse_compile() {
    # Extrai registros/spills do log do ptxas (primeira KernelA)
    local log="$1"
    local regs spill
    regs=$(grep -m1 "Used .* registers" "$log" | grep -oE "[0-9]+ registers" | grep -oE "[0-9]+" || echo "?")
    spill=$(grep -m1 "spill stores" "$log" | grep -oE "[0-9]+ bytes spill stores" | grep -oE "^[0-9]+" || echo "0")
    echo "$regs|$spill"
}

parse_speed() {
    # Extrai todas as velocidades do log e calcula média descartando warmup
    local log="$1"
    local warmup_min="$2"
    
    # Captura linhas tipo "CONC: Speed: 2.70 GKeys/s | Time: 0d 00h 01m"
    # Converte tempo (XdYhZm) em minutos totais; mantém apenas amostras com tempo >= warmup_min
    
    awk -v warmup="$warmup_min" '
        /Speed:[[:space:]]+[0-9.]+[[:space:]]+GKeys/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "Speed:") speed = $(i+1)
                if ($i == "Time:") {
                    d = h = m = 0
                    if (match($(i+1), /[0-9]+d/)) d = substr($(i+1), RSTART, RLENGTH-1)
                    if (match($(i+2), /[0-9]+h/)) h = substr($(i+2), RSTART, RLENGTH-1)
                    if (match($(i+3), /[0-9]+m/)) m = substr($(i+3), RSTART, RLENGTH-1)
                    total_min = d*1440 + h*60 + m
                    if (total_min >= warmup/60 && speed+0 > 0) {
                        sum += speed; n++
                    }
                }
            }
        }
        END {
            if (n > 0) printf "%.3f|%d\n", sum/n, n
            else print "0.000|0"
        }
    ' "$log"
}

# ----------------------------------------------------------------------------
# Loop principal
# ----------------------------------------------------------------------------
for occ in $OCC_LIST; do
    for pnt in $PNT_LIST; do
        TEST_NUM=$((TEST_NUM + 1))
        TAG="occ${occ}_pnt${pnt}"
        COMPILE_LOG="$OUTDIR/compile_${TAG}.log"
        RUN_LOG="$OUTDIR/run_${TAG}.log"
        
        echo "[Teste $TEST_NUM/$TOTAL_TESTS] OCC=$occ PNT=$pnt"
        
        # ---- compile ----
        echo "    Compilando..."
        make clean > /dev/null 2>&1
        if make V45_OCCUPANCY=$occ V45_PNT_GROUP_CNT=$pnt -j$(nproc) > "$COMPILE_LOG" 2>&1; then
            COMPILE_OK=1
        else
            COMPILE_OK=0
            echo "    ❌ Falha de compilação"
            echo "$occ,$pnt,?,?,0,0.000,0,0" >> "$RESULTS_CSV"
            continue
        fi
        
        # Parse registers/spills
        IFS='|' read REGS SPILL <<< "$(parse_compile "$COMPILE_LOG")"
        echo "    Compile OK: ${REGS} regs, ${SPILL}B spill"
        
        # ---- run ----
        echo "    Rodando ${RUN_SECONDS}s..."
        timeout --kill-after=10 ${RUN_SECONDS}s "${RUN_CMD[@]}" > "$RUN_LOG" 2>&1
        RUN_RC=$?
        # rc=124: timeout (esperado), rc=137: SIGKILL after timeout, qualquer outra: erro
        if [ $RUN_RC -eq 124 ] || [ $RUN_RC -eq 137 ] || [ $RUN_RC -eq 0 ]; then
            RUN_OK=1
        else
            RUN_OK=0
            echo "    ⚠️  Saída anormal (rc=$RUN_RC), pode haver dados parciais"
        fi
        
        # Parse speed
        IFS='|' read GKEY_S SAMPLES <<< "$(parse_speed "$RUN_LOG" "$WARMUP_SECONDS")"
        
        if [ "$SAMPLES" -gt 0 ]; then
            echo "    ✓ ${GKEY_S} GKeys/s (${SAMPLES} amostras estáveis)"
        else
            echo "    ⚠️  Sem amostras estáveis (rodou pouco?)"
        fi
        
        echo "$occ,$pnt,$REGS,$SPILL,$COMPILE_OK,$GKEY_S,$SAMPLES,$RUN_OK" >> "$RESULTS_CSV"
        echo ""
    done
done

# ----------------------------------------------------------------------------
# Restaurar build padrão
# ----------------------------------------------------------------------------
echo "Restaurando build com configuração padrão (OCC=1, PNT=24)..."
make clean > /dev/null 2>&1
make V45_OCCUPANCY=1 V45_PNT_GROUP_CNT=24 -j$(nproc) > "$OUTDIR/restore.log" 2>&1
if [ $? -eq 0 ]; then
    echo "    ✓ Build padrão restaurado"
else
    echo "    ⚠️  Falha ao restaurar build padrão (veja $OUTDIR/restore.log)"
fi
echo ""

# ----------------------------------------------------------------------------
# Tabela final ranqueada
# ----------------------------------------------------------------------------
ELAPSED=$(($(date +%s) - START_TS))

{
    echo "================================================================================"
    echo "RESULTADOS — ranqueados por GKeys/s"
    echo "================================================================================"
    echo ""
    printf "%-4s %-5s %-7s %-7s %-8s %-9s %-7s\n" "OCC" "PNT" "REGS" "SPILL" "GKEY/S" "SAMPLES" "STATUS"
    echo "--------------------------------------------------------------------------------"
    
    # Skip header, sort by GKey/s desc, format as table
    tail -n +2 "$RESULTS_CSV" | sort -t',' -k6,6 -gr | while IFS=',' read occ pnt regs spill cok gks samp rok; do
        if [ "$cok" = "0" ]; then
            status="COMPILE FAIL"
        elif [ "$samp" = "0" ]; then
            status="NO SAMPLES"
        elif [ "$rok" = "0" ]; then
            status="PARTIAL"
        else
            status="OK"
        fi
        printf "%-4s %-5s %-7s %-7s %-8s %-9s %-7s\n" \
            "$occ" "$pnt" "$regs" "$spill" "$gks" "$samp" "$status"
    done
    
    echo ""
    echo "--------------------------------------------------------------------------------"
    
    # Vencedor
    BEST_LINE=$(tail -n +2 "$RESULTS_CSV" | awk -F',' '$5==1 && $7>0' | sort -t',' -k6,6 -gr | head -1)
    if [ -n "$BEST_LINE" ]; then
        IFS=',' read occ pnt regs spill cok gks samp rok <<< "$BEST_LINE"
        echo "🏆 MELHOR CONFIGURAÇÃO:  OCC=$occ  PNT=$pnt  →  $gks GKeys/s"
        echo "   Compile flags:  make V45_OCCUPANCY=$occ V45_PNT_GROUP_CNT=$pnt"
    fi
    
    # Comparação com baseline (OCC=1, PNT=24)
    BASELINE=$(tail -n +2 "$RESULTS_CSV" | awk -F',' '$1==1 && $2==24 && $5==1 && $7>0 {print $6}' | head -1)
    if [ -n "$BEST_LINE" ] && [ -n "$BASELINE" ]; then
        IFS=',' read _ _ _ _ _ best_gks _ _ <<< "$BEST_LINE"
        IMPROVEMENT=$(awk "BEGIN { printf \"%.1f\", ($best_gks/$BASELINE - 1) * 100 }")
        echo "   Baseline (OCC=1, PNT=24): $BASELINE GKeys/s"
        echo "   Ganho vs baseline:        ${IMPROVEMENT}%"
    fi
    
    echo ""
    echo "Tempo total: $((ELAPSED/60))m $((ELAPSED%60))s"
    echo "Logs em:     $OUTDIR"
    echo "================================================================================"
} | tee "$SUMMARY_TXT"

echo ""
echo "Para retomar a busca normal:"
echo "  cd $PSCK_DIR"
echo "  ./psckangaroo [seus parâmetros normais com -loadwild wild_checkpoint.dat]"
