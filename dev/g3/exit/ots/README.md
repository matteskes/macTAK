# OpenTAKServer for the G3 exit run

`compose.yml` runs OpenTAKServer in VMPal's container engine for the G3
exit run (`../../NOTES.md` §The G3 exit). Start it with
`make g3-exit-servers` (`../servers.sh up`).

These files are not part of the app and nothing here ships in it.

| File | Where it came from |
|---|---|
| `compose.yml` | written for macTAK from OpenTAKServer-Docker's `docker-compose.yml`, cut down to what the exit needs |
| `ots.env` | written for macTAK from OpenTAKServer-Docker's `ots_config.env` |
| `nginx/templates/https-8443.conf.template`, `nginx/templates/https-8446.conf.template`, `nginx/includes/*`, `rabbitmq/*` | copied unchanged from OpenTAKServer-Docker's `ots/configs/` |

OpenTAKServer-Docker is <https://github.com/brian7704/OpenTAKServer-Docker>,
at commit `30aa20b4c9575f338987aa7bd568b0fe9ec258f0`, under GPL-3.0, the
same license as macTAK.
