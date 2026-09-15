#!/usr/bin/env bash
# Grok per-model reasoning-effort evidence.
#
# Sourced by bin/fm-spawn.sh before an opt-in preset Grok launch and by the
# focused test suite. `grok models` lists only model ids and the
# `--reasoning-effort` help names no accepted values, so the installed CLI's own
# fetched model catalog is the authoritative advertised menu:
# <GROK_HOME>/models_cache.json, written by the CLI from its authenticated
# models endpoint and stamped with the grok version that fetched it.
#
#   fm_grok_effort_evidence <catalog> <installed-version-output> <model> <effort>
#
# It proves the pair only when the catalog is readable, carries a version stamp
# matching the installed CLI's own `grok --version` output as a whole token, and
# advertises <effort> in the selected model's `info.reasoning_efforts` menu. It
# prints nothing and returns 0 when the pair is proven; otherwise it prints one
# reason line and returns 1. It never writes the catalog, never contacts a
# provider, and never guesses a global low/medium/high rule from the model name.
fm_grok_effort_evidence() {  # <catalog> <installed-version> <model> <effort>
  local catalog=$1 installed=$2 model=$3 effort=$4 catalog_version advertised
  if [ ! -f "$catalog" ]; then
    printf '%s\n' "no fetched Grok model catalog at $catalog"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' 'jq is required to read the fetched Grok model catalog'
    return 1
  }
  catalog_version=$(jq -r '.grok_version // empty' "$catalog" 2>/dev/null) || {
    printf '%s\n' "the fetched Grok model catalog at $catalog is unreadable"
    return 1
  }
  if [ -z "$catalog_version" ]; then
    printf '%s\n' "the fetched Grok model catalog at $catalog carries no grok version stamp"
    return 1
  fi
  case " $installed " in
    *" $catalog_version "*) ;;
    *)
      printf '%s\n' "the fetched Grok model catalog was written by grok $catalog_version, not the running $installed"
      return 1
      ;;
  esac
  advertised=$(jq -r --arg model "$model" '
    if (.models[$model].info | type) == "object" then
      ([.models[$model].info.reasoning_efforts[]?.value] | join(","))
    else "no-catalog-entry" end
  ' "$catalog" 2>/dev/null) || {
    printf '%s\n' "the fetched Grok model catalog at $catalog is unreadable"
    return 1
  }
  if [ "$advertised" = no-catalog-entry ]; then
    printf '%s\n' "the fetched Grok model catalog has no entry for model $model"
    return 1
  fi
  case ",$advertised," in
    *",$effort,"*) return 0 ;;
  esac
  printf '%s\n' "model $model does not advertise reasoning effort '$effort' (advertised: ${advertised:-none})"
  return 1
}
