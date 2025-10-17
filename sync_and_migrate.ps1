# ====================================================================
#  Sync remote Postgres -> local, run migrations, grant privileges,
#  verify, and CLEANUP dumps on both sides.
# ====================================================================

# -------------------- CONFIG --------------------
# 🔧 CHANGE ME: remote SSH user (on the server that hosts Postgres)
$RemoteUser = "<remote_ssh_user>"            # e.g., "ubuntu" or "postgres"

# 🔧 CHANGE ME: remote server IP / hostname (where the remote DB lives)
$RemoteHost = "<remote_host_or_ip>"          # e.g., "203.0.113.10"

# 🔧 CHANGE ME: SSH port for that server
$RemotePort = 22                             # usually 22

# 🔧 CHANGE ME: remote PostgreSQL database name (to dump from)
$RemoteDb   = "<remote_db_name>"             # e.g., "new_db"

# 🔧 CHANGE ME (optional): local Postgres bin folder (psql/pg_restore/createdb)
# If you installed PostgreSQL 17 in default path, this is correct. Otherwise update.
$PgBin  = "C:\Program Files\PostgreSQL\17\bin"

# 🔧 CHANGE ME: local Postgres superuser (the owner we use for recreate/restore)
$DbUser = "postgres"                         # e.g., "postgres"

# 🔧 CHANGE ME: local database name to DROP + RECREATE + RESTORE INTO
$DbName = "<local_db_name>"                  # e.g., "new_db"

# 🔧 CHANGE ME: local Django project folder (only if you want migrations run)
$ProjectRoot = "C:\Users\<YourUser>\Desktop\<project_name>"  # e.g., C:\Users\Mody\Desktop\Trader
$Python      = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
$ManagePy    = Join-Path $ProjectRoot "manage.py"

# Which Django DB user should have privileges locally.
# If empty, we try to auto-detect from Django settings; if that fails,
# we fall back to this default:
# 🔧 CHANGE ME: the DB role your Django app uses locally (if auto-detect fails)
$AppRoleFallback = "<app_db_user>"           # e.g., "newuser"

# Keep dumps? (set to $true if you want to keep either)
$KeepRemoteDump = $false
$KeepLocalDump  = $false

# Optional: avoid local password prompts for postgres superuser
# 🔐 If needed: uncomment and set your local postgres password temporarily for this session
# $env:PGPASSWORD = "YOUR_LOCAL_POSTGRES_PASSWORD"

$LocalDir = "$env:USERPROFILE\Downloads\pgsync"
New-Item -ItemType Directory -Force $LocalDir | Out-Null

$stamp      = Get-Date -Format yyyyMMdd_HHmmss
$RemoteDump = "/tmp/${RemoteDb}_$stamp.dump"
$LocalDump  = Join-Path $LocalDir (Split-Path $RemoteDump -Leaf)

$ErrorActionPreference = "Stop"
# ------------------------------------------------

Write-Host "== Step 0: tool versions ==" -ForegroundColor Cyan
& "$PgBin\psql.exe" --version | Write-Host
& "$PgBin\pg_restore.exe" --version | Write-Host

Write-Host "`n== Step 1: create dump on remote ($RemoteDb) ==" -ForegroundColor Cyan
$remoteCmd = "sudo -H -u postgres bash -lc 'set -euo pipefail; " +
             "pg_dump -Fc --no-owner --no-privileges -d $RemoteDb -f $RemoteDump; " +
             "chmod 0644 $RemoteDump; ls -lh $RemoteDump'"
ssh -tt -o StrictHostKeyChecking=accept-new -p $RemotePort "$RemoteUser@$RemoteHost" $remoteCmd

Write-Host "`n== Step 2: scp dump to Windows ==" -ForegroundColor Cyan
# IMPORTANT: use $() around variables so PowerShell doesn't mis-parse the colon
scp -P $RemotePort "$($RemoteUser)@$($RemoteHost):$RemoteDump" "$LocalDump"
if (-not (Test-Path $LocalDump)) { throw "SCP failed: $LocalDump not found." }
$localFile = Get-Item $LocalDump
Write-Host ("   Copied to {0} ({1:N1} MB)" -f $localFile.FullName, ($localFile.Length/1MB))

Write-Host "`n== Step 3: drop & recreate local DB ($DbName) ==" -ForegroundColor Cyan
& "$PgBin\psql.exe" -h localhost -U $DbUser -d postgres -w `
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DbName' AND pid <> pg_backend_pid();" | Out-Null
& "$PgBin\dropdb.exe"   -h localhost -U $DbUser --if-exists $DbName 2>$null
& "$PgBin\createdb.exe" -h localhost -U $DbUser -O $DbUser $DbName
Write-Host "   Local DB recreated."

Write-Host "`n== Step 4: restore into local DB (atomic) ==" -ForegroundColor Cyan
& "$PgBin\pg_restore.exe" -h localhost -U $DbUser -d $DbName -w `
  --no-owner --role=$DbUser `
  --clean --if-exists `
  --single-transaction `
  "$LocalDump"
Write-Host "   Restore completed."

Write-Host "`n== Step 5: run Django migrations (best-effort) ==" -ForegroundColor Cyan
$ranMigrations = $false
try {
  Push-Location $ProjectRoot
  & $Python $ManagePy showmigrations --plan
  & $Python $ManagePy migrate --noinput
  $ranMigrations = $true
} catch {
  Write-Warning "Migrations skipped (error: $($_.Exception.Message)). Continuing."
} finally {
  Pop-Location
}
if ($ranMigrations) { Write-Host "   Migrations done." } else { Write-Host "   Migrations skipped." }

Write-Host "`n== Step 6: determine app DB user (role) ==" -ForegroundColor Cyan
$AppRole = $null
try {
  $AppRole = (& $Python $ManagePy shell -c "from django.db import connection; print(connection.settings_dict['USER'])").Trim()
} catch {
  Write-Warning "Could not auto-detect app role from Django. Falling back to '$AppRoleFallback'."
}
if ([string]::IsNullOrWhiteSpace($AppRole)) { $AppRole = $AppRoleFallback }
Write-Host "   App role: $AppRole"

Write-Host "`n== Step 7: grant/refresh privileges for '$AppRole' ==" -ForegroundColor Cyan
& "$PgBin\psql.exe" -h localhost -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -w `
  -c "GRANT CONNECT ON DATABASE $DbName TO $AppRole;"
& "$PgBin\psql.exe" -h localhost -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -w `
  -c "GRANT USAGE ON SCHEMA public TO $AppRole;"
& "$PgBin\psql.exe" -h localhost -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -w `
  -c "GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO $AppRole;"
& "$PgBin\psql.exe" -h localhost -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -w `
  -c "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO $AppRole;"
& "$PgBin\psql.exe" -h localhost -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -w `
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO $AppRole;"
& "$PgBin\psql.exe" -h localhost -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -w `
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO $AppRole;"
Write-Host "   Grants refreshed."

Write-Host "`n== Step 8: quick verify ==" -ForegroundColor Cyan
& "$PgBin\psql.exe" -h localhost -U $DbUser -d $DbName -w `
  -c "SELECT COUNT(*) AS indicators_n FROM indicators_indicator;" `
  -c "SELECT COUNT(*) AS timeintervals_n FROM core_timeinterval;" `
  -c "SELECT id, name FROM core_strategy ORDER BY id LIMIT 10;"

Write-Host "`n== Step 9: cleanup dumps ==" -ForegroundColor Cyan
# Remote cleanup
try {
  if (-not $KeepRemoteDump) {
    ssh -o StrictHostKeyChecking=accept-new -p $RemotePort "$RemoteUser@$RemoteHost" "sudo rm -f $RemoteDump"
    Write-Host "   Remote dump deleted: $RemoteDump"
  } else {
    Write-Host "   Remote dump kept:    $RemoteDump"
  }
} catch {
  Write-Warning "Remote cleanup failed: $($_.Exception.Message)"
}

# Local cleanup
try {
  if ((-not $KeepLocalDump) -and (Test-Path $LocalDump)) {
    Remove-Item -Force $LocalDump
    Write-Host "   Local dump deleted:  $LocalDump"
  } else {
    Write-Host "   Local dump kept:     $LocalDump"
  }
} catch {
  Write-Warning "Local cleanup failed: $($_.Exception.Message)"
}

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Remote path: $RemoteDump"
Write-Host "Local path:  $LocalDump"
