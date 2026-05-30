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

`/thumbnail` downloads the existing Blink thumbnail. `/snapshot` asks Blink for
a fresh picture first, waits briefly, and then downloads the thumbnail.

## Deployment

Create a token file once with `blinkpy` and store it as:

```text
data/blink_login.json
```

Then configure `.env` from `.env.example` and run:

```sh
docker compose up -d --build
```

The default HTTP port is `8766`.

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
```

For Pushover attachments, keep `imagePath` aligned with the FHEM Pushover
module `storagePath`, commonly `/tmp`.

Example notify for a fresh image:

```text
define blink.pictureUpdate.notify notify blink.bridge:last_image_updated.* { sendCameraPicture();; }
```
