# DBsync

DBsync is a lightweight PowerShell automation script that **synchronizes a remote PostgreSQL database** to a local development environment.  
It handles every step from remote dump to local restore, migration, and privilege repair — all in one run.

---

## 🚀 Features

- **Secure remote dump** via SSH (`pg_dump` on the remote server)
- **Automatic local restore** using `pg_restore` (atomic, transactional)
- **Runs Django migrations** after restore to keep schema in sync
- **Grants/repairs permissions** for the Django database user
- **Verifies key tables** after import (basic sanity check)
- **Auto-detects PostgreSQL bin path** (works even if not in PATH)
- **Optional cleanup** for remote and local dump files
- **Session-safe PATH injection** (no registry edits, no global pollution)

---

## 🧩 Requirements

- Windows with **PowerShell 5+**  
- **PostgreSQL client tools** (pg_dump, pg_restore, psql) installed locally  
- Access to the remote host via **SSH (key or password)**  
- Optional: Python/Django project with `manage.py` available for migrations  

---

## ⚙️ Configuration

Edit the top of `sync_and_migrate.ps1`:

```powershell
$RemoteUser = "your_remote_user"
$RemoteHost = "your.server.ip"
$RemotePort = 22
$RemoteDb   = "trader_db"

$DbUser = "postgres"
$DbName = "trader_db"
$ProjectRoot = "C:\Path\To\Your\DjangoProject"
```

If you use a Django app with a specific database role, update:
```powershell
$AppRoleFallback = "traderuser"
```

---

## ▶️ Usage

1. Open **PowerShell** and run:
   ```powershell
   cd "C:\Users\<You>\Desktop\DBsync"
   .\sync_and_migrate.ps1
   ```
2. The script will:
   - Create a remote dump on the server
   - Copy it locally via `scp`
   - Drop & recreate your local DB
   - Restore the dump atomically
   - Run Django migrations (if project path is valid)
   - Apply and refresh all database privileges
   - Verify key data and clean up dump files

---

## 🔐 Security Notes

- No passwords are hard-coded.
- You can temporarily set your local DB password via:
  ```powershell
  $env:PGPASSWORD = "your_password"
  ```
- All SSH operations respect your user’s SSH config and keys.
- Dumps are deleted after restore unless `$KeepRemoteDump` or `$KeepLocalDump` are set to `$true`.

---

## 🧱 Example Output

```
== Step 1: create dump on remote (trader_db) ==
== Step 2: scp dump to Windows ==
   Copied to C:\Users\...\pgsync\trader_db_20251017.dump (44.1 MB)
== Step 3: drop & recreate local DB (trader_db) ==
   Local DB recreated.
== Step 4: restore into local DB (atomic) ==
   Restore completed.
== Step 5: run Django migrations (best-effort) ==
   Migrations done.
== Step 7: grant/refresh privileges ==
   Grants refreshed.
== Step 8: quick verify ==
   indicators_n | 12900
   timeintervals_n | 4
Done.
```

---

## 🧰 Troubleshooting

| Problem | Cause | Fix |
|----------|--------|-----|
| `psql.exe not found` | PostgreSQL client not installed or PATH not set | Update `$PgBin` or install PostgreSQL |
| `permission denied for table django_migrations` | App role lacks rights | Fixed automatically in Step 7 |
| SSH fails | wrong port or missing key | Verify `$RemoteUser`, `$RemoteHost`, and `$RemotePort` |

---

## 📄 License

MIT License © 2025 [AMMorsy](https://github.com/AMMorsy)
