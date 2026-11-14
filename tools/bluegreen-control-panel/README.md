# Blue-Green Demo Panel (local)

A tiny local page for demonstrating Blue-Green deployment live:

1. Click **Turn ON Blue** → after a few seconds click **Open the website** →
   the page says **"You are on Blue environment"** (blue banner).
2. Click **Turn ON Green** → **Open the website** →
   **"You are on Green environment"** (green banner).

A switch takes about **5–20 seconds** (longer only when the environment
first has to be started from OFF).

## Run

```powershell
cd healthcare-devops\tools\bluegreen-control-panel
python server.py --key ..\..\devops-lab-key.pem
```

* Panel: <http://127.0.0.1:8090/>
* Website (production): <http://127.0.0.1:18060/> – also opened by the
  "Open the website" link. Keep the panel running while you demo; it provides
  the connection to the website.

Requirements: Python 3.9+, Windows OpenSSH, and SSH access to the EC2 node
with your key. No Jenkins token is needed.

## What "Turn ON" does

On the K3s node (over SSH):

1. takes the shared namespace deploy lock (refuses if a Jenkins deployment is running),
2. starts the chosen environment if it is OFF and waits until its pods are Ready,
3. points the production Service `healthcare-service` at it,
4. checks that the website really answers from that environment (otherwise
   switches straight back),
5. turns the other environment OFF (0 pods).

It only switches to a version that previously passed a full release through
the `Healthcare-Blue-Green` Jenkins pipeline (the environment's current image
must equal its recorded verified image). To put a **new** version into an
environment, run that Jenkins job (`ACTION=deploy`) once; the panel then
switches between the released versions instantly.

## Security

* Listens on `127.0.0.1` only; the website tunnel also binds to `127.0.0.1`.
* Buttons work only from this page (per-session token + same-origin check).
* SSH uses the pinned host-key fingerprint (`StrictHostKeyChecking=yes`).
* The website itself has no Kubernetes permissions.
