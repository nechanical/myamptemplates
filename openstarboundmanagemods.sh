#!/usr/bin/env bash
# AMP/OpenStarbound unified mod manager.
# Manages Steam Workshop items/collections and local/private mods without modifying source files.

set -o pipefail

log()  { printf '[OpenStarbound Mods] %s\n' "$*"; }
warn() { printf '[OpenStarbound Mods] WARNING: %s\n' "$*" >&2; }

INSTANCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$INSTANCE_DIR/openstarbound"
BASE_DIR="$ROOT_DIR/server"
MOD_DIR="$BASE_DIR/mods"
STORAGE_DIR="$BASE_DIR/storage"
MOD_CFG="$BASE_DIR/amp_openstarbound_mods.cfg"
AMP_STEAM_CFG="$INSTANCE_DIR/steamcmdplugin.kvp"
REPORT="$STORAGE_DIR/amp_mods_report.txt"
STEAM_APP_ID="211820"
PRESTART=false
[[ "${1:-}" == "--prestart" ]] && PRESTART=true

mkdir -p "$MOD_DIR" "$STORAGE_DIR"

kvp_value() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$file" | tail -n 1
}

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# AMP list settings normally serialize as JSON arrays. This also accepts comma/semicolon
# separated fallback syntax so the helper remains tolerant of older/custom AMP builds.
list_values() {
  local raw="$1"
  raw="$(trim "$raw")"
  [[ -n "$raw" ]] || return 0

  if [[ "$raw" == \[* ]]; then
    local quoted
    quoted="$(printf '%s' "$raw" | grep -oE '"([^"\\]|\\.)*"' 2>/dev/null || true)"
    if [[ -n "$quoted" ]]; then
      printf '%s\n' "$quoted" | sed -E 's/^"//; s/"$//; s/\\"/"/g; s/\\\\/\\/g'
      return 0
    fi
  fi

  printf '%s' "$raw" |
    tr ',;' '\n' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//' |
    awk 'NF'
}

extract_ids() {
  grep -oE '[0-9]{6,}' 2>/dev/null || true
}

bool_value() {
  local raw="${1:-}" fallback="${2:-true}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '"[:space:]')"
  case "$raw" in
    true|1|yes|on) printf 'true' ;;
    false|0|no|off) printf 'false' ;;
    *) printf '%s' "$fallback" ;;
  esac
}

unique_lines() {
  awk 'NF && !seen[$0]++'
}

contains_exact() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

sanitize_name() {
  local name="$1"
  name="$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+//; s/_+$//')"
  [[ -n "$name" ]] || name="mod"
  printf '%s' "$name"
}

safe_local_dir() {
  local raw="$1"
  raw="$(trim "$raw")"
  raw="${raw%/}"
  [[ -n "$raw" ]] || raw="localmods"
  if [[ "$raw" == /* || "$raw" == *'..'* ]]; then
    warn "Rejected unsafe Local Mods Directory '$raw'; using 'localmods'."
    raw="localmods"
  fi
  printf '%s' "$raw"
}

readarray -t native_ids < <(
  kvp_value 'SteamWorkshop\.WorkshopItemIDs' "$AMP_STEAM_CFG" | extract_ids | unique_lines
)
readarray -t collection_ids < <(
  list_values "$(kvp_value 'WorkshopCollectionIDs' "$MOD_CFG")" | extract_ids | unique_lines
)
readarray -t preference_entries < <(
  list_values "$(kvp_value 'UnifiedModPreference' "$MOD_CFG")" | unique_lines
)
# Backward compatibility with v2's key.
if (( ${#preference_entries[@]} == 0 )); then
  readarray -t preference_entries < <(
    list_values "$(kvp_value 'ModLoadOrder' "$MOD_CFG")" | unique_lines
  )
fi
readarray -t managed_local_names < <(
  list_values "$(kvp_value 'ManagedLocalMods' "$MOD_CFG")" | unique_lines
)
readarray -t disabled_local_names < <(
  list_values "$(kvp_value 'DisabledLocalMods' "$MOD_CFG")" | unique_lines
)

managed_enabled="$(bool_value "$(kvp_value 'ManagedModsEnabled' "$MOD_CFG")" true)"
download_missing="$(bool_value "$(kvp_value 'DownloadMissingWorkshopItems' "$MOD_CFG")" true)"
prune_managed="$(bool_value "$(kvp_value 'PruneManagedMods' "$MOD_CFG")" true)"
auto_enable_local="$(bool_value "$(kvp_value 'AutoEnableLocalMods' "$MOD_CFG")" true)"
local_rel="$(safe_local_dir "$(kvp_value 'LocalModsDirectory' "$MOD_CFG")")"
LOCAL_DIR="$BASE_DIR/$local_rel"

mkdir -p "$LOCAL_DIR"

if [[ "$managed_enabled" != "true" ]]; then
  log "Managed mod synchronization is disabled."
  exit 0
fi

declare -a collection_item_ids=()
declare -a collection_errors=()

resolve_collection() {
  local cid="$1"
  local cache="$STORAGE_DIR/amp_collection_${cid}.txt"
  local response="" resolved=""

  if command -v curl >/dev/null 2>&1; then
    response="$(curl -fsS --connect-timeout 10 --max-time 30 \
      -X POST \
      -d 'collectioncount=1' \
      --data-urlencode "publishedfileids[0]=$cid" \
      'https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/' 2>/dev/null || true)"

    if [[ -n "$response" ]]; then
      resolved="$(
        printf '%s' "$response" |
          grep -oE '"publishedfileid"[[:space:]]*:[[:space:]]*"[0-9]+"' |
          grep -oE '[0-9]+' |
          awk -v collection="$cid" '$0 != collection' |
          unique_lines
      )"
    fi
  else
    warn "curl is not installed; collection $cid can only use an existing cache."
  fi

  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved" > "$cache"
    printf '%s\n' "$resolved"
    return 0
  fi

  if [[ -s "$cache" ]]; then
    warn "Could not refresh collection $cid; using cached membership."
    cat "$cache"
    return 0
  fi

  collection_errors+=("$cid")
  return 1
}

for cid in "${collection_ids[@]}"; do
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] && collection_item_ids+=("$id")
  done < <(resolve_collection "$cid")
done

readarray -t workshop_ids < <(
  {
    printf '%s\n' "${native_ids[@]}"
    printf '%s\n' "${collection_item_ids[@]}"
  } | unique_lines | sort -n
)

find_item_source() {
  local id="$1"
  local candidates=(
    "$ROOT_DIR/workshop/$id"
    "$ROOT_DIR/workshop/content/$STEAM_APP_ID/$id"
    "$ROOT_DIR/steamapps/workshop/content/$STEAM_APP_ID/$id"
    "$BASE_DIR/steamapps/workshop/content/$STEAM_APP_ID/$id"
    "$ROOT_DIR/211820/steamapps/workshop/content/$STEAM_APP_ID/$id"
    "$HOME/Steam/steamapps/workshop/content/$STEAM_APP_ID/$id"
    "$HOME/.steam/steam/steamapps/workshop/content/$STEAM_APP_ID/$id"
    "$HOME/.local/share/Steam/steamapps/workshop/content/$STEAM_APP_ID/$id"
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -d "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

find_steamcmd() {
  local candidates=(
    "$ROOT_DIR/steamcmd.sh"
    "$INSTANCE_DIR/steamcmd.sh"
  )
  local p
  for p in "${candidates[@]}"; do
    [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

download_item() {
  local id="$1"
  [[ "$download_missing" == "true" ]] || return 1

  local steamcmd
  steamcmd="$(find_steamcmd || true)"
  if [[ -z "$steamcmd" ]]; then
    warn "SteamCMD wrapper was not found; cannot auto-download Workshop item $id."
    return 1
  fi

  log "Downloading missing Workshop item $id with AMP's cached Steam login..."
  if /bin/bash "$steamcmd" +login +workshop_download_item "$STEAM_APP_ID" "$id" validate +quit; then
    return 0
  fi

  warn "SteamCMD could not download Workshop item $id."
  return 1
}

# ----- Discover local/private mod sources -----

declare -a discovered_local_names=()
declare -a invalid_local_names=()
declare -A local_path_by_name=()
declare -A local_kind_by_name=()

while IFS= read -r -d '' entry; do
  name="$(basename "$entry")"
  [[ "$name" == .* || "$name" == _* ]] && continue

  if [[ -f "$entry" && "${name,,}" == *.pak ]]; then
    discovered_local_names+=("$name")
    local_path_by_name["$name"]="$entry"
    local_kind_by_name["$name"]="pak"
  elif [[ -d "$entry" && -f "$entry/_metadata" ]]; then
    discovered_local_names+=("$name")
    local_path_by_name["$name"]="$entry"
    local_kind_by_name["$name"]="directory"
  elif [[ -d "$entry" ]]; then
    mapfile -t nested_paks < <(find "$entry" -maxdepth 2 -type f -iname '*.pak' -print 2>/dev/null | sort)
    if (( ${#nested_paks[@]} > 0 )); then
      discovered_local_names+=("$name")
      local_path_by_name["$name"]="$entry"
      local_kind_by_name["$name"]="pakbundle"
    else
      invalid_local_names+=("$name")
    fi
  else
    invalid_local_names+=("$name")
  fi
done < <(find "$LOCAL_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

IFS=$'\n' discovered_local_names=($(printf '%s\n' "${discovered_local_names[@]}" | awk 'NF' | sort -f))
unset IFS

declare -a enabled_local_names=()
declare -a missing_local_names=()

if [[ "$auto_enable_local" == "true" ]]; then
  for name in "${discovered_local_names[@]}"; do
    contains_exact "$name" "${disabled_local_names[@]}" && continue
    enabled_local_names+=("$name")
  done
else
  for name in "${managed_local_names[@]}"; do
    contains_exact "$name" "${disabled_local_names[@]}" && continue
    if [[ -n "${local_path_by_name[$name]:-}" ]]; then
      enabled_local_names+=("$name")
    else
      missing_local_names+=("$name")
    fi
  done
fi

# ----- Build unified source keys -----

declare -a available_keys=()
declare -A key_kind=()
declare -A key_value=()

for id in "${workshop_ids[@]}"; do
  key="ws:$id"
  available_keys+=("$key")
  key_kind["$key"]="workshop"
  key_value["$key"]="$id"
done

for name in "${enabled_local_names[@]}"; do
  key="local:$name"
  available_keys+=("$key")
  key_kind["$key"]="local"
  key_value["$key"]="$name"
done

normalize_preference() {
  local raw="$1"
  raw="$(trim "$raw")"
  local lower="${raw,,}"
  if [[ "$lower" =~ ^ws:[[:space:]]*([0-9]+)$ ]]; then
    printf 'ws:%s' "${BASH_REMATCH[1]}"
  elif [[ "$lower" =~ ^workshop:[[:space:]]*([0-9]+)$ ]]; then
    printf 'ws:%s' "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf 'ws:%s' "$raw"
  elif [[ "$lower" == local:* ]]; then
    printf 'local:%s' "$(trim "${raw#*:}")"
  else
    printf 'local:%s' "$raw"
  fi
}

declare -a ordered_keys=()
declare -a unknown_preference=()
declare -A seen_key=()

for raw in "${preference_entries[@]}"; do
  key="$(normalize_preference "$raw")"
  if contains_exact "$key" "${available_keys[@]}"; then
    if [[ -z "${seen_key[$key]:-}" ]]; then
      ordered_keys+=("$key")
      seen_key["$key"]=1
    fi
  else
    unknown_preference+=("$raw")
  fi
done

# Append unlisted Workshop IDs first (numeric), then local mods alphabetically.
for id in "${workshop_ids[@]}"; do
  key="ws:$id"
  if [[ -z "${seen_key[$key]:-}" ]]; then
    ordered_keys+=("$key")
    seen_key["$key"]=1
  fi
done
for name in "${enabled_local_names[@]}"; do
  key="local:$name"
  if [[ -z "${seen_key[$key]:-}" ]]; then
    ordered_keys+=("$key")
    seen_key["$key"]=1
  fi
done

# ----- Clear only AMP-managed staging entries -----

if [[ "$prune_managed" == "true" ]]; then
  find "$MOD_DIR" -maxdepth 1 \( -type f -o -type l -o -type d \) -name 'amp_*' -exec rm -rf {} + 2>/dev/null || true
fi

# Track unmanaged existing files so admins can distinguish them from managed sources.
declare -a unmanaged_existing=()
while IFS= read -r -d '' entry; do
  name="$(basename "$entry")"
  [[ "$name" == amp_* ]] && continue
  unmanaged_existing+=("$name")
done < <(find "$MOD_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
IFS=$'\n' unmanaged_existing=($(printf '%s\n' "${unmanaged_existing[@]}" | awk 'NF' | sort -f))
unset IFS

stage_file() {
  local source="$1" target="$2"
  rm -f "$target"
  if ! ln "$source" "$target" 2>/dev/null; then
    if ! ln -s "$source" "$target" 2>/dev/null; then
      cp -f "$source" "$target"
    fi
  fi
}

stage_directory() {
  local source="$1" target="$2"
  rm -rf "$target"
  if ! ln -s "$source" "$target" 2>/dev/null; then
    cp -a "$source" "$target"
  fi
}

declare -a staged_keys=()
declare -a missing_keys=()
index=0

for key in "${ordered_keys[@]}"; do
  index=$((index + 1))
  kind="${key_kind[$key]}"
  value="${key_value[$key]}"
  safe="$(sanitize_name "$value")"

  if [[ "$kind" == "workshop" ]]; then
    src="$(find_item_source "$value" || true)"
    if [[ -z "$src" ]]; then
      download_item "$value" || true
      src="$(find_item_source "$value" || true)"
    fi
    if [[ -z "$src" ]]; then
      missing_keys+=("$key")
      warn "Workshop item $value is not available locally."
      continue
    fi

    mapfile -t paks < <(find -L "$src" -maxdepth 3 -type f -iname '*.pak' -print 2>/dev/null | sort)
    if (( ${#paks[@]} > 0 )); then
      n=0
      for pak in "${paks[@]}"; do
        n=$((n + 1))
        if (( ${#paks[@]} == 1 )); then
          target="$(printf '%s/amp_%04d_ws_%s.pak' "$MOD_DIR" "$index" "$value")"
        else
          target="$(printf '%s/amp_%04d_ws_%s_%02d.pak' "$MOD_DIR" "$index" "$value" "$n")"
        fi
        stage_file "$pak" "$target"
      done
      staged_keys+=("$key")
    elif [[ -f "$src/_metadata" ]]; then
      target="$(printf '%s/amp_%04d_ws_%s' "$MOD_DIR" "$index" "$value")"
      stage_directory "$src" "$target"
      staged_keys+=("$key")
    else
      missing_keys+=("$key")
      warn "Workshop item $value has no .pak or root _metadata."
    fi
    continue
  fi

  # Local/private source
  src="${local_path_by_name[$value]:-}"
  local_kind="${local_kind_by_name[$value]:-}"
  if [[ -z "$src" || -z "$local_kind" ]]; then
    missing_keys+=("$key")
    warn "Local mod '$value' is no longer present in '$LOCAL_DIR'."
    continue
  fi

  case "$local_kind" in
    pak)
      target="$(printf '%s/amp_%04d_local_%s.pak' "$MOD_DIR" "$index" "${safe%.pak}")"
      stage_file "$src" "$target"
      staged_keys+=("$key")
      ;;
    directory)
      target="$(printf '%s/amp_%04d_local_%s' "$MOD_DIR" "$index" "$safe")"
      stage_directory "$src" "$target"
      staged_keys+=("$key")
      ;;
    pakbundle)
      mapfile -t bundle_paks < <(find "$src" -maxdepth 2 -type f -iname '*.pak' -print 2>/dev/null | sort)
      if (( ${#bundle_paks[@]} == 0 )); then
        missing_keys+=("$key")
      else
        n=0
        for pak in "${bundle_paks[@]}"; do
          n=$((n + 1))
          target="$(printf '%s/amp_%04d_local_%s_%02d.pak' "$MOD_DIR" "$index" "$safe" "$n")"
          stage_file "$pak" "$target"
        done
        staged_keys+=("$key")
      fi
      ;;
  esac
done

# ----- Lightweight metadata validation for unpacked local mods -----
# Packed .pak metadata is intentionally not unpacked on every start.

metadata_field() {
  local file="$1" field="$2"
  grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null |
    head -n1 |
    sed -E "s/.*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

metadata_array() {
  local file="$1" field="$2"
  local block
  block="$(tr '\n' ' ' < "$file" | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\[[^]]*\]" | head -n1 || true)"
  printf '%s' "$block" | grep -oE '"[^"]+"' | tail -n +2 | tr -d '"' || true
}

declare -A metadata_owner_by_name=()
declare -A metadata_path_by_local=()
declare -a duplicate_metadata_names=()
declare -a missing_declared_requires=()
declare -a metadata_notes=()

for name in "${enabled_local_names[@]}"; do
  [[ "${local_kind_by_name[$name]:-}" == "directory" ]] || continue
  meta="${local_path_by_name[$name]}/_metadata"
  [[ -f "$meta" ]] || continue

  modname="$(metadata_field "$meta" name)"
  [[ -n "$modname" ]] || modname="$name"
  metadata_path_by_local["$name"]="$meta"

  if [[ -n "${metadata_owner_by_name[$modname]:-}" ]]; then
    duplicate_metadata_names+=("$modname :: ${metadata_owner_by_name[$modname]} | $name")
  else
    metadata_owner_by_name["$modname"]="$name"
  fi
done

for name in "${enabled_local_names[@]}"; do
  meta="${metadata_path_by_local[$name]:-}"
  [[ -n "$meta" ]] || continue
  modname="$(metadata_field "$meta" name)"
  [[ -n "$modname" ]] || modname="$name"
  priority="$(grep -oE '"priority"[[:space:]]*:[[:space:]]*-?[0-9]+([.][0-9]+)?' "$meta" 2>/dev/null | head -n1 | sed -E 's/.*:[[:space:]]*//' || true)"
  [[ -n "$priority" ]] && metadata_notes+=("$name :: name=$modname priority=$priority")

  while IFS= read -r req; do
    [[ -n "$req" ]] || continue
    # 'base' is supplied by Starbound packed.pak. Packed Workshop/local mods are not
    # introspected, so only report requirements that are definitely absent from the
    # readable unpacked local metadata set.
    if [[ "$req" != "base" && -z "${metadata_owner_by_name[$req]:-}" ]]; then
      metadata_notes+=("$name :: requires '$req' (not found among readable unpacked local metadata; it may be supplied by a packed/Workshop mod)")
    fi
  done < <(metadata_array "$meta" requires)
done

{
  echo "OpenStarbound AMP unified mod report"
  echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Mode: $([[ "$PRESTART" == true ]] && echo pre-start || echo update/manual)"
  echo
  echo "LOCAL MOD SOURCE DIRECTORY"
  echo "  $LOCAL_DIR"
  echo
  echo "NATIVE AMP WORKSHOP IDS"
  printf '  %s\n' "${native_ids[@]:-}"
  echo
  echo "WORKSHOP COLLECTION IDS"
  printf '  %s\n' "${collection_ids[@]:-}"
  echo
  echo "RESOLVED COLLECTION ITEM IDS"
  printf '  %s\n' "${collection_item_ids[@]:-}"
  echo
  echo "DISCOVERED LOCAL SOURCES"
  printf '  %s\n' "${discovered_local_names[@]:-}"
  echo
  echo "ENABLED LOCAL SOURCES"
  printf '  %s\n' "${enabled_local_names[@]:-}"
  echo
  echo "DISABLED LOCAL SOURCES"
  printf '  %s\n' "${disabled_local_names[@]:-}"
  echo
  echo "INVALID/UNSUPPORTED LOCAL ENTRIES"
  printf '  %s\n' "${invalid_local_names[@]:-}"
  echo
  echo "REQUESTED UNIFIED PREFERENCE"
  printf '  %s\n' "${preference_entries[@]:-}"
  echo
  echo "UNKNOWN PREFERENCE ENTRIES"
  printf '  %s\n' "${unknown_preference[@]:-}"
  echo
  echo "EFFECTIVE MANAGED STAGING SEQUENCE"
  printf '  %s\n' "${ordered_keys[@]:-}"
  echo
  echo "SUCCESSFULLY STAGED"
  printf '  %s\n' "${staged_keys[@]:-}"
  echo
  echo "MISSING/UNUSABLE MANAGED SOURCES"
  printf '  %s\n' "${missing_keys[@]:-}"
  printf '  local:%s\n' "${missing_local_names[@]:-}"
  echo
  echo "UNMANAGED EXISTING server/mods ENTRIES"
  printf '  %s\n' "${unmanaged_existing[@]:-}"
  echo
  echo "DUPLICATE READABLE LOCAL METADATA NAMES"
  printf '  %s\n' "${duplicate_metadata_names[@]:-}"
  echo
  echo "READABLE LOCAL METADATA NOTES"
  printf '  %s\n' "${metadata_notes[@]:-}"
  echo
  echo "COLLECTIONS THAT COULD NOT BE RESOLVED"
  printf '  %s\n' "${collection_errors[@]:-}"
  echo
  echo "ORDERING NOTE"
  echo "  amp_#### filenames provide deterministic staging/fallback order."
  echo "  OpenStarbound ultimately sorts asset sources using mod metadata priority/name"
  echo "  and then dependency metadata (requires/includes). This helper does not rewrite"
  echo "  mod metadata or packed .pak contents, avoiding asset-digest/client mismatches."
  echo
  echo "LOCAL MOD FORMAT"
  echo "  Put .pak files, unpacked mod directories containing _metadata, or release"
  echo "  directories containing .pak files into the local source directory."
} > "$REPORT"

log "Managed ${#staged_keys[@]} source(s): ${#workshop_ids[@]} Workshop candidate(s), ${#enabled_local_names[@]} enabled local source(s)."
log "Report: $REPORT"
if (( ${#missing_keys[@]} + ${#missing_local_names[@]} + ${#unknown_preference[@]} > 0 )); then
  warn "One or more configured mod sources/preferences need attention. See the report."
fi
exit 0
