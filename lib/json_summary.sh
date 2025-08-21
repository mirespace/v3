#!/bin/bash
# lib/json_summary.sh - Versión corregida con validación JSON robusta
num_or_zero() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Función segura para validar JSON
safe_json() {
  local input="$1"
  if [ -z "$input" ] || [ "$input" = "null" ]; then
    echo "{}"
    return 0
  fi
  
  # Verificar si es JSON válido
  if echo "$input" | jq empty 2>/dev/null; then
    echo "$input"
  else
    echo "{}"
  fi
}

# Función segura para validar arrays JSON
safe_json_array() {
  local input="$1"
  if [ -z "$input" ] || [ "$input" = "null" ]; then
    echo "[]"
    return 0
  fi
  
  # Verificar si es JSON válido
  if echo "$input" | jq empty 2>/dev/null; then
    echo "$input"
  else
    echo "[]"
  fi
}

collect_metrics_from_stdout() {
  local file="$1"
  [ -f "$file" ] || { echo "{}"; return 0; }
  
  # Extraer métricas de manera más robusta
  local metrics_raw
  metrics_raw=$(awk -F'METRIC:' '/^METRIC:/{print $2}' "$file" | \
    awk -F'=' '{
      key=$1; sub(/^[ \t]+/,"",key); sub(/[ \t]+$/,"",key);
      $1=""; val=substr($0,2);
      gsub(/^[ \t]+|[ \t]+$/, "", val);
      printf("(\"%s\")=(\"%s\")\n", key, val);
    }')
  
  if [ -z "$metrics_raw" ]; then
    echo "{}"
    return 0
  fi
  
  # Construir JSON de manera segura
  local json_result="{}"
  while IFS= read -r line; do
    if [[ "$line" =~ ^\(\"([^\"]*)\"\)=\(\"([^\"]*)\"\)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      # Escapar caracteres especiales JSON
      key=$(printf '%s' "$key" | sed 's/\\/\\\\/g; s/"/\\"/g')
      val=$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')
      json_result=$(jq -cn --arg k "$key" --arg v "$val" --argjson base "$json_result" '$base + {($k): $v}')
    fi
  done <<< "$metrics_raw"
  
  echo "$json_result"
}

parse_result_line() {
  local line="$1"
  
  # Extraer campos de manera segura
  local status vm test series type size offer sku detail
  status=$(echo "$line" | cut -d'|' -f1)
  vm=$(echo "$line" | grep -oE 'vm=[^|]*' | cut -d'=' -f2- || echo "")
  test=$(echo "$line" | grep -oE 'test=[^|]*' | cut -d'=' -f2- || echo "")
  series=$(echo "$line" | grep -oE 'series=[^|]*' | cut -d'=' -f2- || echo "")
  type=$(echo "$line" | grep -oE 'type=[^|]*' | cut -d'=' -f2- || echo "")
  size=$(echo "$line" | grep -oE 'size=[^|]*' | cut -d'=' -f2- || echo "")
  offer=$(echo "$line" | grep -oE 'offer=[^|]*' | cut -d'=' -f2- || echo "")
  sku=$(echo "$line" | grep -oE 'sku=[^|]*' | cut -d'=' -f2- || echo "")
  detail=$(echo "$line" | grep -oE 'detail=[^|]*' | cut -d'=' -f2- || echo "")
  
  # Construir JSON de manera segura
  jq -n \
    --arg status "$status" \
    --arg vm "$vm" \
    --arg test "$test" \
    --arg series "$series" \
    --arg type "$type" \
    --arg size "$size" \
    --arg offer "$offer" \
    --arg sku "$sku" \
    --arg detail "$detail" \
    --arg timestamp "$(now_utc)" \
    '{
      status: $status,
      vm: $vm,
      test: $test,
      series: $series,
      type: $type,
      size: $size,
      offer: $offer,
      sku: $sku,
      detail: $detail,
      failed_policies: [],
      failure_category: "unknown",
      timestamp: $timestamp
    }'
}

parse_skip_line() {
  local line="$1"
  
  # Extraer campos de manera segura
  local code vm series type size offer sku message
  code=$(echo "$line" | cut -d'|' -f1)
  vm=$(echo "$line" | grep -oE 'vm=[^|]*' | cut -d'=' -f2- || echo "")
  series=$(echo "$line" | grep -oE 'series=[^|]*' | cut -d'=' -f2- || echo "")
  type=$(echo "$line" | grep -oE 'type=[^|]*' | cut -d'=' -f2- || echo "")
  size=$(echo "$line" | grep -oE 'size=[^|]*' | cut -d'=' -f2- || echo "")
  offer=$(echo "$line" | grep -oE 'offer=[^|]*' | cut -d'=' -f2- || echo "")
  sku=$(echo "$line" | grep -oE 'sku=[^|]*' | cut -d'=' -f2- || echo "")
  
  # El mensaje es todo lo que queda después de quitar los campos conocidos
  message=$(echo "$line" | sed 's/^[^|]*|//g' | sed 's/[a-z]*=[^|]*|//g' | sed 's/[a-z]*=[^|]*$//g')
  
  # Clasificar skip category
  local skip_category="other"
  case "$code" in
    PRE:*) skip_category="pre_validation" ;;
    RUN:CREATE*) skip_category="vm_creation" ;;
    RUN:IP|RUN:SSH*) skip_category="connectivity" ;;
    RUN:REBOOT*) skip_category="reboot" ;;
    RUN:ABORT*) skip_category="aborted" ;;
  esac
  
  local is_critical="false"
  case "$code" in
    RUN:CREATE|RUN:CREATE_POWER|RUN:IP|RUN:SSH|RUN:SSH_LOST|RUN:REBOOT_SSH) is_critical="true" ;;
  esac
  
  jq -n \
    --arg code "$code" \
    --arg vm "$vm" \
    --arg series "$series" \
    --arg type "$type" \
    --arg size "$size" \
    --arg offer "$offer" \
    --arg sku "$sku" \
    --arg message "$message" \
    --arg skip_category "$skip_category" \
    --argjson is_critical "$is_critical" \
    --arg timestamp "$(now_utc)" \
    '{
      code: $code,
      vm: $vm,
      series: $series,
      type: $type,
      size: $size,
      offer: $offer,
      sku: $sku,
      message: $message,
      skip_category: $skip_category,
      is_critical: $is_critical,
      timestamp: $timestamp
    }'
}

write_summary_json() {
  local out="$1" results_log="$2" skip_log="$3" rg="$4" location="$5" series_filter="$6" max_parallel="$7"

  local totals_good totals_bad totals_skip
  totals_good=$(grep -c '^GOOD|' "$results_log" 2>/dev/null || echo 0)
  totals_bad=$(grep -c '^BAD|'  "$results_log" 2>/dev/null || echo 0)
  totals_skip=$(wc -l < "$skip_log" 2>/dev/null | tr -d ' ' || echo 0)

  # Crear objeto base
  jq -n \
    --arg ts "$(now_utc)" \
    --arg rg "$rg" \
    --arg loc "$location" \
    --arg sf "$series_filter" \
    --argjson mp "$(num_or_zero "$max_parallel")" \
    --argjson good "$(num_or_zero "$totals_good")" \
    --argjson bad  "$(num_or_zero "$totals_bad")" \
    --argjson skip "$(num_or_zero "$totals_skip")" \
    --arg runner_host "$(hostname 2>/dev/null || echo unknown)" \
    --arg runner_user "$(whoami 2>/dev/null || echo unknown)" \
    --arg azure_subscription "$(az account show --query id -o tsv 2>/dev/null || echo unknown)" \
    '{
      _comments: "Test summary generated by improved json_summary.sh",
      _version: "2.0",
      run: { 
        timestamp: $ts, 
        resource_group: $rg, 
        location: $loc, 
        series_filter: $sf, 
        max_parallel: $mp,
        runner_host: $runner_host,
        runner_user: $runner_user,
        azure_subscription: $azure_subscription
      },
      totals: { 
        GOOD: $good, 
        BAD: $bad, 
        SKIP: $skip,
        total: ($good + $bad + $skip),
        success_rate: (if ($good + $bad) > 0 then ($good / ($good + $bad) * 100 | floor) else 0 end)
      },
      results: [], 
      skips: [], 
      metrics: [], 
      vm_rollup: {},
      summary_stats: {
        by_status: {},
        by_series: {},  
        by_type: {},
        by_failure_category: {},
        by_skip_category: {},
        critical_skips: 0,
        policy_failures: 0,
        most_common_failures: []
      },
      performance_stats: {
        total_vms: 0,
        avg_metrics_per_vm: 0,
        test_distribution: {},
        completion_rate: 0
      }
    }' > "$out"

  # Procesar results si existe el archivo
  if [ -f "$results_log" ] && [ -s "$results_log" ]; then
    local tmp_res
    tmp_res="$(mktemp)"
    echo "[]" > "$tmp_res"
    
    # Procesar línea por línea de manera segura
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local result_json
      result_json=$(parse_result_line "$line" 2>/dev/null || echo '{}')
      if [ "$result_json" != "{}" ]; then
        jq --argjson new "$result_json" '. + [$new]' "$tmp_res" > "$tmp_res.new" && mv "$tmp_res.new" "$tmp_res"
      fi
    done < "$results_log"
    
    # Integrar results
    local results_array
    results_array=$(safe_json_array "$(cat "$tmp_res")")
    jq --argjson arr "$results_array" '.results = $arr' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    rm -f "$tmp_res" "$tmp_res.new"
  fi

  # Procesar skips si existe el archivo
  if [ -f "$skip_log" ] && [ -s "$skip_log" ]; then
    local tmp_sk
    tmp_sk="$(mktemp)"
    echo "[]" > "$tmp_sk"
    
    # Procesar línea por línea de manera segura
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local skip_json
      skip_json=$(parse_skip_line "$line" 2>/dev/null || echo '{}')
      if [ "$skip_json" != "{}" ]; then
        jq --argjson new "$skip_json" '. + [$new]' "$tmp_sk" > "$tmp_sk.new" && mv "$tmp_sk.new" "$tmp_sk"
      fi
    done < "$skip_log"
    
    # Integrar skips
    local skips_array
    skips_array=$(safe_json_array "$(cat "$tmp_sk")")
    jq --argjson arr "$skips_array" '.skips = $arr' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    rm -f "$tmp_sk" "$tmp_sk.new"
  fi

  # Procesar métricas si existen artefactos
  if [ -d "artifacts" ]; then
    local metrics_array="[]"
    local vm_rollup="{}"
    
    # Buscar VMs de manera segura
    while IFS= read -r -d '' vm_dir; do
      local vm_name
      vm_name=$(basename "$vm_dir")
      [ -z "$vm_name" ] && continue
      
      local merged='{}'
      # Buscar tests de manera segura
      while IFS= read -r -d '' test_dir; do
        local test_name
        test_name=$(basename "$test_dir")
        [ -z "$test_name" ] && continue
        
        local stdout_file="$test_dir/stdout.log"
        if [ -f "$stdout_file" ]; then
          local test_metrics
          test_metrics=$(collect_metrics_from_stdout "$stdout_file" 2>/dev/null || echo '{}')
          test_metrics=$(safe_json "$test_metrics")
          
          # Agregar metadata del test
          local m_with_meta
          m_with_meta=$(jq -cn \
            --argjson m "$test_metrics" \
            --arg test "$test_name" \
            --arg vm "$vm_name" \
            '$m + {_test_name: $test, _vm_name: $vm, _timestamp: now | strftime("%Y-%m-%dT%H:%M:%SZ")}')
          
          # Agregar a metrics_array
          metrics_array=$(jq -cn \
            --arg vm "$vm_name" \
            --arg t "$test_name" \
            --argjson m "$m_with_meta" \
            --argjson arr "$metrics_array" \
            '$arr + [{vm:$vm, test:$t, metrics:$m}]')
          
          # Merge con métricas de la VM
          merged=$(jq -cn --argjson A "$merged" --argjson B "$test_metrics" '$A + $B')
        fi
      done < <(find "$vm_dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
      
      # Agregar métricas derivadas por VM
      local vm_metrics_count
      vm_metrics_count=$(echo "$merged" | jq 'keys | length' 2>/dev/null || echo 0)
      merged=$(jq -cn \
        --argjson M "$merged" \
        --argjson count "$vm_metrics_count" \
        '$M + {_metrics_count: $count, _vm_completion_time: now | strftime("%Y-%m-%dT%H:%M:%SZ")}')
      
      vm_rollup=$(jq -cn \
        --arg vm "$vm_name" \
        --argjson R "$vm_rollup" \
        --argjson M "$merged" \
        '$R + {($vm): $M}')
        
    done < <(find artifacts -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
    
    # Integrar métricas y vm_rollup
    metrics_array=$(safe_json_array "$metrics_array")
    vm_rollup=$(safe_json "$vm_rollup")
    
    jq --argjson arr "$metrics_array" '.metrics = $arr' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    jq --argjson vr "$vm_rollup" '.vm_rollup = $vr' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
  fi
  
  # Actualizar estadísticas de rendimiento
  jq '
    .performance_stats = {
      total_vms: (.vm_rollup | keys | length),
      avg_metrics_per_vm: (
        if (.vm_rollup | keys | length) > 0 then
          (.vm_rollup | [.[] | ._metrics_count // 0] | add / length)
        else 0 end
      ),
      test_distribution: (.results | group_by(.test) | map({test: .[0].test, count: length}) | from_entries),
      completion_rate: (
        if .totals.total > 0 then
          ((.totals.GOOD + .totals.BAD) / .totals.total * 100 | floor)
        else 0 end
      )
    }
  ' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
  
  # Actualizar critical_skips
  if [ -f "$out" ]; then
    jq '.summary_stats.critical_skips = (.skips | map(select(.is_critical // false)) | length)' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
  fi
  
  # Validar el JSON final
  if ! jq empty "$out" 2>/dev/null; then
    warn "Generated JSON is invalid. Creating minimal fallback."
    jq -n \
      --arg ts "$(now_utc)" \
      --arg error "JSON generation failed" \
      '{
        _comments: "Fallback summary due to JSON generation error",
        run: {timestamp: $ts},
        error: $error,
        totals: {GOOD: 0, BAD: 0, SKIP: 0}
      }' > "$out"
  fi
}