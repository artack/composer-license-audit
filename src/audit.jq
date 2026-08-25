# Audit result for composer-license-audit.
#
# Input (stdin):   `composer licenses --format=json` output.
# $allowlist:      array of allowed license identifiers, or null when no allowlist is configured.
# $base:           the PR base composer.lock, slurped (--slurpfile); an empty file means "no base".
#
# Output: one document. Every decision the renderers need is made here, once.
#   allowlist_enabled  bool
#   base_available     bool   (a base lock with at least one package)
#   packages[]         {name, version, licenses[], allowed, is_new}   sorted by name
#   counts[]           {license, count, allowed}                       sorted by -count, license
#   has_violations     bool   (false whenever the allowlist is disabled)
# `allowed` and `is_new` are null when the corresponding input is absent.

def normalize_license($licenses):
  if $licenses == null then ["UNKNOWN"]
  elif ($licenses | type) == "array" then (if ($licenses | length) == 0 then ["UNKNOWN"] else $licenses end)
  else [$licenses]
  end;

def allowlist_enabled: $allowlist != null and ($allowlist | length) > 0;

# Composer treats multiple entries in `license` as a disjunction (the consumer may pick any of
# them), so a package is allowed as soon as one of its licenses is in the allowlist.
def allowed_of($licenses):
  if allowlist_enabled then any($licenses[]; . as $lic | any($allowlist[]; . == $lic)) else null end;

def base_names:
  if ($base | length) == 0 or $base[0] == null then null
  else [ ($base[0].packages // [] | .[].name), ($base[0]["packages-dev"] // [] | .[].name) ]
  end;

base_names as $names
| ($names != null and ($names | length) > 0) as $base_available
| (
    (.dependencies // {})
    | to_entries
    | map({
        name: .key,
        version: (.value.version // "unknown"),
        licenses: normalize_license(.value.license)
      })
    | map(. + {
        allowed: allowed_of(.licenses),
        is_new: (if $base_available then (.name as $n | any($names[]; . == $n) | not) else null end)
      })
    | sort_by(.name)
  ) as $packages
| (
    $packages
    | map(.licenses) | flatten | sort | group_by(.)
    | map({license: .[0], count: length, allowed: allowed_of([.[0]])})
    | sort_by(-.count, .license)
  ) as $counts
| {
    allowlist_enabled: allowlist_enabled,
    base_available: $base_available,
    packages: $packages,
    counts: $counts,
    has_violations: (allowlist_enabled and any($packages[]; .allowed == false))
  }
