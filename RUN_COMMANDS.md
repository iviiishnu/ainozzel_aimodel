# Run Commands — AI Nozzle

Copy-paste commands for running the project. All commands are **PowerShell**.
For first-time setup (installing Python, JDK, Flutter, config files) see [HOW_TO_RUN.md](HOW_TO_RUN.md).

Project folder:
```
C:\Users\Vishn\Documents\Projects\Ai_server\Ai_nozzel\Ai_Nozzle
```

---

## 1. Start the servers (every time)

Open **two PowerShell windows** and keep both open.

**Window 1: ML server (port 5010)**
```powershell
cd C:\Users\Vishn\Documents\Projects\Ai_server\Ai_nozzel\Ai_Nozzle\ai_service
.\.venv\Scripts\python farm_app.py
```
Ready when it prints `Serving on http://0.0.0.0:5010`.

**Window 2: Spring backend (port 8000)**
```powershell
cd C:\Users\Vishn\Documents\Projects\Ai_server\Ai_nozzel\Ai_Nozzle\spring_backend\spring_backend_fresh\spring_backend
.\mvnw.cmd spring-boot:run
```
Ready when it prints `Tomcat started on port 8000`.

**Check that both work** (in a third window):
```powershell
curl.exe http://localhost:8000/api/crop/health
```
You should see `"status":"ok"`, `"model_loaded":true` and `"num_classes":10`.

To stop a server, press **Ctrl + C** in its window.

---

## 2. Point the tablet at the PC

The PC's IP changes every time the hotspot/WiFi reconnects. Find it:
```powershell
ipconfig | findstr IPv4
```
On the tablet: **⚙ Settings → Backend URL** → `http://<PC-IP>:8000` (e.g. `http://10.103.147.34:8000`) → **Test connections**.

Tip: with **On-device** turned ON in Settings, the app uses the model on the
tablet itself — no PC, no network, about 0.5 s per scan. The servers are then
not needed at all.

**If the tablet can't reach the PC**, allow port 8000 through the Windows
firewall (run once, in PowerShell **as Administrator**):
```powershell
New-NetFirewallRule -DisplayName "AI Nozzle backend 8000" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Any
```

---

## 3. Install / run the app on the tablet (wireless)

Only needed after changing app code or the model. Tablet and PC on the same WiFi.

1. Tablet: **Settings → Developer options → Wireless debugging → ON**.
2. First time only (or if it says "not paired"): tap **Pair device with pairing code**, then:
   ```powershell
   adb pair <IP>:<PAIRING-PORT> <6-DIGIT-CODE>
   ```
3. Connect, using the IP:port shown on the **main** Wireless debugging screen (not the pairing one):
   ```powershell
   adb connect <IP>:<PORT>
   adb devices
   ```
4. Build and run:
   ```powershell
   cd C:\Users\Vishn\Documents\Projects\Ai_server\Ai_nozzel\Ai_Nozzle\flutter_app
   flutter run -d <IP>:<PORT> --dart-define-from-file=config/app_config.json
   ```
   Use the `<IP>:<PORT>` form for `-d`. Flutter can't handle the
   `adb-XXXX (2)._adb-tls-connect._tcp` names that `adb devices` sometimes shows.

`config/app_config.json` → `BACKEND_URL` is only the default for a fresh install;
a URL saved in the app's Settings always wins.

---

## 4. Retrain the model (optional, takes ~5 hours)

Run in its **own** PowerShell window, with the servers stopped and heavy apps
(Chrome etc.) closed — training needs most of the RAM. If it stops, run the
same command again: it resumes from the last finished epoch.
```powershell
cd C:\Users\Vishn\Documents\Projects\Ai_server\Ai_nozzel\Ai_Nozzle\ai_service
$env:PYTHONIOENCODING='utf-8'; .\.venv\Scripts\python -u train_model.py *> train_log_multicrop.txt
```
Check progress from another window:
```powershell
Select-String "val_accuracy" train_log_multicrop.txt | Select-Object -Last 3
```

After training, convert, test on real field photos, and copy into the app:
```powershell
.\.venv\Scripts\python convert_tflite.py --mode float16
.\.venv\Scripts\python -X utf8 eval_field.py
copy models\crop_model_float16.tflite, models\class_names.json, models\ood_stats.json, models\ood_prototypes.bin ..\flutter_app\assets\models\
```
Then restart the ML server and re-run the app (section 3).

`eval_field.py` compares against an older model with
`--model-dir models\backup_pre_multicrop_2026-10-13`.

---

## 5. Push the code, models, and datasets to GitHub

The configured destination is `https://github.com/iviiishnu/Ai_Nozzle.git`.
The local training images and raw datasets are about 3.6 GB, and the model
directory is about 300 MB. Use Git LFS for these assets; make sure your GitHub
account has enough LFS storage and bandwidth. Check the dataset licenses and
attribution before publishing them in this repository.

Run from the project folder in PowerShell:
```powershell
git lfs install
git lfs track "ai_service/images/**" "ai_service/raw_datasets/**" "ai_service/field_test/**" "ai_service/models/**"
git add .gitattributes
git add --renormalize ai_service/images ai_service/raw_datasets ai_service/field_test ai_service/models
git add -A
git add -f ai_service/images ai_service/raw_datasets ai_service/field_test ai_service/models
```

Review what will be sent before committing:
```powershell
git status --short
git lfs ls-files | Select-Object -First 30
git diff --cached --check
git diff --cached --stat
git diff --cached --name-only | Select-String '(^|/)\.env$|(^|/)secrets\.h$|(^|/)app_config\.json$'
```

If the last command lists a real secret or local config file, unstage it before
continuing. `git diff --cached --check` may report pre-existing trailing
whitespace in the pump firmware; review warnings rather than blindly changing
unrelated code. Then commit, reconcile the local and GitHub `main` histories,
and push without force:
```powershell
git commit -m "Update AI nozzle app, models, and datasets"
git fetch origin
git rebase origin/main
git push origin HEAD:main
```

If the rebase reports conflicts, resolve them and run `git add <resolved-file>`
followed by `git rebase --continue`; do not force-push. Git LFS quota or upload
limits can also prevent the data upload, even when the code push is accepted.
