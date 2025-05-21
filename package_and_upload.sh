#!/bin/bash

# Script to package the Flask app and prepare for upload and setup/update.

# --- Configuration ---
APP_NAME="nclgisa_drawing_app"
ARCHIVE_NAME="${APP_NAME}.tar.gz"

# Try to load remote user and host from .env.local, with fallbacks
if [ -f .env.local ]; then
    source .env.local
fi

# Require REMOTE_USER and REMOTE_HOST to be provided via environment
# variables or a local .env.local file. No hard-coded defaults.
: "${REMOTE_USER:?REMOTE_USER not set. Define it in the environment or .env.local}"
: "${REMOTE_HOST:?REMOTE_HOST not set. Define it in the environment or .env.local}"

REMOTE_TEMP_UPLOAD_DIR="/tmp"
PROJECT_DIR_ON_SERVER_BASE="/srv"

FILES_TO_ARCHIVE=(
    "app.py"
    "requirements.txt"
    "initial_registrants.csv"
    "templates/"
    "uploads/"
)

REMOTE_FULL_SETUP_SCRIPT_NAME="remote_server_setup.sh"
REMOTE_APP_UPDATE_SCRIPT_NAME="remote_app_update.sh"

echo "--- Starting Packaging and Upload Preparation ---"
echo "Using REMOTE_USER=${REMOTE_USER}, REMOTE_HOST=${REMOTE_HOST}"

echo "Checking for necessary files and directories..."
for item in "${FILES_TO_ARCHIVE[@]}"; do
    if [ ! -e "$item" ]; then
        if [ "$item" == "initial_registrants.csv" ]; then
            echo "WARNING: 'initial_registrants.csv' not found. The app expects this for initial DB population."
            echo "         If this is not the first setup, this might be fine. Otherwise, create or rename your data CSV."
        else
            echo "ERROR: Required file or directory '$item' not found. Aborting."
            exit 1
        fi
    fi
done
echo "All required application files checked."

# --- Generate remote_server_setup.sh (Full Setup) ---
echo "Generating ${REMOTE_FULL_SETUP_SCRIPT_NAME} for full server setup..."
cat << EOF > "${REMOTE_FULL_SETUP_SCRIPT_NAME}"
#!/bin/bash
# Full server setup script for the Flask application.
# Must be run with sudo. Expects hostname as $1.

APP_NAME="nclgisa_drawing_app"
ARCHIVE_NAME="${APP_NAME}.tar.gz"
REMOTE_USER_ON_SERVER="${REMOTE_USER}" # From parent script
PROJECT_HOME_DIR_ON_SERVER="/srv"
PROJECT_DIR_ON_SERVER="${PROJECT_HOME_DIR_ON_SERVER}/${APP_NAME}"
NGINX_GROUP="www-data"
# SERVER_APP_PIN is no longer passed from parent; must be set manually in .env on server
CONFIG_REMOTE_HOST=""

log_action() { echo ""; echo "---- $1 ----"; }

if [ "$(id -u)" -ne 0 ]; then echo "ERROR: Must run with sudo."; exit 1; fi
if [ -z "$1" ]; then echo "ERROR: Hostname argument required."; exit 1; else CONFIG_REMOTE_HOST="$1"; fi

log_action "Starting FULL Server Setup for ${APP_NAME} on ${CONFIG_REMOTE_HOST}"

log_action "Updating packages & installing prerequisites"
apt update -y && apt install -y python3 python3-pip python3-venv nginx build-essential

log_action "Creating project directory: ${PROJECT_DIR_ON_SERVER}"
mkdir -p "${PROJECT_DIR_ON_SERVER}/uploads"
chown -R "${REMOTE_USER_ON_SERVER}:${REMOTE_USER_ON_SERVER}" "${PROJECT_HOME_DIR_ON_SERVER}/${APP_NAME}"

log_action "Extracting application archive from $(pwd)/${ARCHIVE_NAME}"
if [ ! -f "${ARCHIVE_NAME}" ]; then echo "ERROR: Archive ${ARCHIVE_NAME} not found."; exit 1; fi
tar -xzf "${ARCHIVE_NAME}" -C "${PROJECT_DIR_ON_SERVER}"
chown -R "${REMOTE_USER_ON_SERVER}:${REMOTE_USER_ON_SERVER}" "${PROJECT_DIR_ON_SERVER}"

log_action "Setting up Python virtual environment"
sudo -u "${REMOTE_USER_ON_SERVER}" python3 -m venv "${PROJECT_DIR_ON_SERVER}/venv"

log_action "Installing Python dependencies"
sudo -u "${REMOTE_USER_ON_SERVER}" "${PROJECT_DIR_ON_SERVER}/venv/bin/pip" install -r "${PROJECT_DIR_ON_SERVER}/requirements.txt"
sudo -u "${REMOTE_USER_ON_SERVER}" "${PROJECT_DIR_ON_SERVER}/venv/bin/pip" install gunicorn

log_action "Generating .env file. IMPORTANT: You MUST manually set DRAWING_APP_PIN in this file!"
FLASK_SECRET_KEY_VALUE=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
ENV_FILE_PATH="${PROJECT_DIR_ON_SERVER}/.env"
cat << EOTENV > "${ENV_FILE_PATH}"
FLASK_APP=app.py
FLASK_ENV=production
FLASK_SECRET_KEY=${FLASK_SECRET_KEY_VALUE}
# IMPORTANT: Set your production PIN here manually after script runs!
DRAWING_APP_PIN="# YOUR_PRODUCTION_PIN_HERE (e.g., 000000)"
EOTENV
chown "${REMOTE_USER_ON_SERVER}:${REMOTE_USER_ON_SERVER}" "${ENV_FILE_PATH}" && chmod 600 "${ENV_FILE_PATH}"
echo "IMPORTANT: .env file created. Please edit ${ENV_FILE_PATH} and set DRAWING_APP_PIN to your production PIN."

log_action "Initializing database (will use default PIN from app.py if DRAWING_APP_PIN not yet set in .env)"
sudo -u "${REMOTE_USER_ON_SERVER}" bash -c "cd ${PROJECT_DIR_ON_SERVER} && set -a && source .env && set +a && ./venv/bin/flask init-db"

log_action "Configuring Gunicorn systemd service: ${APP_NAME}.service"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
cat << EOTSYSTEMD > "${SYSTEMD_SERVICE_FILE}"
[Unit]
Description=Gunicorn instance for ${APP_NAME}
After=network.target

[Service]
User=${REMOTE_USER_ON_SERVER}
Group=${NGINX_GROUP}
WorkingDirectory=${PROJECT_DIR_ON_SERVER}
EnvironmentFile=${PROJECT_DIR_ON_SERVER}/.env
ExecStart=${PROJECT_DIR_ON_SERVER}/venv/bin/gunicorn --workers 3 --bind unix:${APP_NAME}.sock -m 007 app:app

[Install]
WantedBy=multi-user.target
EOTSYSTEMD
systemctl stop "${APP_NAME}" >/dev/null 2>&1
systemctl daemon-reload && systemctl start "${APP_NAME}"
if systemctl is-active --quiet "${APP_NAME}"; then echo "Service ${APP_NAME} started."; systemctl enable "${APP_NAME}"; else echo "ERROR: Service ${APP_NAME} failed."; fi

log_action "Configuring Nginx site: ${APP_NAME}"
NGINX_CONF_FILE="/etc/nginx/sites-available/${APP_NAME}"
cat << EOTNGINX > "${NGINX_CONF_FILE}"
server {
    listen 80;
    server_name ${CONFIG_REMOTE_HOST};
    location / {
        include proxy_params;
        proxy_pass http://unix:${PROJECT_DIR_ON_SERVER}/${APP_NAME}.sock;
    }
}
EOTNGINX
if [ -L "/etc/nginx/sites-enabled/${APP_NAME}" ]; then rm "/etc/nginx/sites-enabled/${APP_NAME}"; fi
ln -s "${NGINX_CONF_FILE}" "/etc/nginx/sites-enabled/"
if [ -L "/etc/nginx/sites-enabled/default" ] && [ -e "/etc/nginx/sites-enabled/default" ]; then rm /etc/nginx/sites-enabled/default; echo "Removed default Nginx site."; fi
nginx -t && systemctl restart nginx || echo "ERROR: Nginx config error or restart failed."

log_action "Full Setup Script Finished. IMPORTANT: Manually verify/set DRAWING_APP_PIN in ${ENV_FILE_PATH} then restart the service: sudo systemctl restart ${APP_NAME}"
log_action "Access at http://${CONFIG_REMOTE_HOST}"
EOF
chmod +x "${REMOTE_FULL_SETUP_SCRIPT_NAME}"
echo "${REMOTE_FULL_SETUP_SCRIPT_NAME} generated."


# --- Generate remote_app_update.sh (App Update Only) ---
echo "Generating ${REMOTE_APP_UPDATE_SCRIPT_NAME} for application updates..."
cat << EOF > "${REMOTE_APP_UPDATE_SCRIPT_NAME}"
#!/bin/bash
# Application update script for the Flask app.
# Assumes initial setup (Python, venv, Gunicorn service, Nginx, .env file) is done.
# Must be run with sudo.

APP_NAME="nclgisa_drawing_app"
ARCHIVE_NAME="${APP_NAME}.tar.gz"
REMOTE_USER_ON_SERVER="${REMOTE_USER}" # Needs to match user in systemd service
PROJECT_HOME_DIR_ON_SERVER="/srv"
PROJECT_DIR_ON_SERVER="${PROJECT_HOME_DIR_ON_SERVER}/${APP_NAME}"

log_action() { echo ""; echo "---- $1 ----"; }

if [ "$(id -u)" -ne 0 ]; then echo "ERROR: Must run with sudo."; exit 1; fi

log_action "Starting Application Update for ${APP_NAME}"

if [ ! -d "${PROJECT_DIR_ON_SERVER}/venv" ]; then
    echo "ERROR: Virtual environment not found at ${PROJECT_DIR_ON_SERVER}/venv. Run full setup first."
    exit 1
fi
if [ ! -f "${PROJECT_DIR_ON_SERVER}/.env" ]; then
    echo "ERROR: .env file not found at ${PROJECT_DIR_ON_SERVER}/.env. Run full setup first."
    exit 1
fi

log_action "Stopping Gunicorn service: ${APP_NAME}.service"
systemctl stop "${APP_NAME}"

log_action "Extracting new application archive from $(pwd)/${ARCHIVE_NAME}"
if [ ! -f "${ARCHIVE_NAME}" ]; then echo "ERROR: Archive ${ARCHIVE_NAME} not found."; exit 1; fi

log_action "Removing old application files (app.py, templates, initial_registrants.csv, requirements.txt)..."
rm -f "${PROJECT_DIR_ON_SERVER}/app.py"
rm -rf "${PROJECT_DIR_ON_SERVER}/templates"
rm -f "${PROJECT_DIR_ON_SERVER}/initial_registrants.csv"
rm -f "${PROJECT_DIR_ON_SERVER}/requirements.txt"

# Extract specific files to overwrite, strip leading components if tarball has them (ours doesn't based on current FILES_TO_ARCHIVE)
tar -xzf "${ARCHIVE_NAME}" -C "${PROJECT_DIR_ON_SERVER}" app.py templates/ initial_registrants.csv requirements.txt

# Ensure ownership is correct for newly extracted files
chown -R "${REMOTE_USER_ON_SERVER}:${REMOTE_USER_ON_SERVER}" "${PROJECT_DIR_ON_SERVER}/app.py" \
    "${PROJECT_DIR_ON_SERVER}/templates" \
    "${PROJECT_DIR_ON_SERVER}/initial_registrants.csv" \
    "${PROJECT_DIR_ON_SERVER}/requirements.txt"

log_action "Installing/updating Python dependencies (if any changed)"
sudo -u "${REMOTE_USER_ON_SERVER}" "${PROJECT_DIR_ON_SERVER}/venv/bin/pip" install -r "${PROJECT_DIR_ON_SERVER}/requirements.txt"

log_action "Restarting Gunicorn service: ${APP_NAME}.service"
systemctl start "${APP_NAME}"
if systemctl is-active --quiet "${APP_NAME}"; then
    echo "Service ${APP_NAME} restarted successfully."
else
    echo "ERROR: Service ${APP_NAME} failed to restart. Check 'systemctl status ${APP_NAME}' and 'journalctl -u ${APP_NAME}'."
fi

log_action "Application Update Script Finished."
EOF
chmod +x "${REMOTE_APP_UPDATE_SCRIPT_NAME}"
echo "${REMOTE_APP_UPDATE_SCRIPT_NAME} generated."


# --- Create application archive ---
echo "Creating application archive: ${ARCHIVE_NAME}..."
# Ensure initial_registrants.csv is included if it exists, otherwise tar might warn/fail depending on settings.
if [ -f "initial_registrants.csv" ]; then
    tar -czvf "${ARCHIVE_NAME}" "${FILES_TO_ARCHIVE[@]}"
else
    # Create archive without initial_registrants.csv if it doesn't exist
    # This assumes it's okay for it not to be in the tarball for an update if it's not present locally
    TEMP_FILES_TO_ARCHIVE=("${FILES_TO_ARCHIVE[@]/initial_registrants.csv}")
    tar -czvf "${ARCHIVE_NAME}" "${TEMP_FILES_TO_ARCHIVE[@]}"
fi
if [ $? -ne 0 ]; then echo "ERROR: Failed to create archive ${ARCHIVE_NAME}. Aborting."; exit 1; fi
echo "Archive ${ARCHIVE_NAME} created successfully."


# --- Display SCP and SSH commands ---
echo ""
log_action "--- Next Steps: Manual Execution Required ---"
echo "1. Ensure your intended initial data CSV is named 'initial_registrants.csv' in your project root if this is a first-time setup."
echo "2. Upload the archive and the desired script to your server's temporary directory:"
echo "   For INITIAL SETUP (or full re-setup):"
echo "     scp \"${ARCHIVE_NAME}\" \"${REMOTE_FULL_SETUP_SCRIPT_NAME}\" ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_TEMP_UPLOAD_DIR}/"
echo "   Then SSH and run: cd ${REMOTE_TEMP_UPLOAD_DIR} && sudo ./${REMOTE_FULL_SETUP_SCRIPT_NAME} ${REMOTE_HOST}"
echo "   IMPORTANT: After initial setup, manually edit /srv/${APP_NAME}/.env to set your DRAWING_APP_PIN."

echo ""
echo "   For APP CODE UPDATE ONLY (after initial setup and .env configuration are complete):"
echo "     scp \"${ARCHIVE_NAME}\" \"${REMOTE_APP_UPDATE_SCRIPT_NAME}\" ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_TEMP_UPLOAD_DIR}/"
echo "   Then SSH and run: cd ${REMOTE_TEMP_UPLOAD_DIR} && sudo ./${REMOTE_APP_UPDATE_SCRIPT_NAME}"
echo ""
echo "--- End of Local Script ---" 