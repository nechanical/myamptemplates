#!/usr/bin/env bash
# Read-only prediction of OpenStarbound's standard assets/ then mods/ scan.
set -o pipefail
base_dir="$1"
report="$2"

unavailable() {
  printf '\nENGINE LOAD ORDER STATUS\n  UNAVAILABLE: %s\n' "$1" >> "$report"
  printf '[OpenStarbound Mods] WARNING: Load-order diagnostics unavailable: %s\n' "$1" >&2
}
command -v jq >/dev/null 2>&1 || { unavailable 'Install jq to inspect packed metadata and dependencies.'; exit 0; }

packed_metadata() {
  local path="$1" offset size
  [[ "$(head -c 8 -- "$path")" == SBAsset6 ]] || return 1
  size="$(stat -Lc %s -- "$path")" || return 1
  offset="$(od -An -tu1 -j8 -N8 -- "$path" | awk '
    { for(i=1;i<=NF;i++) { v=v*256+$i; n++ } }
    END { if(n!=8 || v>9007199254740991) exit 1; printf "%.0f",v }')" || return 1
  (( offset >= 16 && offset <= size - 6 )) || return 1
  [[ "$(dd if="$path" bs=1 skip="$offset" count=5 2>/dev/null)" == INDEX ]] || return 1
  # Read only a bounded index prefix, never unpack asset payloads. Drain the pipe
  # after parsing so an ordinary early metadata end does not cause SIGPIPE.
  LC_ALL=C od -An -v -tu1 -j"$((offset+5))" -N1048576 -- "$path" | LC_ALL=C awk '
    function fail() { exit 1 }
    function byte( b) {
      while(pos>NF) { if((getline)<=0) fail(); pos=1 }
      if(++consumed>1048576) fail()
      b=$(pos++); return b+0
    }
    function vlq( v,b,n) {
      v=0
      for(n=0;n<10;n++) { b=byte(); v=v*128+b%128; if(v>9007199254740991) fail(); if(b<128) return v }
      fail()
    }
    function count( n) { n=vlq(); if(n>1048576) fail(); return n }
    function str( n,i,b,s) {
      n=count(); s="\""
      for(i=0;i<n;i++) {
        b=byte()
        if(b==34) s=s "\\\""
        else if(b==92) s=s "\\\\"
        else if(b<32) s=s sprintf("\\u%04x",b)
        else s=s sprintf("%c",b)
      }
      return s "\""
    }
    function map(depth, n,i,k,v,s) {
      if(depth>48) fail()
      n=count(); s="{"
      for(i=0;i<n;i++) { k=str(); v=value(depth+1); s=s (i?",":"") k ":" v }
      return s "}"
    }
    function value(depth, tag,n,i,b1,b2,e,m,d,s,v) {
      if(depth>48) fail()
      tag=byte()
      if(tag==1) return "null"
      if(tag==2) {
        b1=byte(); b2=byte(); e=(b1%128)*16+int(b2/16); m=b2%16
        for(i=0;i<6;i++) m=m*256+byte()
        if(e==2047) fail()
        d=(e==0 ? m/2^52*2^-1022 : (1+m/2^52)*2^(e-1023))
        if(b1>=128) d=-d
        return sprintf("%.17g",d)
      }
      if(tag==3) { v=byte(); if(v>1) fail(); return v?"true":"false" }
      if(tag==4) { v=vlq(); return sprintf("%.0f",v%2 ? -int(v/2)-1 : v/2) }
      if(tag==5) return str()
      if(tag==6) {
        n=count(); s="["
        for(i=0;i<n;i++) { v=value(depth+1); s=s (i?",":"") v }
        return s "]"
      }
      if(tag==7) return map(depth)
      fail()
    }
    BEGIN { pos=1; result=map(0); while((getline)>0) {} print result }
  '
}

records="$(mktemp "$base_dir/storage/.amp-order.XXXXXX")" || { unavailable 'Could not create metadata scratch file.'; exit 0; }
# This file contains diagnostic records only; source mods are opened read-only.
trap 'rm -f -- "$records"' EXIT
for directory in assets mods; do
  [[ -d "$base_dir/$directory" ]] || continue
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    [[ "$name" == .* || "$name" == _* ]] && continue
    label="$directory/$name"
    if [[ -d "$path" ]]; then
      if [[ -f "$path/_metadata" ]]; then metadata="$(cat -- "$path/_metadata")"; else metadata='{}'; fi
    elif [[ "$name" == *.pak ]]; then
      metadata="$(packed_metadata "$path" 2>/dev/null)" || metadata=''
    else
      continue
    fi
    if ! printf '%s' "$metadata" | jq -ce --arg path "$label" '{path:$path, metadata:.}' >> "$records" 2>/dev/null; then
      jq -cn --arg path "$label" '{path:$path,error:"Could not read JSON/SBAsset6 metadata (1 MiB limit for packed metadata)."}' >> "$records"
    fi
  done < <(find "$base_dir/$directory" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
done

# Same selection/sort/DFS rules as StarRoot::scanForAssetSources. Optional includes
# only order providers that exist; requires are reported when a provider is absent.
analysis="$(jq -cs '
  def strings: type=="array" and all(.[];type=="string");
  def f32:
    if .==0 then 0 else . as $x | fabs as $a |
      pow(2;([($a|log2|floor),-126]|max)-23) as $step |
      ($a/$step) as $q | ($q|floor) as $n |
      (if $q-$n>0.5 or ($q-$n==0.5 and $n%2==1) then $n+1 else $n end)*$step*(if $x<0 then -1 else 1 end)
    end;
  def source:
    .path as $path | .metadata as $m |
    if ($m|type)!="object" then error("Metadata must be a JSON object.")
    elif ($m|has("name")) and ($m.name|type)!="string" then error("Metadata name must be a string.")
    elif ($m|has("priority")) and (($m.priority|type)!="number" or ($m.priority|fabs)>3.4028234663852886e38) then error("Metadata priority must be finite and numeric.")
    elif ($m|has("includes")) and ($m.includes|strings|not) then error("Metadata includes must be an array of strings.")
    elif ($m|has("requires")) and ($m.requires|strings|not) then error("Metadata requires must be an array of strings.")
    else {path:$path,name:$m.name,named:($m|has("name")),priority:(($m.priority//0)|f32),includes:($m.includes//[]),requires:($m.requires//[]),managed:($path|test("^mods/amp_[0-9]{4,}_(ws|local)_"))} end;
  def visit($s;$owners):
    if .black[$s.path] then .
    elif .gray[$s.path] then .cycle=true | .problems += ["Dependency cycle: "+((.stack+[$s.path])|join(" -> "))]
    else .gray[$s.path]=true | .stack+=[$s.path] |
      reduce ($s.includes+$s.requires)[] as $d (.; if $owners|has($d) then visit($owners[$d];$owners) else . end) |
      .stack=.stack[:-1] | .gray[$s.path]=false | .black[$s.path]=true | .order+=[$s]
    end;
  . as $records |
  reduce $records[] as $r ({sources:[],owners:{},issues:[],duplicates:[]};
    if $r.error then .issues+=[$r.path+" :: "+$r.error]
    else (try ($r|source) catch {error:.,path:$r.path}) as $s |
      if $s.error then .issues+=[$s.path+" :: "+$s.error]
      elif $s.named and (.owners|has($s.name)) then
        .owners[$s.name] as $i | .sources[$i] as $old |
        (if $old.priority<=$s.priority then $s else $old end) as $winner |
        (if $old.priority<=$s.priority then $old else $s end) as $loser |
        .sources[$i]=$winner |
        .duplicates += [(($s.name|tojson)+" :: selected "+$winner.path+" (priority "+($winner.priority|tostring)+"); skipped "+$loser.path+" (priority "+($loser.priority|tostring)+")")]
      else (if $s.named then .owners[$s.name]=(.sources|length) else . end) | .sources+=[$s] end
    end) |
  .sources as $sources |
  (reduce $sources[] as $s ({};if $s.named then .[$s.name]=$s else . end)) as $owners |
  .problems=[$sources[] as $s | $s.requires[] as $r | select($owners|has($r)|not) | $s.path+" :: missing required "+($r|tojson)] |
  .black={} | .gray={} | .stack=[] | .order=[] | .cycle=false |
  reduce ($sources|sort_by([.priority,if .named then .name else "../"+.path end]))[] as $s (.;visit($s;$owners)) |
  ([$records[].path | select(test("^mods/amp_[0-9]{4,}_(ws|local)_"))]) as $scan |
  .differences=([.order[]|select(.managed)] | to_entries | map(. as $e | ($scan|index($e.value.path))+1 as $staged |
    select($staged!=$e.key+1) | $e.value.path+" :: staging position "+($staged|tostring)+" -> engine managed position "+(($e.key+1)|tostring)+" (metadata priority/name/dependencies)"))
' "$records")" || { unavailable 'Metadata analysis failed.'; exit 0; }

printf '%s' "$analysis" | jq -r '
  def line: gsub("\r";"\\r")|gsub("\n";"\\n")|gsub("\t";"\\t");
  def section($name;$values): "",$name,($values[]|"  "+line);
  "","ENGINE LOAD ORDER STATUS",
  (if (.issues|length)>0 then "  INCOMPLETE: unreadable metadata can change source selection and dependency order."
   elif (.problems|length)>0 then "  INVALID: missing required dependencies or a dependency cycle prevents normal startup."
   else "  COMPLETE: metadata prediction for the standard assets/ then mods/ scan." end),
  "  Custom boot configurations or extra asset sources are outside this prediction. This is not an asset compatibility check.",
  section("SOURCE METADATA ISSUES";.issues),section("DUPLICATE METADATA NAMES";.duplicates),section("DEPENDENCY PROBLEMS";.problems),
  section("PREFERENCE/ENGINE ORDER DIFFERENCES";if .cycle then [] else .differences end),
  "","PREDICTED ENGINE LOAD ORDER",
  (if .cycle then "  Unavailable until the dependency cycle is resolved."
   else .order|to_entries[]|"  "+((.key+1|tostring)|("0000"+.)[-4:])+" :: "+(.value.path|line)+" :: name="+(if .value.named then .value.name|tojson else "<unnamed>" end)+" priority="+(.value.priority|tostring)+" includes="+(.value.includes|tojson)+" requires="+(.value.requires|tojson) end),""
' >> "$report" || { unavailable 'Could not format metadata analysis.'; exit 0; }
if printf '%s' "$analysis" | jq -e '(.issues+.duplicates+.problems+.differences)|length>0' >/dev/null; then
  printf '[OpenStarbound Mods] WARNING: Load-order diagnostics need attention. See amp_mods_report.txt.\n' >&2
fi
