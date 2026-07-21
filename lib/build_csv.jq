# Input (.): [ {service:string, report:(null|object|array)}, ... ] in column order.
# Args: $date (YYYY/MM/DD), $ver (snyk version string).
# Emits the full CSV (two header rows + one row per vulnerable package).

def csvfield:
  if . == null then ""
  elif type == "string" then
    (if test("[,\"\r\n]") then "\"" + gsub("\""; "\"\"") + "\"" else . end)
  else tostring end;

def csvrow: map(csvfield) | join(",");

# order-preserving dedup
def dedup: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);

# flatten a service entry's report (null | single-project object | multi-project array)
# into a flat list of vulnerability objects
def vulns_of($entry):
  ($entry.report) as $r
  | ( if $r == null then []
      elif ($r|type) == "array" then $r
      else [$r] end )
  | [ .[] | (.vulnerabilities // [])[] ];

def fixed_str:
  if (.fixedIn // [] | length) > 0 then (.fixedIn | join(", ")) else "Not fixed" end;

def urls_of:
  if (.identifiers.CVE // [] | length) > 0 then
    [ .identifiers.CVE[] | "https://cve.mitre.org/cgi-bin/cvename.cgi?name=" + . ]
  elif (.identifiers.GHSA // [] | length) > 0 then
    [ .identifiers.GHSA[] | "https://github.com/advisories/" + . ]
  else [ (.url // "") ] end;

# per-service cell for one package: "<pkg>@<installed>" + optional remediation line
def cell_for($vs; $pkg):
  [ $vs[] | select(.packageName == $pkg) ] as $m
  | if ($m | length) == 0 then null
    else
      ($m[0].version) as $v0
      | ([ $m[] | (.fixedIn // [])[] ] | dedup) as $fixes
      | "\($pkg)@\($v0)"
        + (if ($fixes | length) > 0
           then "\nRemediation Upgrade to \($pkg)@" + ($fixes | join(", "))
           else "" end)
    end;

[ .[] | { service: .service, vulns: vulns_of(.) } ] as $svc
| ( [ $svc[].service ] ) as $order
| ( [ $svc[].vulns[].packageName ] | unique ) as $packages
| ([ "Snyk CLI version " + $ver ]
    + ( [range(0; 2 + ($order|length))] | map(null) )) as $row1
| ([ $date, "Issue", "No Fix Reason" ] + $order) as $row2
| ( [ $row1, $row2 ]
    + ( $packages | map(
        . as $pkg
        | ( [ $svc[].vulns[]
              | select(.packageName == $pkg)
              | . as $v
              | ($v | urls_of) as $us
              | ($v | fixed_str) as $fx
              | $us[]
              | . + "\nFixed in " + $pkg + "@" + $fx
            ] | dedup | join("\n") ) as $issue
        | [ $pkg, $issue, null ] + ( $svc | map( cell_for(.vulns; $pkg) ) )
      ) )
  )
| map(csvrow) | join("\n")