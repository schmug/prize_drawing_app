#!/bin/bash

# This script is intended mainly for local development using `flask run`.
# Production deployments usually run the app via Gunicorn and systemd.
# In those cases FLASK_ENV should remain unset or be set to `production`.

# Set the target Flask app
export FLASK_APP=app.py

# Enable development conveniences only if FLASK_ENV isn't already defined.
# Developers benefit from auto-reload and debug features by leaving this unset.
if [ -z "$FLASK_ENV" ]; then
    export FLASK_ENV=development
fi

# Initialize the database (creates tables and imports initial data if DB is empty)
flask init-db

# Run the Flask application on port 8080
# The app.py itself is already configured to run on port 8080 with debug=True
flask run --host=0.0.0.0 --port=8080

# For production deployments use a WSGI server like Gunicorn instead of
# running this script. The setup scripts in this project create a systemd
# service that starts Gunicorn with FLASK_ENV=production.

# Alternative using python directly if you prefer (app.py already sets port and debug):
# python app.py
