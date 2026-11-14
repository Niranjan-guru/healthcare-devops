# Blue-Green Control Panel (local showcase)

A small local web page for demonstrating Activity 8: **Turn ON Blue** /
**Turn ON Green** buttons, a live view of which environment serves
production, and the status of the Jenkins pipeline.

The panel never changes the cluster itself. Every button runs the
`Healthcare-Blue-Green` Jenkins job, so each switch goes through the same
gates as a release:

1. start the chosen environment with its **recorded verified image**
   (`ACTION=activate`, `TARGET_ENV=blue|green`),
2. wait until it is Ready, check probes, restarts and the version of every pod,
3. smoke-test it through the internal preview Service,
4. switch the production Service selector and verify production,
5. if "Stop the other environment" is ticked (`STOP_PREVIOUS=true`), turn the
   previous environment **OFF** (scale to 0). Rollback can restart it.

## Run

```powershell
cd healthcare-devops\tools\bluegreen-control-panel
python server.py --key ..\..\devops-lab-key.pem
```

Open <http://127.0.0.1:8090/>. The hospital app (production) is available
through the panel's SSH tunnel at <http://127.0.0.1:18060/>.

Requirements: Python 3.9+, Windows OpenSSH (`ssh`, `ssh-keyscan`,
`ssh-keygen`), the Jenkins API token in `%USERPROFILE%\.jenkins-api-token`
(one line `username:token`), and SSH access to the EC2 node.

## Security

* Listens on `127.0.0.1` only; the SSH tunnel also binds to `127.0.0.1`.
* The Jenkins token stays in the server process; it is never sent to the browser.
* POST requests require the per-session token embedded in the page **and** a
  same-origin `Origin` header (other websites cannot trigger builds).
* SSH uses the same pinned host-key fingerprint as the pipelines
  (`StrictHostKeyChecking=yes`).
* The hospital app has no Kubernetes permissions; nothing in production can
  switch traffic.

## What you see

* A large banner coloured **blue** or **green** with the version and pod that
  answered the last request, plus a timeline of the last 30 responses - the
  colour flips at the moment the production Service is switched.
* One card per environment: LIVE / ON (idle) / OFF, ready pods and the
  verified version.
* The latest Jenkins build with a link to its console.
