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
ORDER_FILE="$STORAGE_DIR/amp_mods_order.txt"
STEAM_APP_ID="211820"
PRESTART=false
[[ "${1:-}" == "--prestart" ]] && PRESTART=true

mkdir -p "$MOD_DIR" "$STORAGE_DIR" || exit 1

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
  [[ "$raw" =~ ^\[[[:space:]]*\]$ ]] && return 0

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
download_timeout=900
timeout_value="$(trim "$(kvp_value 'WorkshopDownloadTimeoutSeconds' "$MOD_CFG")")"
if [[ "$timeout_value" =~ ^[0-9]{1,5}$ ]] && (( 10#$timeout_value >= 1 && 10#$timeout_value <= 86400 )); then
  download_timeout=$((10#$timeout_value))
fi
prune_managed="$(bool_value "$(kvp_value 'PruneManagedMods' "$MOD_CFG")" true)"
auto_enable_local="$(bool_value "$(kvp_value 'AutoEnableLocalMods' "$MOD_CFG")" true)"
local_rel="$(safe_local_dir "$(kvp_value 'LocalModsDirectory' "$MOD_CFG")")"
LOCAL_DIR="$BASE_DIR/$local_rel"

if [[ "$managed_enabled" != "true" ]]; then
  log "Managed mod synchronization is disabled."
  exit 0
fi

# Resolve aliases before comparing containment. Reject overlaps before cleanup,
# including a symlinked source or staging directory pointing at the other tree.
base_path="$(realpath -m -- "$BASE_DIR")" || exit 1
mods_path="$(realpath -m -- "$MOD_DIR")" || exit 1
source_path="$(realpath -m -- "$LOCAL_DIR")" || exit 1
if [[ "$source_path" != "$base_path/"* || "$source_path" == "$mods_path" ||
      "$source_path" == "$mods_path/"* || "$mods_path" == "$source_path/"* ]]; then
  warn 'Local Mods Directory must be inside the server directory and must not overlap server/mods.'
  exit 1
fi
mkdir -p "$LOCAL_DIR" || exit 1

# The native AMP listfile control owns this file. Existing empty files reset the
# preference; only absent files migrate the old config/ModLoadOrder value.
if [[ -L "$ORDER_FILE" || ( -e "$ORDER_FILE" && ! -f "$ORDER_FILE" ) ]]; then
  warn 'Mod Staging Preference must be a regular file, not a directory or link.'
  exit 1
fi
order_existed=false
order_before=""
if [[ -f "$ORDER_FILE" ]]; then
  order_existed=true
  order_before="$(cat -- "$ORDER_FILE")" || exit 1
  readarray -t preference_entries < "$ORDER_FILE"
  if (( ${#preference_entries[@]} )); then preference_entries[0]="${preference_entries[0]#$'\xef\xbb\xbf'}"; fi
fi

declare -a collection_item_ids=()
declare -a collection_errors=()

if (( ${#collection_ids[@]} > 0 )) && ! command -v jq >/dev/null 2>&1; then
  warn 'jq is required to resolve Workshop collections. Install jq, then rerun Update.'
  exit 1
fi

# Keep state in this shell; process-substitution mutations would lose diagnostics.
# Each bounded batch shares one request and timeout. Parse records by collection ID,
# never response order or a global grep of publishedfileid fields.
for (( offset=0; offset<${#collection_ids[@]}; offset+=50 )); do
  batch=("${collection_ids[@]:offset:50}")
  curl_args=(-fsS --connect-timeout 10 --max-time 30 -X POST -d "collectioncount=${#batch[@]}")
  for i in "${!batch[@]}"; do
    curl_args+=(--data-urlencode "publishedfileids[$i]=${batch[$i]}")
  done
  response=""
  if command -v curl >/dev/null 2>&1; then
    response="$(curl "${curl_args[@]}" 'https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/' 2>/dev/null || true)"
  fi
  declare -A batch_status=() batch_members=()
  if [[ -n "$response" ]] && parsed="$(printf '%s' "$response" | jq -r '
      def valid_id: if type == "string" then test("^[0-9]+$") else false end;
      def valid_children: if type == "array" then
        all(.[]; if type == "object" then (.publishedfileid | valid_id) else false end)
        else false end;
      if (.response.collectiondetails | type) != "array" then error("Missing collection details")
      else .response.collectiondetails[] | select(type == "object") |
        select(.publishedfileid | valid_id) | .publishedfileid as $cid |
        if .result == 1 and (.children | valid_children)
        then [$cid, "ok", ([.children[].publishedfileid | select(. != $cid)] | unique | join(","))]
        else [$cid, "invalid", ""] end | @tsv
      end' 2>/dev/null)"; then
    parsed="${parsed//$'\r'/}"
    while IFS=$'\t' read -r cid status members; do
      [[ "$cid" =~ ^[0-9]+$ ]] || continue
      if [[ -n "${batch_status[$cid]:-}" ]]; then
        batch_status["$cid"]=invalid
      else
        batch_status["$cid"]="$status"
        batch_members["$cid"]="$members"
      fi
    done <<< "$parsed"
  fi
  for cid in "${batch[@]}"; do
    cache="$STORAGE_DIR/amp_collection_${cid}.txt"
    ids=()
    if [[ "${batch_status[$cid]:-}" == ok ]]; then
      IFS=',' read -r -a ids <<< "${batch_members[$cid]}"
      # An empty file is an authoritative, cached empty collection.
      if ! { if (( ${#ids[@]} > 0 )); then printf '%s\n' "${ids[@]}"; fi; } > "$cache"; then
        warn "Could not cache collection $cid."
      fi
    elif [[ -f "$cache" ]]; then
      warn "Could not refresh collection $cid; using cached membership."
      mapfile -t ids < <(tr -d '\r' < "$cache" | grep -E '^[0-9]+$')
    else
      collection_errors+=("$cid")
      warn "Could not resolve collection $cid and no cached membership is available."
    fi
    collection_item_ids+=("${ids[@]}")
  done
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
  local steamcmd
  while IFS= read -r steamcmd; do
    candidates+=("$(dirname "$steamcmd")/steamapps/workshop/content/$STEAM_APP_ID/$id")
  done < <(steamcmd_candidates)
  for p in "${candidates[@]}"; do
    if [[ -d "$p" ]] && { [[ -f "$p/_metadata" ]] ||
        [[ -n "$(find -L "$p" -maxdepth 3 -type f -iname '*.pak' -print -quit 2>/dev/null)" ]]; }; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

steamcmd_candidates() {
  local candidates=(
    "$ROOT_DIR/steamcmd.sh"
    "$ROOT_DIR/steamcmd/steamcmd.sh"
    "$INSTANCE_DIR/steamcmd.sh"
    "$INSTANCE_DIR/steamcmd/steamcmd.sh"
    "$HOME/Steam/steamcmd.sh"
    "$HOME/.steam/steam/steamcmd.sh"
    "$HOME/.local/share/Steam/steamcmd.sh"
  )
  local p
  for p in "${candidates[@]}"; do
    [[ -f "$p" ]] && printf '%s\n' "$p"
  done | unique_lines
}

workshop_steam_context() {
  local username owner='' launcher='' manifest path content block owner_name selected name
  username="$(trim "$(kvp_value 'WorkshopSteamUsername' "$MOD_CFG")")"
  username="${username#\"}"; username="${username%\"}"
  if [[ -n "$username" && ! "$username" =~ ^[A-Za-z0-9_]+$ ]]; then
    warn 'Workshop Steam Username must contain only letters, numbers, or underscores.'
    return 1
  fi
  local executables=() manifests=() contexts=() owner_contexts=() names=() all_names=() identities=()
  mapfile -t executables < <(steamcmd_candidates)
  if (( ${#executables[@]} == 0 )); then
    warn 'SteamCMD wrapper was not found; cannot auto-download Workshop items.'
    return 1
  fi
  # Match the account from AMP's successful app update to the same installation's
  # cache. Never combine an account from one cache with another executable.
  for manifest in "$ROOT_DIR/$STEAM_APP_ID/steamapps/appmanifest_$STEAM_APP_ID.acf" \
      "$ROOT_DIR/steamapps/appmanifest_$STEAM_APP_ID.acf" "$BASE_DIR/steamapps/appmanifest_$STEAM_APP_ID.acf"; do
    [[ -f "$manifest" ]] && manifests+=("$(stat -c %Y "$manifest")"$'\t'"$manifest")
  done
  while IFS=$'\t' read -r _ manifest; do
    [[ -f "$manifest" ]] || continue
    content="$(tr '\r\n' ' ' < "$manifest")"
    owner="$(printf '%s' "$content" | sed -n -E 's/.*"LastOwner"[[:space:]]*"([1-9][0-9]+)".*/\1/p')"
    if [[ -n "$owner" ]]; then
      launcher="$(printf '%s' "$content" | sed -n -E 's/.*"LauncherPath"[[:space:]]*"([^"]+)".*/\1/p')"
      break
    fi
  done < <(printf '%s\n' "${manifests[@]}" | sort -t $'\t' -k1,1nr)
  for path in "${executables[@]}"; do
    local cache="$(dirname "$path")/config/config.vdf"
    [[ -f "$cache" ]] || continue
    content="$(tr '\r\n' ' ' < "$cache")"
    block="$(printf '%s' "$content" | sed -n -E 's/.*"ConnectCache"[[:space:]]*\{([^{}]*)\}.*/\1/p')"
    # Only identity names leave this function; tokens stay in their original file.
    mapfile -t names < <(printf '%s' "$block" |
      grep -oE '"[^"]*"[[:space:]]*"[^"]*"' |
      sed -E 's/^"([^"]*)".*/\1/' | grep -E '^[A-Za-z0-9_]+$' | unique_lines)
    all_names+=("${names[@]}")
    owner_name=''
    if [[ -n "$owner" ]]; then
      owner_name="$(printf '%s' "$content" | sed -n -E 's/.*"([A-Za-z0-9_]+)"[[:space:]]*\{[^{}]*"SteamID"[[:space:]]*"'"$owner"'"[^{}]*\}.*/\1/p')"
    fi
    selected=''
    if [[ -n "$username" ]]; then
      for name in "${names[@]}" "$owner_name"; do
        [[ "${name,,}" == "${username,,}" ]] && selected="$username"
      done
    elif [[ -n "$owner_name" ]]; then selected="$owner_name"
    elif (( ${#names[@]} == 1 )); then selected="${names[0]}"
    fi
    if [[ -n "$selected" ]]; then
      local launcher_match=0
      [[ -n "$launcher" && ( "$launcher" == "$path" || "$launcher" == "$(dirname "$path")/linux32/steamcmd" ) ]] && launcher_match=1
      local record="$launcher_match"$'\t'"$(stat -c %Y "$cache")"$'\t'"$path"$'\t'"$selected"
      contexts+=("$record")
      [[ -n "$owner_name" && "${selected,,}" == "${owner_name,,}" ]] && owner_contexts+=("$record")
    fi
  done
  (( ${#owner_contexts[@]} == 0 )) || contexts=("${owner_contexts[@]}")
  if (( ${#contexts[@]} > 0 )); then
    mapfile -t identities < <(printf '%s\n' "${contexts[@]}" | cut -f4 | tr '[:upper:]' '[:lower:]' | unique_lines)
    if [[ -z "$username" ]] && (( ${#owner_contexts[@]} == 0 )); then
      mapfile -t identities < <(printf '%s\n' "${all_names[@]}" | tr '[:upper:]' '[:lower:]' | unique_lines)
    fi
    if (( ${#identities[@]} == 1 )); then
      IFS=$'\t' read -r _ _ path selected < <(printf '%s\n' "${contexts[@]}" | sort -t $'\t' -k1,1nr -k2,2nr | head -n 1)
      printf '%s\n%s\n' "$path" "$selected"
      return 0
    fi
  elif [[ -n "$username" ]]; then
    # Explicit names still support cache formats we cannot inspect.
    printf '%s\n%s\n' "${executables[0]}" "$username"
    return 0
  fi
  warn "Cannot identify AMP's cached Steam account unambiguously. Set Workshop Steam Username to the account authenticated in AMP, then rerun Update."
  return 1
}

download_item() {
  local id="$1"
  [[ "$download_missing" == "true" ]] || return 1

  local context=() steamcmd username
  mapfile -t context < <(workshop_steam_context)
  (( ${#context[@]} == 2 )) || return 1
  steamcmd="${context[0]}"; username="${context[1]}"

  if ! command -v timeout >/dev/null 2>&1; then
    warn 'GNU timeout is required for unattended Workshop downloads. Install coreutils, then rerun Update.'
    return 1
  fi
  log "Using SteamCMD and its existing login cache: $steamcmd"
  log "Downloading locally missing Workshop item $id with AMP's cached Steam login (timeout: ${download_timeout}s)..."
  # timeout owns a process group, so both the wrapper and its descendants are
  # terminated at the deadline. No inherited input can leave a password prompt open.
  (cd "$(dirname "$steamcmd")" && exec timeout --signal=TERM --kill-after=5s "${download_timeout}s" \
    /bin/bash "$steamcmd" +@ShutdownOnFailedCommand 1 +@NoPromptForPassword 1 \
    +login "$username" +workshop_download_item "$STEAM_APP_ID" "$id" validate +quit) </dev/null &
  local download_pid=$! status
  trap 'kill -TERM "$download_pid" 2>/dev/null; wait "$download_pid" 2>/dev/null; exit 1' INT TERM
  wait "$download_pid"
  status=$?
  trap - INT TERM
  if (( status == 124 || status == 137 )); then
    warn "Workshop item $id timed out after ${download_timeout}s. Reauthenticate Steam through AMP if required, then rerun Update."
  elif (( status != 0 )); then
    warn "SteamCMD failed for Workshop item $id (exit code $status). Check the output above; reauthenticate through AMP if required."
  fi
  return "$status"
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
  [[ "$raw" =~ ^[[:space:]]*$ ]] && continue
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

# Keep remembered entries, even if a mod is temporarily disabled/unavailable.
# Preferences never enable sources; new configured/enabled sources append once.
declare -a saved_order_keys=()
declare -A saved_order_seen=()
for raw in "${preference_entries[@]}"; do
  [[ "$raw" =~ ^[[:space:]]*$ ]] && continue
  key="$(normalize_preference "$raw")"
  if [[ -z "${saved_order_seen[$key]:-}" ]]; then saved_order_keys+=("$key"); saved_order_seen["$key"]=1; fi
done
for key in "${ordered_keys[@]}"; do
  if [[ -z "${saved_order_seen[$key]:-}" ]]; then saved_order_keys+=("$key"); saved_order_seen["$key"]=1; fi
done
for key in "${saved_order_keys[@]}"; do
  if [[ "$key" == *$'\n'* || "$key" == *$'\r'* ]]; then warn 'Mod Staging Preference entries must fit on one line.'; exit 1; fi
done
if [[ -L "$ORDER_FILE" || ( -e "$ORDER_FILE" && ! -f "$ORDER_FILE" ) ]]; then
  warn 'Mod Staging Preference must be a regular file, not a directory or link.'
  exit 1
fi
exists_now=false
[[ -f "$ORDER_FILE" ]] && exists_now=true
order_now=""
if [[ "$exists_now" == true ]]; then order_now="$(cat -- "$ORDER_FILE")" || exit 1; fi
if [[ "$exists_now" != "$order_existed" ]] ||
   [[ "$order_now" != "$order_before" ]]; then
  warn 'Mod Staging Preference changed during discovery. Rerun Update; the newer edits were preserved.'
  exit 1
fi
temporary_order="$(mktemp "$STORAGE_DIR/.amp-order.XXXXXX")" || exit 1
if (( ${#saved_order_keys[@]} )) && ! printf '%s\n' "${saved_order_keys[@]}" > "$temporary_order"; then
  rm -f -- "$temporary_order"
  exit 1
fi
if [[ "$order_existed" == true ]] && cmp -s -- "$temporary_order" "$ORDER_FILE"; then
  rm -f -- "$temporary_order"
elif ! mv -f -- "$temporary_order" "$ORDER_FILE"; then
  rm -f -- "$temporary_order"
  exit 1
fi

# ----- Clear only AMP-managed staging entries -----

# Reconcile generated names even when broad orphan pruning is disabled.
while IFS= read -r -d '' entry; do
  name="$(basename "$entry")"
  if [[ "$prune_managed" == true || "$name" =~ ^amp_[0-9]{4,}_(ws|local)_ ]]; then
    rm -rf -- "$entry" || exit 1
  fi
done < <(find "$MOD_DIR" -mindepth 1 -maxdepth 1 -name 'amp_*' -print0)

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
  rm -f -- "$target" || return 1
  if ! ln "$source" "$target" 2>/dev/null; then
    if ! ln -s "$source" "$target" 2>/dev/null; then
      cp -f -- "$source" "$target" || return 1
    fi
  fi
  [[ -f "$target" ]]
}

stage_directory() {
  local source="$1" target="$2"
  rm -rf -- "$target" || return 1
  if ! ln -s "$source" "$target" 2>/dev/null; then
    cp -a -- "$source" "$target" || return 1
  fi
  [[ -d "$target" ]]
}

declare -a staged_keys=()
declare -a missing_keys=()
declare -a staging_failures=()
declare -a download_failures=()
index=0

record_staging_result() {
  if [[ "$2" == true ]]; then
    staged_keys+=("$1")
  else
    staging_failures+=("$1")
    missing_keys+=("$1")
    warn "Could not stage $1. See the filesystem error above."
  fi
}

for key in "${ordered_keys[@]}"; do
  stage_ok=true
  index=$((index + 1))
  kind="${key_kind[$key]}"
  value="${key_value[$key]}"
  safe="$(sanitize_name "$value")"

  if [[ "$kind" == "workshop" ]]; then
    src="$(find_item_source "$value" || true)"
    if [[ -z "$src" && "$download_missing" == true ]]; then
      if download_item "$value"; then src="$(find_item_source "$value" || true)"; fi
      if [[ -z "$src" ]]; then
        download_failures+=("$key")
        warn "Workshop download $value did not produce usable local assets. See SteamCMD output above and rerun Update after resolving the failure."
      fi
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
        stage_file "$pak" "$target" || stage_ok=false
      done
    elif [[ -f "$src/_metadata" ]]; then
      target="$(printf '%s/amp_%04d_ws_%s' "$MOD_DIR" "$index" "$value")"
      stage_directory "$src" "$target" || stage_ok=false
    else
      missing_keys+=("$key")
      warn "Workshop item $value has no .pak or root _metadata."
      continue
    fi
    record_staging_result "$key" "$stage_ok"
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
      stage_file "$src" "$target" || stage_ok=false
      ;;
    directory)
      target="$(printf '%s/amp_%04d_local_%s' "$MOD_DIR" "$index" "$safe")"
      stage_directory "$src" "$target" || stage_ok=false
      ;;
    pakbundle)
      mapfile -t bundle_paks < <(find "$src" -maxdepth 2 -type f -iname '*.pak' -print 2>/dev/null | sort)
      if (( ${#bundle_paks[@]} == 0 )); then
        missing_keys+=("$key")
        continue
      else
        n=0
        for pak in "${bundle_paks[@]}"; do
          n=$((n + 1))
          target="$(printf '%s/amp_%04d_local_%s_%02d.pak' "$MOD_DIR" "$index" "$safe" "$n")"
          stage_file "$pak" "$target" || stage_ok=false
        done
      fi
      ;;
  esac
  record_staging_result "$key" "$stage_ok"
done

{
  echo "OpenStarbound AMP unified mod report"
  echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Mode: $([[ "$PRESTART" == true ]] && echo pre-start || echo update/manual)"
  echo
  echo "LOCAL MOD SOURCE DIRECTORY"
  echo "  $LOCAL_DIR"
  echo
  echo "MOD STAGING PREFERENCE FILE"
  echo "  $ORDER_FILE"
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
  echo "STAGING FAILURES"
  printf '  %s\n' "${staging_failures[@]:-}"
  echo
  echo "WORKSHOP DOWNLOAD FAILURES"
  printf '  %s\n' "${download_failures[@]:-}"
  echo
  echo "UNMANAGED EXISTING server/mods ENTRIES"
  printf '  %s\n' "${unmanaged_existing[@]:-}"
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
} > "$REPORT" || exit 1

if [[ -f "$INSTANCE_DIR/openstarboundmoddiagnostics.sh" ]]; then
  /bin/bash "$INSTANCE_DIR/openstarboundmoddiagnostics.sh" "$BASE_DIR" "$REPORT"
else
  printf '\nENGINE LOAD ORDER STATUS\n  UNAVAILABLE: Run Update to install the load-order diagnostics helper.\n' >> "$REPORT"
  warn "Run Update to install the load-order diagnostics helper."
fi
log "Managed ${#staged_keys[@]} source(s): ${#workshop_ids[@]} Workshop candidate(s), ${#enabled_local_names[@]} enabled local source(s)."
log "Report: $REPORT"
log "Mod staging list: $ORDER_FILE (${#saved_order_keys[@]} entries; saved positions preserved)."
if (( ${#missing_keys[@]} + ${#missing_local_names[@]} + ${#unknown_preference[@]} + ${#collection_errors[@]} > 0 )); then
  warn "One or more configured mod sources/preferences need attention. See the report."
fi
(( ${#staging_failures[@]} + ${#download_failures[@]} == 0 )) || exit 1
exit 0
