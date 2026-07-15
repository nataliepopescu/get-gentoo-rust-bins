#!/usr/bin/env bash
#
# scan_dyn_dispatch.sh — find Rust crates in the Gentoo tree that use dynamic
# dispatch (`dyn Trait`, `Box<dyn ...>`, `&dyn ...`, `impl dyn ...`).
#
# Gentoo's cargo-eclass ebuilds don't contain Rust source themselves — they
# just declare which crates (name@version) get vendored via a CRATES="..."
# variable. So the pipeline is:
#
#   1. Clone (or reuse) a sparse checkout of the Gentoo tree (ebuilds only).
#   2. Find every ebuild that inherits the `cargo` eclass.
#   3. Extract every "name@version" entry from each ebuild's CRATES var,
#      and remember which ebuild(s) pulled in which crate.
#   4. Download each unique crate from static.crates.io (cached locally,
#      so re-runs are cheap), extract it, and grep the source for dynamic
#      dispatch patterns.
#   5. Emit a TSV report: crate, version, dyn-pattern count, sample lines,
#      and which Gentoo package(s) depend on it.
#   6. Roll up to top-level packages (which binaries are affected at all,
#      even transitively, and how much).
#   7. Fetch each package's own upstream source (from SRC_URI — separate
#      from the vendored dependency crates in step 4) and rank packages by
#      lines of Rust code in their own source, excluding dependencies.
#
# Usage:
#   ./scan_dyn_dispatch.sh [options]
#
# Options:
#   -t DIR      Path to gentoo tree (sparse clone created here if missing). Default: ./gentoo-tree
#   -o DIR      Output directory for reports/cache. Default: ./report, or
#               ./report_<slugified -p value> if -p is given without -o.
#   -c DIR      Crate download/extract cache. Default: ./crates-cache
#   -u DIR      Upstream package source download/extract cache. Default: ./upstream-cache
#   -n NUM      Limit to first NUM unique crates (0 = no limit). Default: 0
#   -j NUM      Parallel download/grep jobs. Default: 8
#   -p PATTERN  Only scan ebuilds under this path prefix (e.g. media-sound/). Default: all
#   -b          Only include packages confirmed to produce a binary (has a
#               src/main.rs, src/bin/*.rs, or [[bin]] in Cargo.toml) in the
#               final report — excludes library-only crates. Off by default,
#               since the is_binary column is always present either way.
#   -h          Show this help
#
# Requires: git, curl, tar, unzip, grep (GNU), xargs, awk, perl

# Note: deliberately NOT using `set -e` / `pipefail` here — grep routinely
# returns nonzero when it finds no matches (e.g. an ebuild with no CRATES
# entries, or a crate with no dyn-dispatch hits), which is expected, not
# a failure. We check exit codes explicitly where it actually matters
# (e.g. curl downloads).
set -u

TREE_DIR="./gentoo-tree"
OUT_DIR="./report"
OUT_DIR_EXPLICIT=0
CACHE_DIR="./.crates-cache"
UPSTREAM_CACHE_DIR="./.upstream-cache"
LIMIT=0
JOBS=8
PKG_PREFIX=""
BINARIES_ONLY=0

while getopts "t:o:c:u:n:j:p:bh" opt; do
  case "$opt" in
    t) TREE_DIR="$OPTARG" ;;
    o) OUT_DIR="$OPTARG"; OUT_DIR_EXPLICIT=1 ;;
    c) CACHE_DIR="$OPTARG" ;;
    u) UPSTREAM_CACHE_DIR="$OPTARG" ;;
    n) LIMIT="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    p) PKG_PREFIX="$OPTARG" ;;
    b) BINARIES_ONLY=1 ;;
    h) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown option"; exit 1 ;;
  esac
done

# If a category/package prefix was given via -p but no explicit -o, name the
# output dir after the prefix instead of the generic "./report" — makes it
# obvious which run produced which directory when scanning multiple
# categories, and avoids one run's report silently overwriting another's.
if [ -n "$PKG_PREFIX" ] && [ "$OUT_DIR_EXPLICIT" -eq 0 ]; then
  SLUG=$(printf '%s' "$PKG_PREFIX" | sed -e 's#/*$##' -e 's#[/ ]#-#g')
  OUT_DIR="./report_${SLUG}"
fi

# WORK_DIR holds intermediate/scratch files that exist purely to pass data
# between steps of this script — not meant to be read directly. The single
# real deliverable (report.tsv, the package-by-size ranking with dyn-dispatch
# split) lives directly in $OUT_DIR.
WORK_DIR="$OUT_DIR/.work"
mkdir -p "$OUT_DIR" "$WORK_DIR" "$CACHE_DIR" "$UPSTREAM_CACHE_DIR"
MAP_FILE="$WORK_DIR/ebuild_crate_map.tsv"                     # ebuild_path \t crate_name \t crate_version
CRATES_FILE="$WORK_DIR/unique_crates.txt"                     # name@version, deduped
RESULTS_FILE="$WORK_DIR/dyn_results.tsv"                       # crate \t version \t dyn_count \t sample
FINAL_REPORT="$WORK_DIR/dependency_dynamic_dispatches.tsv"    # per (ebuild, dependency-crate) detail

log() { echo "[scan] $*" >&2; }

# --- Step 1: get the tree (sparse: ebuilds + metadata only) ---
if [ ! -d "$TREE_DIR/.git" ]; then
  log "Cloning sparse Gentoo tree into $TREE_DIR (ebuilds only, this is a few hundred MB)..."
  git clone --depth 1 --filter=blob:none --sparse https://github.com/gentoo/gentoo.git "$TREE_DIR"
  (cd "$TREE_DIR" && git sparse-checkout set --no-cone '*.ebuild' '*/metadata.xml')
else
  log "Reusing existing tree at $TREE_DIR"
fi

# --- Step 2 & 3: find cargo ebuilds, extract CRATES entries ---
log "Scanning for cargo-eclass ebuilds under '${PKG_PREFIX:-<all>}'..."
SEARCH_ROOT="$TREE_DIR/${PKG_PREFIX}"
: > "$MAP_FILE"

# Find ebuilds that inherit the cargo eclass at all (handles `inherit foo cargo bar`)
mapfile -t CARGO_EBUILDS < <(grep -rlE '^inherit(\s+[a-zA-Z0-9_.-]+)*\s+cargo(\s|$)' --include="*.ebuild" "$SEARCH_ROOT" 2>/dev/null || true)

# Record every cargo-eclass ebuild found, regardless of whether it declares
# any CRATES entries. Some packages (e.g. ones whose deps are fetched via a
# separate Gentoo-hosted crate-dist bundle rather than listed individually)
# have an empty CRATES="" — those still need to reach Step 7's own-source
# scan, so this list (not MAP_FILE) is what Step 7 iterates over.
ALL_CARGO_EBUILDS_FILE="$WORK_DIR/all_cargo_ebuilds.txt"
printf '%s\n' "${CARGO_EBUILDS[@]}" > "$ALL_CARGO_EBUILDS_FILE"

log "Found ${#CARGO_EBUILDS[@]} cargo-based ebuilds."

for ebuild in "${CARGO_EBUILDS[@]}"; do
  # CRATES var holds lines like: name@version  (one per line, inside a quoted block)
  grep -oP '^\t?[a-zA-Z0-9_.+-]+@[0-9][0-9a-zA-Z.+_-]*' "$ebuild" 2>/dev/null | sed 's/^\t//' | while read -r entry; do
    name="${entry%@*}"
    ver="${entry##*@}"
    printf '%s\t%s\t%s\n' "$ebuild" "$name" "$ver" >> "$MAP_FILE"
  done
done

cut -f2,3 "$MAP_FILE" | awk -F'\t' '{print $1"@"$2}' | sort -u > "$CRATES_FILE"

TOTAL_CRATES=$(wc -l < "$CRATES_FILE")
log "Found $TOTAL_CRATES unique crates referenced across the tree."

if [ "$LIMIT" -gt 0 ]; then
  log "Limiting to first $LIMIT crates (-n $LIMIT)."
  head -n "$LIMIT" "$CRATES_FILE" > "$CRATES_FILE.tmp" && mv "$CRATES_FILE.tmp" "$CRATES_FILE"
fi

# --- Step 4: download + extract + grep each crate ---
: > "$RESULTS_FILE"

process_crate() {
  entry="$1"
  cache_dir="$2"
  name="${entry%@*}"
  ver="${entry##*@}"
  crate_dir="$cache_dir/${name}-${ver}"
  crate_file="$cache_dir/${name}-${ver}.crate"

  if [ ! -d "$crate_dir" ]; then
    if [ ! -f "$crate_file" ]; then
      url="https://static.crates.io/crates/${name}/${name}-${ver}.crate"
      if ! curl -sf -o "$crate_file" "$url"; then
        echo "${name}	${ver}	ERROR_DOWNLOAD	" 
        return
      fi
    fi
    mkdir -p "$crate_dir"
    tar -xzf "$crate_file" -C "$crate_dir" --strip-components=1 2>/dev/null || {
      echo "${name}	${ver}	ERROR_EXTRACT	"
      return
    }
  fi

  # Dynamic dispatch patterns: Box<dyn X>, &dyn X, dyn Trait bounds.
  # Comments are stripped first so doc comments / commented-out code showing
  # example usage (very common for e.g. `Box<dyn Error>` in doc examples)
  # don't inflate the count.
  matches=""
  while IFS= read -r -d '' rsfile; do
    file_hits=$(strip_comments "$rsfile" | grep -nE 'Box<\s*dyn\s|&\s*dyn\s|Rc<\s*dyn\s|Arc<\s*dyn\s|:\s*dyn\s|\bdyn\s+[A-Za-z_]' 2>/dev/null)
    if [ -n "$file_hits" ]; then
      matches="${matches}$(printf '%s\n' "$file_hits" | sed "s#^#${rsfile}:#")
"
    fi
  done < <(find "$crate_dir" -name "*.rs" -print0 2>/dev/null)
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  sample=$(printf '%s\n' "$matches" | head -3 | tr -d '\r' | tr '\n' '|' | sed -e 's/\t/ /g' -e 's/"//g')

  echo "${name}	${ver}	${count}	${sample}"
}
export -f process_crate

# Strip Rust comments while preserving line numbers, so grep -n still reports
# the correct original line. Two passes:
#   1. Block comments /* ... */ (incl. doc comments /** ... */) — non-greedy,
#      replaced with an equal number of blank lines to keep numbering intact.
#      (Best-effort: doesn't handle Rust's nested block comments, which are rare.)
#   2. Line comments // ... and doc comments /// ... — truncate rest of line.
#      (Best-effort: doesn't special-case // inside string literals, e.g. a URL
#      in a string; those are rare enough not to matter for this kind of scan.)
strip_comments() {
  perl -0777 -pe 's{/\*.*?\*/}{ my $c = $&; "\n" x ($c =~ tr/\n//) }gse' "$1" 2>/dev/null \
    | sed -E 's,//.*,,'
}
export -f strip_comments

log "Downloading + scanning $(wc -l < "$CRATES_FILE") crates with $JOBS parallel jobs (cached in $CACHE_DIR)..."
xargs -a "$CRATES_FILE" -P "$JOBS" -I{} bash -c 'process_crate "$1" "$2"' _ {} "$CACHE_DIR" >> "$RESULTS_FILE"

# --- Step 5: build final joined report ---
log "Building final report..."
{
  while IFS=$'\t' read -r ebuild name ver; do
    row=$(awk -F'\t' -v n="$name" -v v="$ver" '$1==n && $2==v {print $3"\t"$4; exit}' "$RESULTS_FILE")
    count=$(echo "$row" | cut -f1)
    sample=$(echo "$row" | cut -f2)
    if [ -n "$count" ] && [ "$count" != "0" ] && [[ "$count" != ERROR* ]]; then
      echo -e "${ebuild}\t${name}\t${ver}\t${count}\t${sample}"
    fi
  done < "$MAP_FILE"
} | sort -t$'\t' -k4,4 -rn > "$FINAL_REPORT.body"
{ echo -e "ebuild\tcrate\tversion\tdyn_dispatch_count\tsample_matches"; cat "$FINAL_REPORT.body"; } > "$FINAL_REPORT"
rm -f "$FINAL_REPORT.body"

HITS=$(($(wc -l < "$FINAL_REPORT") - 1))
log "Done. $HITS (ebuild, crate) pairs use dynamic dispatch. Detail (intermediate): $FINAL_REPORT"

# --- Step 6: roll up to top-level packages ---
# dependency_dynamic_dispatches.tsv is per (ebuild, dependency-crate) — useful
# as intermediate detail, but what you usually want is "which top-level
# binaries does this affect at all, even transitively". Collapse to one row
# per package. (This rollup is itself still intermediate — it gets merged
# into the final report.tsv below, alongside own-code dyn-dispatch data.)
PACKAGES_FILE="$WORK_DIR/packages_with_dyn_dispatch.tsv"
log "Rolling up to top-level packages..."
awk -F'\t' 'NR>1 {
    ebuild=$1; crate=$2; ver=$3; cnt=$4;
    n[ebuild]++;
    total[ebuild]+=cnt;
    crates[ebuild] = crates[ebuild] (crates[ebuild]==""?"":", ") crate"@"ver;
  }
  END {
    for (e in n) print e"\t"n[e]"\t"total[e]"\t"crates[e]
  }' "$FINAL_REPORT" | while IFS=$'\t' read -r ebuild ncrates total crates; do
    # Turn .../CATEGORY/PN/PF.ebuild into "CATEGORY/PF" (standard Gentoo atom form)
    category=$(basename "$(dirname "$(dirname "$ebuild")")")
    pf=$(basename "$ebuild" .ebuild)
    echo -e "${category}/${pf}\t${category}\t${ncrates}\t${total}\t${crates}"
  done | sort -t$'\t' -k4,4 -rn > "$PACKAGES_FILE.body"
{ echo -e "package\tcategory\tdistinct_crates_using_dyn\ttotal_dyn_hits\tcrates"; cat "$PACKAGES_FILE.body"; } > "$PACKAGES_FILE"
rm -f "$PACKAGES_FILE.body"

PKG_COUNT=$(($(wc -l < "$PACKAGES_FILE") - 1))
log "$PKG_COUNT top-level package(s) use dynamic dispatch somewhere in their dependency tree."
log "Package summary (intermediate): $PACKAGES_FILE"
log ""
awk -F'\t' 'NR==1{printf "  %-40s %-12s %-10s %s\n", "PACKAGE", "#CRATES", "HITS", "CRATES (name@version)"; next} {printf "  %-40s %-12s %-10s %s\n", $1, $3, $4, $5}' "$PACKAGES_FILE" >&2

log ""
log "Per-crate detail (which dependency crate contributed):"
head -n 11 "$FINAL_REPORT" | awk -F'\t' '{printf "  %-45s %-25s %-10s %s\n", $2, $3, $4, $1}' >&2

# --- Step 7: rank all scanned packages by their own source size ---
# Everything so far measures the vendored *dependency* crates. This step
# fetches each package's own upstream source (from SRC_URI, e.g. its GitHub
# release tarball) — separate from the dependency crates — and counts lines
# of Rust code in it directly, excluding any vendored/target dirs. This
# covers every cargo-based package found in this run, not just the ones
# with dyn-dispatch hits, so you can rank by size independent of that.
SIZE_FILE="$OUT_DIR/report.tsv"
log ""
log "Fetching upstream source per package to measure own lines of Rust code..."

fetch_and_count_loc() {
  ebuild="$1"
  cache_dir="$2"

  pn=$(basename "$(dirname "$ebuild")")
  pf=$(basename "$ebuild" .ebuild)
  if [[ "$pf" =~ -r[0-9]+$ ]]; then
    p="${pf%-r*}"
  else
    p="$pf"
  fi
  pv="${p#"${pn}"-}"

  # Grab the SRC_URI="..." block (may span multiple lines) and pull out the
  # first http(s) URL that isn't the ${CARGO_CRATE_URIS} macro expansion —
  # that's the package's own upstream tarball/zip, not a dependency crate.
  raw_url=$(perl -0777 -ne 'print $1 if /SRC_URI="(.*?)"/s' "$ebuild" \
              | grep -Eo 'https?://[^[:space:]]+' \
              | grep -v 'CARGO_CRATE_URIS' \
              | head -1)

  if [ -z "$raw_url" ]; then
    echo -e "${pn}\t${pv}\t${ebuild}\tNO_SRC_URI_FOUND\t0\t0\tunknown\t"
    return
  fi

  # Substitute the handful of ebuild variables that commonly appear in SRC_URI.
  url=$(printf '%s' "$raw_url" | sed -e "s/\${PV}/${pv}/g" -e "s/\${PN}/${pn}/g" -e "s/\${P}/${p}/g" -e "s/\${PF}/${pf}/g")

  # Some ebuilds set S= to point at a specific subdirectory of the extracted
  # archive — e.g. a package that only builds one member of an upstream
  # cargo workspace/monorepo (dev-libs/blazesym_c is a real example: its
  # SRC_URI ships the whole blazesym repo, which also contains an unrelated
  # cli/ binary crate and examples/, but S="${WORKDIR}/.../capi" means only
  # the capi/ library is actually built). Scanning the whole extracted tree
  # in that case would wrongly attribute cli/'s main.rs or examples' dyn
  # usage to this package. So: parse S=, strip it down to the path relative
  # to the archive root (which --strip-components=1 below already peels
  # off), and scope LOC/dyn/is_binary detection to that subdir if present.
  s_line=$(grep -m1 -E '^S=' "$ebuild" 2>/dev/null)
  scan_subdir=""
  if [ -n "$s_line" ]; then
    s_val=$(printf '%s' "$s_line" | sed -E 's/^S="?//; s/"$//' \
              | sed -e "s/\${PV}/${pv}/g" -e "s/\${PN}/${pn}/g" -e "s/\${P}/${p}/g" -e "s/\${PF}/${pf}/g" -e 's#\${WORKDIR}#WORKDIR#g')
    # Drop the WORKDIR segment and the archive's own top-level dir segment
    # (both already collapsed away by --strip-components=1) — whatever's
    # left is the subdir path relative to extract_dir.
    scan_subdir=$(printf '%s' "$s_val" | awk -F'/' '{ if (NF>2) { out=""; for(i=3;i<=NF;i++){out=out (out==""?"":"/") $i}; print out } }')
  fi

  domain=$(printf '%s' "$url" | sed -E 's#https?://([^/]+)/.*#\1#')
  key="${pn}-${pv}"
  extract_dir="${cache_dir}/${key}"

  if [ ! -d "$extract_dir" ]; then
    case "$url" in
      *.tar.gz|*.tgz)  ext="tar.gz" ;;
      *.tar.xz)        ext="tar.xz" ;;
      *.tar.bz2)       ext="tar.bz2" ;;
      *.zip)           ext="zip" ;;
      *)               ext="unknown" ;;
    esac
    archive_file="${cache_dir}/${key}.${ext}"

    if [ ! -f "$archive_file" ]; then
      if ! curl -sfL -o "$archive_file" "$url" 2>/dev/null; then
        rm -f "$archive_file"
        echo -e "${pn}\t${pv}\t${ebuild}\tERROR_DOWNLOAD(${domain})\t0\t0\tunknown\t"
        return
      fi
    fi

    mkdir -p "$extract_dir"
    ok=1
    case "$ext" in
      tar.gz)  tar -xzf "$archive_file" -C "$extract_dir" --strip-components=1 2>/dev/null || ok=0 ;;
      tar.xz)  tar -xJf "$archive_file" -C "$extract_dir" --strip-components=1 2>/dev/null || ok=0 ;;
      tar.bz2) tar -xjf "$archive_file" -C "$extract_dir" --strip-components=1 2>/dev/null || ok=0 ;;
      zip)     unzip -q -d "$extract_dir" "$archive_file" 2>/dev/null || ok=0 ;;
      *)       ok=0 ;;
    esac
    if [ "$ok" -eq 0 ]; then
      echo -e "${pn}\t${pv}\t${ebuild}\tERROR_EXTRACT\t0\t0\tunknown\t"
      return
    fi
  fi

  scan_root="$extract_dir"
  if [ -n "$scan_subdir" ] && [ -d "${extract_dir}/${scan_subdir}" ]; then
    scan_root="${extract_dir}/${scan_subdir}"
  fi

  loc=$(find "$scan_root" -name "*.rs" -not -path "*/vendor/*" -not -path "*/target/*" -print0 2>/dev/null \
          | xargs -0 cat 2>/dev/null | wc -l)

  # Same dyn-dispatch scan as Step 4 (comment-stripped first), but run against
  # this package's own source instead of a dependency crate. This is what
  # answers "does the *top-level binary's own code* use dynamic dispatch",
  # as distinct from "does something it depends on use it".
  own_matches=""
  while IFS= read -r -d '' rsfile; do
    file_hits=$(strip_comments "$rsfile" | grep -nE 'Box<\s*dyn\s|&\s*dyn\s|Rc<\s*dyn\s|Arc<\s*dyn\s|:\s*dyn\s|\bdyn\s+[A-Za-z_]' 2>/dev/null)
    if [ -n "$file_hits" ]; then
      own_matches="${own_matches}$(printf '%s\n' "$file_hits" | sed "s#^#${rsfile}:#")
"
    fi
  done < <(find "$scan_root" -name "*.rs" -not -path "*/vendor/*" -not -path "*/target/*" -print0 2>/dev/null)
  own_dyn_count=$(printf '%s\n' "$own_matches" | grep -c . || true)
  own_dyn_sample=$(printf '%s\n' "$own_matches" | head -3 | tr -d '\r' | tr '\n' '|' | sed -e 's/\t/ /g' -e 's/"//g')

  # Does this package actually produce an executable, or is it a library-only
  # crate? A cargo-eclass ebuild can be either (or both) — the ebuild itself
  # doesn't distinguish them, so check the actual upstream source (scoped to
  # scan_root, so a workspace member Gentoo doesn't build isn't mistaken for
  # part of this package): a binary target shows up as either a src/main.rs
  # / src/bin/*.rs file, or an explicit [[bin]] table in Cargo.toml.
  has_main=$(find "$scan_root" \( -path "*/src/main.rs" -o -path "*/src/bin/*.rs" \) \
               -not -path "*/vendor/*" -not -path "*/target/*" -print -quit 2>/dev/null)
  has_bin_section=$(grep -rlE '^[[:space:]]*\[\[bin\]\]' --include="Cargo.toml" "$scan_root" 2>/dev/null | head -1)
  if [ -n "$has_main" ] || [ -n "$has_bin_section" ]; then
    is_binary="yes"
  else
    is_binary="no"
  fi

  echo -e "${pn}\t${pv}\t${ebuild}\tOK\t${loc}\t${own_dyn_count}\t${is_binary}\t${own_dyn_sample}"
}
export -f fetch_and_count_loc

cp "$ALL_CARGO_EBUILDS_FILE" "$WORK_DIR/unique_ebuilds.txt"
LOC_RESULTS="$WORK_DIR/loc_results.tsv"
xargs -a "$WORK_DIR/unique_ebuilds.txt" -P "$JOBS" -I{} bash -c 'fetch_and_count_loc "$1" "$2"' _ {} "$UPSTREAM_CACHE_DIR" > "$LOC_RESULTS"

# Join with the dyn-dispatch package rollup (if a package has no dependency
# dyn hits at all, it just won't appear in PACKAGES_FILE — treat that as 0/0).
# Own-code hits and is_binary come straight from fetch_and_count_loc above.
{
  while IFS=$'\t' read -r pn pv ebuild status loc own_dyn_count is_binary own_dyn_sample; do
    category=$(basename "$(dirname "$(dirname "$ebuild")")")
    pf=$(basename "$ebuild" .ebuild)
    pkg="${category}/${pf}"
    dyn_row=$(awk -F'\t' -v p="$pkg" '$1==p {print $3"\t"$4; exit}' "$PACKAGES_FILE")
    dep_ncrates=$(echo "$dyn_row" | cut -f1)
    dep_total=$(echo "$dyn_row" | cut -f2)
    [ -z "$dep_ncrates" ] && dep_ncrates=0
    [ -z "$dep_total" ] && dep_total=0
    [ -z "$own_dyn_count" ] && own_dyn_count=0
    combined=$((own_dyn_count + dep_total))
    echo -e "${pkg}\t${loc}\t${is_binary}\t${own_dyn_count}\t${dep_total}\t${combined}\t${dep_ncrates}\t${status}\t${own_dyn_sample}"
  done < "$LOC_RESULTS"
} | sort -t$'\t' -k2,2 -rn > "$SIZE_FILE.body"

if [ "$BINARIES_ONLY" -eq 1 ]; then
  TOTAL_ROWS=$(wc -l < "$SIZE_FILE.body")
  EXCLUDED=$(awk -F'\t' '$3!="yes"' "$SIZE_FILE.body" | wc -l)
  awk -F'\t' '$3=="yes"' "$SIZE_FILE.body" > "$SIZE_FILE.filtered"
  mv "$SIZE_FILE.filtered" "$SIZE_FILE.body"
  log "Filtering to binaries only (-b): excluded $EXCLUDED of $TOTAL_ROWS package(s) that are libraries, or whose upstream source couldn't be fetched to confirm either way."
fi

{ echo -e "package\town_source_loc_rust\tis_binary\town_dyn_hits\tdep_dyn_hits\ttotal_dyn_hits\tdep_distinct_crates_using_dyn\tfetch_status\town_dyn_sample"; cat "$SIZE_FILE.body"; } > "$SIZE_FILE"
rm -f "$SIZE_FILE.body"

FAILED=$(awk -F'\t' 'NR>1 && $8!="OK"' "$SIZE_FILE" | wc -l)
log "Package size ranking (with own-code vs dependency dyn-dispatch split): $SIZE_FILE"
if [ "$FAILED" -gt 0 ]; then
  log "Note: $FAILED package(s) failed to fetch upstream source (unsupported host not in this sandbox's network allowlist, or no parseable SRC_URI). Their own_source_loc, is_binary, and own_dyn_hits are unmeasured, not confirmed-zero/no — see fetch_status column."
fi
log ""
awk -F'\t' 'NR==1{printf "  %-38s %-10s %-9s %-10s %-10s %-8s %s\n", "PACKAGE", "OWN_LOC", "IS_BIN", "OWN_DYN", "DEP_DYN", "TOTAL", "STATUS"; next} {printf "  %-38s %-10s %-9s %-10s %-10s %-8s %s\n", $1, $2, $3, $4, $5, $6, $8}' "$SIZE_FILE" | head -11 >&2
