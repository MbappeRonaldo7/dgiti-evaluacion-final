# Versión PowerShell (Windows) de check-balancing.sh
# Uso: .\scripts\check-balancing.ps1 -Url http://<alb-dns> -N 20
param(
  [Parameter(Mandatory = $true)][string]$Url,
  [int]$N = 20
)

1..$N | ForEach-Object {
  $r = Invoke-RestMethod "$Url/"
  "$($r.served_by.instance_id) $($r.served_by.availability_zone)"
} | Group-Object | Select-Object Count, Name | Format-Table -AutoSize
