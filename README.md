# FHEM Blink Bridge

Local HTTP bridge for Blink cameras using `blinkpy`, plus a small FHEM module.

The bridge keeps Python packages and Blink OAuth handling outside the FHEM
container. FHEM only talks to a local HTTP endpoint and receives normal readings
for networks, cameras, arm state, and downloaded images.

## Why

The historic FHEM `BlinkCamera` module used Blink login flows that can break
when Blink changes its API. This bridge delegates the current OAuth/PKCE flow to
`blinkpy` and exposes a stable local API to FHEM.

## HTTP API

- `GET /health`
- `GET /state`
- `GET /set?arm=on|off[&network=<name>]`
- `GET /thumbnail?camera=<name-or-id>`
- `GET /snapshot?camera=<name-or-id>`
- `GET /video?camera=<name-or-id>[&since_hours=24]`

`/thumbnail` downloads the existing Blink thumbnail. `/snapshot` asks Blink for
a fresh picture first, refreshes Blink metadata until the thumbnail changes or
`SNAPSHOT_TIMEOUT` is reached, and then downloads the thumbnail.
`/video` downloads the newest available MP4 clip for the camera from the last
24 hours by default.

## Docker Image

The repository publishes a multi-arch image for `linux/amd64` and
`linux/arm64`:

```text
ghcr.io/mrstrategy/fhem-blink-bridge:latest
```

For Raspberry Pi deployments this means you usually do not need to build
anything locally.

## Setup Token File

Create a token file once with `blinkpy` and store it as:

```text
data/blink_login.json
```

The file contains Blink OAuth tokens and must not be committed. Keep it private
and readable only by the bridge user.

One practical setup flow is to run a temporary Python environment, log in with
`blinkpy`, complete 2FA, and save the resulting login file as
`data/blink_login.json`.

## Deployment With Docker

Copy `.env.example` to `.env` and adjust values if needed:

```sh
cp .env.example .env
mkdir -p data
```

Put `blink_login.json` into `data/`, then start the bridge:

```sh
docker compose up -d --build
```

The default `docker-compose.yml` uses the published GHCR image:

```yaml
image: ghcr.io/mrstrategy/fhem-blink-bridge:latest
```

The default HTTP port is `8766`.

### Build The Docker Image Locally

If you want to build on the target machine instead of using GHCR:

```sh
docker compose -f docker-compose.build.yml up -d --build
```

Or manually:

```sh
docker build -t fhem-blink-bridge:0.1.1 .
docker run --rm --network host \
  --env-file .env \
  -v "$PWD/data:/data" \
  fhem-blink-bridge:0.1.1
```

## Deployment Without Docker

Use Python 3.11 or newer.

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install .
cp .env.example .env
mkdir -p data
```

Put `blink_login.json` into `data/`, then run:

```sh
BLINK_DATA_FILE="$PWD/data/blink_login.json" \
HTTP_HOST=0.0.0.0 \
HTTP_PORT=8766 \
fhem-blink-bridge
```

For a permanent non-Docker installation, run the command from a systemd service
and set the same environment variables there.

## FHEM

Copy `fhem/70_BlinkBridge.pm` into your FHEM module directory and reload it.

Example:

```text
define blink.bridge BlinkBridge http://10.0.0.80:8766 60
attr blink.bridge room Sicherheit
attr blink.bridge imagePath /tmp
```

Useful commands:

```text
set blink.bridge arm on
set blink.bridge arm off
get blink.bridge update
get blink.bridge thumbnail AussenVorne
get blink.bridge snapshot AussenVorne
get blink.bridge video AussenVorne
```

For Pushover attachments, keep `imagePath` aligned with the FHEM Pushover
module `storagePath`, commonly `/tmp`.

Snapshot freshness is controlled by:

```text
SNAPSHOT_DELAY=2
SNAPSHOT_TIMEOUT=30
```

The bridge polls every `SNAPSHOT_DELAY` seconds after requesting a snapshot and
waits at most `SNAPSHOT_TIMEOUT` seconds for Blink to publish a new thumbnail.

Example notify for a fresh image:

```text
define blink.pictureUpdate.notify notify blink.bridge:last_image_updated.* { sendCameraPicture();; }
```
