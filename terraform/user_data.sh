#!/bin/bash
# ---------------------------------------------------------------------------
# user_data.sh - Se ejecuta al arrancar cada instancia del Auto Scaling Group.
# Instala Python, copia la aplicación y la deja corriendo con gunicorn (systemd).
# Terraform reemplaza las variables con templatefile().
# ---------------------------------------------------------------------------
set -euxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

dnf install -y python3 python3-pip

mkdir -p /opt/app
echo "${app_py_b64}" | base64 -d > /opt/app/app.py
echo "${requirements_b64}" | base64 -d > /opt/app/requirements.txt
python3 -m pip install -r /opt/app/requirements.txt

# Variables de entorno de la app (archivo legible solo por root)
cat > /etc/dgiti-app.env <<EOF
APP_VERSION=${app_version}
DB_HOST=${db_host}
DB_REPLICA_HOST=${db_replica_host}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
EOF
chmod 600 /etc/dgiti-app.env

cat > /etc/systemd/system/dgiti-app.service <<EOF
[Unit]
Description=DGITI API (Flask + gunicorn)
After=network-online.target

[Service]
WorkingDirectory=/opt/app
EnvironmentFile=/etc/dgiti-app.env
ExecStart=/usr/local/bin/gunicorn --workers 2 --threads 4 --bind 0.0.0.0:${app_port} --access-logfile - app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dgiti-app
