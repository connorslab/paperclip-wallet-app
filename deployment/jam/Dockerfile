# Preserve the upstream TLS, Tor, privilege separation and RPC-filter entrypoint.
FROM ghcr.io/kilombino/jam-xbt:0.43.0-xbt7@sha256:f6f4a194a6f20ac56949b02f2a92032bad29dc5e466a4938838951a2960a217d
COPY deployment/jam/paperclip_jam /opt/venv/lib/python3.14/site-packages/paperclip_jam
COPY deployment/jam/install.py /tmp/paperclip-jam-install.py
RUN /opt/venv/bin/python /tmp/paperclip-jam-install.py /opt/venv/lib/python3.14/site-packages/jmwalletd/app.py \
    && /opt/venv/bin/python -c 'from paperclip_jam.api import Prepare; from jmwalletd.app import create_app' \
    && rm /tmp/paperclip-jam-install.py
